// Reclaiming SOL from the wallet's token accounts. Each holds rent, about 0.002 SOL, that closing
// it returns to the wallet. Empty accounts are simply closed: nothing else changes, and if the
// token comes back later a new account is opened for it. Accounts holding junk (worth under a
// dollar, or with no price) can be closed too, their tokens burned first, but only those the user
// picked and acknowledged, and only if they're still junk when checked again. Collectibles and
// wrapped SOL are never offered. Every account is read from the chain again right before, every
// transaction test-run, and signed only if the test run closes those accounts and returns their
// rent to the wallet. Background only.
import { base58, base64 } from '@scure/base';
import { getApi, rpcEndpoints } from '@/lib/api';
import {
  RECLAIM_BATCH,
  RECLAIM_JUNK_MAX_USD,
  type ReclaimAccount,
  type ReclaimFailure,
  type ResponseMap,
} from '@/lib/messages';
import { loadPreferences, type Preferences } from '@/lib/preferences';
import { signMessage } from '@/lib/secrets';
import { trackSent } from '@/lib/sent';
import { TOKEN_2022_PROGRAM, TOKEN_PROGRAM, decodeAddress } from '@/lib/solana/addresses';
import { ChainError, getAccounts, parsedOf, rpc, type ParsedAccount } from '@/lib/solana/rpc';
import {
  burnTokens,
  closeTokenAccount,
  compileMessage,
  serializeTransaction,
  setComputeUnitLimit,
  setComputeUnitPrice,
  type Instruction,
} from '@/lib/solana/transaction';
import { formatUnits } from '@/lib/units';
import { LockedError, getSession, withActiveWallet } from '@/lib/vault';
import { ApiError, type Coin } from '@/server/api';

// Compute units per account, generously (a close takes about 3,000, a burn about 5,000), and the
// priority fee per unit: nothing here is urgent.
const UNITS = { close: 8_000, burn: 16_000 };
const PRICE = 1_000n;
const BASE_FEE = 5_000n;
// The most accounts one request may name.
const MAX_ACCOUNTS = 500;

// Token-2022 extensions that don't keep an account from closing or its tokens from burning. Any
// other (a confidential balance, fees withheld) and the account is left alone.
const HARMLESS_EXTENSIONS = new Set(['immutableOwner', 'memoTransfer', 'cpiGuard', 'nonTransferableAccount', 'transferHookAccount']);

class ReclaimError extends Error {
  readonly failure: ReclaimFailure;

  constructor(failure: ReclaimFailure) {
    super(failure.reason);
    this.failure = failure;
  }
}

function fail(failure: ReclaimFailure): never {
  throw new ReclaimError(failure);
}

function failureOf(error: unknown): ReclaimFailure {
  if (error instanceof ReclaimError) return error.failure;
  if (error instanceof LockedError) return { reason: 'locked' };
  if (error instanceof ChainError) return { reason: 'network', failure: error.reason };
  throw error;
}

async function context() {
  const account = await getSession();
  if (!account) throw new LockedError();
  const preferences = await loadPreferences();
  return { from: account.address, preferences, url: rpcEndpoints(preferences)[preferences.network] };
}

// A token account the wallet alone controls and can close, with what's in it.
type Account = { address: string; mint: string; program: string; lamports: bigint; amount: bigint; decimals: number };

function closable(entry: { pubkey: string; account: ParsedAccount }, owner: string): Account | null {
  const { account } = entry;
  const parsed = parsedOf(account);
  const info = parsed?.info;
  const tokenAmount = info?.tokenAmount as { amount?: unknown; decimals?: unknown } | undefined;
  if (parsed?.type !== 'account' || !info || typeof info.mint !== 'string') return null;
  if (account.owner !== TOKEN_PROGRAM && account.owner !== TOKEN_2022_PROGRAM) return null;
  if (typeof tokenAmount?.amount !== 'string' || !/^\d+$/.test(tokenAmount.amount) || typeof tokenAmount.decimals !== 'number') return null;
  // The wallet's, usable, not wrapped SOL, and closable by the wallet: no one else holds that right.
  if (info.owner !== owner || info.state !== 'initialized' || info.isNative === true) return null;
  if (info.closeAuthority !== undefined && info.closeAuthority !== null && info.closeAuthority !== owner) return null;
  const extensions = Array.isArray(info.extensions) ? (info.extensions as { extension?: unknown; state?: Record<string, unknown> }[]) : [];
  const harmless = extensions.every(
    ({ extension, state }) =>
      (typeof extension === 'string' && HARMLESS_EXTENSIONS.has(extension)) ||
      (extension === 'transferFeeAmount' && Number(state?.withheldAmount ?? 0) === 0),
  );
  if (!harmless || !Number.isSafeInteger(account.lamports) || account.lamports <= 0) return null;
  return {
    address: entry.pubkey,
    mint: info.mint,
    program: account.owner,
    lamports: BigInt(account.lamports),
    amount: BigInt(tokenAmount.amount),
    decimals: tokenAmount.decimals,
  };
}

