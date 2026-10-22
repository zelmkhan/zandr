// An address's history: its latest transactions from the RPC node, each read for what it did to
// the address. What moved is taken from the balances before and after, which the node reports for
// every account, so it holds for any program; instructions are read only to name the other side
// of a transfer. Names and logos come from the token list.
import { ApiError, type Activity, type ActivityChange, type ActivityKind, type ActivityPage, type Network } from './api.ts';
import { isObject, type Fetch } from './http.ts';
import type { Jupiter, TokenInfo } from './jupiter.ts';
import { SOL_LOGO, WRAPPED_SOL } from './portfolio.ts';
import { formatUnits, getSignatures, getTransaction } from './rpc.ts';

const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const SIGNATURE = /^[1-9A-HJ-NP-Za-km-z]{64,88}$/;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;
// Transactions read at once.
const PARALLEL = 3;
// How long a page may go on once its first transaction came: a slow node gives a shorter page,
// which the next one continues.
const BUDGET_MS = 7_000;

// Programs every wallet uses: they move coins and open accounts, but aren't an app.
const BASIC_PROGRAMS = new Set([
  '11111111111111111111111111111111',
  'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
  'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb',
  'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL',
  'ComputeBudget111111111111111111111111111111',
  'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
  'Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo',
]);

// Well-known apps, by program.
const APPS: Record<string, string> = {
  JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4: 'Jupiter',
  whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc: 'Orca',
  '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8': 'Raydium',
  CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK: 'Raydium',
  CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C: 'Raydium',
  LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo: 'Meteora',
  '6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P': 'Pump.fun',
  MarBmsSgKXdrN1egZf5sqe1TMai9K1rChYNDJgjq7aD: 'Marinade',
  Stake11111111111111111111111111111111111111: 'Staking',
  M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K: 'Magic Eden',
  TSWAPaqyCSx2KABk68Shruf4rp7CxcNi8hAsbdwmHbN: 'Tensor',
  dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH: 'Drift',
  KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD: 'Kamino',
  PhoeNiXZ8ByJGLkxNfZRnkUfjvmuYqLR89jjFHGqdXY: 'Phoenix',
};

export type ActivityDeps = { fetch: Fetch; rpc: Record<Network, string>; jupiter: Jupiter };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// The pace of requests to one node, kept between calls. Public nodes allow only a few
// transactions a second: when one says it's busy, every request waits a while, and then they go
// on further apart. A node that keeps up is asked faster again, a little at a time.
type Pace = { spacing: number; last: number; resumeAt: number; pause: number };

const paces = new Map<string, Pace>();
const FASTEST = 60;
const SLOWEST = 1200;
const TRIES = 6;

async function paced<T>(url: string, attempt: () => Promise<T>): Promise<T> {
  let pace = paces.get(url);
  if (!pace) paces.set(url, (pace = { spacing: FASTEST, last: 0, resumeAt: 0, pause: 1000 }));
  for (let tries = 1; ; tries++) {
    // Nothing between reading the clock and taking the turn: requests take turns in order.
    for (;;) {
      const wait = Math.max(pace.resumeAt, pace.last + pace.spacing) - Date.now();
      if (wait <= 0) break;
      await sleep(wait);
    }
    pace.last = Date.now();
    try {
      const result = await attempt();
      pace.spacing = Math.max(FASTEST, pace.spacing * 0.9);
      pace.pause = Math.max(1000, pace.pause * 0.75);
      return result;
    } catch (error) {
      if (!(error instanceof ApiError) || error.reason !== 'rate-limited' || tries >= TRIES) throw error;
      pace.resumeAt = Math.max(pace.resumeAt, Date.now() + pace.pause);
      pace.pause = Math.min(pace.pause * 2, 8000);
      pace.spacing = Math.min(SLOWEST, pace.spacing * 2);
    }
  }
}

// `work` over `items` in order, a few at a time: the results up to the first failure, and that
// failure. Nothing new is started after one fails, or `budget` after the first is done (a busy
// node may make that one wait); what's started is seen through, so the results have no gaps.
async function inParallel<T, R>(items: T[], work: (item: T) => Promise<R>, budget: number): Promise<{ results: R[]; error: unknown }> {
  const results: R[] = [];
  let next = 0;
  let failedAt = items.length;
  let error: unknown = null;
  let deadline = Infinity;
  const worker = async () => {
    while (next < items.length && next < failedAt && Date.now() < deadline) {
      const index = next++;
      try {
        results[index] = await work(items[index]!);
        if (index === 0) deadline = Date.now() + budget;
      } catch (cause) {
        if (index < failedAt) [failedAt, error] = [index, cause];
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(PARALLEL, items.length) }, worker));
  // Started in order and all seen through: what's done runs from the first without a gap.
  const count = Math.min(next, failedAt);
  return { results: results.slice(0, count), error: failedAt < items.length ? error : null };
}

