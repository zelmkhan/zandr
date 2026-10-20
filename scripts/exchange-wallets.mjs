// Refreshes src/server/exchangeWallets.json: the wallets exchanges control on Solana, which tell
// their deposit addresses apart (src/server/exchanges.ts). Run before a release:
// `npm run exchange-wallets`.
//
// Where each exchange's wallets come from, best first (`trust` in the file):
// - "exchange": the exchange's own API (Binance's proof of reserves, Backpack, Bitstamp);
// - "proof-of-reserves": its proof-of-reserves wallets as DefiLlama collects them for its exchange
//   dashboards (OKX, Bitget, KuCoin, Gate, HTX, Bitfinex);
// - "on-chain": zandr checking on chain, by hand (Bybit, which publishes no list); kept as they are;
// - "community": Dune Spellbook's exchange labels. Its license (BSL 1.1, until it turns GPL on
//   2027-03-03) doesn't cover data platforms; they're used at the project owner's decision, kept
//   apart so they can be dropped at once.
// An address claimed by two exchanges goes to the more trusted source; claimed by two at the same
// trust, it's left out. Every address is read from the chain: token and stake accounts are left out.
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const file = join(root, 'src/server/exchangeWallets.json');
const RPC = process.env.SOLANA_RPC_MAINNET || 'https://api-production-3931.up.railway.app/rpc/mainnet';
const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

async function json(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.json();
}

const TRUST = ['exchange', 'proof-of-reserves', 'on-chain', 'community'];

async function binance() {
  const source = 'https://www.binance.com/bapi/apex/v1/public/apex/market/por/address';
  const { data } = await json(source);
  const wallets = data
    .filter((row) => row.network === 'SOL')
    .map((row) => ({ address: row.address, ...(row.thirdPartyCustodianName ? { note: `held with ${row.thirdPartyCustodianName}` } : {}) }));
  return [{ name: 'Binance', trust: 'exchange', source, basis: "Binance's own proof-of-reserves address list", wallets }];
}

async function backpack() {
  const source = 'https://api.backpack.exchange/api/v1/wallets';
  const rows = await json(source);
  const wallets = rows.filter((row) => row.blockchain === 'Solana').map(({ address }) => ({ address }));
  return [{ name: 'Backpack', trust: 'exchange', source, basis: "Backpack's own wallet list", wallets }];
}

async function bitstamp() {
  const source = 'https://www.bitstamp.net/api/v2/wallet_transparency/';
  const addresses = new Set();
  for (let page = 1; page <= 50; page++) {
    const { wallets } = await json(`${source}?perPage=100&page=${page}`);
    const lists = Object.values(wallets ?? {});
    if (!lists.length) break;
    for (const list of lists) for (const wallet of list) if (/^sol/i.test(wallet.network)) addresses.add(wallet.address);
  }
  return [{ name: 'Bitstamp', trust: 'exchange', source, basis: "Bitstamp's own wallet transparency list", wallets: [...addresses].map((address) => ({ address })) }];
}