// The wallet's token accounts that could be closed, as the chain has them now: empty ones, and
// ones holding tokens that aren't collectibles (those have no decimals).
async function findAccounts(url: string, owner: string): Promise<{ empty: Account[]; held: Account[] }> {
  const lists = await Promise.all(
    [TOKEN_PROGRAM, TOKEN_2022_PROGRAM].map((programId) =>
      rpc<{ value: { pubkey: string; account: ParsedAccount }[] }>(url, 'getTokenAccountsByOwner', [
        owner,
        { programId },
        { encoding: 'jsonParsed', commitment: 'confirmed' },
      ]),
    ),
  );
  const accounts = lists.flatMap((list) => list.value.flatMap((entry) => closable(entry, owner) ?? []));
  return {
    empty: accounts.filter((account) => account.amount === 0n),
    held: accounts.filter((account) => account.amount > 0n && account.decimals > 0),
  };
}

// What each mint's coins are worth now, from the wallet's portfolio. Throws if it can't be known.
async function coinsOf(preferences: Preferences, address: string): Promise<Map<string, Coin>> {
  const portfolio = await getApi(preferences).getPortfolio({ network: preferences.network, address });
  return new Map(portfolio.coins.map((coin) => [coin.mint, coin]));
}

function valueOf(account: Account, coin: Coin | undefined): number | null {
  return coin?.price == null ? null : Number(formatUnits(account.amount, account.decimals)) * coin.price;
}

const isJunk = (value: number | null) => value === null || value < RECLAIM_JUNK_MAX_USD;

function view(account: Account, names: { symbol: string | null; logo: string | null; verified: boolean } | null | undefined, held: boolean, value: number | null): ReclaimAccount {
  return {
    address: account.address,
    mint: account.mint,
    symbol: names?.symbol ?? null,
    logo: names?.logo ?? null,
    verified: names?.verified ?? false,
    sol: formatUnits(account.lamports, 9),
    balance: held ? formatUnits(account.amount, account.decimals) : null,
    value: held ? value : null,
  };
}

const byRent = (a: Account, b: Account) => (a.lamports > b.lamports ? -1 : a.lamports < b.lamports ? 1 : 0);

export async function reclaimPlan(): Promise<ResponseMap['reclaim:plan']> {
  try {
    const { from, url, preferences } = await context();
    const { empty, held } = await findAccounts(url, from);

    // Junk, by value: without prices it can't be told apart, and none is offered.
    let coins: Map<string, Coin> | null = null;
    if (held.length) coins = await coinsOf(preferences, from).catch(() => null);
    const junk = coins ? held.filter((account) => isJunk(valueOf(account, coins!.get(account.mint)))) : [];

    // Names and logos for the empty ones; the tokens are all but forgotten, so lacking them is fine.
    const mints = [...new Set(empty.map((account) => account.mint))];
    const names: Record<string, { symbol: string | null; logo: string | null; verified: boolean } | null> = {};
    for (let i = 0; i < mints.length; i += 100) {
      Object.assign(names, await getApi(preferences).getTokens({ network: preferences.network, mints: mints.slice(i, i + 100) }).catch(() => ({})));
    }

    return {
      ok: true,
      empty: empty.sort(byRent).map((account) => view(account, names[account.mint], false, null)),
      junk: junk
        .map((account) => ({ account, coin: coins!.get(account.mint), value: valueOf(account, coins!.get(account.mint)) }))
        // Those with no price first, then the least worth.
        .sort((a, b) => (a.value ?? -1) - (b.value ?? -1))
        .map(({ account, coin, value }) => view(account, coin, true, value)),
      pricesKnown: !held.length || coins !== null,
    };
  } catch (error) {
    return { ok: false, failure: failureOf(error) };
  }
}

const feeFor = (units: number) => BASE_FEE + (PRICE * BigInt(units) + 999_999n) / 1_000_000n;

// What one transaction does with its accounts: each burned first if it holds anything, then closed,
// the rent going to the wallet.
function transactionFor(accounts: Account[], owner: string) {
  const units = accounts.reduce((sum, account) => sum + (account.amount > 0n ? UNITS.burn : UNITS.close), 0);
  const instructions: Instruction[] = [setComputeUnitLimit(units), setComputeUnitPrice(PRICE)];
  for (const account of accounts) {
    if (account.amount > 0n) instructions.push(burnTokens(account.program, account.address, account.mint, owner, account.amount, account.decimals));
    instructions.push(closeTokenAccount(account.program, account.address, owner, owner));
  }
  return { instructions, fee: feeFor(units) };
}

type Simulation = { err: unknown; logs: string[] | null; accounts?: ({ lamports: number } | null)[] | null };

