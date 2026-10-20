// The exchanges the exchange check knows on Solana, for Settings: how far it covers each one. Its
// deposit addresses are recognized when its own wallets are known (src/server/exchangeWallets.json);
// its tokens are checked when zandr has its list of the tokens it accepts (lib/exchangeTokens.ts).
// Logos are bundled for the big ones, never fetched (see assets/exchanges/NOTICE.md).
import ascendex from '@/assets/exchanges/ascendex.svg';
import backpack from '@/assets/exchanges/backpack.svg';
import binance from '@/assets/exchanges/binance.svg';
import bitfinex from '@/assets/exchanges/bitfinex.png';
import bitget from '@/assets/exchanges/bitget.svg';
import bitstamp from '@/assets/exchanges/bitstamp.svg';
import bybit from '@/assets/exchanges/bybit.svg';
import coinbase from '@/assets/exchanges/coinbase.svg';
import coindcx from '@/assets/exchanges/coindcx.png';
import coinlist from '@/assets/exchanges/coinlist.svg';
import cryptoCom from '@/assets/exchanges/crypto-com.svg';
import gate from '@/assets/exchanges/gate.svg';
import htx from '@/assets/exchanges/htx.png';
import kraken from '@/assets/exchanges/kraken.svg';
import kucoin from '@/assets/exchanges/kucoin.svg';
import latoken from '@/assets/exchanges/latoken.svg';
import mexc from '@/assets/exchanges/mexc.svg';
import okx from '@/assets/exchanges/okx.svg';
import rollbit from '@/assets/exchanges/rollbit.svg';
import swissborg from '@/assets/exchanges/swissborg.svg';
import wallets from '@/server/exchangeWallets.json';
import { exchangeTokenLists } from '@/lib/exchangeTokens';

// "full": deposit addresses recognized and every token checked against the exchange's own list.
// "traded": no list of its own; checked against the tokens it trades (CoinGecko), which stops a token
// it doesn't trade at all. "partial": a list that can't tell every unsupported token (matched by
// symbol, some left unmatched) or is too old. "addresses": its wallets are known, but there's no
// token list, so only its own wallets are stopped.
export type ExchangeCoverage = {
  name: string;
  logo: string | null;
  status: 'full' | 'traded' | 'partial' | 'addresses';
  tokens: number;
  updated: string | null;
};

const LOGOS: Record<string, string> = {
  Binance: binance,
  Coinbase: coinbase,
  OKX: okx,
  Bybit: bybit,
  Kraken: kraken,
  Bitget: bitget,
  KuCoin: kucoin,
  Gate: gate,
  MEXC: mexc,
  HTX: htx,
  AscendEX: ascendex,
  Backpack: backpack,
  Bitfinex: bitfinex,
  Bitstamp: bitstamp,
  CoinDCX: coindcx,
  CoinList: coinlist,
  'Crypto.com': cryptoCom,
  LAToken: latoken,
  Rollbit: rollbit,
  Swissborg: swissborg,
};
// The biggest first, then the rest by name.
const ORDER = ['Binance', 'Coinbase', 'OKX', 'Bybit', 'Kraken', 'Bitget', 'KuCoin', 'Gate', 'MEXC', 'HTX'];
const TRUSTED_FOR = 60 * 24 * 60 * 60 * 1000;
const STATUS_ORDER: ExchangeCoverage['status'][] = ['full', 'traded', 'partial', 'addresses'];

export async function exchangeCoverage(): Promise<ExchangeCoverage[]> {
  const lists = await exchangeTokenLists();
  const names = new Set([...(wallets as { exchanges: { name: string }[] }).exchanges.map(({ name }) => name), ...lists.map(({ exchange }) => exchange)]);
  const coverage = [...names].map((name): ExchangeCoverage => {
    const list = lists.find((entry) => entry.exchange === name);
    const fresh = list ? Date.now() - Date.parse(list.fetchedAt) <= TRUSTED_FOR : false;
    const status = !list ? 'addresses' : !list.complete || !fresh ? 'partial' : list.matchedBy === 'coingecko' ? 'traded' : 'full';
    return { name, logo: LOGOS[name] ?? null, status, tokens: list?.tokens.length ?? 0, updated: list?.fetchedAt ?? null };
  });
  const rank = (name: string) => (ORDER.includes(name) ? ORDER.indexOf(name) : ORDER.length);
  return coverage.sort(
    (a, b) => STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status) || rank(a.name) - rank(b.name) || a.name.localeCompare(b.name),
  );
}
