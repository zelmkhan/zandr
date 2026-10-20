// zandr's API over HTTP, on zandr's server. It runs the same code the extension runs in its
// background (src/server), unchanged, with the RPC endpoints from the environment. It answers what
// an address is to an exchange (/v1/address-info), it's the extension's default mainnet node
// (/rpc/mainnet, see rpc.ts), so the RPC provider's key stays here, and it serves tokens' logos
// (/v1/logo/<mint>, see logos.ts), the exchanges' token lists (/v1/exchange-tokens, see
// exchangeTokens.ts) and Jupiter with zandr's key (/jupiter/..., see jupiter.ts). It keeps no record of who asked about which address, and logs none.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { ApiError } from '../src/server/api.ts';
import { createApi } from '../src/server/index.ts';
import { createExchangeTokenFeed } from './exchangeTokens.ts';
import { createJupiterProxy } from './jupiter.ts';
import { exchangeKeys } from './keys.ts';
import { createLogos } from './logos.ts';
import { createRpcProxy } from './rpc.ts';

// SOLANA_RPC_MAINNET: the provider's URL with its key (Helius). Set in Railway's variables only.
const MAINNET = process.env.SOLANA_RPC_MAINNET || 'https://api.mainnet-beta.solana.com';

// JUPITER_API_KEY: a paid Jupiter key, set in Railway's variables only. The wallets' requests to
// Jupiter go through here with it (/jupiter/..., see jupiter.ts), and so do this server's own.
const JUPITER_URL = process.env.JUPITER_API_URL || 'https://api.jup.ag';
const JUPITER_KEY = process.env.JUPITER_API_KEY || undefined;

const api = createApi({
  rpc: {
    mainnet: MAINNET,
    devnet: process.env.SOLANA_RPC_DEVNET || 'https://api.devnet.solana.com',
  },
  ...(JUPITER_KEY && { jupiter: { url: JUPITER_URL, rate: { requests: 20, perMs: 10_000 }, key: JUPITER_KEY } }),
});
const jupiterProxy = createJupiterProxy({ url: JUPITER_URL, key: JUPITER_KEY });

// The provider's socket: SOLANA_WS_MAINNET if it has its own address, else the same one over wss.
const rpcProxy = createRpcProxy({
  http: MAINNET,
  socket: process.env.SOLANA_WS_MAINNET || MAINNET.replace(/^http/, 'ws'),
  maxRps: Number(process.env.RPC_MAX_RPS) || 40,
  maxSockets: Number(process.env.RPC_MAX_SOCKETS) || 2000,
});

const logos = createLogos(api);

// Read-only exchange API keys, as Railway variables (see keys.ts), for Bybit, OKX and MEXC.
const exchangeTokens = createExchangeTokenFeed((input, init) => fetch(input, init), exchangeKeys(process.env));
const PORT = Number(process.env.PORT) || 8080;
const MAX_BODY = 1024;

// Per client: a burst of 20 requests, then one every 3 seconds.
const BURST = 20;
const REFILL_MS = 3_000;
const buckets = new Map<string, { tokens: number; at: number }>();

function allowed(client: string): boolean {
  const now = Date.now();
  const bucket = buckets.get(client) ?? { tokens: BURST, at: now };
  bucket.tokens = Math.min(BURST, bucket.tokens + (now - bucket.at) / REFILL_MS);
  bucket.at = now;
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  buckets.set(client, bucket);
  if (buckets.size > 100_000) buckets.delete(buckets.keys().next().value!);
  return true;
}

// Behind Railway's edge, the client's address is in X-Real-IP, which the edge sets itself.
// (X-Forwarded-For's first entry is whatever the client claims.)
const clientOf = (request: IncomingMessage) => String(request.headers['x-real-ip'] ?? request.socket.remoteAddress ?? '').trim();
const pathOf = (request: IncomingMessage) => (request.url ?? '').split('?')[0] ?? '';

const HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Max-Age': '86400',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

function reply(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { ...HEADERS, 'Content-Type': 'application/json' });
  response.end(JSON.stringify(body));
}

async function bodyOf(request: IncomingMessage): Promise<unknown> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new ApiError('invalid-request', 'rpc');
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new ApiError('invalid-request', 'rpc');
  }
}

const STATUS: Record<string, number> = { 'invalid-request': 400, 'rate-limited': 503, forbidden: 502, unreachable: 502, 'bad-response': 502 };

const server = createServer(async (request, response) => {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, HEADERS);
    return response.end();
  }
  if (request.method === 'GET' && request.url === '/health') return reply(response, 200, { ok: true });
  if (request.method === 'GET' && pathOf(request) === '/v1/exchange-tokens') return exchangeTokens.handle(response);
  if (request.method === 'POST' && pathOf(request) === '/rpc/mainnet') return rpcProxy.handle(request, response, clientOf(request));
  if (pathOf(request).startsWith('/jupiter/')) return jupiterProxy.handle(request, response, (request.url ?? '').slice('/jupiter'.length), clientOf(request));
  const logo = request.method === 'GET' ? /^\/v1\/logo\/([^/]+)$/.exec(pathOf(request)) : null;
  if (logo) return logos.handle(response, logo[1]!, clientOf(request));
  if (request.method !== 'POST' || request.url !== '/v1/address-info') return reply(response, 404, { error: 'not-found' });
  if (!allowed(clientOf(request))) return reply(response, 429, { error: 'rate-limited' });

  try {
    const body = (await bodyOf(request)) as { network?: unknown; address?: unknown } | null;
    const info = await api.getAddressInfo({ network: body?.network as 'mainnet', address: body?.address as string });
    reply(response, 200, info);
  } catch (error) {
    if (error instanceof ApiError) return reply(response, STATUS[error.reason] ?? 502, { error: error.reason });
    console.error('address-info failed:', error instanceof Error ? error.message : error);
    reply(response, 500, { error: 'internal' });
  }
});

// The live coins' sockets (the extension's lib/live.ts), on the same address as the requests.
server.on('upgrade', (request, socket) => {
  if (pathOf(request) === '/rpc/mainnet') rpcProxy.upgrade(request, socket, clientOf(request));
  else socket.destroy();
});

server.listen(PORT, () => console.log(`zandr api listening on ${PORT}`));
