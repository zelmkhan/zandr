// Messages that extension pages (popup, onboarding) can send to the background.
import type { Activity, ApiFailure, ApiService, Network, Portfolio, TokenListing } from '@/server/api';

// What the user brings to create or import a wallet: a recovery phrase (generated or typed
// in) or a private key.
export type WalletSecret = { kind: 'phrase'; words: string[] } | { kind: 'privateKey'; key: string };

export type SecretCheck =
  | { ok: true }
  | { ok: false; error: 'word-count' | 'checksum' | 'invalid-key' }
  | { ok: false; error: 'unknown-word'; index: number };

// Checked by the onboarding page and enforced again by the background.
export const PASSWORD_MIN_LENGTH = 8;
export const WALLET_NAME_MAX_LENGTH = 32;

export const DEFAULT_WALLET_NAME = 'Main wallet';

// How many wrong passwords in a row the user may allow before zandr erases itself, if they turn
// that on (lib/guard.ts).
export const ERASE_CHOICES = [3, 5, 10, 20];

// A wrong password: how many more may be tried before zandr erases itself (null with that off),
// or that this one was the last and it just did.
export type WrongPassword = { attemptsLeft: number | null; erased: boolean };

// Shown only while unlocked: on disk both are encrypted along with the keys.
export type Account = { name: string; address: string };

// One of the wallets in the vault, as the wallet switcher lists it.
// `source`: how it came into the vault, by its recovery phrase or by its private key alone (only the
// kind, never the secret).
export type WalletSummary = Account & { id: string; source?: 'phrase' | 'privateKey' };

// Why a wallet couldn't be added. For duplicate, `conflict` names the wallet with that address;
// for secret, `check` says what's wrong with the phrase or key.
export type WalletAddResult =
  | { ok: true; wallet: WalletSummary }
  | { ok: false; error: 'name' | 'duplicate'; conflict?: string }
  | { ok: false; error: 'secret'; check: SecretCheck };

// A saved address. The whole address book is encrypted and authenticated on disk, so entries
// can't be read or swapped outside zandr.
export type Contact = { id: string; name: string; address: string; addedAt: number };

export const CONTACT_NAME_MAX_LENGTH = 32;

// Why an address can't be saved. For duplicate and lookalike, `conflict` names the saved entry
// (or the wallet itself) it collides with.
export type ContactError = 'name' | 'invalid-address' | 'own-address' | 'duplicate' | 'lookalike';

// The active wallet's coins as last fetched, kept while unlocked. `problem` says why the last
// refresh failed, if it did; `portfolio` then still holds what came before, if anything.
export type PortfolioEntry = {
  portfolio: Portfolio | null;
  problem: { reason: ApiFailure; service: ApiService } | null;
  checkedAt: number;
};

// The port a popup or side panel holds open while it shows a wallet, so the background watches
// that wallet's coins live (lib/live.ts). The view pings over it every LIVE_PING_MS.
export const LIVE_PORT = 'live';
export const LIVE_PING_MS = 20_000;

// A transaction in the wallet's history, with what zandr knows about the other side: the name it
// has in the address book or among the user's wallets, or that it's a lookalike of one of those or
// of an address the wallet sent to (the shape of address poisoning).
export type ActivityItem = Activity & { name: string | null; lookalike: boolean };

// The wallet's history as kept while unlocked: `loaded` is false until a first page came. `more`:
// there's older history to load. `problem`: why the last load failed, if it did.
export type ActivityView = { items: ActivityItem[]; more: boolean; loaded: boolean; problem: PortfolioEntry['problem'] };

// A token account of the wallet that can be closed, and the SOL (rent) closing returns: an empty
// one, or one holding junk (worth under RECLAIM_JUNK_MAX_USD, or with no price), whose tokens are
// burned first. `balance` and `value` (US dollars, null without a price) for junk only.
export type ReclaimAccount = {
  address: string;
  mint: string;
  symbol: string | null;
  logo: string | null;
  verified: boolean;
  sol: string;
  balance: string | null;
  value: number | null;
};

export const RECLAIM_JUNK_MAX_USD = 1;
// Accounts per transaction, and about what each transaction costs, in lamports.
export const RECLAIM_BATCH = { close: 20, burn: 8 };
export const RECLAIM_FEE_PER_TRANSACTION = 5_200;

