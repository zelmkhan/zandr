// The exchanges' token lists the wallet goes by: the snapshot that ships with zandr, or, where
// fresher, the lists zandr's server keeps up to date. Those are fetched whole every 12 hours, so the
// server learns nothing about anyone's transfers, checked field by field, and kept in
// storage.local (public data). A fetched list much shorter than the shipped one is passed over.
import shippedFile from '@/server/exchangeTokens.json';
import { newestLists, validLists, type ExchangeTokenList, type ExchangeTokenLists } from '@/server/exchangeTokens';
import { ZANDR_API } from '@/lib/network';

const STORAGE_KEY = 'exchangeTokens';
// When fresh lists were last tried for, fetched or not.
const TRIED_KEY = 'exchangeTokensTriedAt';
// Tries at a time, 2 and then 4 seconds apart: a server that can't answer isn't asked again until
// `maxAge` has passed since, however often the background wakes.
const TRIES = 3;
const PAUSE_MS = 2000;
const EVERY_MS = 12 * 60 * 60 * 1000;
export const EXCHANGE_TOKENS_ALARM = 'exchange-tokens';

const shipped = (shippedFile as ExchangeTokenLists).lists;

type Stored = { checkedAt: number; data: unknown };

async function stored(): Promise<{ checkedAt: number; lists: ExchangeTokenList[] }> {
  const { [STORAGE_KEY]: value } = await browser.storage.local.get(STORAGE_KEY);
  const entry = value as Stored | undefined;
  return { checkedAt: entry?.checkedAt ?? 0, lists: validLists(entry?.data)?.lists ?? [] };
}

// The lists to go by now.
export async function exchangeTokenLists(): Promise<ExchangeTokenList[]> {
  return newestLists(shipped, (await stored()).lists);
}

// Fetches fresh lists from zandr's server, unless they were fetched, or tried for, within `maxAge`
// (12 hours, as the alarm runs it; a transfer to an exchange whose list is missing asks for
// fresher). True if new lists came. A failed fetch keeps what's there. With public services too:
// the lists are the one thing still asked of zandr's server.
export async function refreshExchangeTokens(maxAge = EVERY_MS): Promise<boolean> {
  const { checkedAt } = await stored();
  const { [TRIED_KEY]: tried } = await browser.storage.local.get(TRIED_KEY);
  const now = Date.now();
  if (now - Math.max(checkedAt, typeof tried === 'number' ? tried : 0) < maxAge) return false;
  await browser.storage.local.set({ [TRIED_KEY]: now });
  for (let attempt = 1; attempt <= TRIES; attempt++) {
    if (attempt > 1) await new Promise((resolve) => setTimeout(resolve, PAUSE_MS * (attempt - 1)));
    let response: Response;
    try {
      response = await fetch(`${ZANDR_API}/v1/exchange-tokens`, { signal: AbortSignal.timeout(15_000) });
    } catch {
      // Offline, or the server is down.
      continue;
    }
    // Not running (Railway answers in its place, marking it), failing or busy: worth another try.
    // Any other answer stands.
    if (response.headers.get('x-railway-fallback') === 'true' || response.status >= 500 || response.status === 429) continue;
    if (!response.ok) return false;
    try {
      const data = validLists(await response.json());
      if (!data) return false;
      await browser.storage.local.set({ [STORAGE_KEY]: { checkedAt: Date.now(), data } satisfies Stored });
      return true;
    } catch {
      return false;
    }
  }
  return false;
}
