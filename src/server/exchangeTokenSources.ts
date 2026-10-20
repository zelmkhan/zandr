// Where each exchange's list of the tokens it accepts on Solana comes from: its own API. Most answer
// anyone (Binance through the API its website uses); Bybit, OKX and MEXC only requests signed with
// an API key, and are fetched only when keys are given. Bitstamp and Bitfinex name tokens by symbol
// only: those are matched to mints through Jupiter's verified tokens, one per symbol. Exchanges with
// no list of their own get one from CoinGecko: the tokens they trade that exist on Solana. Used by `npm run exchange-tokens` for the snapshot that ships, and by zandr's server to
// keep the lists fresh.
import type { ExchangeToken, ExchangeTokenList } from './exchangeTokens.ts';
import type { Fetch } from './http.ts';
import { createJupiter } from './jupiter.ts';

export type ExchangeKeys = {
  bybit?: { key: string; secret: string };
  okx?: { key: string; secret: string; passphrase: string };
  mexc?: { key: string; secret: string };
  // CoinGecko's free demo key: more requests a minute than without one.
  coingecko?: string;
};
export type SourceDeps = { fetch: Fetch; keys: ExchangeKeys };

const MINT = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const WRAPPED_SOL = 'So11111111111111111111111111111111111111112';

async function getJson(deps: SourceDeps, url: string, headers: Record<string, string> = {}): Promise<unknown> {
  const response = await deps.fetch(url, { headers: { Accept: 'application/json', ...headers }, signal: AbortSignal.timeout(60_000) });
  if (!response.ok) throw new Error(`${new URL(url).host}: HTTP ${response.status}`);
  return response.json();
}

const records = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? value.filter((item): item is Record<string, unknown> => typeof item === 'object' && item !== null) : [];

// An amount as a plain decimal string, or null when there's none (or it's zero).
function decimal(value: unknown): string | null {
  const number = typeof value === 'number' ? value : typeof value === 'string' && value.trim() ? Number(value) : NaN;
  if (!Number.isFinite(number) || number <= 0) return null;
  const text = typeof value === 'string' && /^\d+(\.\d+)?$/.test(value.trim()) ? value.trim() : number.toFixed(20);
  return text.includes('.') ? text.replace(/0+$/, '').replace(/\.$/, '') : text;
}

const coinName = (value: unknown) => String(value ?? '').replace(/[\p{Cc}\p{Cf}]/gu, '').trim().slice(0, 40).toUpperCase();

// One token from an exchange's entry: SOL itself (no contract, wrapped SOL's mint standing for it,
// or a placeholder like Backpack's "So1"), or a mint. Anything else isn't a Solana token and is
// left out.
function token(coin: unknown, contract: unknown, depositMin: unknown, deposit: boolean): ExchangeToken | null {
  const name = coinName(coin);
  const address = String(contract ?? '').trim();
  if (name === 'SOL' && (address === WRAPPED_SOL || !MINT.test(address))) return { mint: null, coin: 'SOL', depositMin: decimal(depositMin), deposit };
  if (!name || !MINT.test(address)) return null;
  return { mint: address, coin: name, depositMin: decimal(depositMin), deposit };
}

function list(exchange: string, source: string, entries: (ExchangeToken | null)[], matchedBy: ExchangeTokenList['matchedBy'] = 'mint', complete = true): ExchangeTokenList {
  // One entry per mint; where an exchange lists one twice, an open one wins.
  const byMint = new Map<string | null, ExchangeToken>();
  for (const entry of entries) {
    if (!entry) continue;
    const current = byMint.get(entry.mint);
    if (!current || (!current.deposit && entry.deposit)) byMint.set(entry.mint, entry);
  }
  const tokens = [...byMint.values()].sort((a, b) => (a.mint === null ? -1 : b.mint === null ? 1 : a.coin.localeCompare(b.coin)));
  // A list with almost nothing on it is a broken answer, not an exchange that dropped Solana.
  if (tokens.length < 2) throw new Error(`${exchange}: only ${tokens.length} Solana tokens`);
  return { exchange, fetchedAt: new Date().toISOString(), source, matchedBy, complete, tokens };
}

