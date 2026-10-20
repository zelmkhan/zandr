// Sending SOL and tokens. A transfer is planned from the chain as it is now and checked (amount,
// fees, what the recipient really is) and test-run by the node before anything is signed.
// Submitting plans it all over again, so what gets signed is never staler than what the user
// confirmed. A sent transfer is then followed until it lands, and sent again meanwhile.
// Background only.
import { base58, base64 } from '@scure/base';
import { lookalike } from '@/lib/addressBook';
import { getApi, rpcEndpoints } from '@/lib/api';
import { refreshExchangeTokens } from '@/lib/exchangeTokens';
import type { ResponseMap, SendCheck, SendCheckId, SendFailure, SendIntent, SendNote, SendReview } from '@/lib/messages';
import { loadPreferences } from '@/lib/preferences';
import { signMessage } from '@/lib/secrets';
import { trackSent } from '@/lib/sent';
import {
  SYSTEM_PROGRAM,
  TOKEN_2022_PROGRAM,
  TOKEN_PROGRAM,
  associatedTokenAddress,
  decodeAddress,
  isOnCurve,
} from '@/lib/solana/addresses';
import { ChainError, getAccounts, parsedOf, rpc, type ParsedAccount } from '@/lib/solana/rpc';
import {
  compileMessage,
  createTokenAccount,
  serializeTransaction,
  setComputeUnitLimit,
  setComputeUnitPrice,
  transferSol,
  transferTokens,
  type Instruction,
} from '@/lib/solana/transaction';
import { LockedError, getSession, getWallets, readAddressBook, withActiveWallet } from '@/lib/vault';
import { formatUnits, parseUnits } from '@/lib/units';
import type { Network, TransferCheck } from '@/server/api';

// Lamports per signature.
const BASE_FEE = 5_000n;
// A SOL transfer needs about 450 compute units, its compute budget instructions included.
const SOL_UNITS = 600;
// The limit for the test run that measures a token transfer.
const SIMULATION_UNITS = 400_000;
// The size of a token account, about: Token-2022 ones run a few bytes over.
const TOKEN_ACCOUNT_SIZE = 170;
// The priority fee offered, in micro-lamports per compute unit, stays within these.
const MIN_PRICE = 1_000n;
const MAX_PRICE = 5_000_000n;

class SendError extends Error {
  readonly failure: SendFailure;

  constructor(failure: SendFailure) {
    super(failure.reason);
    this.failure = failure;
  }
}

function fail(failure: SendFailure): never {
  throw new SendError(failure);
}

const sol = (lamports: bigint) => formatUnits(lamports, 9);

// The least a system account may hold (other than nothing) and about what opening a token
// account costs. They change rarely: asked once an hour per endpoint.
const minimums = new Map<string, { at: number; system: bigint; tokenAccount: bigint }>();

async function rentMinimums(url: string) {
  const known = minimums.get(url);
  if (known && Date.now() - known.at < 60 * 60 * 1000) return known;
  const [system, tokenAccount] = await Promise.all([
    rpc<number>(url, 'getMinimumBalanceForRentExemption', [0]),
    rpc<number>(url, 'getMinimumBalanceForRentExemption', [TOKEN_ACCOUNT_SIZE]),
  ]);
  const fresh = { at: Date.now(), system: BigInt(system), tokenAccount: BigInt(tokenAccount) };
  minimums.set(url, fresh);
  return fresh;
}

function feeFor(units: number, price: bigint): bigint {
  return BASE_FEE + (price * BigInt(units) + 999_999n) / 1_000_000n;
}

// What recent transactions touching these accounts paid per compute unit, the median of those
// that paid anything, within bounds: enough to land soon without overpaying.
function priorityPrice(fees: { prioritizationFee: number }[]): bigint {
  const paid = fees
    .map((fee) => BigInt(fee.prioritizationFee))
    .filter((fee) => fee > 0n)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const median = paid[Math.floor(paid.length / 2)] ?? 0n;
  return median < MIN_PRICE ? MIN_PRICE : median > MAX_PRICE ? MAX_PRICE : median;
}

type Simulation = {
  err: unknown;
  logs: string[] | null;
  unitsConsumed?: number;
  accounts?: ({ lamports: number } | null)[] | null;
};

