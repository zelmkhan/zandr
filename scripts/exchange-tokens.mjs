// Fetches which tokens each exchange accepts as deposits on Solana, from the exchanges' own APIs
// (src/server/exchangeTokenSources.ts), into src/server/exchangeTokens.json: the snapshot that
// ships with zandr, used until the extension fetches fresher lists from zandr's server. Run
// before a release: `npm run exchange-tokens`.
//
// Bybit, OKX and MEXC answer only signed requests. To include them, make read-only API keys (no
// trading or withdrawal permissions) and put them in .env.exchanges at the repo root, which stays
// on this machine:
//   BYBIT_API_KEY=…  BYBIT_API_SECRET=…
//   OKX_API_KEY=…  OKX_API_SECRET=…  OKX_API_PASSPHRASE=…
//   MEXC_API_KEY=…  MEXC_API_SECRET=…
// Without them, those exchanges keep the lists the snapshot already has, if any.
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { exchangeKeys } from '../api/keys.ts';
import { fetchExchangeTokens } from '../src/server/exchangeTokenSources.ts';

const file = join(resolve(import.meta.dirname, '..'), 'src/server/exchangeTokens.json');
let previous = [];
try {
  previous = JSON.parse(readFileSync(file, 'utf8')).lists ?? [];
} catch {
  // No snapshot yet.
}

const fetcher = (input, init) => fetch(input, init);
const { lists, problems } = await fetchExchangeTokens({ fetch: fetcher, keys: exchangeKeys(process.env) }, previous);
writeFileSync(file, `${JSON.stringify({ updated: new Date().toISOString(), lists }, null, 1)}\n`);
for (const problem of problems) console.warn(problem);
console.log(lists.map((list) => `${list.exchange} ${list.tokens.length}${list.matchedBy === 'coingecko' ? ' (traded, CoinGecko)' : ''}${list.complete ? '' : ' (incomplete)'}`).join(', '));
