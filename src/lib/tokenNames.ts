// Tokens' symbols and logos as the approval window shows them, kept in session storage while
// unlocked. The background is put to sleep when idle, and whatever it kept in memory goes with it:
// without this, a site's first request after a pause would wait on the token list again. The
// active wallet's own coins are put here as they load, so the tokens it holds have their names from
// the start. Gone on lock, with the rest of the session. Background only.
import { getApi } from '@/lib/api';
import type { Preferences } from '@/lib/preferences';
import { peekSession } from '@/lib/vault';
import type { Coin, Network } from '@/server/api';

export type TokenName = { symbol: string | null; logo: string | null; verified: boolean };

const KEY = 'tokenNames';
const KEPT = 2_000;
// As long as the token list's own cache keeps them. A token the list doesn't know is asked about
// again sooner: a new one may be listed any time.
const KNOWN_MS = 60 * 60 * 1000;
const UNKNOWN_MS = 10 * 60 * 1000;
// How long a lookup may take, retries after the token list's rate limit included.
const LOOKUP_MS = 10_000;

// By mint; null: the token list doesn't know it. Mainnet only: devnet tokens have no names.
type Stored = Record<string, { name: TokenName | null; at: number }>;

async function read(): Promise<Stored> {
  const stored = await browser.storage.session.get(KEY);
  return (stored[KEY] as Stored | undefined) ?? {};
}

// What's known of these tokens: a mint left out isn't known yet, or not lately.
export async function knownNames(network: Network, mints: string[]): Promise<Map<string, TokenName | null>> {
  const found = new Map<string, TokenName | null>();
  if (network !== 'mainnet' || !mints.length) return found;
  const stored = await read();
  const now = Date.now();
  for (const mint of mints) {
    const entry = stored[mint];
    if (entry && now - entry.at < (entry.name ? KNOWN_MS : UNKNOWN_MS)) found.set(mint, entry.name);
  }
  return found;
}

// One write at a time, each adding to what the one before it wrote.
let writing = Promise.resolve();

export function rememberNames(network: Network, names: Map<string, TokenName | null>): Promise<void> {
  if (network !== 'mainnet' || !names.size) return writing;
  writing = writing
    .then(async () => {
      // Locked meanwhile: nothing about the wallet may outlive the session.
      if (!(await peekSession())) return;
      const stored = await read();
      const at = Date.now();
      for (const [mint, name] of names) {
        delete stored[mint];
        stored[mint] = { name, at };
      }
      // In the order they were last updated: past the limit, the oldest go.
      const mints = Object.keys(stored);
      for (const mint of mints.slice(0, Math.max(mints.length - KEPT, 0))) delete stored[mint];
      await browser.storage.session.set({ [KEY]: stored });
    })
    .catch(() => {});
  return writing;
}

// A wallet's coins, by name. SOL itself goes under the wrapped SOL mint, unless the wallet holds
// wrapped SOL too: the approval window shows SOL with wrapped SOL's logo.
export function coinNames(coins: Coin[]): Map<string, TokenName> {
  const names = new Map<string, TokenName>();
  for (const coin of [...coins].sort((a, b) => Number(a.native) - Number(b.native))) {
    if (coin.native && names.has(coin.mint)) continue;
    names.set(coin.mint, coin.native ? { symbol: 'SOL', logo: coin.logo, verified: true } : { symbol: coin.symbol, logo: coin.logo, verified: coin.verified });
  }
  return names;
}

// Lookups under way, by mint: a token being looked up already isn't asked about twice.
const asked = new Map<string, Promise<Map<string, TokenName | null>>>();

// Looks tokens up on the token list, ahead of other requests to it, and keeps what's found. Only
// what was found is in the answer: a token missing from it couldn't be looked up just now.
export async function lookUpNames(preferences: Preferences, mints: string[]): Promise<Map<string, TokenName | null>> {
  const { network } = preferences;
  const wanted = [...new Set(mints)].slice(0, 100);
  if (network !== 'mainnet' || !wanted.length) return new Map();
  const fresh = wanted.filter((mint) => !asked.has(mint));
  if (fresh.length) {
    const lookup = getApi(preferences)
      .getTokens({ network, mints: fresh }, { urgent: true, signal: AbortSignal.timeout(LOOKUP_MS) })
      .then((tokens) => {
        const names = new Map(
          fresh.map((mint) => {
            const token = tokens[mint];
            return [mint, token ? { symbol: token.symbol, logo: token.logo, verified: token.verified } : null] as const;
          }),
        );
        void rememberNames(network, names);
        return names;
      })
      .finally(() => fresh.forEach((mint) => asked.delete(mint)));
    fresh.forEach((mint) => asked.set(mint, lookup));
  }
  const found = new Map<string, TokenName | null>();
  const lookups = new Set(wanted.map((mint) => asked.get(mint)).filter((lookup) => lookup !== undefined));
  for (const result of await Promise.allSettled(lookups)) {
    if (result.status !== 'fulfilled') continue;
    for (const [mint, name] of result.value) if (wanted.includes(mint)) found.set(mint, name);
  }
  return found;
}