async function hmac(secret: string, message: string): Promise<Uint8Array> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(message)));
}
const hex = (bytes: Uint8Array) => [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

// Symbols to mints, by Jupiter's verified tokens: a symbol maps only when exactly one verified token
// has it. Null for a symbol that doesn't.
async function mintsBySymbol(deps: SourceDeps, symbols: string[]): Promise<Map<string, string | null>> {
  const jupiter = createJupiter(deps.fetch);
  const found = new Map<string, string | null>();
  for (const symbol of symbols) {
    // Jupiter turns away bursts: a symbol it won't answer for now is tried again a little later,
    // and left unmatched if it still won't.
    for (let attempt = 0; attempt < 4 && !found.has(symbol); attempt++) {
      try {
        // Symbols are compared without a leading "$" ($WIF is WIF).
        const plain = (text: string | null | undefined) => (text ?? '').replace(/^\$/, '').toUpperCase();
        const matches = (await jupiter.search(symbol)).filter((info) => info.verified && plain(info.symbol) === plain(symbol));
        found.set(symbol, matches.length === 1 ? matches[0]!.mint : null);
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 10_000));
      }
    }
    if (!found.has(symbol)) found.set(symbol, null);
  }
  return found;
}

// A list from symbols: complete only if every symbol found its mint.
async function bySymbol(deps: SourceDeps, exchange: string, source: string, symbols: { coin: string; deposit: boolean }[]): Promise<ExchangeTokenList> {
  const mints = await mintsBySymbol(deps, symbols.map(({ coin }) => coin).filter((coin) => coin !== 'SOL'));
  const entries = symbols.map(({ coin, deposit }) => (coin === 'SOL' ? token('SOL', '', null, deposit) : token(coin, mints.get(coin) ?? '', null, deposit)));
  const unmatched = symbols.filter(({ coin }) => coin !== 'SOL' && !mints.get(coin)).map(({ coin }) => coin);
  return { ...list(exchange, source, entries, 'symbol', unmatched.length === 0), ...(unmatched.length ? { unmatched } : {}) };
}

type Source = { exchange: string; key?: keyof ExchangeKeys; fetch: (deps: SourceDeps) => Promise<ExchangeTokenList> };

