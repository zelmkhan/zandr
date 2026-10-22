// Which tokens each exchange accepts as deposits on Solana. The lists come from the exchanges' own
// APIs (exchangeTokenSources.ts): a snapshot ships with zandr (exchangeTokens.json, written by
// `npm run exchange-tokens`), zandr's server refreshes them every few hours, and the extension
// fetches those. Tokens are matched by mint address, never by name, so a look-alike token isn't
// taken for the real one.

// One token an exchange takes on Solana: its mint (null for SOL itself), the exchange's name for
// it, the least it credits in whole tokens (null if it doesn't say), and whether deposits were
// open when the list was fetched.
export type ExchangeToken = { mint: string | null; coin: string; depositMin: string | null; deposit: boolean };

export type ExchangeTokenList = {
  exchange: string;
  // When it was fetched (ISO time).
  fetchedAt: string;
  source: string;
  // "mint": the exchange names each token's mint. "symbol": it names only symbols, which zandr
  // matched to mints (verified tokens, one per symbol). "coingecko": the exchange publishes no list;
  // these are the tokens it trades, by CoinGecko, that exist on Solana. Such a list tells a token
  // the exchange doesn't trade at all, but not one it trades yet takes only on another network.
  matchedBy: 'mint' | 'symbol' | 'coingecko';
  // Whether a token missing from the list means the exchange doesn't take it. A list matched by
  // symbol with any symbol left unmatched isn't complete.
  complete: boolean;
  // For a list by symbol: the symbols that found no single verified mint.
  unmatched?: string[];
  tokens: ExchangeToken[];
};

export type ExchangeTokenLists = { updated: string; lists: ExchangeTokenList[] };

// What a list says about sending a token to one of the exchange's deposit addresses.
export type ExchangeVerdict = {
  // False when the list is complete and the token isn't on it.
  accepted: boolean;
  coin: string | null;
  depositMin: string | null;
  // Deposits of it were paused when the list was fetched, however long ago: the protection stops the
  // transfer, and turning it off is the user's call.
  paused: boolean;
  // What the list is of: the tokens the exchange takes on Solana, or (from CoinGecko) the ones it trades.
  basis: 'deposits' | 'trading';
};

const DAY = 24 * 60 * 60 * 1000;
// A list this old may miss tokens the exchange has added since: it no longer says what isn't taken.
const TRUSTED_FOR = 60 * DAY;

// CoinGecko often files an exchange's markets in these under the fiat they track: a list from it
// that lacks one says nothing about it.
const STABLECOINS = new Set(['EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB']);

const MINT = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const DECIMAL = /^\d{1,20}(\.\d{1,20})?$/;

function age(list: ExchangeTokenList, now: number): number {
  const fetched = Date.parse(list.fetchedAt);
  return Number.isFinite(fetched) ? now - fetched : Infinity;
}

// What the exchange's list says about a token, or null when there's no list for the exchange or it
// says nothing of the token. However old the list, a token on it keeps its pause and minimum;
// only past TRUSTED_FOR does a token missing from it no longer count as not taken.
export function exchangeVerdict(lists: ExchangeTokenList[], exchange: string, mint: string | null, now = Date.now()): ExchangeVerdict | null {
  const list = lists.find((entry) => entry.exchange === exchange);
  if (!list) return null;
  const old = age(list, now);
  if (!Number.isFinite(old) || old < -DAY) return null;
  const token = list.tokens.find((entry) => entry.mint === mint) ?? null;
  const basis = list.matchedBy === 'coingecko' ? 'trading' : 'deposits';
  if (!token && basis === 'trading' && mint !== null && STABLECOINS.has(mint)) return null;
  if (!token) return list.complete && old <= TRUSTED_FOR ? { accepted: false, coin: null, depositMin: null, paused: false, basis } : null;
  return { accepted: true, coin: token.coin, depositMin: token.depositMin, paused: !token.deposit, basis };
}

// Per exchange, the newer of two sets of lists: the snapshot that ships and a fetched one. A
// fetched list much shorter than the one it would replace is taken for a broken fetch and passed
// over.
export function newestLists(shipped: ExchangeTokenList[], fetched: ExchangeTokenList[]): ExchangeTokenList[] {
  const byExchange = new Map(shipped.map((list) => [list.exchange, list]));
  for (const list of fetched) {
    const current = byExchange.get(list.exchange);
    if (!current) byExchange.set(list.exchange, list);
    else if (Date.parse(list.fetchedAt) > Date.parse(current.fetchedAt) && list.tokens.length >= current.tokens.length * 0.7) {
      byExchange.set(list.exchange, list);
    }
  }
  return [...byExchange.values()];
}

// Lists as they came over the network, checked field by field, or null if anything is off.
export function validLists(value: unknown): ExchangeTokenLists | null {
  if (typeof value !== 'object' || value === null) return null;
  const { updated, lists } = value as { updated?: unknown; lists?: unknown };
  if (typeof updated !== 'string' || !Array.isArray(lists) || lists.length > 100) return null;
  const checked: ExchangeTokenList[] = [];
  for (const list of lists as Record<string, unknown>[]) {
    if (typeof list !== 'object' || list === null) return null;
    const { exchange, fetchedAt, source, matchedBy, complete, unmatched, tokens } = list;
    if (typeof exchange !== 'string' || !exchange || exchange.length > 40) return null;
    if (typeof fetchedAt !== 'string' || !Number.isFinite(Date.parse(fetchedAt)) || typeof source !== 'string') return null;
    if ((matchedBy !== 'mint' && matchedBy !== 'symbol' && matchedBy !== 'coingecko') || typeof complete !== 'boolean') return null;
    if (unmatched !== undefined && (!Array.isArray(unmatched) || unmatched.some((symbol) => typeof symbol !== 'string'))) return null;
    if (!Array.isArray(tokens) || tokens.length > 5000) return null;
    const entries: ExchangeToken[] = [];
    for (const token of tokens as Record<string, unknown>[]) {
      if (typeof token !== 'object' || token === null) return null;
      const { mint, coin, depositMin, deposit } = token;
      if (mint !== null && (typeof mint !== 'string' || !MINT.test(mint))) return null;
      if (typeof coin !== 'string' || coin.length > 40 || typeof deposit !== 'boolean') return null;
      if (depositMin !== null && (typeof depositMin !== 'string' || !DECIMAL.test(depositMin))) return null;
      entries.push({ mint, coin, depositMin, deposit });
    }
    // A list with nothing on it says nothing.
    if (!entries.length) continue;
    checked.push({
      exchange,
      fetchedAt,
      source,
      matchedBy,
      complete,
      ...(unmatched ? { unmatched: (unmatched as string[]).slice(0, 100) } : {}),
      tokens: entries,
    });
  }
  return { updated, lists: checked };
}
