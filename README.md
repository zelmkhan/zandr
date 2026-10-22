# Zandr

Crypto wallet browser extension for Chrome (Manifest V3).

Stack: [WXT](https://wxt.dev) (Vite) + TypeScript + Svelte 5.

## Commands

```sh
npm ci            # install exactly what package-lock.json specifies
npm run dev       # dev mode with HMR, opens Chrome with the extension loaded
npm run check     # type-check
npm run build     # production build to .output/chrome-mv3
npm run zip       # package for the Chrome Web Store
```

To load a build manually: `chrome://extensions` → enable Developer mode → Load unpacked → `.output/chrome-mv3`.

## Structure

```
src/
  assets/
    theme.css         palette and base styles shared by all extension pages: dark, and the light override
    ui.css            form controls and text styles shared by full-page views (onboarding, settings)
  entrypoints/
    background.ts     service worker: all wallet logic and keys live here
    popup/            360×600 UI, opened by the toolbar button once a wallet exists; its wallet view is shared with the side panel
    sidepanel/        the same wallet view in Chrome's side panel, when "Side panel mode" is on
    onboarding/       full-page onboarding, opened by the toolbar button while there is no wallet
    options/          app and network settings in a full tab, from "Settings" in the wallet's menu
    explore/          Explore, in a full tab (empty for now; the wallet's Explore button doesn't open it yet)
    approval/         the window a site's request opens: connect, sign transactions (and send), sign a message
    offscreen/        a hidden page that watches the browser's light or dark theme, for the toolbar icon
    wallet.content.ts the wallet web pages see (Wallet Standard), in the page's own world; holds nothing
    bridge.content.ts relays the page's requests to the background, in zandr's isolated world
  components/         small UI pieces shared by pages (password strength meter, show/hide button)
  lib/
    messages.ts       page ↔ background message types
    secrets.ts        recovery phrases, private keys, address derivation; background only
    password.ts       password strength, shared by the forms that set one
    vault.ts          encrypted wallet storage, the address book and the unlocked session; background only
    addressBook.ts    what may be saved in the address book, and why not; background only
    wallets.ts        adding wallets: a new one with its own recovery phrase, or an import; background only
    format.ts         display helpers: shortened addresses, amounts, dollars
    preferences.ts    app preferences (theme, display, network and RPC, auto-lock), unencrypted
    theme.ts          puts the chosen theme (dark, light or the system's) on each page before it draws
    network.ts        Solana networks, RPC URL checks and connection probes
    guard.ts          erasing everything after too many wrong passwords, if turned on; background only
    portfolio.ts      the open wallet's coins: fetched through the API, cached while unlocked; background only
    live.ts           live coins while a popup or side panel is open: a WebSocket to the RPC node, refreshed on each change; background only
    activity.ts       the open wallet's history: newest first, cached while unlocked, lookalike addresses flagged; background only
    send.ts           transfers: planned, checked and test-run against the chain, signed, followed; background only
    swap.ts           swaps through Jupiter: quoted, built, taken apart and test-run before signing; background only
    reclaim.ts        closing the wallet's empty token accounts, and burning picked junk, for the SOL rent they hold; background only
    units.ts          amounts in whole coins and in a token's smallest unit, converted exactly
    api.ts            the background's handle on zandr's API and the RPC endpoints
    dapp.ts           sites: connections, their requests waiting for approval, what a transaction does; background only
    dappChannel.ts    the page ↔ bridge channel and the sites the content scripts run on
    solana/           addresses (PDAs, token accounts), transaction encoding and decoding (legacy and v0), instructions, RPC calls
  server/             zandr's API (balances, history, token names, prices): runs in the background for now,
                      moves to zandr's server unchanged; api.ts is the contract the extension uses
api/                  zandr's API on a real server (Railway): main.ts serves src/server over HTTP, Dockerfile builds it
public/icon/          extension icons: the mark in black (manifest, light themes); dark/ has the white toolbar icon for dark themes
scripts/              build checks (src/server stays self-contained), the site's download (release-site.mjs),
                      exchanges' wallets (exchange-wallets.mjs) and token lists (exchange-tokens.mjs, API keys
                      from .env.exchanges, never committed)
wxt.config.ts         manifest: permissions, CSP
website/              project website: separate Astro project, see website/README.md
```

## zandr's API server

`src/server` runs in the extension's background, and the same code also runs on zandr's server
(`api/`), deployed on Railway (project **Zandr**, service **api**): https://api.zandr.xyz.
Node runs the TypeScript as it is, with no dependencies; the image holds `src/server` and `api/` only. The extension
also fetches tokens' logos and the exchanges' token lists from it, even with a custom RPC endpoint. With Settings →
Network → Public on Mainnet, it uses this server only for the exchanges' token lists (fetched whole every 12 hours, three
tries at a time): Helius's node under a key meant to be public, Jupiter's public API and logos through the wsrv.nl image
proxy instead. With Private (the default), while this server can't answer, Helius's public node stands in for its node
for ten minutes at a time, Jupiter is asked directly and logos come through wsrv.nl.

