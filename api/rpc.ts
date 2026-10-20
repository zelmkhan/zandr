// zandr's RPC proxy: the extension's default Solana node on mainnet. It forwards the wallet's
// JSON-RPC requests, and its WebSocket subscriptions, to the RPC provider whose URL is in
// SOLANA_RPC_MAINNET, API key included, so the key stays on this server and never ships in the
// extension. Anyone can reach the proxy, so it does only what the wallet needs: an allowlist of
// methods, one request at a time and of bounded size, subscriptions to a wallet's own accounts,
// and limits per client and overall. It logs no addresses, transactions or IPs; clients' IPs are
// kept in memory for the limits only.
import { createHash } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Duplex } from 'node:stream';

export type RpcProxyConfig = {
  // The provider's HTTP endpoint and its WebSocket one.
  http: string;
  socket: string;
  // Requests a second forwarded for everyone together: under the provider's plan limit.
  maxRps: number;
  // Open sockets, everyone together.
  maxSockets: number;
};

// What the wallet calls, and nothing else: no getProgramAccounts, no blocks, no batches.
const METHODS = new Set([
  'getAccountInfo',
  'getBalance',
  'getBlockHeight',
  'getGenesisHash',
  'getHealth',
  'getLatestBlockhash',
  'getMinimumBalanceForRentExemption',
  'getMultipleAccounts',
  'getRecentPrioritizationFees',
  'getSignatureStatuses',
  'getSignaturesForAddress',
  'getSlot',
  'getTokenAccountsByOwner',
  'getTransaction',
  'getVersion',
  'sendTransaction',
  'simulateTransaction',
]);

const MAX_BODY = 32 * 1024;
const TIMEOUT_MS = 20_000;

// Per client: a burst of 120 requests, then 15 a second, and 30,000 a day at most. An open
// wallet makes a few a minute; loading its history, a few dozen at once.
const BURST = 120;
const PER_SECOND = 15;
const PER_DAY = 30_000;

// Sockets: a few per client (popup, side panel, a reconnect overlapping, and one for each
// transaction just sent, until it lands), a few subscriptions each (the wallet uses three), small
// messages, and closed when the client goes quiet (the wallet pings every 20 seconds).
const SOCKETS_PER_CLIENT = 8;
const SUBSCRIPTIONS_PER_SOCKET = 4;
const MAX_MESSAGE = 16 * 1024;
const QUIET_MS = 90_000;

const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const SIGNATURE = /^[1-9A-HJ-NP-Za-km-z]{64,90}$/;
const TOKEN_PROGRAMS = new Set(['TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA', 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb']);
const ENCODINGS = new Set(['base64', 'base64+zstd', 'jsonParsed']);

const HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Content-Type': 'application/json',
};

type Id = number | string | null;
const isObject = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const rpcError = (id: Id, code: number, message: string) => JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } });

