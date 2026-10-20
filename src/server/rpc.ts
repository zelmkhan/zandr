// A minimal Solana JSON-RPC client: just the calls the API makes.
import { ApiError } from './api.ts';
import { fetchJson, isObject, type Fetch } from './http.ts';

export const TOKEN_PROGRAMS = {
  token: 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
  'token-2022': 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb',
} as const;

export type TokenProgram = keyof typeof TOKEN_PROGRAMS;

export type TokenAccount = { mint: string; amount: string; decimals: number; balance: string };

// A node asked for state at least as new as a slot it hasn't reached yet (minContextSlot) says
// so with this code. It catches up within moments: ask again a few times.
const BEHIND = -32016;
const BEHIND_WAIT_MS = 400;
const BEHIND_TRIES = 6;

async function call(fetcher: Fetch, url: string, method: string, params: unknown[] | Record<string, unknown>): Promise<unknown> {
  for (let attempt = 1; ; attempt++) {
    const body = await fetchJson(fetcher, 'rpc', url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    });
    if (!isObject(body)) throw new ApiError('bad-response', 'rpc');

    // Some nodes report rate limits as a JSON-RPC error rather than HTTP 429.
    if (isObject(body.error)) {
      const { code } = body.error;
      if (code === BEHIND && attempt < BEHIND_TRIES) {
        await new Promise((resolve) => setTimeout(resolve, BEHIND_WAIT_MS));
        continue;
      }
      if (code === BEHIND) throw new ApiError('unreachable', 'rpc');
      if (code === 429 || code === -32429) throw new ApiError('rate-limited', 'rpc');
      if (code === -32602) throw new ApiError('invalid-request', 'rpc');
      throw new ApiError('bad-response', 'rpc');
    }
    if (!('result' in body)) throw new ApiError('bad-response', 'rpc');
    return body.result;
  }
}

// Balances read at the processed commitment, as soon as a node has run a block, the way the live
// coins are told of changes; and, given a slot, from a node that has reached it.
function readConfig(minContextSlot?: number) {
  return { commitment: 'processed', ...(minContextSlot !== undefined && { minContextSlot }) };
}

// A token's image as its metadata names it, by the DAS API's getAsset. Providers like Helius have
// it; a plain node doesn't, and the call fails.
export async function getAssetImage(fetcher: Fetch, url: string, mint: string): Promise<string | null> {
  const result = await call(fetcher, url, 'getAsset', { id: mint });
  const content = isObject(result) && isObject(result.content) ? result.content : null;
  const links = content && isObject(content.links) ? content.links : null;
  const file = content && Array.isArray(content.files) && isObject(content.files[0]) ? content.files[0] : null;
  const image = links?.image ?? file?.uri;
  return typeof image === 'string' ? image : null;
}

// The SOL balance, in lamports.
export async function getBalance(fetcher: Fetch, url: string, address: string, minContextSlot?: number): Promise<bigint> {
  const result = await call(fetcher, url, 'getBalance', [address, readConfig(minContextSlot)]);
  const lamports = isObject(result) ? result.value : undefined;
  if (typeof lamports !== 'number' || !Number.isSafeInteger(lamports) || lamports < 0) throw new ApiError('bad-response', 'rpc');
  return BigInt(lamports);
}

// The address's token accounts under one token program. An entry that doesn't parse is skipped
// rather than failing the whole list.
export async function getTokenAccounts(
  fetcher: Fetch,
  url: string,
  address: string,
  program: TokenProgram,
  minContextSlot?: number,
): Promise<TokenAccount[]> {
  const result = await call(fetcher, url, 'getTokenAccountsByOwner', [
    address,
    { programId: TOKEN_PROGRAMS[program] },
    { encoding: 'jsonParsed', ...readConfig(minContextSlot) },
  ]);
  if (!isObject(result) || !Array.isArray(result.value)) throw new ApiError('bad-response', 'rpc');

  const accounts: TokenAccount[] = [];
  for (const entry of result.value) {
    const info = isObject(entry) && isObject(entry.account) && isObject(entry.account.data) && isObject(entry.account.data.parsed)
      ? entry.account.data.parsed.info
      : undefined;
    if (!isObject(info) || typeof info.mint !== 'string' || !isObject(info.tokenAmount)) continue;

    const { amount, decimals, uiAmountString } = info.tokenAmount;
    if (typeof amount !== 'string' || !/^\d+$/.test(amount) || typeof decimals !== 'number') continue;
    const balance = typeof uiAmountString === 'string' && /^\d+(\.\d+)?$/.test(uiAmountString) ? uiAmountString : formatUnits(BigInt(amount), decimals);
    accounts.push({ mint: info.mint, amount, decimals, balance });
  }
  return accounts;
}

export type SignatureInfo = { signature: string; time: number | null };

// The address's transactions, newest first: before `before`, newer than `until`, up to `limit`.
export async function getSignatures(
  fetcher: Fetch,
  url: string,
  address: string,
  options: { before?: string; until?: string; limit: number },
): Promise<SignatureInfo[]> {
  const result = await call(fetcher, url, 'getSignaturesForAddress', [
    address,
    { limit: options.limit, commitment: 'confirmed', ...(options.before && { before: options.before }), ...(options.until && { until: options.until }) },
  ]);
  if (!Array.isArray(result)) throw new ApiError('bad-response', 'rpc');
  return result.flatMap((entry) =>
    isObject(entry) && typeof entry.signature === 'string'
      ? [{ signature: entry.signature, time: typeof entry.blockTime === 'number' ? entry.blockTime * 1000 : null }]
      : [],
  );
}

// One transaction as the node parses it, or null if the node doesn't have it (yet).
export async function getTransaction(fetcher: Fetch, url: string, signature: string): Promise<Record<string, unknown> | null> {
  const result = await call(fetcher, url, 'getTransaction', [
    signature,
    // Version 1 transactions are on mainnet now, and a node refuses to return one to a client that
    // says it reads only up to version 0. Parsed, they look like the others.
    { encoding: 'jsonParsed', commitment: 'confirmed', maxSupportedTransactionVersion: 1 },
  ]);
  if (result === null) return null;
  if (!isObject(result)) throw new ApiError('bad-response', 'rpc');
  return result;
}

// An amount in a token's smallest unit as a decimal string: 1234500 with 6 decimals is "1.2345".
export function formatUnits(amount: bigint, decimals: number): string {
  const digits = amount.toString().padStart(decimals + 1, '0');
  const whole = digits.slice(0, digits.length - decimals);
  const fraction = digits.slice(digits.length - decimals).replace(/0+$/, '');
  return fraction ? `${whole}.${fraction}` : whole;
}

// The sum of two non-negative decimal strings, exactly.
export function addDecimals(a: string, b: string): string {
  const places = Math.max(a.split('.')[1]?.length ?? 0, b.split('.')[1]?.length ?? 0);
  const units = (value: string) => {
    const [whole, fraction = ''] = value.split('.');
    return BigInt(whole + fraction.padEnd(places, '0'));
  };
  return formatUnits(units(a) + units(b), places);
}