export type ReclaimFailure =
  | { reason: 'locked' }
  // None of the accounts asked for can be closed any more.
  | { reason: 'nothing' }
  // Burning wasn't acknowledged.
  | { reason: 'unacknowledged' }
  // Token prices couldn't be checked, so nothing is burned.
  | { reason: 'prices' }
  | { reason: 'network'; failure: 'forbidden' | 'rate-limited' | 'unreachable' | 'rejected' }
  // The test run failed, or didn't return what closing should.
  | { reason: 'simulation'; detail: string };

// What the user asks to send: SOL (`mint` null) or a token, to an address. `amount` is in whole
// coins, as a decimal string, or 'max': everything (less the fee, for SOL). `from` is the wallet
// it was asked for: if another becomes active meanwhile, nothing is sent.
export type SendIntent = { from: string; mint: string | null; to: string; amount: string };

// Reasons, found on the recipient, not to send. Each comes from a protection in Security settings,
// and stops the transfer: sending anyway takes turning that protection off.
export type SendCheck =
  // A program; an account a program controls; or an address derived from a program, with no key.
  | { id: 'program'; kind: 'program' | 'owned' | 'derived' }
  | { id: 'mint'; token: string | null }
  | { id: 'tokenAccount'; owner: string }
  // Starts and ends like a saved address or one of the wallets, but isn't it.
  | { id: 'lookalike'; name: string; address: string }
  // An exchange's own wallet, not a deposit address: nothing sent there is credited to anyone.
  | { id: 'exchangeWallet'; exchange: string }
  // A deposit address of an exchange that doesn't accept this token on Solana (`basis` "deposits",
  // by its own list) or doesn't trade it at all ("trading", by CoinGecko).
  | { id: 'exchangeToken'; exchange: string; basis: 'deposits' | 'trading' }
  // The exchange isn't taking deposits of this token now (by its list from the last two days).
  | { id: 'exchangePaused'; exchange: string; coin: string | null }
  // Less than the exchange credits: its minimum deposit, in whole tokens, and its name for the token.
  | { id: 'exchangeMinimum'; exchange: string; minimum: string; coin: string | null };

export type SendCheckId = SendCheck['id'];

// What zandr couldn't check about a transfer, shown on the review without stopping it: whether the
// address is an exchange's (no answer in time), or the token, at an exchange zandr has no token list
// for.
export type SendNote = { id: 'exchangeUnchecked' } | { id: 'exchangeNoList'; exchange: string };

// What a transfer will do, for the user to confirm. Amounts are decimal strings; fees in SOL.
export type SendReview = {
  network: Network;
  from: string;
  to: string;
  // The recipient's name in the address book, or the wallet's own name for one of the user's wallets.
  contact: string | null;
  coin: { mint: string | null; symbol: string | null; name: string | null; logo: string | null; decimals: number };
  amount: string;
  fee: string;
  // Paid once to open the recipient's account for the token, when they don't have one yet.
  rent: string | null;
  checks: SendCheck[];
  notes: SendNote[];
};

export type SendFailure =
  | {
      reason:
        | 'locked'
        | 'wallet-changed'
        | 'invalid-address'
        | 'own-address'
        | 'no-coin'
        | 'invalid-amount'
        | 'insufficient'
        | 'split-balance'
        | 'non-transferable'
        | 'transfer-hook'
        // A protection stopped it: the review that comes with it says which.
        | 'blocked';
    }
  // SOL needed for the fee (and the recipient's new account), in total.
  | { reason: 'insufficient-sol'; needed: string }
  // A new address must get at least `minimum` SOL; a wallet must keep at least that, or nothing.
  | { reason: 'below-minimum'; minimum: string; leftover: boolean }
  | { reason: 'network'; failure: 'forbidden' | 'rate-limited' | 'unreachable' | 'rejected'; detail?: string }
  // The network ran the transfer as a test and it failed.
  | { reason: 'simulation'; detail: string };

// A swap quote as the popup shows it: amounts in whole coins. Its raw form stays in the
// background, under `id`.
export type SwapQuoteView = {
  id: string;
  inputMint: string;
  outputMint: string;
  inAmount: string;
  outAmount: string;
  minOutAmount: string;
  priceImpactPct: number;
  route: string[];
  // zandr's fee, in SOL, paid in the same transaction; null when there's none.
  fee: string | null;
};