export function createRpcProxy(config: RpcProxyConfig) {
  // ---- Limits ----

  const clients = new Map<string, { tokens: number; at: number; day: string; today: number }>();
  const today = () => new Date().toISOString().slice(0, 10);

  function clientAllowed(client: string): boolean {
    const now = Date.now();
    const day = today();
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

  // Requests forwarded in the last second, everyone together.
  const recent: number[] = [];
  function underPlan(): boolean {
    const now = Date.now();
    while (recent.length && now - recent[0]! >= 1000) recent.shift();
    if (recent.length >= config.maxRps) return false;
    recent.push(now);
    return true;
  }

  // ---- HTTP ----

  function reply(response: ServerResponse, status: number, body: string) {
    response.writeHead(status, HEADERS);
    response.end(body);
  }

  async function readBody(request: IncomingMessage): Promise<string | null> {
    let size = 0;
    const chunks: Buffer[] = [];
    for await (const chunk of request) {
      size += (chunk as Buffer).length;
      if (size > MAX_BODY) return null;
      chunks.push(chunk as Buffer);
    }
    return Buffer.concat(chunks).toString('utf8');
  }

  // Why a request may not go through, or null if it may.
  function refusal(method: string, params: unknown[]): string | null {
    if (!METHODS.has(method)) return 'Method not available on this node';
    if (method === 'getMultipleAccounts' && (!Array.isArray(params[0]) || params[0].length > 100)) return 'Too many accounts';
    if (method === 'getSignaturesForAddress' && isObject(params[1]) && typeof params[1].limit === 'number' && params[1].limit > 100) {
      return 'Limit too high';
    }
    return null;
  }

  async function handle(request: IncomingMessage, response: ServerResponse, client: string) {
    if (!clientAllowed(client)) return reply(response, 429, rpcError(null, 429, 'Too many requests'));

    const text = await readBody(request);
    let body: unknown;
    try {
      body = text === null ? null : JSON.parse(text);
    } catch {
      body = null;
    }
    if (!isObject(body) || typeof body.method !== 'string') return reply(response, 400, rpcError(null, -32600, 'Invalid request'));
    const id: Id = typeof body.id === 'number' || typeof body.id === 'string' ? body.id : null;
    const params = Array.isArray(body.params) ? body.params : [];
    const refused = refusal(body.method, params);
    if (refused) return reply(response, 400, rpcError(id, -32601, refused));
    if (!underPlan()) return reply(response, 429, rpcError(id, 429, 'Too many requests'));

    let upstream: Response;
    try {
      upstream = await fetch(config.http, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id, method: body.method, params }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch {
      return reply(response, 502, rpcError(id, -32000, 'Node unreachable'));
    }
    // The provider refusing zandr's key, or failing, is zandr's problem, not a refusal of the
    // client: say the node is unreachable.
    if (upstream.status === 429) return reply(response, 429, rpcError(id, 429, 'Too many requests'));
    if (upstream.status === 401 || upstream.status === 403 || upstream.status >= 500) {
      return reply(response, 502, rpcError(id, -32000, 'Node unreachable'));
    }
    reply(response, upstream.status, await upstream.text());
  }

  // ---- WebSocket ----

  const sockets = new Map<string, number>();
  let open = 0;

  function upgrade(request: IncomingMessage, socket: Duplex, client: string) {
    const key = request.headers['sec-websocket-key'];
    if (typeof key !== 'string' || String(request.headers.upgrade).toLowerCase() !== 'websocket') {
      return socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    }
    if (open >= config.maxSockets || (sockets.get(client) ?? 0) >= SOCKETS_PER_CLIENT) {
      return socket.end('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
    }
    const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);

    open++;
    sockets.set(client, (sockets.get(client) ?? 0) + 1);
    relay(socket, () => {
      open--;
      const left = (sockets.get(client) ?? 1) - 1;
      if (left > 0) sockets.set(client, left);
      else sockets.delete(client);
    });
  }

  // One client socket, relayed to a socket of its own at the provider.
  function relay(socket: Duplex, onClosed: () => void) {
    const upstream = new WebSocket(config.socket);
    const waiting: string[] = [];
    let subscriptions = 0;
    let heard = Date.now();
    let closed = false;
    // The client's connection itself is gone: nothing more can be written to it.
    let gone = false;

    const send = (opcode: number, payload: Buffer) => {
      if (!closed && !gone) socket.write(frame(opcode, payload));
    };
    const sendText = (text: string) => send(1, Buffer.from(text));

    function close(code = 1000) {
      if (closed) return;
      const payload = Buffer.alloc(2);
      payload.writeUInt16BE(code);
      send(8, payload);
      closed = true;
      clearInterval(watch);
      if (!gone) socket.end();
      upstream.onopen = upstream.onmessage = upstream.onclose = upstream.onerror = null;
      if (upstream.readyState === WebSocket.CONNECTING || upstream.readyState === WebSocket.OPEN) upstream.close();
      onClosed();
    }

    const watch = setInterval(() => Date.now() - heard > QUIET_MS && close(1001), 15_000);

    upstream.onopen = () => {
      for (const message of waiting.splice(0)) upstream.send(message);
    };
    upstream.onmessage = (event) => sendText(String(event.data));
    upstream.onclose = () => close(1011);
    upstream.onerror = () => close(1011);

    // A message from the client: forwarded if it's something the wallet does, else answered here.
    function receive(text: string) {
      heard = Date.now();
      let message: unknown;
      try {
        message = JSON.parse(text);
      } catch {
        return sendText(rpcError(null, -32700, 'Parse error'));
      }
      if (!isObject(message) || typeof message.method !== 'string') return sendText(rpcError(null, -32600, 'Invalid request'));
      const id: Id = typeof message.id === 'number' || typeof message.id === 'string' ? message.id : null;
      const params = Array.isArray(message.params) ? message.params : [];
      const refused = subscriptionRefusal(message.method, params);
      if (refused) return sendText(rpcError(id, -32601, refused));

      if (message.method.endsWith('Subscribe')) {
        if (subscriptions >= SUBSCRIPTIONS_PER_SOCKET) return sendText(rpcError(id, -32602, 'Too many subscriptions'));
        subscriptions++;
      } else if (message.method.endsWith('Unsubscribe')) {
        subscriptions = Math.max(0, subscriptions - 1);
      }
      const forward = JSON.stringify({ jsonrpc: '2.0', id, method: message.method, params });
      if (upstream.readyState === WebSocket.OPEN) upstream.send(forward);
      else if (waiting.length < 8) waiting.push(forward);
    }

    // Frames from the client: masked, as clients' must be; a message may come in several.
    let buffer = Buffer.alloc(0);
    let parts: Buffer[] = [];
    let partsSize = 0;
    socket.on('data', (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        const parsed = readFrame(buffer);
        if (parsed === 'incomplete') return;
        if (parsed === 'invalid') return close(1002);
        buffer = buffer.subarray(parsed.size);
        const { fin, opcode, payload } = parsed;
        if (opcode === 8) return close(1000);
        if (opcode === 9) {
          send(10, payload);
          continue;
        }
        if (opcode === 10) continue;
        if (opcode !== 0 && opcode !== 1) return close(1003);
        partsSize += payload.length;
        if (partsSize > MAX_MESSAGE) return close(1009);
        parts.push(payload);
        if (!fin) continue;
        const text = Buffer.concat(parts).toString('utf8');
        parts = [];
        partsSize = 0;
        receive(text);
      }
    });
    socket.on('close', () => {
      gone = true;
      close(1001);
    });
    socket.on('error', () => {
      gone = true;
      close(1011);
    });
  }

  return { handle, upgrade };
}

// The wallet's subscriptions: its own account, and token accounts it owns (an owner filter at
// byte 32, under a token program). Anything wider would stream other people's activity at
// zandr's expense.
function subscriptionRefusal(method: string, params: unknown[]): string | null {
  const config = params[1];
  const encodingOk = !isObject(config) || config.encoding === undefined || ENCODINGS.has(String(config.encoding));
  switch (method) {
    case 'ping':
      return null;
    case 'accountSubscribe':
      return typeof params[0] === 'string' && ADDRESS.test(params[0]) && encodingOk ? null : 'Invalid subscription';
    case 'programSubscribe': {
      if (typeof params[0] !== 'string' || !TOKEN_PROGRAMS.has(params[0]) || !isObject(config) || !encodingOk) return 'Invalid subscription';
      const filters = Array.isArray(config.filters) ? config.filters : [];
      const owned = filters.some(
        (filter) => isObject(filter) && isObject(filter.memcmp) && filter.memcmp.offset === 32 && typeof filter.memcmp.bytes === 'string' && ADDRESS.test(filter.memcmp.bytes),
      );
      return owned && filters.length <= 3 ? null : 'Only a wallet’s own token accounts';
    }
    // A transaction's outcome, once: commitment the only option.
    case 'signatureSubscribe':
      return typeof params[0] === 'string' && SIGNATURE.test(params[0]) && (config === undefined || (isObject(config) && Object.keys(config).every((key) => key === 'commitment')))
        ? null
        : 'Invalid subscription';
    case 'accountUnsubscribe':
    case 'programUnsubscribe':
    case 'signatureUnsubscribe':
      return typeof params[0] === 'number' ? null : 'Invalid subscription';
    default:
      return 'Method not available on this node';
  }
}

// A frame to the client: whole, unmasked.
function frame(opcode: number, payload: Buffer): Buffer {
  const length = payload.length;
  let head: Buffer;
  if (length < 126) {
    head = Buffer.from([0x80 | opcode, length]);
  } else if (length < 65_536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode;
    head[1] = 126;
    head.writeUInt16BE(length, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x80 | opcode;
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(length), 2);
  }
  return Buffer.concat([head, payload]);
}

// A frame from the client, if all of it is in: its flags, its unmasked payload and its size.
function readFrame(buffer: Buffer): { fin: boolean; opcode: number; payload: Buffer; size: number } | 'incomplete' | 'invalid' {
  if (buffer.length < 2) return 'incomplete';
  const fin = (buffer[0]! & 0x80) !== 0;
  const opcode = buffer[0]! & 0x0f;
  if ((buffer[1]! & 0x80) === 0) return 'invalid';
  let length = buffer[1]! & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return 'incomplete';
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return 'incomplete';
    const long = buffer.readBigUInt64BE(2);
    if (long > BigInt(MAX_MESSAGE)) return 'invalid';
    length = Number(long);
    offset = 10;
  }
  if (length > MAX_MESSAGE) return 'invalid';
  if (buffer.length < offset + 4 + length) return 'incomplete';
  const mask = buffer.subarray(offset, offset + 4);
  const payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length));
  for (let i = 0; i < payload.length; i++) payload[i] = payload[i]! ^ mask[i % 4]!;
  return { fin, opcode, payload, size: offset + 4 + length };
}
