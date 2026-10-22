// The contract of zandr's API: what each call takes and returns. The API runs in the extension's
// background for now and moves to zandr's server later; the extension depends on this file only,
// so the move doesn't change it. Everything here is plain JSON, as it will be over HTTP: amounts
// are decimal strings, so no precision is lost on the way.

export type Network = 'mainnet' | 'devnet';

export type Coin = {
  // SOL itself carries the wrapped SOL mint, which its price is listed under, and `native`.
  mint: string;
  native: boolean;
  program: 'system' | 'token' | 'token-2022';
  // In the token's smallest unit.
  amount: string;
  decimals: number;
  // The amount as wallets show it. For a Token-2022 token it includes any interest or scaling
  // the token applies, so it isn't always `amount` shifted by `decimals`.
  balance: string;
  name: string | null;
  symbol: string | null;
  // Verified tokens only: whoever shows a logo fetches it, and an unknown token's logo URL could
  // be a tracker that learns who holds it.
  logo: string | null;
  verified: boolean;
  // In US dollars. Null when there is no reliable price: devnet, or an illiquid or unknown token.
  price: number | null;
  value: number | null;
  // Price change over the last 24 hours, in percent.
  change24h: number | null;
};

export type Portfolio = {
  network: Network;
  address: string;
  // SOL first, even with nothing in it, then by value, highest first. Collectibles (NFTs) and
  // emptied token accounts are left out.
  coins: Coin[];
  // The sum of the coins' values, in US dollars.
  value: number;
  updatedAt: number;
};

// What the token list says about a token.
export type TokenSummary = { name: string | null; symbol: string | null; logo: string | null; verified: boolean; decimals: number | null };

export type TokenListing = TokenSummary & { mint: string };

// An instruction of a swap, as Jupiter gives it: `data` in base64.
export type SwapInstruction = { program: string; accounts: { address: string; signer: boolean; writable: boolean }[]; data: string };

// A swap built by Jupiter for one wallet: its price, and the instructions carrying it out, which
// the wallet puts into a transaction itself and checks before signing (they come from a third
// party). Amounts are in each token's smallest unit. `minOutAmount` is the least the swap may give,
// slippage taken off: below it the swap fails rather than goes through.
export type SwapBuild = {
  inputMint: string;
  outputMint: string;
  inAmount: string;
  outAmount: string;
  minOutAmount: string;
  slippageBps: number;
  priceImpactPct: number;
  // The markets it goes through, by name.
  route: string[];
  // In order: opening accounts and wrapping SOL, the swap, unwrapping, anything after.
  instructions: SwapInstruction[];
  // The priority fee Jupiter suggests, in micro-lamports per compute unit: the wallet caps it.
  computeUnitPrice: string;
  // Address lookup tables the transaction may load accounts from. Only their addresses: what's in
  // them is read from the chain.
  lookupTables: string[];
  blockhash: string;
  lastValidBlockHeight: number;
};

// One coin's move in or out of an address in one transaction. `mint` is null for SOL (wrapped
// SOL included). `amount` is signed, in whole coins: "-0.1" left, "+25" arrived.
export type ActivityChange = { mint: string | null; amount: string; symbol: string | null; logo: string | null; verified: boolean };

// What a transaction did, as seen from one address:
// send: only coins out, through the system and token programs, signed by the address;
// receive: only coins in, from a transfer to it;
// swap: coins out and in, through an app;
// app: anything else the address signed or took part in (an app, an account opened or closed);
// failed: it failed, so nothing moved but the fee.
export type ActivityKind = 'send' | 'receive' | 'swap' | 'app' | 'failed';

export type Activity = {
  signature: string;
  // When the block was made, in milliseconds; null if the node doesn't know.
  time: number | null;
  kind: ActivityKind;
  // The coins that moved, the fee aside: arrivals first.
  changes: ActivityChange[];
  // In SOL, when this address paid it.
  fee: string | null;
  // The other side of a transfer: the recipient of a send, the sender of a receipt.
  counterparty: string | null;
  // The first program beyond the system and token ones, and its name if it's a well-known app.
  program: string | null;
  app: string | null;
};