// Reasons, found on a swap, to look twice. The user can still swap once they've seen them.
export type SwapCheck =
  // The token bought isn't verified: anyone can make one with any name and logo.
  | { id: 'unverified'; symbol: string | null }
  // The trade moves the price this much, in percent.
  | { id: 'impact'; percent: number };

export type SwapCheckId = SwapCheck['id'];

// A swap built, checked and test-run. Amounts in whole coins, fees in SOL.
export type SwapReview = {
  id: string;
  quote: SwapQuoteView;
  // What the test run says arrives at today's prices; at least `quote.minOutAmount` either way.
  outAmount: string;
  fee: string;
  // Paid once to open the account for the token bought, if the wallet has none yet.
  rent: string | null;
};

export type SwapFailure =
  | {
      reason:
        | 'locked'
        | 'wallet-changed'
        | 'mainnet-only'
        | 'same-token'
        | 'unknown-token'
        | 'invalid-amount'
        | 'insufficient'
        | 'no-route'
        | 'expired';
    }
  | { reason: 'insufficient-sol'; needed: string }
  // The transaction from the swap service failed zandr's checks: nothing was signed.
  | { reason: 'unsafe'; detail: string }
  | { reason: 'simulation'; detail: string }
  | { reason: 'network'; failure: 'forbidden' | 'rate-limited' | 'unreachable' | 'rejected'; detail?: string };

// What a website may ask zandr, through its content script (lib/dapp.ts). Only these, and only for
// the site's own origin, which the background takes from Chrome, never from the message.
// Transactions and messages travel as base64.
export type DappRequest =
  | { type: 'dapp:connect'; silent: boolean }
  | { type: 'dapp:disconnect' }
  | { type: 'dapp:signTransactions'; transactions: string[]; chain: string | null }
  | {
      type: 'dapp:signAndSendTransactions';
      transactions: string[];
      chain: string | null;
      options: { skipPreflight?: boolean; maxRetries?: number };
    }
  | { type: 'dapp:signMessage'; message: string };

// Errors use the codes Solana wallets commonly do: 4001 rejected by the user, 4100 not connected,
// -32002 a request already waiting, -32602 invalid, -32603 internal.
export type DappResponse =
  | { ok: true; accounts: string[] }
  | { ok: true; transactions: string[] }
  | { ok: true; signatures: string[] }
  | { ok: true; signature: string }
  | { ok: true }
  | { ok: false; code: number; message: string };

// What a transaction a site asks to sign would do, as the test run says.
export type TxChange = { mint: string | null; symbol: string | null; logo: string | null; verified: boolean; amount: string };
export type TxWarning = { level: 'danger' | 'caution'; title: string; text: string };
export type TxSummary = {
  // Positive: arrives in the wallet. Negative: leaves it. The network fee is apart.
  changes: TxChange[];
  fee: string;
  // This wallet pays the fee (it signs first); otherwise the site does.
  payer: boolean;
  programs: string[];
  warnings: TxWarning[];
  // The test run failed: why.
  failure: string | null;
  // Can't be signed at all: why.
  blocked: string | null;
};

// A site's request waiting in zandr's approval window.
export type ApprovalView = {
  id: string;
  origin: string;
  // The site's icon, as its page declares it (a large one), if any.
  icon: string | null;
  kind: 'connect' | 'transactions' | 'message';
  network: Network;
  // Locked: the window asks for the password first; there's nothing else to show yet.
  locked: boolean;
  wallet: Account | null;
  send?: boolean;
  transactions?: TxSummary[];
  // Some tokens' names are still being looked up: they show by address until then.
  namesPending?: boolean;
  message?: { text: string | null; hex: string; blocked: string | null };
};

export type ConnectedApp = { origin: string; wallets: string[]; icon: string | null };