- `GET /health`: `{ "ok": true }`.
- `POST /v1/address-info` with `{ "network": "mainnet", "address": "…" }`: whether the address is an
  exchange's hot wallet or one of its deposit addresses, and which exchange (`src/server/exchanges.ts`).
  A deposit address is told apart by what it does: it sweeps what it receives into one of the exchange's
  own wallets, listed in `src/server/exchangeWallets.json` (172 on 20 exchanges), which `npm run
  exchange-wallets` refreshes. Each list says where it comes from and how far it's trusted: the
  exchange's own API, its proof-of-reserves wallets, zandr checking on chain, or Dune Spellbook's
  community labels. Spellbook's license (BSL 1.1, GPL from 2027-03-03) doesn't cover data platforms;
  its labels are used at the project owner's decision and kept in lists of their own (`"trust":
  "community"`), so they can be dropped at once. A disputed address goes to the more trusted source,
  and only plain wallets are kept (Spellbook names some token mints as exchange wallets). The address goes in the body, not the
  URL, so it isn't in access logs; the server logs no addresses and keeps none past its cache.
- `GET /v1/logo/<mint>`: the token's logo, fetched and cached by the server (see the security rules).
- `GET /v1/exchange-tokens`: the exchanges' lists of the tokens they accept on Solana (`api/exchangeTokens.ts`),
  refreshed every 6 hours from the exchanges' APIs; an exchange whose fetch fails or comes back much shorter
  keeps its last list. Bybit, OKX and MEXC are fetched only with read-only keys in Railway variables:
  `BYBIT_API_KEY`/`BYBIT_API_SECRET`, `OKX_API_KEY`/`OKX_API_SECRET`/`OKX_API_PASSPHRASE`,
  `MEXC_API_KEY`/`MEXC_API_SECRET`. Exchanges without a list of their own come from CoinGecko's
  exchange tickers (once a day; `COINGECKO_API_KEY`, a free demo key, raises its rate limit). Data
  provided by [CoinGecko](https://www.coingecko.com).
- `POST /rpc/mainnet`, and a WebSocket on the same address: the extension's default mainnet node
  (`api/rpc.ts`). It forwards to `SOLANA_RPC_MAINNET` (Helius, key included), so the key never ships
  in the extension. Being public, it does only what the wallet needs: an allowlist of JSON-RPC methods
  (no `getProgramAccounts`, no blocks, no batches, bodies up to 32 KB), subscriptions to an account, to
  token accounts with an owner filter only and to a transaction's signature (4 per socket), and limits:
  per client (by `X-Real-IP`, which Railway's edge sets) a burst of 120 requests then 15 a second and
  30,000 a day, 8 sockets;
  overall `RPC_MAX_RPS` requests a second (default 40, keep it under the provider's plan) and
  `RPC_MAX_SOCKETS` sockets (default 2000). Nothing is logged; IPs are held in memory for the limits.
- `GET /jupiter/tokens/v2/search`, `/jupiter/price/v3` and `/jupiter/swap/v2/build` (and Swap API v1's
  `/jupiter/swap/v1/quote` and `POST /jupiter/swap/v1/swap`, for older releases): the extension's
  requests to Jupiter (`api/jupiter.ts`), sent on to
  `JUPITER_API_URL` (default `https://api.jup.ag`) with the paid key in `JUPITER_API_KEY`, so they
  come under its plan's rate limit instead of the public API's 5 requests per 10 seconds per IP. That
  limit is every wallet's together (Jupiter's free plan: 10 requests per 10 seconds in all), so the plan
  has to grow with the number of wallets open at once. Only
  these paths pass, a v1 swap to build must name a quote and a wallet address, and each client gets a
  burst of 40 requests then 4 a second and 10,000 a day. Token lookups are kept for everyone for 10
  minutes and prices for 15 seconds; quotes and swaps never. Jupiter's rate-limit headers are passed
  on, so wallets wait out a used-up window. Without a key it answers 503, and the extension goes
  straight to Jupiter's public API, as it also does for 10 minutes whenever this server can't answer.
  Nothing about the requests is logged.

