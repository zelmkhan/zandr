// Live coins. While a popup or side panel shows a wallet, the background keeps a WebSocket open to
// the network's RPC node, subscribed to the wallet's own account (its SOL) and to its token
// accounts under both token programs. When the node reports a change, the coins are fetched again
// right away, at least as new as the change, and every open view shows them a moment later.
// Where the node has no socket zandr may use (Solana's public mainnet node refuses extensions; zandr's
// default mainnet node has one), or it drops, the coins are fetched every few seconds instead
// until the socket is back.
// Background only.
import type { Browser } from 'wxt/browser';
import { nodeFor } from '@/lib/network';
import type { Network } from '@/server/api';
import { TOKEN_PROGRAMS } from '@/server/rpc';
import { rpcEndpoints } from '@/lib/api';
import { refreshPortfolio } from '@/lib/portfolio';
import { loadPreferences } from '@/lib/preferences';
import { peekSession } from '@/lib/vault';

// Without a live socket: how often the coins are fetched instead.
const POLL_MS = 5_000;
// A request this often, which the node answers: a socket that stops answering is replaced. The
// traffic also keeps the background awake while the socket is open.
const HEARTBEAT_MS = 20_000;
// Waits before connecting again, longer each time in a row the socket fails.
const RETRY_MS = [1_000, 3_000, 10_000, 30_000];
// One transaction changes several accounts, each reported on its own: one refresh for them all.
const SETTLE_MS = 150;

// The wallet's own account, then its token accounts: the wallet is the owner, 32 bytes in, under
// either token program (classic ones are 165 bytes; Token-2022 ones may carry extensions).
function subscriptions(address: string) {
  const owned = { memcmp: { offset: 32, bytes: address } };
  return [
    { method: 'accountSubscribe', params: [address, { commitment: 'processed', encoding: 'base64' }] },
    { method: 'programSubscribe', params: [TOKEN_PROGRAMS.token, { commitment: 'processed', encoding: 'base64', filters: [{ dataSize: 165 }, owned] }] },
    { method: 'programSubscribe', params: [TOKEN_PROGRAMS['token-2022'], { commitment: 'processed', encoding: 'base64', filters: [owned] }] },
  ];
}

// The socket of an RPC endpoint: the same address over ws(s). A node on an explicit port (a local
// test validator's 8899) serves it one port up, as web3.js assumes too. Null if it isn't a URL.
export function socketUrl(rpc: string): string | null {
  let url: URL;
  try {
    url = new URL(rpc);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  if (url.port) url.port = String(Number(url.port) + 1);
  return url.toString();
}

// Watches one wallet on one network, through the node at `rpc` (or the one standing in for it, as
// it is at each connection), until the returned function is called.
function watch(network: Network, address: string, rpc: string): () => void {
  const requests = subscriptions(address);
  let socket: WebSocket | null = null;
  let live = false;
  let stopped = false;
  let failures = 0;
  let subscribed = 0;
  let heard = 0;
  let slot = 0;
  let settle: ReturnType<typeof setTimeout> | undefined;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let heartbeat: ReturnType<typeof setInterval> | undefined;

  const refresh = (changedIn?: number) => void refreshPortfolio(network, address, changedIn).catch(() => {});
  const poll = setInterval(() => {
    if (!live) refresh();
  }, POLL_MS);

  function connect() {
    const url = socketUrl(nodeFor(rpc));
    if (!url) return;
    subscribed = 0;
    try {
      socket = new WebSocket(url);
    } catch {
      return drop();
    }
    socket.onopen = () => {
      heard = Date.now();
      requests.forEach((request, i) => socket?.send(JSON.stringify({ jsonrpc: '2.0', id: i + 1, ...request })));
      heartbeat = setInterval(beat, HEARTBEAT_MS);
    };
    socket.onmessage = (event) => receive(event.data);
    // An error is always followed by close.
    socket.onclose = drop;
  }

  function receive(data: unknown) {
    heard = Date.now();
    let message: unknown;
    try {
      message = JSON.parse(String(data));
    } catch {
      return;
    }
    if (typeof message !== 'object' || message === null) return;
    const { id, method, params } = message as { id?: unknown; method?: unknown; params?: { result?: { context?: { slot?: unknown } } } };

    // The answers to the subscriptions: without all of them, changes could go unseen.
    if (typeof id === 'number' && id >= 1 && id <= requests.length) {
      if (!('result' in message)) return socket?.close();
      if (++subscribed < requests.length) return;
      live = true;
      failures = 0;
      // Whatever changed before the subscriptions were in place.
      refresh();
      return;
    }

    // A change: refresh once the transaction's other changes are in too, from its slot on.
    if (typeof method === 'string' && method.endsWith('Notification')) {
      const reported = params?.result?.context?.slot;
      if (typeof reported === 'number' && Number.isSafeInteger(reported)) slot = Math.max(slot, reported);
      clearTimeout(settle);
      settle = setTimeout(() => refresh(slot || undefined), SETTLE_MS);
    }
  }

  // Solana's sockets have no ping. A method they don't know gets an error back, which is all a
  // heartbeat needs.
  function beat() {
    if (Date.now() - heard > 2 * HEARTBEAT_MS) return socket?.close();
    socket?.send(JSON.stringify({ jsonrpc: '2.0', id: 0, method: 'ping' }));
  }

  // The socket closed, failed or went quiet: poll meanwhile, and connect again in a while.
  function drop() {
    live = false;
    clearInterval(heartbeat);
    if (socket) {
      socket.onopen = socket.onmessage = socket.onclose = null;
      socket.close();
      socket = null;
    }
    if (stopped) return;
    clearTimeout(retry);
    retry = setTimeout(connect, RETRY_MS[Math.min(failures++, RETRY_MS.length - 1)]);
  }

  connect();
  return () => {
    stopped = true;
    clearInterval(poll);
    clearTimeout(settle);
    clearTimeout(retry);
    drop();
  };
}

// `url`: the RPC endpoint watched through.
type Watched = { network: Network; address: string; url: string; views: number; stop: () => void };
const watched = new Map<string, Watched>();

// A view showing a wallet holds a port named LIVE_PORT for as long as it does: the active wallet
// is watched while at least one is open, and their pings keep the background awake meanwhile.
export function holdLive(port: Browser.runtime.Port) {
  let key: string | null = null;
  let gone = false;
  port.onDisconnect.addListener(() => {
    gone = true;
    if (key) release(key);
  });
  // The pings: arriving is all they need to do.
  port.onMessage.addListener(() => {});

  void (async () => {
    const [account, preferences] = await Promise.all([peekSession(), loadPreferences()]);
    // Locked: nothing to watch. The view notices on its own and lets go of the port.
    if (gone || !account) return;

    const { network } = preferences;
    key = `${network}:${account.address}`;
    const current = watched.get(key);
    if (current) {
      current.views++;
      return;
    }
    const url = rpcEndpoints(preferences)[network];
    watched.set(key, { network, address: account.address, url, views: 1, stop: watch(network, account.address, url) });
  })();
}

function release(key: string) {
  const current = watched.get(key);
  if (!current || --current.views > 0) return;
  current.stop();
  watched.delete(key);
}

// The RPC endpoints may have changed: watch over the new ones.
export async function rewatch() {
  const preferences = await loadPreferences();
  for (const current of watched.values()) {
    const url = rpcEndpoints(preferences)[current.network];
    if (url === current.url) continue;
    current.stop();
    current.url = url;
    current.stop = watch(current.network, current.address, url);
  }
}
