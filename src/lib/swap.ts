// Swapping one coin for another through Jupiter. Jupiter quotes a swap and gives the instructions
// that carry it out (Swap API v2, /build); the wallet puts them into a transaction itself, with
// its own compute budget and zandr's fee, and trusts none of it. Before anything is signed it
// takes the transaction apart and checks that only this wallet signs, only programs a swap needs
// run, and in only the ways a swap uses them, that none of the wallet's other token accounts is
// even in it, and that a test run takes out no more than quoted and brings in no less than the
// minimum. Then it signs exactly those bytes. Background only.
import { base58, base64 } from '@scure/base';
import { getApi, rpcEndpoints } from '@/lib/api';
import type { PortfolioEntry, ResponseMap, SwapFailure, SwapQuoteView, SwapReview } from '@/lib/messages';
import { loadPreferences } from '@/lib/preferences';
import { signMessage } from '@/lib/secrets';
import { trackSent } from '@/lib/sent';
import {
  ASSOCIATED_TOKEN_PROGRAM,
  COMPUTE_BUDGET_PROGRAM,
  SYSTEM_PROGRAM,
  TOKEN_2022_PROGRAM,
  TOKEN_PROGRAM,
  WRAPPED_SOL,
  associatedTokenAddress,
  decodeAddress,
} from '@/lib/solana/addresses';
import { LookupError, decodeTransaction, readLookupTables, resolveAccountKeys, withSignature, type DecodedTransaction } from '@/lib/solana/message';
import { ChainError, getAccounts, parsedOf, rpc, type ParsedAccount } from '@/lib/solana/rpc';
import { compileV0Message, serializeTransaction, setComputeUnitLimit, setComputeUnitPrice, transferSol, type Instruction } from '@/lib/solana/transaction';
import { formatUnits, parseUnits } from '@/lib/units';
import { LockedError, getSession, withActiveWallet } from '@/lib/vault';
import { ApiError, type SwapBuild } from '@/server/api';

const JUPITER_PROGRAM = 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4';
// zandr's fee: 0.85% of the swap, always in SOL, sent to zandr's wallet by a transfer of its own in
// the same transaction (so it's paid only if the swap goes through). None while no wallet is set.
const FEE_BPS = 85n;
const FEE_WALLET: string | null = '4GAsMyghyygb4BUxCpcBpPWnMs1YrqBsYvVFDCy3ueme';
// What a swap may cost in SOL beyond what's sold and zandr's fee: the network fee, a priority fee
// (capped at 0.001 SOL) and opening an account for the token bought.
const SOL_BUDGET = 10_000_000n;
const MAX_PRIORITY_FEE = 1_000_000n;
// The most compute a transaction may ask for; a swap asks for what its test run used, and a fifth more.
const MAX_UNITS = 1_400_000;
// The largest transaction the network takes, in bytes.
const MAX_TRANSACTION = 1232;
// Kept back when swapping all of the wallet's SOL, to pay for the swap itself.
const SOL_RESERVE = 5_000_000n;
// How far below the quote a swap may come out before it fails instead: half a percent, enough
// for prices moving while it lands, too little for a bad fill to cost much.
const SLIPPAGE_BPS = 50;
const QUOTE_TTL_MS = 60_000;
// A quote is built with a blockhash good for about a minute; older than this, it's built again.
const REBUILD_MS = 30_000;
// Other token accounts of the wallet a swap may route through (each checked in the test run).
const MAX_OTHER_ACCOUNTS = 4;
// The latest quote, as built, kept while unlocked until it's swapped.
const QUOTE_KEY = 'swap:quote';

// Offered before anything is searched for: SOL, the main stablecoins and well-known tokens.
const POPULAR = [
  WRAPPED_SOL,
  'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', // USDC
  'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB', // USDT
  'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', // JUP
  'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn', // JitoSOL
  'mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So', // mSOL
  'jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL', // JTO
  'HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3', // PYTH
  '4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R', // RAY
  'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', // BONK
  'EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm', // WIF
];

export class SwapError extends Error {
  readonly failure: SwapFailure;

  constructor(failure: SwapFailure) {
    super(failure.reason);
    this.failure = failure;
  }
}

function fail(failure: SwapFailure): never {
  throw new SwapError(failure);
}