// A test run of the transfer by the node, unsigned, against the latest state. `accounts` come back
// as they'd be afterwards.
async function simulate(url: string, from: string, instructions: Instruction[], accounts: string[] = []): Promise<Simulation> {
  const message = compileMessage(from, instructions, base58.encode(new Uint8Array(32)));
  const wire = base64.encode(serializeTransaction(message, [new Uint8Array(64)]));
  const config = { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed' };
  const { value } = await rpc<{ value: Simulation }>(url, 'simulateTransaction', [
    wire,
    accounts.length ? { ...config, accounts: { addresses: accounts, encoding: 'base64' } } : config,
  ]);
  return value;
}

function lacksSol(simulation: Simulation): boolean {
  return (
    /InsufficientFundsForFee|InsufficientFundsForRent|AccountNotFound/.test(JSON.stringify(simulation.err)) ||
    (simulation.logs ?? []).some((line) => /insufficient lamports/i.test(line))
  );
}

// Why a test run failed, in the words of the program that refused it if it said, else the error.
function whyFailed(simulation: Simulation): string {
  const said = (simulation.logs ?? []).findLast((line) => /^Program log: (Error: )?/.test(line) && !/^Program log: Instruction:/.test(line));
  return (said?.replace(/^Program log: (Error: )?/, '') ?? JSON.stringify(simulation.err)).slice(0, 200);
}

type Plan = {
  review: SendReview;
  url: string;
  instructions: Instruction[];
  units: number;
  price: bigint;
  blockhash: string;
  lastValidBlockHeight: number;
};

// How long a transfer waits to learn whether the recipient is an exchange's. Without an answer by
// then it goes on unchecked for that, as when zandr's server or the node is down.
const EXCHANGE_WAIT_MS = 12_000;

const within = <T>(promise: Promise<T>, ms: number): Promise<T | null> =>
  Promise.race([promise, new Promise<null>((resolve) => setTimeout(() => resolve(null), ms))]);

// A missing list is fetched again at a transfer at most this often.
const LIST_RETRY_MS = 10 * 60 * 1000;

// The recipient as it's typed in: whether it's an exchange's is worked out now (and remembered), so
// the review has the answer at once. Nothing is checked or shown yet.
export async function inspectRecipient(to: string): Promise<void> {
  const preferences = await loadPreferences();
  if (preferences.network !== 'mainnet' || !preferences.protection.exchangeSupport || !decodeAddress(to)) return;
  getApi(preferences)
    .getTransferCheck({ network: 'mainnet', to, mint: null })
    .catch(() => {});
}

// Everything about the transfer, checked, short of signing it. `maxFee` caps the priority fee,
// at submit time, to the fee the user saw.
async function plan(intent: SendIntent, maxFee: bigint | null): Promise<Plan> {
  // Sending counts as activity: this reads the session the way a user action does.
  const account = await getSession();
  if (!account) throw new LockedError();
  const from = account.address;
  if (intent.from !== from) fail({ reason: 'wallet-changed' });

  const to = intent.to.trim();
  const toBytes = decodeAddress(to);
  if (!toBytes) fail({ reason: 'invalid-address' });
  if (to === from) fail({ reason: 'own-address' });
  const { mint } = intent;
  if (mint !== null && !decodeAddress(mint)) fail({ reason: 'no-coin' });

  const preferences = await loadPreferences();
  const { network } = preferences;
  const url = rpcEndpoints(preferences)[network];

  // Whether the recipient is an exchange's, and what the exchange's list says of the token: looked
  // up while the chain is read below (and started already as the address was typed: inspectRecipient).
  // An exchange this install has no list for gets the lists fetched fresh from zandr's server, in
  // case they're newer than this install's. "unknown": no answer in time. Mainnet only: exchanges
  // aren't on devnet.
  const atExchange = (async (): Promise<TransferCheck | 'unknown' | null> => {
    if (network !== 'mainnet' || !preferences.protection.exchangeSupport) return null;
    const api = getApi(preferences);
    const found = await within(api.getTransferCheck({ network, to, mint }), EXCHANGE_WAIT_MS).catch(() => null);
    if (found === null) return 'unknown';
    if (found.exchange && found.kind === 'deposit' && found.listed === null && (await refreshExchangeTokens(LIST_RETRY_MS))) {
      return api.getTransferCheck({ network, to, mint }).catch(() => found);
    }
    return found;
  })();

  // The recipient's usual account for the token, under either token program: which one applies
  // shows once the mint is read, so both are read along.
  const recipientUsual = mint ? [associatedTokenAddress(to, mint, TOKEN_PROGRAM), associatedTokenAddress(to, mint, TOKEN_2022_PROGRAM)] : [];

  // The chain as it is now, read in one go.
  const [[recipient = null, sender = null, mintAccount = null, ...recipientUsualAccounts], latest, { system: minimum, tokenAccount: accountRent }, held, fees] = await Promise.all([
    getAccounts(url, mint ? [to, from, mint, ...recipientUsual] : [to, from]),
    rpc<{ value: { blockhash: string; lastValidBlockHeight: number } }>(url, 'getLatestBlockhash', [{ commitment: 'confirmed' }]),
    rentMinimums(url),
    mint
      ? rpc<{ value: { pubkey: string; account: ParsedAccount }[] }>(url, 'getTokenAccountsByOwner', [
          from,
          { mint },
          { encoding: 'jsonParsed', commitment: 'confirmed' },
        ]).then((result) => result.value)
      : Promise.resolve([]),
    rpc<{ prioritizationFee: number }[]>(url, 'getRecentPrioritizationFees', [[from, to]]),
  ]);
  const balance = BigInt(sender?.lamports ?? 0);

  // What the recipient really is.
  const checks: SendCheck[] = [];
  const parsed = parsedOf(recipient);
  const tokenOwned = recipient?.owner === TOKEN_PROGRAM || recipient?.owner === TOKEN_2022_PROGRAM;
  // A token account for the very token being sent: the transfer goes straight into it, as meant.
  const intoTokenAccount = mint !== null && tokenOwned && parsed?.type === 'account' && parsed.info?.mint === mint;
  if (recipient?.executable) checks.push({ id: 'program', kind: 'program' });
  else if (tokenOwned && parsed?.type === 'mint') checks.push({ id: 'mint', token: null });
  else if (tokenOwned && parsed?.type === 'account') {
    if (!intoTokenAccount) checks.push({ id: 'tokenAccount', owner: String(parsed.info?.owner ?? '') });
  } else if (recipient && recipient.owner !== SYSTEM_PROGRAM) checks.push({ id: 'program', kind: 'owned' });
  else if (!isOnCurve(toBytes)) checks.push({ id: 'program', kind: 'derived' });

  // Who the recipient is to the user: a saved address, one of their wallets, or a lookalike of one.
  const contacts = await readAddressBook().catch(() => []);
  const known = [...contacts, ...((await getWallets())?.wallets ?? [])];
  const contact = known.find((entry) => entry.address === to)?.name ?? null;
  const similar = contact === null ? known.find((entry) => lookalike(entry.address, to)) : undefined;
  if (similar) checks.push({ id: 'lookalike', name: similar.name, address: similar.address });

  // The priority fee to offer, no more than leaves the total within `maxFee`.
  const priceFor = (units: number) => {
    const price = priorityPrice(fees);
    if (maxFee === null) return price;
    const cap = maxFee > BASE_FEE ? ((maxFee - BASE_FEE) * 1_000_000n) / BigInt(units) : 0n;
    return price < cap ? price : cap;
  };

  let coin: SendReview['coin'];
  let amount: bigint;
  let instructions: Instruction[];
  let units: number;
  let price: bigint;
  let rent: bigint | null = null;

  if (mint === null) {
    coin = { mint: null, symbol: 'SOL', name: 'Solana', logo: null, decimals: 9 };
    units = SOL_UNITS;
    price = priceFor(units);
    const fee = feeFor(units, price);

    const requested = intent.amount === 'max' ? balance - fee : parseUnits(intent.amount, 9);
    if (requested === null || (requested <= 0n && intent.amount !== 'max')) fail({ reason: 'invalid-amount' });
    amount = requested;
    if (amount <= 0n || (amount <= balance && amount + fee > balance)) fail({ reason: 'insufficient-sol', needed: sol(fee) });
    if (amount > balance) fail({ reason: 'insufficient' });
    const leftover = balance - amount - fee;
    if (leftover > 0n && leftover < minimum) fail({ reason: 'below-minimum', minimum: sol(minimum), leftover: true });
    if (!recipient && amount < minimum) fail({ reason: 'below-minimum', minimum: sol(minimum), leftover: false });

    instructions = [transferSol(from, to, amount)];
    // The very transaction to be sent, priority fee included: with "max", one lamport off in the
    // fee would leave dust the network refuses.
    const simulation = await simulate(url, from, [setComputeUnitLimit(units), setComputeUnitPrice(price), ...instructions]);
    if (simulation.err) fail({ reason: 'simulation', detail: whyFailed(simulation) });
  } else {
    const mintInfo = parsedOf(mintAccount)?.info;
    const tokenProgram = mintAccount?.owner;
    if (!mintInfo || parsedOf(mintAccount)?.type !== 'mint' || (tokenProgram !== TOKEN_PROGRAM && tokenProgram !== TOKEN_2022_PROGRAM)) {
      fail({ reason: 'no-coin' });
    }
    const decimals = Number(mintInfo.decimals);
    if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) fail({ reason: 'no-coin' });

    // Token-2022 tokens can carry rules of their own.
    const extensions = Array.isArray(mintInfo.extensions) ? (mintInfo.extensions as { extension?: string; state?: { programId?: string | null } }[]) : [];
    if (extensions.some((extension) => extension.extension === 'nonTransferable')) fail({ reason: 'non-transferable' });
    if (extensions.some((extension) => extension.extension === 'transferHook' && extension.state?.programId)) fail({ reason: 'transfer-hook' });

    // The wallet's accounts holding the token, largest first, its usual one ahead of a tie.
    const own = associatedTokenAddress(from, mint, tokenProgram);
    const sources = held
      .flatMap(({ pubkey, account: tokenAccount }) => {
        const info = parsedOf(tokenAccount)?.info;
        const raw = (info?.tokenAmount as { amount?: unknown } | undefined)?.amount;
        return info?.state === 'initialized' && typeof raw === 'string' && /^\d+$/.test(raw) ? [{ address: pubkey, amount: BigInt(raw) }] : [];
      })
      .filter((source) => source.amount > 0n)
      .sort((a, b) => (a.amount === b.amount ? Number(b.address === own) - Number(a.address === own) : a.amount < b.amount ? 1 : -1));
    if (sources.length === 0) fail({ reason: 'no-coin' });

    const requested = intent.amount === 'max' ? sources[0]!.amount : parseUnits(intent.amount, decimals);
    if (requested === null || requested <= 0n) fail({ reason: 'invalid-amount' });
    amount = requested;
    const source = sources.find((entry) => entry.address === own && entry.amount >= amount) ?? sources.find((entry) => entry.amount >= amount);
    if (!source) fail({ reason: sources.reduce((sum, entry) => sum + entry.amount, 0n) >= amount ? 'split-balance' : 'insufficient' });

    // Into the recipient's usual account for the token, opened on the way if they have none yet.
    const destination = intoTokenAccount ? to : associatedTokenAddress(to, mint, tokenProgram);
    const destinationAccount = intoTokenAccount ? recipient : (recipientUsualAccounts[tokenProgram === TOKEN_PROGRAM ? 0 : 1] ?? null);
    const opening = !destinationAccount;
    instructions = [
      ...(opening ? [createTokenAccount(from, destination, to, mint, tokenProgram)] : []),
      transferTokens(tokenProgram, source.address, mint, destination, from, amount, decimals),
    ];

    // The test run measures the compute units and, for a new account, what opening it costs.
    const simulation = await simulate(url, from, [setComputeUnitLimit(SIMULATION_UNITS), ...instructions], opening ? [destination] : []);
    if (simulation.err) {
      if (lacksSol(simulation)) fail({ reason: 'insufficient-sol', needed: sol(feeFor(SOL_UNITS, MIN_PRICE) + (opening ? accountRent : 0n)) });
      fail({ reason: 'simulation', detail: whyFailed(simulation) });
    }
    units = Math.ceil((simulation.unitsConsumed ?? SIMULATION_UNITS) * 1.15) + 1_000;
    price = priceFor(units);
    if (opening) rent = BigInt(simulation.accounts?.[0]?.lamports ?? accountRent);
    const needed = feeFor(units, price) + (rent ?? 0n);
    if (balance < needed) fail({ reason: 'insufficient-sol', needed: sol(needed) });
    const leftover = balance - needed;
    if (leftover > 0n && leftover < minimum) fail({ reason: 'below-minimum', minimum: sol(minimum), leftover: true });

    coin = { mint, symbol: null, name: null, logo: null, decimals };
  }

  // At an exchange: its own wallet, a token it doesn't take or isn't taking now, or less than it
  // credits. What couldn't be checked is said too, without stopping the transfer.
  const atExchangeNow = await atExchange;
  const notes: SendNote[] = [];
  if (atExchangeNow === 'unknown') notes.push({ id: 'exchangeUnchecked' });
  else if (atExchangeNow?.exchange && atExchangeNow.kind === 'deposit' && !atExchangeNow.listed) notes.push({ id: 'exchangeNoList', exchange: atExchangeNow.exchange });
  if (atExchangeNow && atExchangeNow !== 'unknown' && atExchangeNow.exchange) {
    const { exchange, kind, listed } = atExchangeNow;
    if (kind === 'hot-wallet') checks.push({ id: 'exchangeWallet', exchange });
    else if (kind === 'deposit' && listed && !listed.accepted) checks.push({ id: 'exchangeToken', exchange, basis: listed.basis });
    else if (kind === 'deposit' && listed?.paused) checks.push({ id: 'exchangePaused', exchange, coin: listed.coin });
    else if (kind === 'deposit' && listed?.depositMin) {
      const least = parseUnits(listed.depositMin, coin.decimals);
      if (least !== null && amount < least) checks.push({ id: 'exchangeMinimum', exchange, minimum: listed.depositMin, coin: listed.coin });
    }
  }

  const enabled: Record<SendCheckId, boolean> = {
    program: preferences.protection.programAddresses,
    mint: preferences.protection.mintAddresses,
    tokenAccount: preferences.protection.tokenAccounts,
    lookalike: preferences.protection.lookalikeAddresses,
    exchangeWallet: preferences.protection.exchangeSupport,
    exchangeToken: preferences.protection.exchangeSupport,
    exchangePaused: preferences.protection.exchangeSupport,
    exchangeMinimum: preferences.protection.exchangeSupport,
  };
  const found = checks.filter((check) => enabled[check.id]);

  // Names for the token being sent and for a mint the recipient turned out to be. Optional: the
  // transfer doesn't depend on them.
  const named = [mint, found.some((check) => check.id === 'mint') ? to : null].filter((value): value is string => value !== null);
  const tokens = named.length ? await getApi(preferences).getTokens({ network, mints: named }).catch(() => ({})) : {};
  const token = (address: string) => (tokens as Record<string, { name: string | null; symbol: string | null; logo: string | null } | null>)[address] ?? null;
  if (mint !== null) coin = { ...coin, symbol: token(mint)?.symbol ?? null, name: token(mint)?.name ?? null, logo: token(mint)?.logo ?? null };
  const reviewed = found.map((check) => (check.id === 'mint' ? { ...check, token: token(to)?.symbol ?? token(to)?.name ?? null } : check));

  return {
    review: {
      network: network as Network,
      from,
      to,
      contact,
      coin,
      amount: formatUnits(amount, coin.decimals),
      fee: sol(feeFor(units, price)),
      rent: rent === null ? null : sol(rent),
      checks: reviewed,
      notes,
    },
    url,
    instructions,
    units,
    price,
    blockhash: latest.value.blockhash,
    lastValidBlockHeight: latest.value.lastValidBlockHeight,
  };
}

