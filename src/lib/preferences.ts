// App preferences, remembered on this device: how zandr looks and behaves, which network and
// RPC it uses. Nothing secret, so kept unencrypted in storage.local, next to (not inside) the
// vault. Wallet-specific settings don't belong here.
import type { NetworkId } from '@/lib/network';

// Checks run before a transfer leaves the wallet, each one switchable in Security settings.
// Each one is enforced by the send flow (lib/send.ts).
export type ProtectionId = 'exchangeSupport' | 'programAddresses' | 'mintAddresses' | 'tokenAccounts' | 'lookalikeAddresses';

// How zandr looks: its own dark theme, a light one, or whichever the system uses (the default).
export type Theme = 'dark' | 'light' | 'system';

export const THEME_CHOICES: Theme[] = ['dark', 'light', 'system'];

export type Preferences = {
  theme: Theme;
  hideBalance: boolean;
  // Coins worth less than this many US dollars are left out of the home screen's list; 0 shows all.
  minCoinValue: number;
  // The toolbar button opens the wallet in Chrome's side panel instead of the popup.
  sidePanel: boolean;
  network: NetworkId;
  // A custom RPC URL per network, or null for the default one.
  rpc: Record<NetworkId, string | null>;
  // Public services in place of zandr's server: Helius as mainnet's default node, and Jupiter and
  // tokens' logos asked for directly (only the exchanges' token lists still come from zandr's
  // server). A custom node, where set, is still the one used.
  publicServices: boolean;
  autoLockMinutes: number;
  protection: Record<ProtectionId, boolean>;
};

export const AUTO_LOCK_CHOICES = [5, 15, 30, 60];

export const MIN_COIN_VALUE_CHOICES = [0, 0.01, 1, 5];

export const DEFAULT_PREFERENCES: Preferences = {
  theme: 'system',
  hideBalance: false,
  minCoinValue: 0,
  sidePanel: false,
  network: 'mainnet',
  rpc: { mainnet: null, devnet: null },
  publicServices: false,
  autoLockMinutes: 15,
  // All on unless the user turns one off.
  protection: {
    exchangeSupport: true,
    programAddresses: true,
    mintAddresses: true,
    tokenAccounts: true,
    lookalikeAddresses: true,
  },
};

// Falls back to the defaults rather than failing: a lost preference must not break the popup.
export async function loadPreferences(): Promise<Preferences> {
  try {
    const { preferences } = await browser.storage.local.get('preferences');
    const saved = preferences as Partial<Preferences> | undefined;
    return {
      ...DEFAULT_PREFERENCES,
      ...saved,
      theme: THEME_CHOICES.includes(saved?.theme as Theme) ? (saved!.theme as Theme) : DEFAULT_PREFERENCES.theme,
      rpc: { ...DEFAULT_PREFERENCES.rpc, ...saved?.rpc },
      publicServices: saved?.publicServices === true,
      // Only the protections that exist now: one removed later drops out instead of lingering.
      protection: Object.fromEntries(
        Object.entries(DEFAULT_PREFERENCES.protection).map(([id, on]) => [id, saved?.protection?.[id as ProtectionId] ?? on]),
      ) as Record<ProtectionId, boolean>,
    };
  } catch {
    return structuredClone(DEFAULT_PREFERENCES);
  }
}

// Changes some preferences, keeping the rest as stored. The popup, side panel and settings can
// be open at once, so each writes only what it changed instead of its whole, maybe stale, copy.
export async function updatePreferences(changes: Partial<Preferences>) {
  const preferences = { ...(await loadPreferences()), ...changes };
  await browser.storage.local.set({ preferences });
}
