// The active wallet's history, read through zandr's API and kept in session storage while
// unlocked, like its coins. A refresh asks only for what's newer than the newest kept: one call to
// the node when nothing happened. Older pages are added as the user asks for them. Each item is
// told apart from the user's own addresses, saved ones and those the wallet sent to, so a
// lookalike stands out. Background only.
import { lookalike } from '@/lib/addressBook';
import { getApi } from '@/lib/api';
import type { ActivityItem, ActivityView } from '@/lib/messages';
import { loadPreferences } from '@/lib/preferences';
import { peekSession, peekWallets, readAddressBook, readCached, writeCached } from '@/lib/vault';
import { ApiError, type Activity } from '@/server/api';

const PAGE = 20;
// Kept, at most: the newest ones.
const KEEP = 200;

type Kept = { items: Activity[]; more: boolean; problem: ActivityView['problem'] };

// What's kept this session, or, just unlocked, what was kept from before (encrypted between
// sessions), shown while anything newer loads.
async function read(key: string): Promise<Kept | null> {
  const stored = (await browser.storage.session.get(key))[key] as Kept | undefined;
  if (stored) return stored;
  const cached = await readCached<Kept>(key);
  if (cached) await browser.storage.session.set({ [key]: cached });
  return cached;
}

// One load per wallet and network at a time: a refresh and a "more" never overwrite each other.
const queues = new Map<string, Promise<unknown>>();

function queued<T>(key: string, task: () => Promise<T>): Promise<T> {
  const run = (queues.get(key) ?? Promise.resolve()).then(task, task);
  queues.set(key, run.catch(() => {}));
  return run;
}

// Names and lookalikes, worked out each time: the address book and wallets may have changed.
async function annotate(items: Activity[]): Promise<ActivityItem[]> {
  const contacts = await readAddressBook().catch(() => []);
  const wallets = (await peekWallets())?.wallets ?? [];
  const names = new Map<string, string>([
    ...wallets.map((wallet) => [wallet.address, wallet.name] as const),
    ...contacts.map((contact) => [contact.address, contact.name] as const),
  ]);
  const known = [...names.keys(), ...items.flatMap((item) => (item.kind === 'send' && item.counterparty ? [item.counterparty] : []))];
  return items.map((item) => {
    const other = item.counterparty;
    return {
      ...item,
      name: other ? (names.get(other) ?? null) : null,
      lookalike: !!other && !names.has(other) && known.some((address) => lookalike(address, other)),
    };
  });
}

async function view(kept: Kept | null): Promise<ActivityView> {
  return { items: await annotate(kept?.items ?? []), more: kept?.more ?? false, loaded: kept !== null, problem: kept?.problem ?? null };
}

export async function getActivity(address: string, mode: 'cached' | 'refresh' | 'more'): Promise<ActivityView> {
  const preferences = await loadPreferences();
  const { network } = preferences;
  const key = `activity:${network}:${address}`;
  if (mode === 'cached') return view(await read(key));

  return queued(key, async () => {
    const kept = await read(key);
    let next: Kept;
    try {
      const api = getApi(preferences);
      if (mode === 'more' && kept?.more && kept.items.length) {
        const page = await api.getActivity({ network, address, before: kept.items.at(-1)!.signature, limit: PAGE });
        const seen = new Set(kept.items.map((item) => item.signature));
        next = { items: [...kept.items, ...page.items.filter((item) => !seen.has(item.signature))], more: page.next !== null, problem: null };
      } else {
        const newest = kept?.items[0]?.signature;
        const page = await api.getActivity({ network, address, until: newest, limit: PAGE });
        // All that's new fit in the page: it goes on top. Otherwise there may be a gap between
        // it and what's kept, so it replaces it.
        next =
          kept && newest && page.next === null
            ? { items: [...page.items, ...kept.items].slice(0, KEEP), more: kept.more || page.items.length + kept.items.length > KEEP, problem: null }
            : { items: page.items, more: page.next !== null, problem: null };
      }
    } catch (error) {
      if (!(error instanceof ApiError)) console.error('Activity load failed', error);
      const problem = error instanceof ApiError ? { reason: error.reason, service: error.service } : ({ reason: 'bad-response', service: 'rpc' } as const);
      // A first load that failed keeps nothing, so the view still says "not loaded"; an older page
      // that failed changes nothing kept, the newest included.
      if (!kept || mode === 'more') return { ...(await view(kept)), problem };
      next = { ...kept, problem };
    }
    // Locked meanwhile: nothing about the wallet may outlive the session, other than encrypted.
    if (await peekSession()) {
      await browser.storage.session.set({ [key]: next });
      if (!next.problem) await writeCached(key, next);
    }
    return view(next);
  });
}