// The `solana` owners in a DefiLlama exchange adapter, leaving out the commented-out ones.
async function defillama(name, project, basis) {
  const source = `https://github.com/DefiLlama/DefiLlama-Adapters/blob/main/projects/${project}/index.js`;
  const response = await fetch(`https://raw.githubusercontent.com/DefiLlama/DefiLlama-Adapters/main/projects/${project}/index.js`);
  if (!response.ok) throw new Error(`${source}: HTTP ${response.status}`);
  const code = await response.text();
  const at = code.search(/["']?solana["']?\s*:\s*\{/);
  if (at < 0) throw new Error(`${source}: no solana section`);
  const open = code.indexOf('[', at);
  const block = code.slice(open + 1, code.indexOf(']', open));
  const addresses = block
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => !line.startsWith('//'))
    .flatMap((line) => [...line.matchAll(/["']([1-9A-HJ-NP-Za-km-z]{32,44})["']/g)].map((match) => match[1]));
  return [{ name, trust: 'proof-of-reserves', source, basis, wallets: [...new Set(addresses)].map((address) => ({ address })) }];
}

// Dune Spellbook's Solana exchange labels, one list per exchange, by the names zandr uses.
const SPELLBOOK_NAMES = { 'Gate.io': 'Gate' };
async function spellbook() {
  const path = 'dbt_subprojects/hourly_spellbook/models/_sector/cex/addresses/chains/solana/cex_solana_addresses.sql';
  const source = `https://github.com/duneanalytics/spellbook/blob/main/${path}`;
  const response = await fetch(`https://raw.githubusercontent.com/duneanalytics/spellbook/main/${path}`);
  if (!response.ok) throw new Error(`${source}: HTTP ${response.status}`);
  const sql = await response.text();
  const byExchange = new Map();
  for (const [, address, cex, label] of sql.matchAll(/\('solana',\s*'([1-9A-HJ-NP-Za-km-z]{32,44})',\s*'([^']+)',\s*'([^']+)'/g)) {
    const name = SPELLBOOK_NAMES[cex] ?? cex;
    byExchange.set(name, [...(byExchange.get(name) ?? []), { address, note: `labeled "${label}"` }]);
  }
  if (byExchange.size < 5) throw new Error(`${source}: only ${byExchange.size} exchanges found`);
  return [...byExchange].map(([name, wallets]) => ({
    name,
    trust: 'community',
    source,
    basis: "Dune Spellbook's community labels (BSL 1.1: not licensed for data platforms; used at the owner's decision)",
    wallets,
  }));
}

const fetchers = {
  Binance: binance,
  OKX: () => defillama('OKX', 'okex', "OKX's proof-of-reserves wallets, as collected by DefiLlama"),
  Bitget: () => defillama('Bitget', 'bitget', "Bitget's proof-of-reserves wallets, as collected by DefiLlama"),
  KuCoin: () => defillama('KuCoin', 'kucoin', "KuCoin's proof-of-reserves wallets, as collected by DefiLlama"),
  Gate: () => defillama('Gate', 'gate-io', "Gate's proof-of-reserves wallets, as collected by DefiLlama"),
  HTX: () => defillama('HTX', 'huobi', "HTX's proof-of-reserves wallets, as collected by DefiLlama"),
  Bitfinex: () => defillama('Bitfinex', 'bitfinex', "Bitfinex's published wallets, as collected by DefiLlama"),
  Backpack: backpack,
  Bitstamp: bitstamp,
  Spellbook: spellbook,
};

// Exchanges left out whatever a source says: they no longer operate.
const LEFT_OUT = new Set(['FTX', 'FTX US']);

const previous = JSON.parse(readFileSync(file, 'utf8'));
const exchanges = [];
for (const [name, fetcher] of Object.entries(fetchers)) {
  try {
    exchanges.push(...(await fetcher()));
  } catch (error) {
    // A source that's down keeps its last lists rather than dropping them.
    const kept = previous.exchanges.filter((exchange) => (name === 'Spellbook' ? exchange.trust === 'community' : exchange.name === name && exchange.trust !== 'community'));
    console.warn(`${name}: ${error.message}${kept.length ? '; keeping the last lists' : ''}`);
    exchanges.push(...kept);
  }
}
for (const exchange of previous.exchanges) if (exchange.trust === 'on-chain') exchanges.push(exchange);
for (let i = exchanges.length - 1; i >= 0; i--) if (LEFT_OUT.has(exchanges[i].name)) exchanges.splice(i, 1);

// What each address is on chain.
const all = [...new Set(exchanges.flatMap((exchange) => exchange.wallets.map((wallet) => wallet.address)))].filter((address) => ADDRESS.test(address));
const kinds = new Map();
for (let i = 0; i < all.length; i += 100) {
  const batch = all.slice(i, i + 100);
  const response = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getMultipleAccounts', params: [batch, { encoding: 'base64', dataSlice: { offset: 0, length: 0 } }] }),
  });
  const { result } = await response.json();
  result.value.forEach((account, j) => kinds.set(batch[j], account === null ? 'empty' : account.executable ? 'program' : account.owner));
}
const usable = (address) => kinds.get(address) === 'empty' || kinds.get(address) === '11111111111111111111111111111111';

// Who each address belongs to: the most trusted source's exchange, if only one at that trust says.
const best = new Map();
for (const exchange of exchanges) {
  const rank = TRUST.indexOf(exchange.trust);
  for (const { address } of exchange.wallets) {
    const current = best.get(address);
    if (!current || rank < current.rank) best.set(address, { rank, names: new Set([exchange.name]), list: exchange });
    else if (rank === current.rank) current.names.add(exchange.name);
  }
}
const contested = [...best].filter(([, claim]) => claim.names.size > 1).map(([address]) => address);
if (contested.length) console.warn(`Claimed by two exchanges at the same trust, left out: ${contested.join(', ')}`);
// Each address in one list only: the one its owner was settled by.
const keep = (list, address) => best.get(address)?.list === list && !contested.includes(address);

const out = {
  updated: new Date().toISOString().slice(0, 10),
  about: previous.about,
  exchanges: exchanges
    .map((exchange) => ({
      ...exchange,
      wallets: exchange.wallets.filter(({ address }) => ADDRESS.test(address) && usable(address) && keep(exchange, address)),
    }))
    .filter((exchange) => exchange.wallets.length)
    .sort((a, b) => TRUST.indexOf(a.trust) - TRUST.indexOf(b.trust) || a.name.localeCompare(b.name)),
};
writeFileSync(file, `${JSON.stringify(out, null, 2)}\n`);
const totals = new Map();
for (const exchange of out.exchanges) totals.set(exchange.name, (totals.get(exchange.name) ?? 0) + exchange.wallets.length);
console.log(`${[...totals].map(([name, count]) => `${name} ${count}`).join(', ')}; ${[...totals.values()].reduce((a, b) => a + b, 0)} wallets`);
