// Token names, logos and prices from Jupiter, the token list and price source most of Solana
// uses. Both are cached: token info for an hour, prices for half a minute.
import { ApiError, type SwapBuild, type SwapInstruction } from './api.ts';
import { fetchJson, isObject, type Fetch } from './http.ts';

// The public API, without a key, allows 5 requests per 10 seconds from one IP, counting the ones
// it turns away (its x-ratelimit headers say so; the free plan with a key allows the same, per
// account). Up to 5 go at once, then they wait for the window. Otherwise the config says where
// Jupiter is and how often it may be asked: with a paid key (`key`, on zandr's server only), or
// through zandr's server, which holds one, with `fallback` for while that server can't answer.
export type JupiterConfig = { url: string; rate: { requests: number; perMs: number }; key?: string; fallback?: string };
export const JUPITER_PUBLIC: JupiterConfig = { url: 'https://lite-api.jup.ag', rate: { requests: 5, perMs: 10_000 } };
// How long requests go to the fallback after the usual place couldn't answer.
const FALLBACK_MS = 10 * 60_000;

// The most mints one request may name: token search returns at most 100 results, and 80 keep the
// query under 4 KB, which zandr's server takes (a mint is up to 44 characters and a comma).
const INFO_BATCH = 80;
const PRICE_BATCH = 50;
const MINT = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

// `traded`: the token has a market, so asking for its price is worth a request. Most airdropped
// spam has none, and a wallet can hold hundreds of it.
export type TokenInfo = {
  name: string | null;
  symbol: string | null;
  logo: string | null;
  verified: boolean;
  decimals: number | null;
  traded: boolean;
};
export type Price = { price: number; change24h: number | null };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// What a request may ask of the limiter: to go before the others waiting (someone is waiting on
// it, as on a search or a quote), and to be dropped while it waits, when it's no longer wanted.
export type RequestOptions = { urgent?: boolean; signal?: AbortSignal };

const aborted = () => new DOMException('The request is no longer wanted', 'AbortError');

// A sliding window, as the API counts: at most `requests` in any `perMs`. Below that requests go at
// once; one past it waits for the oldest to age out. Urgent ones go first, the rest in the order
// they came; one whose signal aborts while it waits is never sent.
function createLimiter({ requests, perMs }: JupiterConfig['rate']) {
  const sent: number[] = [];
  type Waiting = { urgent: boolean; start: () => void; drop: () => void };
  const queue: Waiting[] = [];
  let running = false;
  // Nothing goes out before this time: Jupiter said its window is used up.
  let heldUntil = 0;

  async function run() {
    if (running) return;
    running = true;
    try {
      while (queue.length) {
        const now = Date.now();
        if (now < heldUntil) {
          await sleep(heldUntil - now);
          continue;
        }
        while (sent.length && sent[0]! <= now - perMs) sent.shift();
        if (sent.length >= requests) {
          await sleep(sent[0]! + perMs - now);
          continue;
        }
        const urgent = queue.findIndex((entry) => entry.urgent);
        const [next] = queue.splice(urgent === -1 ? 0 : urgent, 1);
        sent.push(Date.now());
        next!.start();
      }
    } finally {
      running = false;
    }
  }

  function limit<T>(task: () => Promise<T>, options: RequestOptions = {}): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const { signal } = options;
      if (signal?.aborted) return reject(aborted());
      const entry: Waiting = {
        urgent: options.urgent === true,
        start: () => {
          signal?.removeEventListener('abort', entry.drop);
          task().then(resolve, reject);
        },
        drop: () => {
          const at = queue.indexOf(entry);
          if (at === -1) return;
          queue.splice(at, 1);
          reject(aborted());
        },
      };
      signal?.addEventListener('abort', entry.drop, { once: true });
      queue.push(entry);
      run();
    });
  }

  return Object.assign(limit, {
    holdUntil: (time: number) => {
      heldUntil = Math.max(heldUntil, time);
    },
    held: () => Date.now() < heldUntil,
  });
}