export const EXCHANGE_TOKEN_SOURCES: Source[] = [
  {
    exchange: 'Binance',
    async fetch(deps) {
      const source = 'https://www.binance.com/bapi/capital/v1/public/capital/getNetworkCoinAll';
      const body = (await getJson(deps, source)) as { data?: unknown };
      const entries = records(body.data).flatMap((coin) =>
        records(coin.networkList)
          .filter((network) => network.network === 'SOL')
          .map((network) => token(coin.coin, network.contractAddress, network.depositDust, network.depositEnable === true)),
      );
      return list('Binance', source, entries);
    },
  },
  {
    exchange: 'KuCoin',
    async fetch(deps) {
      const source = 'https://api.kucoin.com/api/v3/currencies';
      const body = (await getJson(deps, source)) as { data?: unknown };
      const entries = records(body.data).flatMap((currency) =>
        records(currency.chains)
          .filter((chain) => chain.chainId === 'sol')
          .map((chain) => token(currency.currency, chain.contractAddress, chain.depositMinSize, chain.isDepositEnabled === true)),
      );
      return list('KuCoin', source, entries);
    },
  },
  {
    exchange: 'Gate',
    async fetch(deps) {
      const source = 'https://api.gateio.ws/api/v4/spot/currencies';
      // Delisted tokens aren't credited, whatever their deposit flag says.
      const entries = records(await getJson(deps, source))
        .filter((currency) => currency.delisted !== true)
        .flatMap((currency) =>
          records(currency.chains)
            .filter((chain) => chain.name === 'SOL')
            .map((chain) => token(currency.currency, chain.addr, null, chain.deposit_disabled !== true)),
        );
      return list('Gate', source, entries);
    },
  },
  {
    exchange: 'Bitget',
    async fetch(deps) {
      const source = 'https://api.bitget.com/api/v2/spot/public/coins';
      const body = (await getJson(deps, source)) as { data?: unknown };
      const entries = records(body.data).flatMap((coin) =>
        records(coin.chains)
          .filter((chain) => chain.chain === 'SOL')
          .map((chain) => token(coin.coin, chain.contractAddress, chain.minDepositAmount, chain.rechargeable === 'true')),
      );
      return list('Bitget', source, entries);
    },
  },
  {
    exchange: 'HTX',
    async fetch(deps) {
      const source = 'https://api.huobi.pro/v2/reference/currencies';
      const body = (await getJson(deps, source)) as { data?: unknown };
      const entries = records(body.data)
        .filter((currency) => currency.instStatus !== 'delisted')
        .flatMap((currency) =>
          records(currency.chains)
            .filter((chain) => chain.baseChain === 'SOLANA' || chain.chain === 'sol')
            .map((chain) => token(currency.currency, chain.contractAddress, chain.minDepositAmt, chain.depositStatus === 'allowed')),
        );
      return list('HTX', source, entries);
    },
  },
  {
    exchange: 'Coinbase',
    async fetch(deps) {
      const source = 'https://api.exchange.coinbase.com/currencies';
      const entries = records(await getJson(deps, source))
        .filter((currency) => currency.status !== 'delisted')
        .flatMap((currency) => {
          const details = typeof currency.details === 'object' && currency.details !== null ? (currency.details as Record<string, unknown>) : {};
          return records(details.supported_networks ?? currency.supported_networks)
            .filter((network) => network.id === 'solana')
            .map((network) => token(currency.id, network.contract_address, null, network.status === 'online'));
        });
      return list('Coinbase', source, entries);
    },
  },
  {
    exchange: 'Backpack',
    async fetch(deps) {
      const source = 'https://api.backpack.exchange/api/v1/assets';
      const entries = records(await getJson(deps, source)).flatMap((asset) =>
        records(asset.tokens)
          .filter((entry) => entry.blockchain === 'Solana')
          .map((entry) => token(asset.symbol, entry.contractAddress, entry.minimumDeposit, entry.depositEnabled === true)),
      );
      return list('Backpack', source, entries);
    },
  },
  {
    exchange: 'Bitstamp',
    async fetch(deps) {
      const source = 'https://www.bitstamp.net/api/v2/currencies/';
      const symbols = records(await getJson(deps, source)).flatMap((currency) =>
        records(currency.networks)
          .filter((network) => network.network === 'solana')
          .map((network) => ({ coin: coinName(currency.currency), deposit: network.deposit === 'Enabled' })),
      );
      return bySymbol(deps, 'Bitstamp', source, symbols);
    },
  },
  {
    exchange: 'Bitfinex',
    async fetch(deps) {
      // Bitfinex's deposit methods, by network: those on Solana, with Bitfinex's own currency codes
      // (UST is its USDT).
      const source = 'https://api-pub.bitfinex.com/v2/conf/pub:map:tx:method';
      const [methods] = (await getJson(deps, source)) as [unknown];
      const codes = Array.isArray(methods) ? (methods as [string, string[]][]).filter(([method]) => method === 'SOL' || method.endsWith('SOL')) : [];
      const renamed: Record<string, string> = { UST: 'USDT', XAUT0SOL: 'XAUT0' };
      const symbols = codes.flatMap(([, currencies]) => currencies.map((code) => ({ coin: renamed[code] ?? code, deposit: true })));
      return bySymbol(deps, 'Bitfinex', source, symbols);
    },
  },
  {
    exchange: 'Bybit',
    key: 'bybit',
    async fetch(deps) {
      const { key, secret } = deps.keys.bybit!;
      const source = 'https://api.bybit.com/v5/asset/coin/query-info';
      const timestamp = String(Date.now());
      const window = '10000';
      const sign = hex(await hmac(secret, timestamp + key + window));
      const body = (await getJson(deps, source, { 'X-BAPI-API-KEY': key, 'X-BAPI-TIMESTAMP': timestamp, 'X-BAPI-RECV-WINDOW': window, 'X-BAPI-SIGN': sign })) as {
        retCode?: number;
        retMsg?: string;
        result?: { rows?: unknown };
      };
      if (body.retCode !== 0) throw new Error(`Bybit: ${body.retCode} ${body.retMsg}`);
      const entries = records(body.result?.rows).flatMap((row) =>
        records(row.chains)
          .filter((chain) => chain.chain === 'SOL' || chain.chainType === 'SOL')
          .map((chain) => token(row.coin, chain.contractAddress, chain.depositMin, chain.chainDeposit === '1')),
      );
      return list('Bybit', source, entries);
    },
  },
  {
    exchange: 'OKX',
    key: 'okx',
    async fetch(deps) {
      const { key, secret, passphrase } = deps.keys.okx!;
      const path = '/api/v5/asset/currencies';
      const source = `https://www.okx.com${path}`;
      const timestamp = new Date().toISOString();
      const sign = base64(await hmac(secret, `${timestamp}GET${path}`));
      const body = (await getJson(deps, source, { 'OK-ACCESS-KEY': key, 'OK-ACCESS-SIGN': sign, 'OK-ACCESS-TIMESTAMP': timestamp, 'OK-ACCESS-PASSPHRASE': passphrase })) as {
        code?: string;
        msg?: string;
        data?: unknown;
      };
      if (body.code !== '0') throw new Error(`OKX: ${body.code} ${body.msg}`);
      const entries = records(body.data)
        .filter((currency) => String(currency.chain ?? '').endsWith('-Solana'))
        .map((currency) => token(currency.ccy, currency.ctAddr, currency.minDep, currency.canDep === true));
      return list('OKX', source, entries);
    },
  },
  {
    exchange: 'MEXC',
    key: 'mexc',
    async fetch(deps) {
      const { key, secret } = deps.keys.mexc!;
      const query = `timestamp=${Date.now()}&recvWindow=10000`;
      const source = 'https://api.mexc.com/api/v3/capital/config/getall';
      const body = await getJson(deps, `${source}?${query}&signature=${hex(await hmac(secret, query))}`, { 'X-MEXC-APIKEY': key });
      const entries = records(body).flatMap((coin) =>
        records(coin.networkList)
          .filter((network) => network.netWork === 'SOL' || /^solana\b/i.test(String(network.network ?? '')))
          .map((network) => token(coin.coin, network.contract, network.depositMin ?? network.minDeposit, network.depositEnable === true)),
      );
      return list('MEXC', source, entries);
    },
  },
];

