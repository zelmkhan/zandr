// Jupiter for the extension, through zandr's server: the paid key (JUPITER_API_KEY) stays here,
// and its rate limit, far above the public API's 5 requests per 10 seconds per IP, serves every
// wallet. Only what the wallet asks of Jupiter passes: token lookups and searches, prices, quotes
// and building a swap. Token lookups and prices are kept a little while, for everyone; quotes and
// swaps never. Jupiter's rate-limit headers are passed on, so wallets wait out a used-up window
// rather than be turned away. Without a key it answers 503, and wallets ask Jupiter themselves.
// Nothing about the requests is logged.
import type { IncomingMessage, ServerResponse } from 'node:http';

export type JupiterProxyConfig = { url: string; key: string | undefined };

// The paths the wallet uses, and how long an answer is kept for everyone (0: never).
const ROUTES: Record<string, { method: 'GET' | 'POST'; keepMs: number }> = {
  '/tokens/v2/search': { method: 'GET', keepMs: 10 * 60_000 },
  '/price/v3': { method: 'GET', keepMs: 15_000 },
  '/swap/v2/build': { method: 'GET', keepMs: 0 },
  // For the extension's releases before Swap API v2.
  '/swap/v1/quote': { method: 'GET', keepMs: 0 },
  '/swap/v1/swap': { method: 'POST', keepMs: 0 },
};

const MAX_QUERY = 4096;
const MAX_BODY = 64 * 1024;
const TIMEOUT_MS = 15_000;
const KEPT = 5_000;

// Per client: a burst of 40 requests, then 4 a second and 10,000 a day (an open wallet asks for
// prices and quotes a few times a minute).
const BURST = 40;
const PER_SECOND = 4;
const PER_DAY = 10_000;

const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const PASSED = ['x-ratelimit-remaining', 'x-ratelimit-reset'];
const HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Expose-Headers': PASSED.join(', '),
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Content-Type': 'application/json',
};

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);

export function createJupiterProxy(config: JupiterProxyConfig) {
  const clients = new Map<string, { tokens: number; at: number; day: string; today: number }>();

  function clientAllowed(client: string): boolean {
    const now = Date.now();
    const day = new Date().toISOString().slice(0, 10);
    const entry = clients.get(client) ?? { tokens: BURST, at: now, day, today: 0 };
    entry.tokens = Math.min(BURST, entry.tokens + ((now - entry.at) / 1000) * PER_SECOND);
    entry.at = now;
    if (entry.day !== day) {
      entry.day = day;
      entry.today = 0;
    }
    clients.set(client, entry);
    if (clients.size > 100_000) clients.delete(clients.keys().next().value!);
    if (entry.tokens < 1 || entry.today >= PER_DAY) return false;
    entry.tokens -= 1;
    entry.today += 1;
    return true;
  }

  // Answers kept for everyone, by path and query.
  const kept = new Map<string, { body: string; expires: number }>();

  function reply(response: ServerResponse, status: number, body: string, headers: Record<string, string> = {}) {
    response.writeHead(status, { ...HEADERS, ...headers });
    response.end(body);
  }

  async function bodyOf(request: IncomingMessage): Promise<string | null> {
    let size = 0;
    const chunks: Buffer[] = [];
    for await (const chunk of request) {
      size += (chunk as Buffer).length;
      if (size > MAX_BODY) return null;
      chunks.push(chunk as Buffer);
    }
    return Buffer.concat(chunks).toString('utf8');
  }

  // A swap to build: a quote and the wallet's address, nothing else that isn't the wallet's usual.
  function swapRequest(text: string): boolean {
    try {
      const body: unknown = JSON.parse(text);
      return isObject(body) && isObject(body.quoteResponse) && typeof body.userPublicKey === 'string' && ADDRESS.test(body.userPublicKey);
    } catch {
      return false;
    }
  }

  // `path`: the request's path and query after /jupiter.
  async function handle(request: IncomingMessage, response: ServerResponse, path: string, client: string) {
    const [route = '', query = ''] = path.split(/\?(.*)/s);
    const allowed = ROUTES[route];
    if (!allowed || request.method !== allowed.method || query.length > MAX_QUERY) return reply(response, 404, '{"error":"not-found"}');
    // Not set up: the wallet asks Jupiter itself.
    if (!config.key) return reply(response, 503, '{}');
    if (!clientAllowed(client)) {
      return reply(response, 429, '{"error":"rate-limited"}', { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(Math.ceil(Date.now() / 1000) + 1) });
    }

    const at = `${route}?${query}`;
    const hit = kept.get(at);
    if (hit && hit.expires > Date.now()) return reply(response, 200, hit.body);

    let body: string | undefined;
    if (allowed.method === 'POST') {
      const text = await bodyOf(request);
      if (text === null || !swapRequest(text)) return reply(response, 400, '{"error":"invalid-request"}');
      body = text;
    }

    let upstream: Response;
    try {
      upstream = await fetch(`${config.url}${route}${query ? `?${query}` : ''}`, {
        method: allowed.method,
        headers: { 'x-api-key': config.key, ...(body !== undefined && { 'Content-Type': 'application/json' }) },
        body,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch {
      return reply(response, 502, '{}');
    }
    const text = await upstream.text().catch(() => '');
    const passed = Object.fromEntries(PASSED.flatMap((name) => (upstream.headers.has(name) ? [[name, upstream.headers.get(name)!]] : [])));
    // The key itself is the server's: a refusal of it is said plainly, not passed on as the wallet's.
    if (upstream.status === 401 || upstream.status === 403) {
      console.error('Jupiter refused the API key');
      return reply(response, 502, '{}');
    }
    if (upstream.ok && allowed.keepMs > 0) {
      kept.delete(at);
      kept.set(at, { body: text, expires: Date.now() + allowed.keepMs });
      if (kept.size > KEPT) kept.delete(kept.keys().next().value!);
    }
    reply(response, upstream.status, text, passed);
  }

  return { handle };
}
