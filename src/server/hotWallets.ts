// Wallets exchanges control on Solana mainnet: the ones they sweep their users' deposits into and
// keep their funds in. Address → the exchange's name, as users know it. A deposit address is
// recognized by sweeping into one of these (exchanges.ts), so only the exchanges' own wallets are
// needed, not the countless deposit ones. The list is exchangeWallets.json, which says where each
// exchange's wallets come from.
import wallets from './exchangeWallets.json' with { type: 'json' };

type ExchangeWallets = { exchanges: { name: string; wallets: { address: string }[] }[] };

export const HOT_WALLETS: Record<string, string> = Object.fromEntries(
  (wallets as ExchangeWallets).exchanges.flatMap(({ name, wallets: list }) => list.map(({ address }) => [address, name])),
);