// The transaction from the swap service isn't what a swap should be: nothing gets signed.
function unsafe(detail: string): never {
  fail({ reason: 'unsafe', detail });
}

type Mint = { decimals: number; program: string };
// `fee`: zandr's, in lamports.
type StoredQuote = { id: string; at: number; from: string; build: SwapBuild; input: Mint; output: Mint; fee: string };

// Swaps go through Jupiter, which trades on mainnet only.
async function context() {
  const account = await getSession();
  if (!account) throw new LockedError();
  const preferences = await loadPreferences();
  if (preferences.network !== 'mainnet') fail({ reason: 'mainnet-only' });
  return { from: account.address, preferences, url: rpcEndpoints(preferences).mainnet, api: getApi(preferences) };
}

function failureOf(error: unknown, stage: 'tokens' | 'quote' | 'swap'): SwapFailure {
  if (error instanceof SwapError) return error.failure;
  if (error instanceof LockedError) return { reason: 'locked' };
  if (error instanceof ChainError) return { reason: 'network', failure: error.reason, detail: error.detail };
  if (error instanceof ApiError) {
    // Jupiter answers a pair or amount it can't route with an error, not an empty quote.
    if (stage === 'quote' && (error.reason === 'bad-response' || error.reason === 'invalid-request')) return { reason: 'no-route' };
    if (error.reason === 'forbidden' || error.reason === 'rate-limited' || error.reason === 'unreachable') return { reason: 'network', failure: error.reason };
    return { reason: 'network', failure: 'rejected', detail: error.detail ? `the swap service says: ${error.detail}` : 'the swap service gave an unexpected answer.' };
  }
  throw error;
}

// Decimals and token program of each mint, read from the chain once: neither ever changes.
const known = new Map<string, Mint>();

async function mints(url: string, addresses: string[]): Promise<Mint[]> {
  const missing = addresses.filter((address) => !known.has(address));
  const accounts = missing.length ? await getAccounts(url, missing) : [];
  accounts.forEach((account, i) => {
    const parsed = parsedOf(account);
    const decimals = Number(parsed?.info?.decimals);
    if (!account || parsed?.type !== 'mint' || (account.owner !== TOKEN_PROGRAM && account.owner !== TOKEN_2022_PROGRAM) || !Number.isInteger(decimals)) {
      fail({ reason: 'unknown-token' });
    }
    known.set(missing[i]!, { decimals, program: account.owner });
  });
  return addresses.map((address) => known.get(address)!);
}

// The wallet's SOL, or what it holds of a token in its usual account for it: the one a swap uses.
async function holding(url: string, from: string, mint: string, token: Mint): Promise<bigint> {
  if (mint === WRAPPED_SOL) return BigInt((await rpc<{ value: number }>(url, 'getBalance', [from, { commitment: 'confirmed' }])).value);
  const [account = null] = await getAccounts(url, [associatedTokenAddress(from, mint, token.program)]);
  return tokenAmount(account);
}

function tokenAmount(account: ParsedAccount | null | undefined): bigint {
  const raw = (parsedOf(account ?? null)?.info?.tokenAmount as { amount?: unknown } | undefined)?.amount;
  return typeof raw === 'string' && /^\d+$/.test(raw) ? BigInt(raw) : 0n;
}

function view({ id, build, input, output, fee }: StoredQuote): SwapQuoteView {
  return {
    id,
    inputMint: build.inputMint,
    outputMint: build.outputMint,
    inAmount: formatUnits(BigInt(build.inAmount), input.decimals),
    outAmount: formatUnits(BigInt(build.outAmount), output.decimals),
    minOutAmount: formatUnits(BigInt(build.minOutAmount), output.decimals),
    // Jupiter gives it as a fraction.
    priceImpactPct: build.priceImpactPct * 100,
    route: build.route,
    fee: BigInt(fee) > 0n ? formatUnits(BigInt(fee), 9) : null,
  };
}

