// The active wallet's coins and balance, fetched through zandr's API and kept in session storage
// while unlocked: a reopened popup shows them at once while fresh ones load, and the popup and
// side panel get each update together. The last ones fetched are also kept encrypted between
// sessions, so unlocking shows them at once too. While a view is open, lib/live.ts refreshes them
// the moment they change on chain. Background only.
import { ApiError, type Network } from '@/server/api';
import { getApi } from '@/lib/api';
import type { PortfolioEntry } from '@/lib/messages';
import { loadPreferences, type Preferences } from '@/lib/preferences';
import { coinNames, rememberNames } from '@/lib/tokenNames';
import { peekSession, readCached, writeCached } from '@/lib/vault';

// Older than this, asking for the coins also refreshes them.
const FRESH_MS = 20_000;

// Where a wallet's coins are kept, per network; apart for public services, whose logos come from
// elsewhere.
export const portfolioKey = (preferences: Preferences, network: Network, address: string) =>
  `portfolio:${network}${preferences.publicServices ? '-public' : ''}:${address}`;

async function readEntry(key: string): Promise<PortfolioEntry | null> {
  const stored = await browser.storage.session.get(key);
  return (stored[key] as PortfolioEntry | undefined) ?? null;
}

// Refreshes under way, by key. A change reported while one runs may have come too late for it:
// it goes once more when done, at least as new as the newest change.
const refreshing = new Map<string, { again: boolean; minContextSlot?: number }>();

// Fetches the coins and stores them, or, on failure, why it failed next to what was there.
// One refresh per wallet and network at a time. `change`: the slot of a change on chain, which the
// coins fetched must include.
async function refresh(key: string, network: Network, address: string, preferences: Preferences, change?: { slot: number }) {
  const running = refreshing.get(key);
  if (running) {
    if (change) {
      running.again = true;
      running.minContextSlot = Math.max(running.minContextSlot ?? 0, change.slot);
    }
    return;
  }

  const state: { again: boolean; minContextSlot?: number } = { again: false, minContextSlot: change?.slot };
  refreshing.set(key, state);
  try {
    do {
      const { minContextSlot } = state;
      state.again = false;
      state.minContextSlot = undefined;
      await fetchAndStore(key, network, address, preferences, minContextSlot);
    } while (state.again);
  } finally {
    refreshing.delete(key);
  }
}

async function fetchAndStore(key: string, network: Network, address: string, preferences: Preferences, minContextSlot?: number) {
  let entry: PortfolioEntry;
  try {
    const portfolio = await getApi(preferences).getPortfolio({ network, address, minContextSlot });
    entry = { portfolio, problem: null, checkedAt: Date.now() };
  } catch (error) {
    if (!(error instanceof ApiError)) console.error('Portfolio refresh failed', error);
    const problem = error instanceof ApiError ? { reason: error.reason, service: error.service } : ({ reason: 'bad-response', service: 'rpc' } as const);
    entry = { portfolio: (await readEntry(key))?.portfolio ?? null, problem, checkedAt: Date.now() };
  }
  // Locked meanwhile: nothing about the wallet may outlive the session.
  if (await peekSession()) {
    await browser.storage.session.set({ [key]: entry });
    if (!entry.problem && entry.portfolio) {
      await writeCached(key, entry);
      // So a site's request names this wallet's tokens without asking the token list.
      void rememberNames(network, coinNames(entry.portfolio.coins));
    }
  }
}

// Fetches the coins of a watched wallet again (lib/live.ts): after a change on chain in `slot`,
// or, without one, because there's no live connection to tell. Not if the network was switched
// meanwhile: the wallet is watched on the other one now.
export async function refreshPortfolio(network: Network, address: string, slot?: number) {
  const preferences = await loadPreferences();
  if (preferences.network !== network) return;
  await refresh(portfolioKey(preferences, network, address), network, address, preferences, slot === undefined ? undefined : { slot });
}

// What's cached for this wallet on the chosen network, right away; a refresh starts if that's
// nothing yet, getting old, or asked for (after a transfer, say).
export async function getPortfolio(address: string, force = false) {
  const preferences = await loadPreferences();
  const { network } = preferences;
  const key = portfolioKey(preferences, network, address);
  let entry = await readEntry(key);
  // Just unlocked (or switched to): what was last fetched, from before, while fresh coins load.
  if (!entry) {
    entry = await readCached<PortfolioEntry>(key);
    if (entry) await browser.storage.session.set({ [key]: entry });
    if (entry?.portfolio) void rememberNames(network, coinNames(entry.portfolio.coins));
  }

  if (force || !entry || Date.now() - entry.checkedAt >= FRESH_MS) refresh(key, network, address, preferences);
  return { key, network, address, entry };
}