type Instruction = { programId: string; type: string | null; info: Record<string, unknown> };

// What one transaction did to `address`, before names and logos.
type Reading = {
  kind: ActivityKind;
  // Smallest units, by mint; null for SOL.
  moves: { mint: string | null; delta: bigint; decimals: number }[];
  fee: string | null;
  counterparty: string | null;
  program: string | null;
};

const asString = (value: unknown) => (typeof value === 'string' ? value : null);
const asBigInt = (value: unknown) => (typeof value === 'number' && Number.isSafeInteger(value) ? BigInt(value) : typeof value === 'string' && /^\d+$/.test(value) ? BigInt(value) : null);

function instructionsOf(transaction: Record<string, unknown>): Instruction[] {
  const message = isObject(transaction.transaction) && isObject(transaction.transaction.message) ? transaction.transaction.message : null;
  const meta = isObject(transaction.meta) ? transaction.meta : null;
  const top = Array.isArray(message?.instructions) ? message.instructions : [];
  const inner = Array.isArray(meta?.innerInstructions)
    ? meta.innerInstructions.flatMap((group) => (isObject(group) && Array.isArray(group.instructions) ? group.instructions : []))
    : [];
  return [...top, ...inner].flatMap((instruction) => {
    if (!isObject(instruction) || typeof instruction.programId !== 'string') return [];
    const parsed = isObject(instruction.parsed) ? instruction.parsed : null;
    return [{ programId: instruction.programId, type: asString(parsed?.type), info: isObject(parsed?.info) ? parsed.info : {} }];
  });
}

export function readTransaction(transaction: Record<string, unknown>, address: string): Reading | null {
  const meta = isObject(transaction.meta) ? transaction.meta : null;
  const message = isObject(transaction.transaction) && isObject(transaction.transaction.message) ? transaction.transaction.message : null;
  if (!meta || !message || !Array.isArray(message.accountKeys) || !Array.isArray(meta.preBalances) || !Array.isArray(meta.postBalances)) return null;

  // With jsonParsed, keys include those loaded from lookup tables, in balance order.
  const keys = message.accountKeys.map((key) =>
    typeof key === 'string' ? { pubkey: key, signer: false } : isObject(key) ? { pubkey: asString(key.pubkey) ?? '', signer: key.signer === true } : { pubkey: '', signer: false },
  );
  const index = keys.findIndex((key) => key.pubkey === address);
  const signed = index >= 0 && keys[index]!.signer;
  const fee = asBigInt(meta.fee) ?? 0n;
  const payer = index === 0;
  const failed = meta.err !== null && meta.err !== undefined;

  // SOL: the address's balance change, the fee aside when it paid it.
  let sol = 0n;
  if (index >= 0) {
    const before = asBigInt(meta.preBalances[index]);
    const after = asBigInt(meta.postBalances[index]);
    if (before !== null && after !== null) sol = after - before + (payer ? fee : 0n);
  }

  // Tokens: every token account the address owns, before and after, by mint. Token accounts are
  // also how the other side of a token transfer is found.
  const owners = new Map<string, string>();
  const tokens = new Map<string, { delta: bigint; decimals: number }>();
  for (const [balances, sign] of [
    [meta.preTokenBalances, -1n],
    [meta.postTokenBalances, 1n],
  ] as const) {
    if (!Array.isArray(balances)) continue;
    for (const balance of balances) {
      if (!isObject(balance) || typeof balance.accountIndex !== 'number' || typeof balance.mint !== 'string') continue;
      const account = keys[balance.accountIndex]?.pubkey;
      const owner = asString(balance.owner);
      if (account && owner) owners.set(account, owner);
      const amount = isObject(balance.uiTokenAmount) ? balance.uiTokenAmount : null;
      const units = asBigInt(amount?.amount);
      if (owner !== address || units === null || typeof amount?.decimals !== 'number') continue;
      const entry = tokens.get(balance.mint) ?? { delta: 0n, decimals: amount.decimals };
      entry.delta += sign * units;
      tokens.set(balance.mint, entry);
    }
  }
  // Wrapped SOL is SOL to the user.
  const wrapped = tokens.get(WRAPPED_SOL);
  if (wrapped) {
    sol += wrapped.delta;
    tokens.delete(WRAPPED_SOL);
  }

  const moves = failed
    ? []
    : [
        ...[...tokens].filter(([, entry]) => entry.delta !== 0n).map(([mint, entry]) => ({ mint, delta: entry.delta, decimals: entry.decimals })),
        ...(sol !== 0n ? [{ mint: null, delta: sol, decimals: 9 }] : []),
      ];

  const instructions = instructionsOf(transaction);
  const program = instructions.find((instruction) => !BASIC_PROGRAMS.has(instruction.programId))?.programId ?? null;

  // The other side: whoever a transfer from the address went to, or came from.
  const ownerOf = (account: unknown) => (typeof account === 'string' ? (owners.get(account) ?? account) : null);
  let to: string | null = null;
  let from: string | null = null;
  for (const { type, info } of instructions) {
    if (type !== 'transfer' && type !== 'transferChecked') continue;
    const sender = asString(info.authority) ?? asString(info.multisigAuthority) ?? (typeof info.lamports === 'number' ? asString(info.source) : ownerOf(info.source));
    const recipient = typeof info.lamports === 'number' ? asString(info.destination) : ownerOf(info.destination);
    if (!sender || !recipient || sender === recipient) continue;
    if (sender === address && recipient !== address) to ??= recipient;
    if (recipient === address && sender !== address) from ??= sender;
  }

  const ins = moves.filter((move) => move.delta > 0n);
  const outs = moves.filter((move) => move.delta < 0n);
  let kind: ActivityKind;
  if (failed) kind = 'failed';
  else if (program === null && signed && outs.length && !ins.length && to) kind = 'send';
  else if (ins.length && !outs.length && from && (program === null || !signed)) kind = 'receive';
  else if (program !== null && ins.length && outs.length) kind = 'swap';
  else kind = 'app';

  return {
    kind,
    moves: [...ins, ...outs],
    fee: payer ? formatUnits(fee, 9) : null,
    counterparty: kind === 'send' || kind === 'failed' ? to : kind === 'receive' ? from : null,
    program,
  };
}