// zandr's fee for a swap, in lamports: a share of what's sold or bought, whichever is SOL; else of
// what's sold, at its price in SOL (the wallet's own coins' prices, which it holds what it sells).
// None without a price, or while no wallet is set to receive it.
async function feeOf(from: string, build: SwapBuild, input: Mint): Promise<bigint> {
  if (!FEE_WALLET) return 0n;
  if (build.inputMint === WRAPPED_SOL) return (BigInt(build.inAmount) * FEE_BPS) / 10_000n;
  if (build.outputMint === WRAPPED_SOL) return (BigInt(build.outAmount) * FEE_BPS) / 10_000n;
  const key = `portfolio:mainnet:${from}`;
  const coins = ((await browser.storage.session.get(key))[key] as PortfolioEntry | undefined)?.portfolio?.coins ?? [];
  const sol = coins.find((coin) => coin.native)?.price;
  const token = coins.find((coin) => !coin.native && coin.mint === build.inputMint)?.price;
  if (!sol || !token) return 0n;
  const inSol = (Number(build.inAmount) / 10 ** input.decimals) * (token / sol);
  return BigInt(Math.floor((inSol * 1e9 * Number(FEE_BPS)) / 10_000));
}

const buildOf = (api: ReturnType<typeof getApi>, from: string, inputMint: string, outputMint: string, amount: bigint) =>
  api.buildSwap({ network: 'mainnet', inputMint, outputMint, amount: amount.toString(), slippageBps: SLIPPAGE_BPS, user: from });

async function readStored<T>(key: string): Promise<T | null> {
  return ((await browser.storage.session.get(key))[key] as T | undefined) ?? null;
}

// The search in progress: a newer one drops it if it's still waiting its turn.
let searching: AbortController | null = null;

export async function swapTokens(query: string): Promise<ResponseMap['swap:tokens']> {
  try {
    const { api } = await context();
    if (query.trim()) {
      searching?.abort();
      const controller = new AbortController();
      searching = controller;
      try {
        return { ok: true, tokens: await api.searchTokens({ network: 'mainnet', query }, { signal: controller.signal }) };
      } catch (error) {
        // Dropped for a newer search, whose answer the picker waits for instead.
        if (error instanceof DOMException && error.name === 'AbortError') return { ok: true, tokens: [] };
        throw error;
      }
    }
    const found = await api.getTokens({ network: 'mainnet', mints: POPULAR });
    return { ok: true, tokens: POPULAR.flatMap((mint) => (found[mint] ? [{ mint, ...found[mint] }] : [])) };
  } catch (error) {
    return { ok: false, failure: failureOf(error, 'tokens') };
  }
}

export async function swapQuote(inputMint: string, outputMint: string, amountText: string): Promise<ResponseMap['swap:quote']> {
  try {
    const { from, url, api } = await context();
    if (!decodeAddress(inputMint) || !decodeAddress(outputMint)) fail({ reason: 'unknown-token' });
    if (inputMint === outputMint) fail({ reason: 'same-token' });
    const [input, output] = (await mints(url, [inputMint, outputMint])) as [Mint, Mint];

    const held = await holding(url, from, inputMint, input);
    const amount = amountText === 'max' ? (inputMint === WRAPPED_SOL ? held - SOL_RESERVE : held) : parseUnits(amountText, input.decimals);
    if (amount === null) fail({ reason: 'invalid-amount' });
    if (amount <= 0n) fail({ reason: amountText === 'max' ? 'insufficient' : 'invalid-amount' });
    if (amount > held) fail({ reason: 'insufficient' });

    const build = await buildOf(api, from, inputMint, outputMint, amount);
    const fee = await feeOf(from, build, input);
    const stored: StoredQuote = { id: crypto.randomUUID(), at: Date.now(), from, build, input, output, fee: fee.toString() };
    await browser.storage.session.set({ [QUOTE_KEY]: stored });
    return { ok: true, quote: view(stored) };
  } catch (error) {
    return { ok: false, failure: failureOf(error, 'quote') };
  }
}

type Simulation = { err: unknown; logs: string[] | null; accounts?: (ParsedAccount | null)[] | null; unitsConsumed?: number };

// A swap to check: what was quoted, for whom, and zandr's fee (lamports) the transaction pays.
type Checked = { from: string; build: SwapBuild; input: Mint; output: Mint; fee: bigint };

// A test run that failed: why, as the user should hear it.
function failedRun(simulation: Simulation): never {
  const failed = JSON.stringify(simulation.err);
  if (/InsufficientFundsForFee|InsufficientFundsForRent|AccountNotFound/.test(failed) || (simulation.logs ?? []).some((line) => /insufficient lamports/i.test(line))) {
    fail({ reason: 'insufficient-sol', needed: formatUnits(SOL_BUDGET, 9) });
  }
  const said = (simulation.logs ?? []).findLast((line) => /^Program log: (Error|error)/.test(line));
  fail({ reason: 'simulation', detail: (said?.replace(/^Program log: /, '') ?? failed).slice(0, 200) });
}