// ---- CoinGecko ----

// Exchanges without a list of their own, by their CoinGecko ids. One that gets its own list (with an
// API key) goes by that instead.
const COINGECKO_EXCHANGES: Record<string, string> = {
  OKX: 'okex',
  Bybit: 'bybit_spot',
  MEXC: 'mxc',
  Kraken: 'kraken',
  'Crypto.com': 'crypto_com',
  CoinDCX: 'coindcx',
  LAToken: 'latoken',
};
// Trading lists change slowly: fetched again once a day, not at every refresh.
const COINGECKO_EVERY_MS = 20 * 60 * 60 * 1000;
// CoinGecko's free API allows a few requests a minute: they're spaced out, and a refusal waits a minute.
const COINGECKO_SPACING_MS = 2_500;
let coingeckoLast = 0;

async function coingecko(deps: SourceDeps, path: string): Promise<unknown> {
  const url = `https://api.coingecko.com/api/v3${path}`;
  for (let attempt = 0; attempt < 4; attempt++) {
    const wait = coingeckoLast + COINGECKO_SPACING_MS - Date.now();
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    coingeckoLast = Date.now();
    const response = await deps.fetch(url, {
      headers: { Accept: 'application/json', ...(deps.keys.coingecko ? { 'x-cg-demo-api-key': deps.keys.coingecko } : {}) },
      signal: AbortSignal.timeout(120_000),
    });
    if (response.status === 429) {
      await new Promise((resolve) => setTimeout(resolve, 60_000));
      continue;
    }
    if (!response.ok) throw new Error(`CoinGecko ${path.split('?')[0]}: HTTP ${response.status}`);
    return response.json();
  }
  throw new Error(`CoinGecko ${path.split('?')[0]}: rate-limited`);
}

