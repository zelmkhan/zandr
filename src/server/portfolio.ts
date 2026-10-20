// An address's coins and their value: balances from the RPC node, names and prices from Jupiter.
import { ApiError, type Coin, type Network, type Portfolio } from './api.ts';
import type { Fetch } from './http.ts';
import type { Jupiter, Price, TokenInfo } from './jupiter.ts';
import { addDecimals, formatUnits, getBalance, getTokenAccounts, type TokenProgram } from './rpc.ts';

export const WRAPPED_SOL = 'So11111111111111111111111111111111111111112';
export const SOL_LOGO = 'https://raw.githubusercontent.com/solana-labs/token-list/main/assets/mainnet/So11111111111111111111111111111111111111112/logo.png';
const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

export type PortfolioDeps = { fetch: Fetch; rpc: Record<Network, string>; jupiter: Jupiter };

type Holding = { mint: string; program: TokenProgram; amount: bigint; decimals: number; balance: string };

// `minContextSlot`: balances at least as new as this slot, as after a change reported in it.
export async function getPortfolio(
  deps: PortfolioDeps,
  request: { network: Network; address: string; minContextSlot?: number },
): Promise<Portfolio> {
  const { network, address, minContextSlot } = request;
  if (!Object.hasOwn(deps.rpc, network) || typeof address !== 'string' || !ADDRESS.test(address)) {
    throw new ApiError('invalid-request', 'rpc');
  }
  if (minContextSlot !== undefined && !(Number.isSafeInteger(minContextSlot) && minContextSlot >= 0)) {
    throw new ApiError('invalid-request', 'rpc');
  }
  const url = deps.rpc[network];

  const [lamports, token, token2022] = await Promise.all([
    getBalance(deps.fetch, url, address, minContextSlot),
    getTokenAccounts(deps.fetch, url, address, 'token', minContextSlot),
    getTokenAccounts(deps.fetch, url, address, 'token-2022', minContextSlot),
  ]);

  // One holding per mint: several accounts of the same token add up. Emptied accounts are left
  // out, and so are collectibles (NFTs), which have no decimals.
  const holdings = new Map<string, Holding>();
  for (const [program, accounts] of [['token', token], ['token-2022', token2022]] as const) {
    for (const account of accounts) {
      if (account.amount === '0' || account.decimals === 0) continue;
      const held = holdings.get(account.mint);
      if (held) {
        held.amount += BigInt(account.amount);
        held.balance = addDecimals(held.balance, account.balance);
      } else {
        holdings.set(account.mint, { ...account, program, amount: BigInt(account.amount) });
      }
    }
  }

  // Token info and prices exist for mainnet only: devnet tokens have no market. Prices are asked
  // for only for tokens that trade at all.
  const infos = network === 'mainnet' ? await deps.jupiter.tokenInfo([...holdings.keys()]) : new Map<string, TokenInfo | null>();
  const traded = [...holdings.keys()].filter((mint) => infos.get(mint)?.traded);
  const prices = network === 'mainnet' ? await deps.jupiter.prices([WRAPPED_SOL, ...traded]) : new Map<string, Price | null>();

  const priced = (mint: string, balance: string) => {
    const quote = prices.get(mint) ?? null;
    return {
      price: quote?.price ?? null,
      value: quote ? Number(balance) * quote.price : null,
      change24h: quote?.change24h ?? null,
    };
  };

  const solBalance = formatUnits(lamports, 9);
  const sol: Coin = {
    mint: WRAPPED_SOL,
    native: true,
    program: 'system',
    amount: lamports.toString(),
    decimals: 9,
    balance: solBalance,
    name: 'Solana',
    symbol: 'SOL',
    logo: deps.jupiter.logoOf(WRAPPED_SOL) ?? SOL_LOGO,
    verified: true,
    ...priced(WRAPPED_SOL, solBalance),
  };

  const tokens: Coin[] = [];
  for (const holding of holdings.values()) {
    // Wrapped SOL, which some swaps leave behind, is listed as SOL: it gets its own name, so it isn't
    // taken for the SOL itself.
    const wrapped = holding.mint === WRAPPED_SOL;
    const info = wrapped
      ? { name: 'Wrapped SOL', symbol: 'wSOL', logo: deps.jupiter.logoOf(WRAPPED_SOL) ?? SOL_LOGO, verified: true }
      : (infos.get(holding.mint) ?? null);
    tokens.push({
      mint: holding.mint,
      native: false,
      program: holding.program,
      amount: holding.amount.toString(),
      decimals: holding.decimals,
      balance: holding.balance,
      name: info?.name ?? null,
      symbol: info?.symbol ?? null,
      logo: info?.logo ?? null,
      verified: info?.verified ?? false,
      ...priced(holding.mint, holding.balance),
    });
  }

  // Highest value first; tokens without a price after, by name, unknown ones last.
  const byName = (coin: Coin) => coin.name ?? '￿';
  tokens.sort((a, b) => (b.value ?? -1) - (a.value ?? -1) || byName(a).localeCompare(byName(b)));

  const coins = [sol, ...tokens];
  return { network, address, coins, value: coins.reduce((sum, coin) => sum + (coin.value ?? 0), 0), updatedAt: Date.now() };
}
