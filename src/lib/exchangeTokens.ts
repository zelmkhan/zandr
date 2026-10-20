// The exchanges' token lists the wallet goes by: the snapshot that ships with zandr, or, where
// fresher, the lists zandr's server keeps up to date. Those are fetched whole every 12 hours, so the
// server learns nothing about anyone's transfers, checked field by field, and kept in
// storage.local (public data). A fetched list much shorter than the shipped one is passed over.
import shippedFile from '@/server/exchangeTokens.json';
import { newestLists, validLists, type ExchangeTokenList, type ExchangeTokenLists } from '@/server/exchangeTokens';
import { ZANDR_API } from '@/lib/network';

const STORAGE_KEY = 'exchangeTokens';
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

// Fetches fresh lists from zandr's server, unless they were fetched within `maxAge` (12 hours, as
// the alarm runs it; a transfer to an exchange whose list is missing asks for fresher). True if new
// lists came. A failed fetch keeps what's there; the next try fetches again.
export async function refreshExchangeTokens(maxAge = EVERY_MS): Promise<boolean> {
  const { checkedAt } = await stored();
  if (Date.now() - checkedAt < maxAge) return false;
  try {
    const response = await fetch(`${ZANDR_API}/v1/exchange-tokens`, { signal: AbortSignal.timeout(15_000) });
    if (!response.ok) return false;
    const data = validLists(await response.json());
    if (!data) return false;
    await browser.storage.local.set({ [STORAGE_KEY]: { checkedAt: Date.now(), data } satisfies Stored });
    return true;
  } catch {
    // Offline, or the server is down.
    return false;
  }
}