// Takes the swap apart and test-runs it. Returns what arrives, the fee and any rent, or fails
// with why it isn't safe to sign. Exported for tests.
export async function inspectSwap(url: string, transaction: DecodedTransaction, checked: Checked) {
  const { from, build: quote, input, output, fee: zandrFee } = checked;
  const message = transaction.message;
  if (message.signers !== 1 || message.readonlySigners !== 0 || message.staticKeys[0] !== from) {
    unsafe('It needs a signature from another account, or someone else pays for it.');
  }

  // The wallet's own token accounts a swap touches: the one sold from, the one bought into, and the
  // wrapped SOL account a SOL swap goes through. A token account can only lose tokens to a
  // transaction that names it: any other of the wallet's it names is checked in the test run.
  const wrapped = associatedTokenAddress(from, WRAPPED_SOL, TOKEN_PROGRAM);
  const source = quote.inputMint === WRAPPED_SOL ? wrapped : associatedTokenAddress(from, quote.inputMint, input.program);
  const target = quote.outputMint === WRAPPED_SOL ? wrapped : associatedTokenAddress(from, quote.outputMint, output.program);
  const allowed = new Set([source, target, wrapped]);
  let feePaid = false;
  const watched = [...new Set([from, source, target])];

  // Everything the checks need from the node, asked at once: the lookup tables (read from the
  // chain rather than taken from the swap service), the wallet's token accounts, and the test run
  // with the state before it. The test run is only looked at once the checks pass.
  const [keys, own, before, { value: simulation }] = await Promise.all([
    resolveAccountKeys(url, message, 'mainnet').catch((error: unknown) => {
      if (error instanceof LookupError) unsafe("It refers to an address table that isn't one, or to addresses its tables lack.");
      throw error;
    }),
    Promise.all(
      [TOKEN_PROGRAM, TOKEN_2022_PROGRAM].map((programId) =>
        rpc<{ value: { pubkey: string }[] }>(url, 'getTokenAccountsByOwner', [from, { programId }, { encoding: 'base64', dataSlice: { offset: 0, length: 0 } }]),
      ),
    ),
    getAccounts(url, watched),
    rpc<{ value: Simulation }>(url, 'simulateTransaction', [
      base64.encode(withSignature(transaction, new Uint8Array(64))),
      { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed', accounts: { addresses: watched, encoding: 'jsonParsed' } },
    ]),
  ]);
  const ownAccounts = new Set(own.flatMap((result) => result.value.map((entry) => entry.pubkey)));
  const others = [...new Set(keys.filter((key) => ownAccounts.has(key) && !allowed.has(key)))];
  if (others.length > MAX_OTHER_ACCOUNTS) unsafe('It names too many other token accounts of this wallet.');

  // Instruction by instruction: only what a swap needs, used only the way a swap uses it.
  let units = 200_000n;
  let price = 0n;
  for (const instruction of message.instructions) {
    if (instruction.program >= message.staticKeys.length) unsafe('It runs a program from an address table.');
    const program = message.staticKeys[instruction.program];
    const account = (index: number) => keys[instruction.accounts[index] ?? -1];
    const data = instruction.data;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

    switch (program) {
      case COMPUTE_BUDGET_PROGRAM:
        if (data[0] === 2 && data.length === 5) units = BigInt(view.getUint32(1, true));
        else if (data[0] === 3 && data.length === 9) price = view.getBigUint64(1, true);
        else if (data[0] !== 1 && data[0] !== 4) unsafe('It sets the compute budget in an unexpected way.');
        break;
      case SYSTEM_PROGRAM: {
        // Wrapping SOL: a transfer from the wallet into its own wrapped SOL account. And zandr's
        // fee, once, of exactly what was shown.
        if (data.length !== 12 || view.getUint32(0, true) !== 2 || account(0) !== from) unsafe("It moves SOL somewhere other than the wallet's own wrapped SOL account.");
        const fee = FEE_WALLET !== null && account(1) === FEE_WALLET && !feePaid && view.getBigUint64(4, true) === zandrFee && zandrFee > 0n;
        if (fee) feePaid = true;
        else if (FEE_WALLET !== null && account(1) === FEE_WALLET) unsafe("It pays zandr's fee other than as shown.");
        else if (account(1) !== wrapped) unsafe("It moves SOL somewhere other than the wallet's own wrapped SOL account.");
        break;
      }
      case TOKEN_PROGRAM:
      case TOKEN_2022_PROGRAM:
        // Syncing and closing the wrapped SOL account, the SOL going back to the wallet.
        if (data[0] === 17 && account(0) === wrapped) break;
        if (data[0] === 9 && account(0) === wrapped && account(1) === from && account(2) === from) break;
        unsafe("It runs a token instruction a swap doesn't need, like handing over control of an account.");
      case ASSOCIATED_TOKEN_PROGRAM:
        // Opening the wallet's own accounts, paid by the wallet.
        if ((data.length === 0 || data[0] === 0 || data[0] === 1) && account(0) === from && account(2) === from) break;
        unsafe('It opens a token account for someone else.');
      case JUPITER_PROGRAM:
        break;
      default:
        unsafe(`It runs a program a swap doesn't need (${program!.slice(0, 4)}…${program!.slice(-4)}).`);
    }
  }

  // The test run: what leaves the wallet and what arrives, against the latest state.
  if (simulation.err) failedRun(simulation);

  // A route through a token the wallet also holds may go through the wallet's own account for it.
  // Allowed only if the test run leaves each such account as it was or better: still the wallet's,
  // nothing taken from it, no one given the right to spend from or close it.
  if (others.length) {
    const [was, { value: run }] = await Promise.all([
      getAccounts(url, others),
      rpc<{ value: Simulation }>(url, 'simulateTransaction', [
        base64.encode(withSignature(transaction, new Uint8Array(64))),
        { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed', accounts: { addresses: others, encoding: 'jsonParsed' } },
      ]),
    ]);
    if (run.err) fail({ reason: 'simulation', detail: JSON.stringify(run.err).slice(0, 200) });
    others.forEach((_, i) => {
      const before = parsedOf(was[i] ?? null)?.info;
      const now = parsedOf(run.accounts?.[i] ?? null)?.info;
      const same = (field: string) => (now?.[field] ?? null) === (before?.[field] ?? null);
      if (!now || now.owner !== from || !same('delegate') || !same('closeAuthority') || !same('state') || tokenAmount(run.accounts?.[i]) < tokenAmount(was[i])) {
        unsafe("It would take from, or hand over, another of this wallet's token accounts.");
      }
    });
  }

  const after = simulation.accounts ?? [];
  const at = (address: string) => watched.indexOf(address);
  const lamports = (account: ParsedAccount | null | undefined) => BigInt(account?.lamports ?? 0);
  const solChange = lamports(after[at(from)]) - lamports(before[at(from)]);

  const inAmount = BigInt(quote.inAmount);
  const minOut = BigInt(quote.minOutAmount);
  const fee = 5_000n + (price * units + 999_999n) / 1_000_000n;
  if (quote.inputMint === WRAPPED_SOL) {
    if (-solChange > inAmount + zandrFee + SOL_BUDGET) unsafe('It takes more SOL than quoted.');
  } else {
    if (tokenAmount(before[at(source)]) - tokenAmount(after[at(source)]) > inAmount) unsafe('It takes more of the token than quoted.');
    if (quote.outputMint !== WRAPPED_SOL && -solChange > zandrFee + SOL_BUDGET) unsafe('It takes more SOL than a swap costs.');
  }

  let received: bigint;
  if (quote.outputMint === WRAPPED_SOL) {
    received = solChange + fee + zandrFee;
    if (solChange < minOut - zandrFee - SOL_BUDGET) unsafe('It brings in less SOL than the minimum.');
  } else {
    received = tokenAmount(after[at(target)]) - tokenAmount(before[at(target)]);
    if (received < minOut) unsafe('It brings in less than the minimum.');
  }
  const opened = quote.outputMint !== WRAPPED_SOL && !before[at(target)] && after[at(target)];
  const rent = opened ? lamports(after[at(target)]) : null;

  return { received: received < 0n ? 0n : received, fee, rent };
}

// Jupiter's instructions, as the wallet's own.
const instructionOf = (instruction: SwapBuild['instructions'][number]): Instruction => ({
  program: instruction.program,
  accounts: instruction.accounts,
  data: base64.decode(instruction.data),
});

// The swap in one go, from the quote the user saw: put into a transaction with the compute it
// needs, checked and test-run, then, only if all of that holds, signed and sent.
export async function executeSwap(quoteId: string): Promise<ResponseMap['swap:execute']> {
  try {
    const { from, url, api } = await context();
    const stored = await readStored<StoredQuote>(QUOTE_KEY);
    if (!stored || stored.id !== quoteId || Date.now() - stored.at > QUOTE_TTL_MS) fail({ reason: 'expired' });
    if (stored.from !== from) fail({ reason: 'wallet-changed' });

    // Built when quoted. A while ago, it's built again for a blockhash with time left, and taken
    // only if it still gives at least the minimum the user saw.
    let { build } = stored;
    let fee = BigInt(stored.fee);
    if (Date.now() - stored.at > REBUILD_MS) {
      build = await buildOf(api, from, build.inputMint, build.outputMint, BigInt(build.inAmount));
      if (BigInt(build.minOutAmount) < BigInt(stored.build.minOutAmount)) fail({ reason: 'expired' });
      fee = await feeOf(from, build, stored.input);
    }

    // The lookup tables, read from the chain (what Jupiter says is in them isn't used).
    const tables = await readLookupTables(url, 'mainnet', build.lookupTables.map((table) => ({ table }))).catch((error: unknown) => {
      if (error instanceof LookupError) unsafe('It refers to an address table that isn\'t one.');
      throw error;
    });
    const body = [...build.instructions.map(instructionOf), ...(fee > 0n && FEE_WALLET ? [transferSol(from, FEE_WALLET, fee)] : [])];
    const compile = (units: number, price: bigint) => {
      const message = compileV0Message(from, [setComputeUnitLimit(units), setComputeUnitPrice(price), ...body], build.blockhash, tables);
      const wire = serializeTransaction(message, [new Uint8Array(64)]);
      if (wire.length > MAX_TRANSACTION) fail({ reason: 'no-route' });
      return wire;
    };

    // How much compute it needs: a test run with the most a transaction may have. It asks for
    // that and a fifth more, at Jupiter's priority fee capped at 0.001 SOL in all.
    const { value: probe } = await rpc<{ value: Simulation }>(url, 'simulateTransaction', [
      base64.encode(compile(MAX_UNITS, 0n)),
      { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed' },
    ]);
    if (probe.err) failedRun(probe);
    const units = Math.min(Math.ceil((probe.unitsConsumed ?? MAX_UNITS) * 1.2), MAX_UNITS);
    const cap = (MAX_PRIORITY_FEE * 1_000_000n) / BigInt(units);
    const price = BigInt(build.computeUnitPrice) < cap ? BigInt(build.computeUnitPrice) : cap;

    // The transaction as it will be signed: taken apart, checked and test-run.
    const transaction = decodeTransaction(compile(units, price));
    const { received, fee: networkFee, rent } = await inspectSwap(url, transaction, { from, build, input: stored.input, output: stored.output, fee });
    const review: SwapReview = {
      id: crypto.randomUUID(),
      quote: view({ ...stored, build, fee: fee.toString() }),
      outAmount: formatUnits(received, stored.output.decimals),
      fee: formatUnits(networkFee, 9),
      rent: rent === null ? null : formatUnits(rent, 9),
    };

    // Exactly the bytes that were checked.
    const signature = await withActiveWallet((wallet, secret) => {
      const signed = signMessage(secret, wallet.account, transaction.messageBytes);
      if (signed.address !== from) throw new Error('The key does not belong to the swapping wallet');
      return signed.signature;
    });
    const wire = base64.encode(withSignature(transaction, signature));
    const id = base58.encode(signature);
    await rpc<string>(url, 'sendTransaction', [wire, { encoding: 'base64', preflightCommitment: 'confirmed', maxRetries: 0 }]);

    // Followed, and sent again until it lands, as transfers are (lib/sent.ts).
    await trackSent(url, id, { wire, network: 'mainnet', lastValidBlockHeight: build.lastValidBlockHeight });
    await browser.storage.session.remove(QUOTE_KEY);
    return { ok: true, signature: id, review };
  } catch (error) {
    return { ok: false, failure: failureOf(error, 'swap') };
  }
}