// The tokens an exchange trades, by CoinGecko, that exist on Solana: each traded coin's Solana mint,
// and SOL itself. Wrapped SOL isn't SOL: exchanges trade the coin, not the token.
async function coingeckoList(deps: SourceDeps, exchange: string, id: string, solanaMints: Map<string, { mint: string; symbol: string }>): Promise<ExchangeTokenList> {
  const traded = new Set<string>();
  for (let page = 1; page <= 60; page++) {
    const body = (await coingecko(deps, `/exchanges/${id}/tickers?page=${page}&depth=false`)) as { tickers?: unknown };
    const tickers = records(body.tickers);
    for (const ticker of tickers) {
      for (const coin of [ticker.coin_id, ticker.target_coin_id]) if (typeof coin === 'string') traded.add(coin);
    }
    if (tickers.length < 100) break;
  }
  const entries = [...traded].map((coin) => {
    if (coin === 'solana') return token('SOL', '', null, true);
    const found = solanaMints.get(coin);
    return found && found.mint !== WRAPPED_SOL ? token(found.symbol, found.mint, null, true) : null;
  });
  const source = `https://www.coingecko.com/en/exchanges/${id}`;
  const tradingList = list(exchange, source, entries, 'coingecko', true);
  if (!usableTradingList(tradingList)) throw new Error(`only ${tradingList.tokens.length} Solana tokens traded, by CoinGecko: too few to go by`);
  return tradingList;
}

// A trading list worth going by: SOL on it, and enough else that it isn't CoinGecko knowing little of
// the exchange (it would stop most transfers wrongly).
const usableTradingList = (entry: ExchangeTokenList) => entry.tokens.length >= 20 && entry.tokens.some((token) => token.mint === null);

// Every exchange's list, fetched now. One that fails, or comes back much shorter than before
// (`previous`), keeps its previous list; `problems` says which and why.
export async function fetchExchangeTokens(deps: SourceDeps, previous: ExchangeTokenList[]): Promise<{ lists: ExchangeTokenList[]; problems: string[] }> {
  const lists: ExchangeTokenList[] = [];
  const problems: string[] = [];
  for (const source of EXCHANGE_TOKEN_SOURCES) {
    const before = previous.find((entry) => entry.exchange === source.exchange);
    if (source.key && !deps.keys[source.key]) {
      if (before) lists.push(before);
      continue;
    }
    try {
      const fetched = await source.fetch(deps);
      if (fetched.unmatched) problems.push(`${source.exchange}: no single verified mint for ${fetched.unmatched.join(', ')}; it won't say a token isn't taken`);
      if (before && fetched.tokens.length < before.tokens.length * 0.7) {
        problems.push(`${source.exchange}: ${fetched.tokens.length} tokens, down from ${before.tokens.length}; keeping the previous list`);
        lists.push(before);
      } else {
        lists.push(fetched);
      }
    } catch (error) {
      problems.push(`${source.exchange}: ${error instanceof Error ? error.message : String(error)}${before ? '; keeping the previous list' : ''}`);
      if (before) lists.push(before);
    }
  }
  // Exchanges with no list of their own (none fetched, none from before): from CoinGecko, unless a
  // recent one is there already.
  const wanting = Object.entries(COINGECKO_EXCHANGES).filter(([exchange]) => !lists.some((entry) => entry.exchange === exchange));
  let solanaMints: Map<string, { mint: string; symbol: string }> | null = null;
  for (const [exchange, id] of wanting) {
    const before = previous.find((entry) => entry.exchange === exchange && entry.matchedBy === 'coingecko' && usableTradingList(entry));
    if (before && Date.now() - Date.parse(before.fetchedAt) < COINGECKO_EVERY_MS) {
      lists.push(before);
      continue;
    }
    try {
      solanaMints ??= new Map(
        records(await coingecko(deps, '/coins/list?include_platform=true')).flatMap((coin) => {
          const platforms = typeof coin.platforms === 'object' && coin.platforms !== null ? (coin.platforms as Record<string, unknown>) : {};
          const mint = String(platforms.solana ?? '').trim();
          return typeof coin.id === 'string' && MINT.test(mint) ? [[coin.id, { mint, symbol: String(coin.symbol ?? '') }] as const] : [];
        }),
      );
      const fetched = await coingeckoList(deps, exchange, id, solanaMints);
      if (before && fetched.tokens.length < before.tokens.length * 0.7) {
        problems.push(`${exchange}: ${fetched.tokens.length} traded tokens, down from ${before.tokens.length}; keeping the previous list`);
        lists.push(before);
      } else {
        lists.push(fetched);
      }
    } catch (error) {
      problems.push(`${exchange} (CoinGecko): ${error instanceof Error ? error.message : String(error)}${before ? '; keeping the previous list' : ''}`);
      if (before) lists.push(before);
    }
  }
  return { lists, problems };
}