// When Jupiter's rate-limit window resets, as it says with each answer (a Unix time in seconds),
// by this device's clock and at most a window away; undefined if it doesn't say.
function windowReset(headers: Headers, perMs: number): number | undefined {
  const reset = Number(headers.get('x-ratelimit-reset'));
  if (!headers.has('x-ratelimit-reset') || !Number.isFinite(reset)) return undefined;
  return Math.min(reset * 1000 + 100, Date.now() + perMs);
}

// Entries expire after `ttl`; past `limit` entries the oldest go first, so a long-running server
// doesn't grow without bound.
class TtlCache<T> {
  private readonly entries = new Map<string, { value: T; expires: number }>();
  private readonly ttl: number;
  private readonly limit: number;

  constructor(ttl: number, limit = 20_000) {
    this.ttl = ttl;
    this.limit = limit;
  }

  get(key: string): T | undefined {
    const entry = this.entries.get(key);
    if (entry && entry.expires > Date.now()) return entry.value;
    this.entries.delete(key);
    return undefined;
  }

  set(key: string, value: T) {
    this.entries.delete(key);
    this.entries.set(key, { value, expires: Date.now() + this.ttl });
    if (this.entries.size > this.limit) this.entries.delete(this.entries.keys().next().value!);
  }
}

// Names and symbols are whatever the token's creator chose. Control and invisible formatting
// characters go (right-to-left overrides and the like can make a name display as another), and
// the length is capped.
function clean(text: unknown, max: number): string | null {
  if (typeof text !== 'string') return null;
  const cleaned = [...text.replace(/[\p{Cc}\p{Cf}]/gu, '').trim()].slice(0, max).join('');
  return cleaned || null;
}

// Where a token's logo is, as its creator put it: https, or IPFS and Arweave by their gateways.
export function iconSource(icon: unknown): string | null {
  if (typeof icon !== 'string') return null;
  try {
    const url = new URL(icon.trim());
    if (url.protocol === 'ipfs:') return `https://ipfs.io/ipfs/${url.host}${url.pathname}`;
    if (url.protocol === 'ar:') return `https://arweave.net/${url.host}${url.pathname}`;
    return url.protocol === 'https:' ? url.href : null;
  } catch {
    return null;
  }
}

// The symbols and names scam tokens borrow most, to pass for the real thing. An unverified token
// using one shows no logo: without it, a fake "USDC" doesn't look like the real one.
const BORROWED = new Set(
  'SOL WSOL USDC USDT USDS USDE USDG PYUSD EURC JUP JTO PYTH BONK WIF RAY ORCA MSOL JITOSOL BSOL JUPSOL INF ETH WETH BTC WBTC CBBTC TRUMP POPCAT SOLANA USDCOIN TETHER BITCOIN ETHEREUM JUPITER WRAPPEDSOL'.split(' '),
);
const plain = (text: string | null) => (text ?? '').normalize('NFKC').toUpperCase().replace(/[^A-Z0-9]/g, '');

// Where logos come from: zandr's logo server (its URL, logos by mint), or an image proxy (a
// function giving a logo's URL through it from where its creator put it).
export type Logos = string | ((source: string) => string);

// A token's logo, as the wallet shows it. With zandr's logo server or an image proxy (`logos`),
// every token's comes from there, unless an unverified token borrows a well-known name: either
// fetches the creator's image itself, so the creator never sees who looks at it. Without one, only
// verified tokens' logos, straight from where they are.
function logoOf(mint: string, icon: unknown, info: { verified: boolean; symbol: string | null; name: string | null }, logos?: Logos): string | null {
  if (!logos) return info.verified ? iconSource(icon) : null;
  if (!info.verified && (BORROWED.has(plain(info.symbol)) || BORROWED.has(plain(info.name)))) return null;
  if (typeof logos === 'string') return `${logos}/${mint}`;
  const source = iconSource(icon);
  return source ? logos(source) : null;
}

function parseToken(token: Record<string, unknown> & { id: string }, logos?: Logos): TokenInfo {
  const verified = token.isVerified === true;
  const decimals = token.decimals;
  const name = clean(token.name, 48);
  const symbol = clean(token.symbol, 16);
  return {
    name,
    symbol,
    logo: logoOf(token.id, token.icon, { verified, symbol, name }, logos),
    verified,
    decimals: typeof decimals === 'number' && Number.isInteger(decimals) && decimals >= 0 && decimals <= 255 ? decimals : null,
    traded: typeof token.usdPrice === 'number' && token.usdPrice > 0,
  };
}