export type Request =
  | { type: 'wallet:getStatus' }
  // From the hidden theme page: the browser's theme, for the toolbar icon.
  | { type: 'theme:set'; dark: boolean }
  | { type: 'wallet:unlock'; password: string }
  | { type: 'wallet:lock' }
  | { type: 'wallet:changePassword'; current: string; next: string }
  | { type: 'wallets:list' }
  | { type: 'wallets:switch'; id: string }
  // A new wallet with a recovery phrase of its own: `words`, from phrase:generate, which the
  // user has written down by now.
  | { type: 'wallets:create'; name: string; words: string[] }
  | { type: 'wallets:import'; secret: WalletSecret; name: string }
  // Both take the password again, even while unlocked. The private key is the other piece of
  // key material a page receives, shown because the user asked to see it.
  | { type: 'wallets:exportKey'; id: string; password: string }
  // The recovery phrase a wallet comes from, for one that came by its phrase. Takes the password too.
  | { type: 'wallets:exportPhrase'; id: string; password: string }
  | { type: 'wallets:remove'; id: string; password: string }
  // The wallets in a new order, as the user dragged them: every wallet's id, once.
  | { type: 'wallets:reorder'; ids: string[] }
  | { type: 'security:getEraseAfter' }
  // Turning the guard on, off or changing it takes the password: whoever guesses can't switch it off.
  | { type: 'security:setEraseAfter'; eraseAfter: number | null; password: string }
  // The cached coins right away; fresh ones, if these are old, arrive in session storage under `key`.
  | { type: 'portfolio:get'; refresh?: boolean }
  // Empty token accounts to close for their rent, and closing them: each checked again first.
  | { type: 'reclaim:plan' }
  // `burn`: junk accounts to burn and close; each one's value is checked again first.
  | { type: 'reclaim:execute'; close: string[]; burn: string[]; acknowledged: boolean }
  // The history kept so far ('cached'), with anything newer ('refresh'), or with an older page ('more').
  | { type: 'activity:get'; mode: 'cached' | 'refresh' | 'more' }
  // What a transfer would do, checked against the chain, without signing anything.
  | { type: 'send:prepare'; intent: SendIntent }
  // The recipient typed in, before the review: zandr starts finding out whether it's an exchange's.
  | { type: 'send:inspect'; to: string }
  // Checks again, then signs and sends. `amount` must be exact (no 'max'); any check found stops
  // it; the fee can't exceed `maxFee`, the one the user saw.
  | { type: 'send:submit'; intent: SendIntent; maxFee: string }
  // `wait`: answered the moment the node says it landed, or after a couple of seconds without news.
  | { type: 'send:status'; signature: string; wait?: boolean }
  // Tokens to swap into: matching `query`, or popular ones for an empty one.
  | { type: 'swap:tokens'; query: string }
  // `inputMint` and `outputMint` are mints; SOL is the wrapped SOL mint. `amount` in whole coins, or 'max'.
  | { type: 'swap:quote'; inputMint: string; outputMint: string; amount: string }
  // Builds the swap from the quote, takes it apart and test-runs it, then, if all is well, signs
  // exactly that transaction and sends it. Its checks are warnings to show, not reasons to stop.
  // Follow it with send:status.
  | { type: 'swap:execute'; quoteId: string }
  // From zandr's approval window.
  // `names`: answers once the tokens' names still being looked up are there (or after a while).
  | { type: 'approval:get'; id: string; names?: boolean }
  | { type: 'approval:decide'; id: string; approved: boolean; acknowledged: boolean }
  // Keeps the background awake while the window is open.
  | { type: 'approval:ping' }
  | { type: 'connections:list' }
  | { type: 'connections:remove'; origin: string }
  | { type: 'addressBook:list' }
  | { type: 'addressBook:add'; name: string; address: string }
  | { type: 'addressBook:remove'; id: string }
  // Only for an address book that failed verification: it can't be read, only discarded.
  | { type: 'addressBook:clear' }
  // A new recovery phrase, for onboarding or a new wallet. It's the one piece of key material a
  // page receives unasked: the user has to see it once to write it down. (Pages also hand an
  // imported phrase or key to the background, when onboarding or adding a wallet.)
  | { type: 'phrase:generate' }
  // Onboarding only.
  | { type: 'onboarding:checkSecret'; secret: WalletSecret }
  | { type: 'onboarding:createWallet'; secret: WalletSecret; password: string; name: string };

