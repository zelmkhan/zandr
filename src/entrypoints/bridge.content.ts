// Carries the wallet's requests from the page to the background and the answers back. Runs in
// zandr's isolated world, so the page can't reach the extension's messaging except through here,
// and the background learns the site's origin from Chrome, not from the page.
import { CHANNEL, MATCHES, pageIcon } from '@/lib/dappChannel';

export default defineContentScript({
  matches: MATCHES,
  runAt: 'document_start',
  main() {
    const reply = (data: Record<string, unknown>) => window.postMessage({ channel: CHANNEL, to: 'page', ...data }, location.origin);
    // Whether this page was ever given an address. Only then does it hear of changes in zandr:
    // other sites don't learn when the user switches wallets.
    let connected = false;

    // The page's icon, worked out once, the first time the page asks for something.
    let icon: Promise<string | null> | null = null;
    const iconSoon = (wait: number) => {
      icon ??= pageIcon().catch(() => null);
      return Promise.race([icon, new Promise<null>((resolve) => setTimeout(() => resolve(null), wait))]);
    };

    window.addEventListener('message', async (event) => {
      // Only the page's own window: not frames inside it, not other windows.
      if (event.source !== window || event.origin !== location.origin) return;
      const data = event.data as { channel?: unknown; to?: unknown; id?: unknown; request?: unknown } | null;
      if (typeof data !== 'object' || data === null || data.channel !== CHANNEL || data.to !== 'zandr' || typeof data.id !== 'string') return;
      const { id } = data;
      // With the page's icon, for zandr's approval window and its list of connected apps. A connect
      // waits for it a moment; anything else takes it only if it's known already (the background
      // has the one kept with the connection), so signing is never held up. Not for the quiet
      // checks a page makes as it loads: no window shows for those.
      const ask = data.request as { type?: unknown; silent?: unknown } | null;
      const quiet = ask?.silent === true;
      const request =
        typeof ask === 'object' && ask !== null && !quiet ? { ...ask, icon: await iconSoon(ask.type === 'dapp:connect' ? 800 : 0) } : data.request;
      browser.runtime.sendMessage(request).then(
        (response) => {
          if (Array.isArray(response?.accounts) && response.accounts.length) connected = true;
          reply({ id, response: response ?? { ok: false, code: -32603, message: 'zandr did not answer.' } });
        },
        // The extension was updated or reloaded since the page opened.
        () => reply({ id, response: { ok: false, code: -32603, message: 'zandr was updated. Reload the page.' } }),
      );
    });

    browser.runtime.onMessage.addListener((message, sender) => {
      if (sender.id !== browser.runtime.id) return;
      if (connected && (message as { type?: unknown } | null)?.type === 'dapp:changed') reply({ event: 'changed' });
    });
  },
});