Environment: `SOLANA_RPC_MAINNET` (the provider's URL with its key: set it in Railway's variables,
never in code) and `SOLANA_RPC_DEVNET` (default: Solana's public nodes, which throttle data-center IPs
hard); `SOLANA_WS_MAINNET` if the provider's socket has another address than its HTTP one;
`JUPITER_API_KEY` (a paid Jupiter key, from portal.jup.ag: Railway's variables only) and `JUPITER_API_URL`. Deploy from the repo root (`.railwayignore`
keeps the upload to what the image needs):

```sh
railway link -p Zandr -e production -s api   # once per checkout
railway up --service api --ci
```

## Security rules

- **Keys and the seed phrase stay in the background.** The popup and content scripts only receive results (addresses, signatures), never key material. The exceptions are deliberate and user-driven: onboarding, and creating another wallet, show a newly generated recovery phrase so the user can write it down; a wallet's private key is shown when the user asks for it and re-enters the password; and an imported phrase or key goes from the page straight to the background.
- **Keys are encrypted at rest.** The vault encrypts every wallet's recovery phrase or private key with AES-256-GCM under a key derived from the password with scrypt (N=2^17, r=8, p=1, OWASP's minimum), with a fresh random salt and IV on every write. The address and the wallet's name are encrypted too. KDF parameters are stored with the vault so they can be raised later.
- **One password, many wallets.** The vault holds keyrings (recovery phrases and private keys) and the wallets made from them: account N of a phrase is `m/44'/501'/N'/0'`, as in Phantom and Solflare. A new wallet gets a recovery phrase of its own (its account 0), shown to be written down first, so it can be created whatever the vault holds (an imported private key alone included) and each phrase recovers only its own wallet. The wallet switcher reads names and addresses from the session, so it never decrypts a phrase; only adding a wallet does, briefly. The active wallet is remembered as an opaque id. Showing a private key or removing a wallet takes the password again, even while unlocked; removing the last wallet using a phrase or key drops that phrase or key from the vault, and the only wallet can't be removed.
- **Unlocked means the vault key in memory, nothing more.** The derived key (never the phrase) sits in `storage.session`: memory only, out of reach of content scripts, cleared when the browser closes, and wiped by an alarm after 15 minutes without activity.
- **What's known about the wallets is never on disk in the clear.** The coins, balance and history are cached in `storage.session` while unlocked, and locking clears it. The last ones fetched are also kept between sessions, encrypted like the address book (AES-256-GCM, under their own key derived from the vault key), so unlocking shows them at once while fresh ones load; without the password they can't be read, and changing the password drops them. Refreshing them doesn't count as activity, so an open popup or side panel still auto-locks. While a popup or side panel is open, the coins follow the chain live: the background keeps a WebSocket to the network's RPC node, subscribed to the wallet's account and its token accounts, and on each change reads the balances again from a node that has reached that change (`minContextSlot`). Both go by the processed commitment, as soon as a node has run the block, and so does a sent transfer, swap or reclaim count as done: the soonest the result is known, at the small risk of a block the network later skips. A sent transaction is watched over a socket of its own (`signatureSubscribe`), so its screen hears the moment it lands; asking the node every second stays as the fallback, and is what sends it again until it lands or its blockhash runs out. If the node offers no socket, or it drops, the coins are fetched every 5 seconds until it's back. The socket closes with the last view, and the node learns nothing it doesn't already see from the balance reads.
- **`src/server` stays movable.** It uses only `fetch` and web APIs and imports nothing from the extension (`npm run check` enforces it); settings come in through `createApi`'s config. Token names and symbols are cleaned of control and invisible formatting characters.
- **Logos come from zandr's server, never from where token creators put them.** Loading a token's logo straight from its creator's host would tell them who holds it, which is what spam tokens are sent for. So every logo loads from `/v1/logo/<mint>` on zandr's server (`api/logos.ts`), which fetches it itself: Jupiter's image for the token, else the one in its metadata. It fetches only public https addresses on the usual port, checked at every connection and redirect (no private, loopback, link-local or Railway-internal addresses), up to 1 MB, keeps only what is truly an image (by its bytes), serves it as an image with a sandboxing CSP, and caches it. An unverified token whose symbol or name borrows a well-known one (SOL, USDC, USDT, JUP…) gets no logo, so a fake doesn't look like the real thing; the verified badge tells the real ones apart. With public services (Settings → Network → Public), logos load through wsrv.nl, an open image proxy, instead: still never from the creator's host, and IPFS ones from gateways that let the proxy in.
- **The history flags address poisoning.** Scammers send dust from addresses that share the first and last characters with one the user knows, hoping it gets copied from the history. Each transaction's other side is compared with the user's wallets, the address book and the addresses the wallet sent to; a lookalike is marked in red. What moved is read from the balances before and after each transaction, so it holds whatever program ran. The history is cached in `storage.session` only, like the coins.
- **A transfer is checked against the chain before it's signed, and signed exactly as reviewed.** The background builds the transaction itself (`src/lib/solana`, on `@noble`/`@scure`, no Solana SDK). It reads the recipient on-chain and stops transfers to programs, accounts programs control, program-derived addresses, token mints and token accounts, and to lookalikes of saved addresses and the user's own wallets: each a protection in Security settings, all on by default. A protection that finds something stops the transfer outright, in the background as well as on screen: there's no sending anyway, only turning that protection off, deliberately, and trying again. On mainnet it also asks whether the recipient is an exchange's (`getTransferCheck`): a deposit address is recognized by its sweeps into the exchange's hot wallets (`src/server/exchanges.ts`). Sending to an exchange's own wallet, a token the exchange doesn't accept on Solana (matched by mint, never by name, so a look-alike is stopped too), a token whose deposits it has turned off (by its latest list, however old, until the protection is turned off), or less than its minimum deposit is stopped like the rest. The token lists come from the exchanges' own APIs (`src/server/exchangeTokenSources.ts`): Binance, KuCoin, Gate, Bitget, HTX, Coinbase and Backpack name each token's mint; Bitstamp and Bitfinex name only symbols, matched to mints through Jupiter's verified tokens (one per symbol), and such a list says a token isn't taken only if every symbol matched; Bybit, OKX and MEXC need read-only API keys. An exchange with no list of its own (OKX, Bybit and MEXC without keys, Kraken, Crypto.com, CoinDCX, LATOKEN) is checked against the tokens it trades, by CoinGecko, that exist on Solana: that stops a token it doesn't trade at all, though not one it trades but takes only on another network; CoinGecko is never mixed into an exchange's own list, where it would let through a token the exchange takes only elsewhere. A snapshot ships (`src/server/exchangeTokens.json`, `npm run exchange-tokens`); zandr's server refreshes the lists every 6 hours and the extension fetches them whole every 12 (so the server learns nothing about anyone's transfers), checks them field by field and passes over one much shorter than the shipped one. A list older than 60 days no longer says what isn't taken; its pauses and minimums still count. The address is looked into as soon as it's typed in, so the review has the answer at once; an exchange this install has no list for gets the lists fetched fresh from zandr's server at the transfer (at most every 10 minutes). An answer that takes over 12 seconds isn't waited for, and what couldn't be checked (no answer in time, or an exchange with no token list) is said on the review, without stopping the transfer. Settings → Security → Unsupported tokens on exchanges shows how far each exchange is covered. The node test-runs every transfer first. Submitting plans it again from fresh state and signs only the exact amount reviewed, with the fee capped at the one shown, and only as the wallet it was started from. The key is decrypted just for the signature and wiped.
- **A swap's route comes from Jupiter, so the wallet checks it before signing.** Jupiter quotes the swap and gives the instructions that carry it out (Swap API v2, `/build`, done when quoting, so pressing Swap asks Jupiter nothing unless the quote is over 30 seconds old). The wallet puts them into a version 0 transaction itself (`compileV0Message`), loading accounts from the lookup tables Jupiter names but with what's in them read from the chain, adds its own compute budget (a test run with the most a transaction may ask for says what it uses; it asks for a fifth more, at Jupiter's priority fee capped at 0.001 SOL in all) and zandr's fee: 0.85% of the swap, always in SOL (of what's sold or bought when that's SOL, else of what's sold at the wallet's own price for it), sent to zandr's wallet by a transfer of its own in the same transaction, so it's paid only if the swap goes through, and shown in the form (none while no wallet is set, `FEE_WALLET` in `src/lib/swap.ts`). The transaction is then decoded byte by byte and refused unless only this wallet signs and pays; only the compute budget, system, token, associated token and Jupiter programs run, the first three only to wrap and unwrap the wallet's own SOL, open its own accounts and pay zandr's fee exactly as shown; any other of the wallet's token accounts it names (a route through a token the wallet also holds may use the wallet's own account for it; at most four) must come out of the test run as it went in or better: still the wallet's, nothing taken, no delegate or close authority given (a token account can't lose tokens to a transaction that doesn't name it); and a test run takes out no more than quoted, brings in no less than the minimum after slippage, and costs no more than 0.01 SOL in fees and rent. Exactly the checked bytes are signed, and only while their blockhash is still good. An unverified token or a high price impact is shown as a warning; it doesn't stop the swap. Swaps are mainnet only. Requests to Jupiter keep to its rate limit as Jupiter reports it with each answer (`x-ratelimit-remaining`, `x-ratelimit-reset`): once its window is used up, the next request waits for the reset instead of being turned away and retried seconds later, which would stall a swap in progress.
- **Reclaiming SOL closes only accounts the wallet alone controls, and burns only junk the user picked.** Empty token accounts are closed for their rent. Accounts holding junk (worth under $1 by Jupiter's price, or with no price) are offered for burning and closing, none picked in advance, and burning takes an explicit acknowledgment; the background checks each one's value again and refuses any worth more. Collectibles (no decimals), wrapped SOL, frozen accounts, ones with another close authority and Token-2022 ones with extensions that could hold value (withheld fees, confidential balances) are never touched. Each account is read from the chain again right before, every transaction is test-run, and it's signed only if the test run closes those accounts and returns at least their rent, less the fee, to the wallet; a transaction that fails over one token is retried without it.
- **A wallet is never overwritten.** Creating or importing is refused while a vault exists.
- **The address book can't be read or swapped outside zandr.** It's encrypted and authenticated (AES-256-GCM) under its own key, derived from the vault key with HKDF, so editing it never decrypts the recovery phrase. Anything changed on disk fails verification and isn't used. Saving refuses invalid, own, duplicate and lookalike addresses (same first and last four characters as a saved one), the shape of address poisoning.
- **Erasing after wrong passwords is opt-in, and can't be switched off by whoever is guessing.** Off by default; turning it on, changing or off takes the password, after a warning. Every wrong password counts toward it, wherever zandr asks for one (unlocking, showing a private key, removing a wallet, changing the password, the setting itself), counted one at a time so tries made at once all count, and kept on disk so a browser restart doesn't reset it; a right password does. The last one allowed erases every wallet, the address book, settings and cached data; only a note that it happened stays. It stops guessing through zandr, not against a copied browser profile: scrypt is what slows that.
- **Changing the password takes the current one, even while unlocked.** The vault is re-encrypted with a fresh salt and IV and the current KDF parameters, and the unlocked session moves to the new key.
- **Sites connect through the Wallet Standard, and each request is approved in zandr's own window.** Two content scripts run on https pages and on `localhost`/`127.0.0.1` (that's why Chrome says zandr can read and change data on sites): one in the page's world registers the wallet and holds nothing; one in zandr's isolated world relays requests from the page's own window (not its frames) to the background. The background learns the site's origin from Chrome, not from the page, and accepts only top-frame https (or local) senders and only the `dapp:*` requests, checked field by field. A site sees an address only after the user connects it, per wallet; asking quietly never opens a window and says nothing while locked or not connected. Connections are kept by origin and opaque wallet id (addresses stay in the vault) and listed under Settings → Connected apps. Every signature goes through the approval window, one request per site at a time, after zandr has decoded the transaction (lookup tables read from the chain; a table read once is kept, since its entries never change and no other table can take its address, and read again only for an entry past what was read; the last 32 are also kept in `storage.session`, so they outlast the background being put to sleep) and test-run it, which starts as the request comes in, while the window opens: it shows what enters and leaves the wallet, the fee and the programs. The window doesn't wait for token names: those already known show at once, the rest are looked up on Jupiter (ahead of other requests to it, starting as soon as the accounts the transaction writes to are read) and fill in as they come. Names looked up, and those of the active wallet's own coins, are kept in `storage.session` for an hour, so the next request after a pause has them; locking clears them with the rest of the session. Handing over the wallet account, letting another address spend tokens or taking over a token account are flagged as dangerous and need ticking a box; a transaction zandr can't read, one with an address table that isn't one, or one that doesn't need this wallet's signature is refused. A "message" that decodes as a transaction naming the wallet is refused (the sign-a-message drainer trick). Only what was shown, for the wallet it was shown for, is signed; closing the window rejects. Approving works only after the window has been on screen for a moment, so a click meant for the site can't land on it.
- **Minimal permissions.** Add to `permissions` in `wxt.config.ts` only what a feature actually uses. Today: `storage`, `alarms`, `offscreen` (the theme watcher; Chrome gives a service worker no `matchMedia`), `sidePanel`, none of which shows a warning at install, and, on Chrome, `favicon` (Chrome lists it at install as "Read the icons of the websites you visit"). A site's icon in the approval window and Connected apps is, best first: the large icon its page declares (an SVG, an Apple touch icon or one of 64 pixels or more, from its links or its web app manifest), found by the bridge when the site asks something and kept with its connection; the background takes only https addresses (http from a local site) or a small inline image, shown only as an image, and the browser has loaded it for the page already; else the browser's own copy of its favicon, from its favicon cache, fetching nothing; else its first letter. The content scripts' sites are the only host access.
- **CSP is stricter than the MV3 default.** WASM is disabled; if a crypto library needs it, add `'wasm-unsafe-eval'` deliberately.
- **The background only accepts messages from the extension's own pages** (`isTrustedSender`). Requests from websites (dApps) go through a separate channel (`siteOrigin`, `dappRequest`) that reaches nothing else and requires the user's approval.
- **Dependencies:** `.npmrc` blocks package install scripts and pins exact versions. Review every new dependency; prefer audited ones (`@noble/*`, `@scure/*`).
- **No `innerHTML` / `{@html}`** with external data.