export type ResponseMap = {
  // erased: there's no wallet because zandr erased itself after too many wrong passwords.
  'wallet:getStatus': { hasWallet: boolean; locked: boolean; account: Account | null; erased: boolean };
  'theme:set': { ok: true };
  'wallet:unlock': { unlocked: true } | ({ unlocked: false } & WrongPassword);
  'wallet:lock': { locked: true };
  // changed is false when the current password is wrong.
  'wallet:changePassword': { changed: true } | ({ changed: false } & WrongPassword);
  'wallets:list': { wallets: WalletSummary[]; activeId: string } | { error: 'locked' };
  'wallets:switch': { ok: true };
  'wallets:reorder': { ok: true };
  'wallets:create': WalletAddResult;
  'wallets:import': WalletAddResult;
  'wallets:exportKey': { ok: true; key: string } | ({ ok: false; error: 'wrong-password' } & WrongPassword);
  // `wallets`: the names of every wallet the phrase restores, this one among them.
  'wallets:exportPhrase':
    | { ok: true; words: string[]; wallets: string[] }
    | ({ ok: false; error: 'wrong-password' } & WrongPassword)
    | { ok: false; error: 'no-phrase' };
  'wallets:remove': { ok: true } | ({ ok: false; error: 'wrong-password' } & WrongPassword) | { ok: false; error: 'last-wallet' };
  'security:getEraseAfter': { eraseAfter: number | null };
  'security:setEraseAfter': { ok: true } | ({ ok: false; error: 'wrong-password' } & WrongPassword) | { ok: false; error: 'no-wallet' };
  // locked: the address book is only readable while unlocked. tampered: it was changed outside
  // zandr and failed verification.
  'portfolio:get': { key: string; network: Network; address: string; entry: PortfolioEntry | null } | { error: 'locked' };
  'activity:get': ActivityView | { error: 'locked' };
  // `pricesKnown`: false when prices couldn't be checked, and so no junk is offered.
  'reclaim:plan': { ok: true; empty: ReclaimAccount[]; junk: ReclaimAccount[]; pricesKnown: boolean } | { ok: false; failure: ReclaimFailure };
  // `skipped`: accounts left as they were, because they couldn't be closed or burned, or turned out
  // to be worth more than junk.
  'reclaim:execute':
    | { ok: true; signatures: string[]; reclaimed: string; burned: number; skipped: number }
    | { ok: false; failure: ReclaimFailure };
  'send:prepare': { ok: true; review: SendReview } | { ok: false; failure: SendFailure };
  'send:inspect': { ok: true };
  'send:submit': { ok: true; signature: string; review: SendReview } | { ok: false; failure: SendFailure; review?: SendReview };
  // pending: not landed yet (it's being sent again meanwhile); expired: it never will, nothing moved.
  'send:status': { status: 'pending' | 'confirmed' } | { status: 'failed' | 'expired'; detail?: string };
  'swap:tokens': { ok: true; tokens: TokenListing[] } | { ok: false; failure: SwapFailure };
  'swap:quote': { ok: true; quote: SwapQuoteView } | { ok: false; failure: SwapFailure };
  'swap:execute': { ok: true; signature: string; review: SwapReview } | { ok: false; failure: SwapFailure; review?: SwapReview };
  // done: answered meanwhile (connected already, say); the window can close.
  'approval:get': { ok: true; approval: ApprovalView } | { ok: false; done: boolean };
  'approval:decide': { ok: true } | { ok: false; error: 'gone' | 'locked' | 'unacknowledged' | 'blocked' | 'failed'; detail?: string };
  'approval:ping': { ok: true };
  'connections:list': { apps: ConnectedApp[] };
  'connections:remove': { ok: true };
  'addressBook:list': { contacts: Contact[] } | { error: 'locked' | 'tampered' };
  'addressBook:add': { ok: true; contact: Contact } | { ok: false; error: ContactError; conflict?: string };
  'addressBook:remove': { ok: true };
  'addressBook:clear': { ok: true };
  'phrase:generate': { words: string[] };
  'onboarding:checkSecret': SecretCheck;
  'onboarding:createWallet': { address: string };
};

export type Response<T extends Request = Request> = ResponseMap[T['type']];

// Rejects if the background failed to handle the request. It then answers with nothing,
// which Chrome delivers as null rather than undefined.
export async function sendToBackground<T extends Request>(request: T): Promise<Response<T>> {
  const response: Response<T> | null | undefined = await browser.runtime.sendMessage(request);
  if (response == null) throw new Error(`Background failed to handle ${request.type}`);
  return response;
}
