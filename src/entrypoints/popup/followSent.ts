// Follows a sent transaction until it lands, fails or expires. The background answers the moment
// the node says it landed, or after a couple of seconds without news (and sends it again
// meanwhile); so this asks again right away, over and over. Returns a function that stops it.
import { sendToBackground } from '@/lib/messages';

// How a transaction ended: landed and done, failed (the fee paid), or expired unsent.
export type Settled = { status: 'confirmed' } | { status: 'failed' | 'expired'; detail?: string };

export function followSent(signature: string, settled: (status: Settled) => void): () => void {
  let stopped = false;
  void (async () => {
    while (!stopped) {
      try {
        const status = await sendToBackground({ type: 'send:status', signature, wait: true });
        if (stopped) return;
        if (status.status !== 'pending') return settled(status as Settled);
      } catch {
        // The background is restarting: a moment, then again.
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    }
  })();
  return () => {
    stopped = true;
  };
}