export async function getActivity(
  deps: ActivityDeps,
  request: { network: Network; address: string; before?: string; until?: string; limit?: number },
): Promise<ActivityPage> {
  const { network, address, before, until } = request;
  const limit = request.limit ?? DEFAULT_LIMIT;
  const valid =
    Object.hasOwn(deps.rpc, network) &&
    typeof address === 'string' &&
    ADDRESS.test(address) &&
    [before, until].every((signature) => signature === undefined || (typeof signature === 'string' && SIGNATURE.test(signature))) &&
    Number.isInteger(limit) &&
    limit >= 1 &&
    limit <= MAX_LIMIT;
  if (!valid) throw new ApiError('invalid-request', 'rpc');
  const url = deps.rpc[network];

  const listed = await paced(url, () => getSignatures(deps.fetch, url, address, { before, until, limit }));
  // A node that stops answering partway gives a shorter page, which the next one continues.
  const { results: transactions, error } = await inParallel(
    listed,
    ({ signature }) => paced(url, () => getTransaction(deps.fetch, url, signature)),
    BUDGET_MS,
  );
  if (error && !transactions.length) throw error;
  const signatures = listed.slice(0, transactions.length);
  const more = signatures.length < listed.length || listed.length === limit;

  const readings = signatures.map((entry, i) => {
    const transaction = transactions[i];
    return { ...entry, reading: transaction ? readTransaction(transaction, address) : null };
  });

  // Names and logos, for mainnet tokens.
  const mints = [...new Set(readings.flatMap(({ reading }) => reading?.moves.flatMap((move) => (move.mint ? [move.mint] : [])) ?? []))];
  const infos = network === 'mainnet' && mints.length ? await deps.jupiter.tokenInfo(mints) : new Map<string, TokenInfo | null>();

  const items: Activity[] = readings.flatMap(({ signature, time, reading }) => {
    // Not yet with the node, or not readable: left out rather than shown wrong.
    if (!reading) return [];
    const changes: ActivityChange[] = reading.moves.map(({ mint, delta, decimals }) => {
      const amount = `${delta < 0n ? '-' : '+'}${formatUnits(delta < 0n ? -delta : delta, decimals)}`;
      if (mint === null) return { mint: null, amount, symbol: 'SOL', logo: deps.jupiter.logoOf(WRAPPED_SOL, SOL_LOGO) ?? SOL_LOGO, verified: true };
      const info = infos.get(mint) ?? null;
      return { mint, amount, symbol: info?.symbol ?? null, logo: info?.logo ?? null, verified: info?.verified ?? false };
    });
    return [
      {
        signature,
        time,
        kind: reading.kind,
        changes,
        fee: reading.fee,
        counterparty: reading.counterparty,
        program: reading.program,
        app: reading.program ? (APPS[reading.program] ?? null) : null,
      },
    ];
  });

  return { network, address, items, next: more && signatures.length ? signatures.at(-1)!.signature : null };
}