function failureOf(error: unknown): SendFailure {
  if (error instanceof SendError) return error.failure;
  if (error instanceof LockedError) return { reason: 'locked' };
  if (error instanceof ChainError) return { reason: 'network', failure: error.reason, detail: error.detail };
  throw error;
}

export async function prepareSend(intent: SendIntent): Promise<ResponseMap['send:prepare']> {
  try {
    return { ok: true, review: (await plan(intent, null)).review };
  } catch (error) {
    return { ok: false, failure: failureOf(error) };
  }
}

export async function submitSend(intent: SendIntent, maxFeeText: string): Promise<ResponseMap['send:submit']> {
  try {
    const maxFee = parseUnits(maxFeeText, 9);
    // Only the exact amount the user saw is signed.
    if (intent.amount === 'max' || maxFee === null) fail({ reason: 'invalid-amount' });

    const planned = await plan(intent, maxFee);
    const { review } = planned;
    // A protection that finds something stops the transfer; only turning it off in Security lets it through.
    if (review.checks.length) return { ok: false, failure: { reason: 'blocked' }, review };

    const message = compileMessage(
      review.from,
      [setComputeUnitLimit(planned.units), setComputeUnitPrice(planned.price), ...planned.instructions],
      planned.blockhash,
    );
    const signature = await withActiveWallet((wallet, secret) => {
      const signed = signMessage(secret, wallet.account, message);
      if (signed.address !== review.from) throw new Error('The key does not belong to the sending wallet');
      return signed.signature;
    });
    const wire = base64.encode(serializeTransaction(message, [signature]));
    const id = base58.encode(signature);

    // The node runs it once more before taking it; it refuses anything that would fail.
    await rpc<string>(planned.url, 'sendTransaction', [wire, { encoding: 'base64', preflightCommitment: 'confirmed', maxRetries: 0 }]);
    await trackSent(planned.url, id, { wire, network: review.network, lastValidBlockHeight: planned.lastValidBlockHeight });
    return { ok: true, signature: id, review };
  } catch (error) {
    return { ok: false, failure: failureOf(error) };
  }
}