// The test run: the accounts closed, and the wallet at least their rent better off, the fee aside.
async function testRun(url: string, owner: string, accounts: Account[], blockhash: string): Promise<{ ok: true; message: Uint8Array } | { ok: false; detail: string }> {
  const { instructions, fee } = transactionFor(accounts, owner);
  const message = compileMessage(owner, instructions, blockhash);
  const watched = [owner, ...accounts.map((account) => account.address)];
  const [before, { value: simulation }] = await Promise.all([
    getAccounts(url, [owner]),
    rpc<{ value: Simulation }>(url, 'simulateTransaction', [
      base64.encode(serializeTransaction(message, [new Uint8Array(64)])),
      { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed', accounts: { addresses: watched, encoding: 'base64' } },
    ]),
  ]);
  if (simulation.err) {
    const said = (simulation.logs ?? []).findLast((line) => /^Program log: Error/.test(line));
    return { ok: false, detail: (said?.replace(/^Program log: (Error: )?/, '') ?? JSON.stringify(simulation.err)).slice(0, 200) };
  }
  const after = simulation.accounts ?? [];
  const closed = after.slice(1).every((account) => !account || account.lamports === 0);
  const gained = BigInt(after[0]?.lamports ?? 0) - BigInt(before[0]?.lamports ?? 0);
  const rent = accounts.reduce((sum, account) => sum + account.lamports, 0n);
  if (!closed || gained < rent - fee) return { ok: false, detail: "The test run didn't close the accounts or return their SOL." };
  return { ok: true, message };
}

function batchesOf<T>(items: T[], size: number): T[][] {
  return Array.from({ length: Math.ceil(items.length / size) }, (_, i) => items.slice(i * size, (i + 1) * size));
}

export async function reclaimExecute(close: string[], burn: string[], acknowledged: boolean): Promise<ResponseMap['reclaim:execute']> {
  try {
    const requested = [...close, ...burn];
    if (!requested.length || requested.length > MAX_ACCOUNTS || !requested.every((address) => decodeAddress(address))) fail({ reason: 'nothing' });
    if (burn.length && !acknowledged) fail({ reason: 'unacknowledged' });
    const { from, url, preferences } = await context();

    // Only what was asked for and can still be closed, as the chain has it now.
    const { empty, held } = await findAccounts(url, from);
    const closing = empty.filter((account) => close.includes(account.address));
    let burning = held.filter((account) => burn.includes(account.address));
    let skipped = requested.length - closing.length - burning.length;

    // Burned only if still junk: what it's worth now, not when the list was shown.
    if (burning.length) {
      let coins: Map<string, Coin>;
      try {
        coins = await coinsOf(preferences, from);
      } catch (error) {
        if (error instanceof ApiError || error instanceof ChainError) fail({ reason: 'prices' });
        throw error;
      }
      const junk = burning.filter((account) => isJunk(valueOf(account, coins.get(account.mint))));
      skipped += burning.length - junk.length;
      burning = junk;
    }
    if (!closing.length && !burning.length) fail({ reason: 'nothing' });

    const { value: latest } = await rpc<{ value: { blockhash: string; lastValidBlockHeight: number } }>(url, 'getLatestBlockhash', [
      { commitment: 'confirmed' },
    ]);

    // Each transaction test-run. One that fails over a token that can't be burned (its mint paused,
    // say) is tried account by account, and the ones that still fail are left out.
    const batches = [...batchesOf(closing, RECLAIM_BATCH.close), ...batchesOf(burning, RECLAIM_BATCH.burn)];
    const runs = await Promise.all(batches.map((batch) => testRun(url, from, batch, latest.blockhash)));
    const messages: Uint8Array[] = [];
    const done: Account[] = [];
    let failed: string | null = null;
    for (const [i, run] of runs.entries()) {
      if (run.ok) {
        messages.push(run.message);
        done.push(...batches[i]!);
        continue;
      }
      failed = run.detail;
      const alone = await Promise.all(batches[i]!.map((account) => testRun(url, from, [account], latest.blockhash)));
      const good = batches[i]!.filter((_, j) => alone[j]!.ok);
      skipped += batches[i]!.length - good.length;
      if (!good.length) continue;
      const retried = await testRun(url, from, good, latest.blockhash);
      if (!retried.ok) {
        skipped += good.length;
        continue;
      }
      messages.push(retried.message);
      done.push(...good);
    }
    if (!messages.length) fail(failed ? { reason: 'simulation', detail: failed } : { reason: 'nothing' });

    // Signed together, sent one by one, and followed until they land.
    const signatures = await withActiveWallet((wallet, secret) =>
      messages.map((message) => {
        const signed = signMessage(secret, wallet.account, message);
        if (signed.address !== from) throw new Error('The key does not belong to the wallet');
        return signed.signature;
      }),
    );
    const sent: string[] = [];
    for (const [i, message] of messages.entries()) {
      const wire = base64.encode(serializeTransaction(message, [signatures[i]!]));
      await rpc<string>(url, 'sendTransaction', [wire, { encoding: 'base64', preflightCommitment: 'confirmed', maxRetries: 0 }]);
      const id = base58.encode(signatures[i]!);
      await trackSent(url, id, { wire, network: preferences.network, lastValidBlockHeight: latest.lastValidBlockHeight });
      sent.push(id);
    }
    return {
      ok: true,
      signatures: sent,
      reclaimed: formatUnits(done.reduce((sum, account) => sum + account.lamports, 0n), 9),
      burned: done.filter((account) => account.amount > 0n).length,
      skipped,
    };
  } catch (error) {
    return { ok: false, failure: failureOf(error) };
  }
}
