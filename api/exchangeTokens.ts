// The exchanges' token lists as zandr's server keeps them: the snapshot it was built with, fetched
// again from the exchanges every 6 hours (with read-only API keys from the environment for the
// exchanges that need one), served whole at GET /v1/exchange-tokens. The extension fetches them
// every 12 hours. An exchange whose fetch fails, or comes back much shorter, keeps its last list.
import type { ServerResponse } from 'node:http';
import shipped from '../src/server/exchangeTokens.json' with { type: 'json' };
import { fetchExchangeTokens, type ExchangeKeys } from '../src/server/exchangeTokenSources.ts';
import type { ExchangeTokenLists } from '../src/server/exchangeTokens.ts';
import type { Fetch } from '../src/server/http.ts';

const EVERY_MS = 6 * 60 * 60 * 1000;

export function createExchangeTokenFeed(fetcher: Fetch, keys: ExchangeKeys) {
  let current = shipped as ExchangeTokenLists;
  let body = JSON.stringify(current);
  let running = false;

  async function refresh() {
    if (running) return;
    running = true;
    try {
      const { lists, problems } = await fetchExchangeTokens({ fetch: fetcher, keys }, current.lists);
      current = { updated: new Date().toISOString(), lists };
      body = JSON.stringify(current);
      const summary = lists.map((list) => `${list.exchange} ${list.tokens.length}`).join(', ');
      console.log(`exchange token lists: ${summary}${problems.length ? ` | ${problems.join(' | ')}` : ''}`);
    } catch (error) {
      console.error('exchange token lists failed:', error instanceof Error ? error.message : error);
    } finally {
      running = false;
    }
  }

  // Soon after starting, then every 6 hours.
  setTimeout(refresh, 10_000);
  setInterval(refresh, EVERY_MS);

  function handle(response: ServerResponse) {
    response.writeHead(200, {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=1800',
      'Access-Control-Allow-Origin': '*',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(body);
  }

  return { handle };
}
