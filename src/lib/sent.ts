// Transactions zandr sent (transfers, swaps, reclaims), followed until they land. Each is watched
// over the node's WebSocket (signatureSubscribe): the node says the moment it's processed, so the
// screen waiting on it learns at once. Asking the node stays as the fallback, and is what sends a
// transaction again while it hasn't landed: for a node without a socket, a socket that drops, or
// a background restarted meanwhile. Background only.
import { rpcEndpoints } from '@/lib/api';
import { socketUrl } from '@/lib/live';
import type { ResponseMap } from '@/lib/messages';
import { loadPreferences } from '@/lib/preferences';
import { rpc } from '@/lib/solana/rpc';
import type { Network } from '@/server/api';

// A transaction on its way, kept while unlocked so it can be sent again until it lands or expires.
export type Pending = { wire: string; network: Network; lastValidBlockHeight: number };

type Status = ResponseMap['send:status'];
type SignatureStatus = { err: unknown; confirmationStatus: string | null } | null;

// How long a screen's question waits for the node to say it landed, before it's asked instead
// (and the transaction sent again). Without a socket, as long as between questions before.
const NEWS_WAIT_MS = 2_000;
const ASK_EVERY_MS = 1_000;
// A blockhash is good for about a minute and a half: past that, a transaction can't land.
const WATCH_MS = 90_000;
// What the node said is kept a little while, for a screen that asks late.
const KEEP_MS = 60_000;

// What the node said of a transaction: the error it ran into, or null when it went through.
type Landing = { err: unknown };
// `result`: undefined while watching; null once the socket is gone without news.
type Watch = { result?: Landing | null; settled: Promise<Landing | null> };
const watches = new Map<string, Watch>();

const statusOf = (landing: Landing): Status =>
  landing.err ? { status: 'failed', detail: JSON.stringify(landing.err).slice(0, 200) } : { status: 'confirmed' };

// A transaction just sent through `url`: kept, and watched.
export async function trackSent(url: string, signature: string, pending: Pending) {
  watch(url, signature);
  await browser.storage.session.set({ [`send:${signature}`]: pending });
}

function watch(rpcUrl: string, signature: string) {
  if (watches.has(signature)) return;
  const url = socketUrl(rpcUrl);
  const entry: Watch = { settled: Promise.resolve(null) };
  watches.set(signature, entry);
  entry.settled = new Promise<Landing | null>((resolve) => {
    let socket: WebSocket;
    try {
      if (!url) throw new Error('No socket');
      socket = new WebSocket(url);
    } catch {
      entry.result = null;
      return resolve(null);
    }
    const timer = setTimeout(() => settle(null), WATCH_MS);
    function settle(result: Landing | null) {
      if (entry.result !== undefined) return;
      entry.result = result;
      clearTimeout(timer);
      socket.close();
      resolve(result);
      setTimeout(() => watches.delete(signature), KEEP_MS);
    }

    socket.onopen = () => socket.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'signatureSubscribe', params: [signature, { commitment: 'processed' }] }));
    socket.onmessage = (event) => {
      let message: { id?: unknown; error?: unknown; method?: unknown; params?: { result?: { value?: unknown } } };
      try {
        message = JSON.parse(String(event.data));
      } catch {
        return;
      }
      if (message.id === 1) {
        if (message.error) return settle(null);
        // Landed before the subscription was in place: the node wouldn't tell any more.
        rpc<{ value: SignatureStatus[] }>(rpcUrl, 'getSignatureStatuses', [[signature]])
          .then(({ value }) => {
            if (value[0]?.confirmationStatus) settle({ err: value[0].err ?? null });
          })
          .catch(() => {});
        return;
      }
      const value = message.method === 'signatureNotification' ? message.params?.result?.value : undefined;
      if (typeof value === 'object' && value !== null && 'err' in value) settle({ err: (value as { err: unknown }).err ?? null });
    };
    socket.onerror = () => settle(null);
    socket.onclose = () => settle(null);
  });
}

// What the node said, waiting up to `ms` while the transaction is watched; without a watch, after
// the usual pause between questions. Null: no news.
async function news(signature: string, ms: number): Promise<Landing | null> {
  const entry = watches.get(signature);
  if (entry?.result) return entry.result;
  const watching = entry !== undefined && entry.result === undefined;
  const pause = new Promise<null>((resolve) => setTimeout(() => resolve(null), watching ? ms : ASK_EVERY_MS));
  return watching ? Promise.race([entry.settled.then((result) => result ?? pause), pause]) : pause;
}

// Whether a sent transaction has landed. Until it has, and while its blockhash is still valid, it's
// sent again: under load the network drops transactions rather than queueing them. `wait`: the
// answer waits for news from the node a moment first, so a screen asking over and over hears the
// moment it lands.
export async function sendStatus(signature: string, wait = false): Promise<Status> {
  const key = `send:${signature}`;
  const read = async () => (await browser.storage.session.get(key))[key] as Pending | undefined;
  const preferences = await loadPreferences();
  const done = () => browser.storage.session.remove(key);

  if (wait) {
    const sent = await read();
    // A background restarted since it was sent has lost the watch: watched again.
    if (sent) watch(rpcEndpoints(preferences)[sent.network], signature);
    const landed = await news(signature, NEWS_WAIT_MS);
    if (landed) {
      await done();
      return statusOf(landed);
    }
  }

  const pending = await read();
  const url = rpcEndpoints(preferences)[pending?.network ?? preferences.network];
  try {
    const { value } = await rpc<{ value: SignatureStatus[] }>(url, 'getSignatureStatuses', [[signature]]);
    const status = value[0];
    // Done once a node has run it in a block (processed): the soonest the result is known. A block
    // that the network later skips takes it along, though that's rare.
    if (status?.err || status?.confirmationStatus) {
      await done();
      return statusOf({ err: status.err ?? null });
    }
    if (!pending) return { status: 'pending' };

    const height = await rpc<number>(url, 'getBlockHeight', [{ commitment: 'confirmed' }]);
    if (height > pending.lastValidBlockHeight) {
      await done();
      return { status: 'expired' };
    }
    rpc(url, 'sendTransaction', [pending.wire, { encoding: 'base64', skipPreflight: true, maxRetries: 0 }]).catch(() => {});
  } catch {
    // The node can't be reached right now: the next check tries again.
  }
  return { status: 'pending' };
}