const AMOUNT = /^\d{1,30}$/;

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const COMPUTE_BUDGET = 'ComputeBudget111111111111111111111111111111';
// Accounts a swap's route may use: below Jupiter's 64, leaving room in the transaction (1232 bytes
// at most) for the wallet's own instructions: the compute limit and zandr's fee.
const MAX_ACCOUNTS = 48;

// Bytes as a Solana address or blockhash is written.
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function base58(bytes: number[]): string {
  let value = bytes.reduce((sum, byte) => sum * 256n + BigInt(byte), 0n);
  let text = '';
  while (value > 0n) {
    text = BASE58[Number(value % 58n)] + text;
    value /= 58n;
  }
  for (const byte of bytes) {
    if (byte !== 0) break;
    text = '1' + text;
  }
  return text;
}

// `logos`: zandr's logo server or an image proxy, as in ApiConfig; `fallbackLogos`: the logos while
// requests go to `config.fallback` (zandr's server, its logo server included, can't answer).
export function createJupiter(fetcher: Fetch, config: JupiterConfig = JUPITER_PUBLIC, logos?: Logos, fallbackLogos?: Logos) {
  const infos = new TtlCache<TokenInfo | null>(60 * 60 * 1000);
  // Where each token's logo is, as Jupiter has it: for zandr's logo server only, never handed out.
  const icons = new TtlCache<string | null>(60 * 60 * 1000);
  const prices = new TtlCache<Price | null>(30 * 1000);
  // What a search found, for a couple of minutes: typing back to an earlier word asks nothing.
  const searches = new TtlCache<(TokenInfo & { mint: string })[]>(2 * 60 * 1000, 200);
  const limit = createLimiter(config.rate);

  // Jupiter says with each answer how much of its rate-limit window is left. Once it's used up,
  // nothing more goes out until the window resets, rather than be turned away: the count kept
  // here starts over whenever the background is put to sleep, and other apps on the same IP
  // count too.
  const heed = (response: Response) => {
    const reset = windowReset(response.headers, config.rate.perMs);
    if (reset !== undefined && (response.status === 429 || response.headers.get('x-ratelimit-remaining') === '0')) limit.holdUntil(reset);
  };

  // Where requests go: the configured place, or, for a while after it couldn't answer (zandr's
  // server without a Jupiter key, or down), the fallback.
  let fallbackUntil = 0;
  const base = () => (config.fallback && Date.now() < fallbackUntil ? config.fallback : config.url);
  const currentLogos = () => (fallbackLogos && config.fallback && Date.now() < fallbackUntil ? fallbackLogos : logos);
  const withKey = (url: string, init?: RequestInit): RequestInit | undefined =>
    config.key && url === config.url ? { ...init, headers: { ...(init?.headers as Record<string, string> | undefined), 'x-api-key': config.key } } : init;

  // Within the rate limit. A request turned away anyway is tried twice more: once the window
  // resets, if Jupiter said when, or else shortly after (waiting out a whole minute would stall
  // the swap in progress). One the usual place couldn't answer goes to the fallback at once.
  async function request(path: string, init?: RequestInit, options: RequestOptions = {}): Promise<unknown> {
    for (let attempt = 0; ; attempt++) {
      const url = base();
      try {
        return await limit(() => fetchJson(fetcher, 'tokens', url + path, withKey(url, init), heed), options);
      } catch (error) {
        if (config.fallback && url === config.url && error instanceof ApiError && error.reason === 'unreachable') {
          fallbackUntil = Date.now() + FALLBACK_MS;
          continue;
        }
        if (attempt === 2 || !(error instanceof ApiError) || error.reason !== 'rate-limited') throw error;
        if (!limit.held()) await sleep(attempt === 0 ? 1500 : 4000);
        if (options.signal?.aborted) throw aborted();
      }
    }
  }

  // Looks mints up in the cache, loads the rest in batches, and caches what they turned out to
  // be, unknown (null) included. Mints that aren't well-formed are never sent anywhere.
  async function lookUp<T>(cache: TtlCache<T | null>, mints: string[], size: number, load: (batch: string[]) => Promise<Map<string, T>>) {
    const found = new Map<string, T | null>();
    const missing: string[] = [];
    for (const mint of new Set(mints)) {
      const hit = cache.get(mint);
      if (hit !== undefined) found.set(mint, hit);
      else if (MINT.test(mint)) missing.push(mint);
    }

    const batches = Array.from({ length: Math.ceil(missing.length / size) }, (_, i) => missing.slice(i * size, (i + 1) * size));
    const loaded = await Promise.all(batches.map(load));
    batches.forEach((batch, i) => {
      for (const mint of batch) {
        const value = loaded[i]!.get(mint) ?? null;
        cache.set(mint, value);
        found.set(mint, value);
      }
    });
    return found;
  }

  // `options`: urgent when someone waits on the answer, as an approval window does.
  const tokenInfo = (mints: string[], options: RequestOptions = {}) =>
    lookUp(infos, mints, INFO_BATCH, async (batch) => {
      const body = await request(`/tokens/v2/search?query=${batch.join(',')}`, undefined, options);
      if (!Array.isArray(body)) throw new ApiError('bad-response', 'tokens');

      const result = new Map<string, TokenInfo>();
      for (const token of body) {
        if (!isObject(token) || typeof token.id !== 'string' || !batch.includes(token.id)) continue;
        result.set(token.id, parseToken({ ...token, id: token.id }, currentLogos()));
        icons.set(token.id, iconSource(token.icon));
      }
      return result;
    });

  return {
    tokenInfo,

    // Where the tokens' logos are (what Jupiter has), for zandr's logo server.
    async iconSources(mints: string[]): Promise<Map<string, string | null>> {
      const found = await tokenInfo(mints);
      return new Map(mints.map((mint) => [mint, found.get(mint) ? (icons.get(mint) ?? null) : null]));
    },

    // A logo by mint from zandr's logo server, or from where it is (`source`) through the image
    // proxy, if there's either: for coins Jupiter isn't asked about, like SOL itself.
    logoOf: (mint: string, source: string): string | null => {
      const from = currentLogos();
      return typeof from === 'string' ? `${from}/${mint}` : from ? from(source) : null;
    },

    // Tokens matching a name, symbol or mint, verified ones first. What's found is cached as
    // token info too.
    async search(query: string, signal?: AbortSignal): Promise<(TokenInfo & { mint: string })[]> {
      const key = query.toLowerCase();
      const cached = searches.get(key);
      if (cached) return cached;
      const body = await request(`/tokens/v2/search?query=${encodeURIComponent(query)}`, undefined, { urgent: true, signal });
      if (!Array.isArray(body)) throw new ApiError('bad-response', 'tokens');
      const found = body.flatMap((token) => {
        if (!isObject(token) || typeof token.id !== 'string' || !MINT.test(token.id)) return [];
        const info = parseToken({ ...token, id: token.id }, currentLogos());
        infos.set(token.id, info);
        icons.set(token.id, iconSource(token.icon));
        return [{ mint: token.id, ...info }];
      });
      const sorted = found.sort((a, b) => Number(b.verified) - Number(a.verified)).slice(0, 30);
      searches.set(key, sorted);
      return sorted;
    },

    // A swap of `amount` (smallest units) of one token for another, built for `taker` (Swap API
    // v2's /build): its price, and the instructions carrying it out, which the wallet puts into a
    // transaction itself and checks before signing. SOL is wrapped and unwrapped on the way. The
    // route is kept to `MAX_ACCOUNTS`, leaving room in the transaction for the wallet's own
    // instructions.
    async build(inputMint: string, outputMint: string, amount: string, slippageBps: number, taker: string): Promise<SwapBuild> {
      const query = new URLSearchParams({ inputMint, outputMint, amount, taker, slippageBps: String(slippageBps), maxAccounts: String(MAX_ACCOUNTS) });
      const body = await request(`/swap/v2/build?${query}`, undefined, { urgent: true });
      const instruction = (value: unknown): SwapInstruction => {
        if (!isObject(value) || typeof value.programId !== 'string' || !MINT.test(value.programId) || !Array.isArray(value.accounts) || typeof value.data !== 'string' || !BASE64.test(value.data)) {
          throw new ApiError('bad-response', 'tokens');
        }
        const accounts = value.accounts.map((account) => {
          if (!isObject(account) || typeof account.pubkey !== 'string' || !MINT.test(account.pubkey) || typeof account.isSigner !== 'boolean' || typeof account.isWritable !== 'boolean') {
            throw new ApiError('bad-response', 'tokens');
          }
          return { address: account.pubkey, signer: account.isSigner, writable: account.isWritable };
        });
        return { program: value.programId, accounts, data: value.data };
      };
      const list = (value: unknown) => (Array.isArray(value) ? value.map(instruction) : []);
      const blockhash = isObject(body) && isObject(body.blockhashWithMetadata) ? body.blockhashWithMetadata : null;
      const hash = blockhash?.blockhash;
      if (
        !isObject(body) ||
        body.inputMint !== inputMint ||
        body.outputMint !== outputMint ||
        body.swapMode !== 'ExactIn' ||
        ![body.inAmount, body.outAmount, body.otherAmountThreshold].every((value) => typeof value === 'string' && AMOUNT.test(value)) ||
        !isObject(body.swapInstruction) ||
        !Array.isArray(hash) ||
        hash.length !== 32 ||
        !hash.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255) ||
        typeof blockhash?.lastValidBlockHeight !== 'number'
      ) {
        throw new ApiError('bad-response', 'tokens');
      }
      const impact = Number(body.priceImpactPct);
      const route = Array.isArray(body.routePlan)
        ? body.routePlan.flatMap((step) => (isObject(step) && isObject(step.swapInfo) ? [clean(step.swapInfo.label, 32) ?? '?'] : []))
        : [];
      // The priority fee Jupiter sets, from recent fees: the wallet caps it.
      const price = list(body.computeBudgetInstructions)
        .map((entry) => (entry.program === COMPUTE_BUDGET ? Uint8Array.from(atob(entry.data), (char) => char.charCodeAt(0)) : null))
        .find((data) => data?.length === 9 && data[0] === 3);
      const tables = isObject(body.addressesByLookupTableAddress) ? Object.keys(body.addressesByLookupTableAddress).filter((table) => MINT.test(table)) : [];
      return {
        inputMint,
        outputMint,
        inAmount: body.inAmount as string,
        outAmount: body.outAmount as string,
        minOutAmount: body.otherAmountThreshold as string,
        slippageBps: typeof body.slippageBps === 'number' ? body.slippageBps : slippageBps,
        priceImpactPct: Number.isFinite(impact) ? impact : 0,
        route,
        instructions: [...list(body.setupInstructions), instruction(body.swapInstruction), ...(body.cleanupInstruction ? [instruction(body.cleanupInstruction)] : []), ...list(body.otherInstructions)],
        computeUnitPrice: price ? new DataView(price.buffer).getBigUint64(1, true).toString() : '0',
        lookupTables: tables,
        blockhash: base58(hash as number[]),
        lastValidBlockHeight: blockhash.lastValidBlockHeight as number,
      };
    },

    // Jupiter leaves out tokens it can't price reliably; they come back as null.
    prices: (mints: string[]) =>
      lookUp(prices, mints, PRICE_BATCH, async (batch) => {
        const body = await request(`/price/v3?ids=${batch.join(',')}`);
        if (!isObject(body)) throw new ApiError('bad-response', 'tokens');

        const result = new Map<string, Price>();
        for (const mint of batch) {
          const entry = body[mint];
          if (!isObject(entry) || typeof entry.usdPrice !== 'number' || !(entry.usdPrice >= 0) || !Number.isFinite(entry.usdPrice)) continue;
          const change = entry.priceChange24h;
          result.set(mint, { price: entry.usdPrice, change24h: typeof change === 'number' && Number.isFinite(change) ? change : null });
        }
        return result;
      }),
  };
}

export type Jupiter = ReturnType<typeof createJupiter>;