// Newest first. `next` continues the history further back (pass it as `before`), null at its end.
export type ActivityPage = { network: Network; address: string; items: Activity[]; next: string | null };

// What an address is to an exchange, from what it does on-chain. `hot-wallet`: one of an
// exchange's own wallets (from a list kept by hand). `deposit`: an address that passes on what it
// receives to an exchange's hot wallet, as the deposit addresses an exchange gives its users do.
// `sweeps` of the `looked` latest transactions went to that exchange.
export type AddressInfo = {
  address: string;
  exchange: string | null;
  kind: 'hot-wallet' | 'deposit' | null;
  sweeps: number;
  looked: number;
};

// What sending a token to an address means at an exchange. `exchange`/`kind`: whether the address
// is an exchange's own wallet or one of its deposit addresses (as in AddressInfo). `listed`, for
// either, from the exchange's token list: whether it accepts this token on Solana, by its mint,
// what it calls it, and the least it credits in whole tokens. Null when there's no list to tell.
export type TransferCheck = {
  exchange: string | null;
  kind: 'hot-wallet' | 'deposit' | null;
  // `paused`: the exchange wasn't taking deposits of it when its list was fetched. `basis`:
  // whether the list is of the tokens it takes on Solana, or (from CoinGecko) of the ones it trades.
  listed: { accepted: boolean; coin: string | null; depositMin: string | null; paused: boolean; basis: 'deposits' | 'trading' } | null;
};

// Which service failed: the Solana RPC node, or the token list and prices.
export type ApiService = 'rpc' | 'tokens';

export type ApiFailure = 'invalid-request' | 'forbidden' | 'rate-limited' | 'unreachable' | 'bad-response';

export class ApiError extends Error {
  readonly reason: ApiFailure;
  readonly service: ApiService;
  // What the service said, when it said why: plain text, cleaned, short.
  readonly detail: string | undefined;

  constructor(reason: ApiFailure, service: ApiService, detail?: string) {
    super(`${service}: ${reason}`);
    this.reason = reason;
    this.service = service;
    this.detail = detail;
  }
}

export interface Api {
  // Both reject with an ApiError.
  // `minContextSlot`: balances at least as new as this slot.
  getPortfolio(request: { network: Network; address: string; minContextSlot?: number }): Promise<Portfolio>;
  // The address's latest transactions, up to `limit` (at most 50): before the one `before` names,
  // and, with `until`, only those newer than it.
  getActivity(request: { network: Network; address: string; before?: string; until?: string; limit?: number }): Promise<ActivityPage>;
  // Whether the address belongs to an exchange, as a hot wallet or a deposit address. Mainnet only:
  // on devnet nothing does.
  getAddressInfo(request: { network: Network; address: string }): Promise<AddressInfo>;
  // Before a transfer of `mint` (null: SOL) to `to`: what it means at an exchange. Mainnet only.
  getTransferCheck(request: { network: Network; to: string; mint: string | null }): Promise<TransferCheck>;
  // For zandr's logo server: where up to 100 mainnet tokens' logos are, as their creators put
  // them. Jupiter's, else the token's own metadata (DAS, where the provider has it), else null.
  getLogoSources(request: { mints: string[] }): Promise<Record<string, string | null>>;
  // Up to 100 mints; ones the token list doesn't know map to null. Devnet tokens are all unknown.
  // `urgent`: someone is waiting on it (ahead of other requests to the token list); `signal`: drop it.
  getTokens(request: { network: Network; mints: string[] }, options?: { urgent?: boolean; signal?: AbortSignal }): Promise<Record<string, TokenSummary | null>>;
  // Swaps are mainnet only. Someone waits on it, so it goes before other requests to the token list;
  // `signal` drops it while it waits, when a newer search makes it moot (it then rejects with an
  // AbortError).
  searchTokens(request: { network: Network; query: string }, options?: { signal?: AbortSignal }): Promise<TokenListing[]>;
  // A swap of `amount` (smallest units) for `user`, built by Jupiter: its price and instructions.
  // Whoever signs a transaction made of them must check it first.
  buildSwap(request: { network: Network; inputMint: string; outputMint: string; amount: string; slippageBps: number; user: string }): Promise<SwapBuild>;
}
