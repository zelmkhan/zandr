<script lang="ts">
  // Swapping one coin for another through Jupiter. The background quotes, builds, takes the
  // transaction apart and test-runs it before anything is signed (lib/swap.ts); this screen asks
  // what to swap and shows what zandr found.
  import { onMount, untrack } from 'svelte';
  import Verified from '@/components/Verified.svelte';
  import { formatAmount, formatUsd, shortAddress } from '@/lib/format';
  import { sendToBackground, type Account, type SwapCheck, type SwapFailure, type SwapQuoteView, type SwapReview } from '@/lib/messages';
  import type { Coin, Network, TokenListing } from '@/server/api';
  import { blockLetters, cleanAmount } from './amountInput';
  import CoinLogo from './CoinLogo.svelte';
  import { followSent } from './followSent';
  import { isListed } from './Coins.svelte';

  let {
    account,
    coins,
    minValue,
    network,
    onback,
    onswapped,
  }: {
    account: Account;
    coins: Coin[] | null;
    minValue: number;
    network: Network;
    onback: () => void;
    onswapped: () => void;
  } = $props();

  // SOL trades as wrapped SOL; to the user it's just SOL.
  const SOL = 'So11111111111111111111111111111111111111112';
  const USDC = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

  // A coin on either side of the swap: one the wallet holds, or one from the token list.
  type Asset = { mint: string; symbol: string | null; name: string | null; logo: string | null; verified: boolean };
  const mintOf = (coin: Coin) => (coin.native ? SOL : coin.mint);
  const assetOf = (coin: Coin): Asset => ({ mint: mintOf(coin), symbol: coin.symbol, name: coin.name, logo: coin.logo, verified: coin.verified });
  const held = (mint: string) => (coins ?? []).find((coin) => mintOf(coin) === mint) ?? null;
  const labelOf = (asset: Asset | null) => (asset ? (asset.mint === SOL ? 'SOL' : (asset.symbol ?? shortAddress(asset.mint))) : '');

  // Each step starts at the top of the view, not wherever the last one was scrolled to.
  const toTop = (_step: Step) => (node: HTMLElement) => {
    node.closest('main')?.scrollTo({ top: 0 });
  };

  // Popular tokens, loaded up front: the receive list starts with them, and they lend their logos
  // to coins the wallet doesn't hold (USDC, by default).
  let popular = $state<TokenListing[]>([]);
  onMount(async () => {
    if (network !== 'mainnet') return;
    try {
      const result = await sendToBackground({ type: 'swap:tokens', query: '' });
      if (result.ok) popular = result.tokens;
    } catch {
      // Logos fall back to initials.
    }
  });
  const logoOf = (asset: Asset | null) =>
    asset ? (held(asset.mint)?.logo ?? asset.logo ?? popular.find((token) => token.mint === asset.mint)?.logo ?? null) : null;

  const sellable = $derived((coins ?? []).filter((coin) => coin.amount !== '0'));
  let payPick = $state<Asset | null>(null);
  let receive = $state<Asset | null>(null);
  // Selling what was picked (read from the latest balances when the wallet holds it), else SOL or
  // the first coin there is; buying USDC by default, or SOL when selling USDC.
  const pay = $derived.by(() => {
    if (payPick) {
      const coin = held(payPick.mint);
      return coin ? assetOf(coin) : payPick;
    }
    return sellable[0] ? assetOf(sellable[0]) : null;
  });
  const payCoin = $derived(pay ? held(pay.mint) : null);
  const balance = $derived(payCoin?.balance ?? '0');

  // More than the wallet holds, as typed (or as the background finds, the balance shown being
  // behind): the balance flashes red and shakes for a moment, in place of a message.
  let shortAlarm = $state(0);
  let short = $state(false);
  function warnShort() {
    shortAlarm++;
    short = true;
  }
  $effect(() => {
    if (!shortAlarm) return;
    const timer = setTimeout(() => (short = false), 1600);
    return () => clearTimeout(timer);
  });
  $effect(() => {
    if (receive || !pay) return;
    receive = pay.mint === USDC ? { mint: SOL, symbol: 'SOL', name: 'Solana', logo: null, verified: true } : { mint: USDC, symbol: 'USDC', name: 'USD Coin', logo: null, verified: true };
  });

  type Step = 'form' | 'pay' | 'receive' | 'result';
  let step = $state<Step>('form');
  let amount = $state('');

  function typed(event: Event & { currentTarget: HTMLInputElement }) {
    amount = cleanAmount(event.currentTarget);
    max = false;
  }

  let max = $state(false);

  // The latest quote for what's on the form, fetched a moment after typing stops.
  let quote = $state<SwapQuoteView | null>(null);
  let quoting = $state(false);
  let failure = $state<SwapFailure | null>(null);
  let quoteRequest = 0;

  const amountValid = $derived(max || (/^\d*\.?\d*$/.test(amount.trim()) && Number(amount) > 0));
  // The mints alone: balances refreshing in the background must not reset the quote.
  const payMint = $derived(pay?.mint ?? null);
  const receiveMint = $derived(receive?.mint ?? null);
  const ready = $derived(network === 'mainnet' && !!pay && !!receive && pay.mint !== receive.mint && amountValid);
  const over = $derived(!max && amountValid && !!pay && Number(amount) > Number(balance));
  $effect(() => {
    if (over) untrack(warnShort);
  });

  async function fetchQuote() {
    // Not while a swap is on its way: its outcome is what the form shows then.
    if (!ready || busy) return;
    const request = ++quoteRequest;
    quoting = true;
    try {
      const result = await sendToBackground({ type: 'swap:quote', inputMint: pay!.mint, outputMint: receive!.mint, amount: max ? 'max' : amount.trim() });
      if (request !== quoteRequest) return;
      if (result.ok) {
        quote = result.quote;
        failure = null;
      } else {
        quote = null;
        failure = result.failure;
        if (result.failure.reason === 'insufficient' && !over) warnShort();
      }
    } catch {
      if (request === quoteRequest) failure = { reason: 'network', failure: 'unreachable' };
    } finally {
      if (request === quoteRequest) quoting = false;
    }
  }

  // Again on every change to the form, after a short pause, and every 20 seconds while it's open:
  // prices move.
  $effect(() => {
    const inputs = [payMint, receiveMint, amount, max, ready];
    quoteRequest++;
    quote = null;
    failure = null;
    quoting = false;
    if (!inputs.at(-1) || step !== 'form') return;
    const soon = setTimeout(fetchQuote, 450);
    const refresh = setInterval(fetchQuote, 20_000);
    return () => {
      clearTimeout(soon);
      clearInterval(refresh);
    };
  });

  function half() {
    if (!payCoin) return;
    const [whole = '0', fraction = ''] = payCoin.balance.split('.');
    const halved = (BigInt(whole + fraction) / 2n).toString().padStart(fraction.length + 1, '0');
    const head = halved.slice(0, halved.length - fraction.length);
    const tail = halved.slice(halved.length - fraction.length).slice(0, payCoin.decimals).replace(/0+$/, '');
    amount = tail ? `${head}.${tail}` : head;
    max = false;
  }

  function setMax() {
    if (!payCoin) return;
    max = true;
    amount = payCoin.balance;
  }

  // Swapping sides; what was being bought becomes what's sold, at the amount quoted.
  function flip() {
    if (!pay || !receive) return;
    const next = receive;
    receive = pay;
    payPick = next;
    amount = quote?.outAmount ?? '';
    max = false;
  }

  function back() {
    failure = null;
    if (step === 'pay' || step === 'receive' || (step === 'result' && outcome === 'stopped')) step = 'form';
    else onback();
  }

  // Picking what to sell: the coins the wallet holds, those the home screen hides after a divider.
  const listed = $derived(sellable.filter((coin) => isListed(coin, minValue)));
  const unlisted = $derived(sellable.filter((coin) => !isListed(coin, minValue)));

  function choosePay(coin: Coin) {
    payPick = assetOf(coin);
    if (receive?.mint === payPick.mint) receive = null;
    amount = '';
    max = false;
    step = 'form';
  }

  // Picking what to buy: popular tokens, or what a search finds, by name, symbol or mint.
  let query = $state('');
  let results = $state<TokenListing[] | null>(null);
  let searchFailed = $state(false);
  let searching = $state(false);
  let searchRequest = 0;

  // Tokens found so far, to match at once while a search is out: what the wallet holds, the popular
  // ones and earlier searches' finds. The search's answer then fills in the rest.
  const seen = new Map<string, TokenListing>();

  function knownMatches(text: string): TokenListing[] {
    const q = text.toLowerCase();
    const known = new Map<string, TokenListing>();
    const holdings = (coins ?? []).map((coin) => ({
      mint: mintOf(coin),
      name: coin.native ? 'Solana' : coin.name,
      symbol: coin.native ? 'SOL' : coin.symbol,
      logo: coin.logo,
      verified: coin.verified,
      decimals: coin.decimals,
    }));
    for (const token of [...holdings, ...popular, ...seen.values()]) if (!known.has(token.mint)) known.set(token.mint, token);
    const leads = (token: TokenListing) => Number(token.symbol?.toLowerCase().startsWith(q) ?? false);
    return [...known.values()]
      .filter((token) => token.mint === text || token.symbol?.toLowerCase().includes(q) || token.name?.toLowerCase().includes(q))
      .sort((a, b) => Number(!!held(b.mint)) - Number(!!held(a.mint)) || Number(b.verified) - Number(a.verified) || leads(b) - leads(a));
  }

  $effect(() => {
    if (step !== 'receive') return;
    const text = query.trim();
    const request = ++searchRequest;
    if (text) {
      const known = untrack(() => knownMatches(text));
      results = known.length ? known : null;
      searching = true;
      searchFailed = false;
    }
    const timer = setTimeout(
      async () => {
        try {
          const result = await sendToBackground({ type: 'swap:tokens', query: text });
          if (request !== searchRequest) return;
          if (result.ok) {
            for (const token of result.tokens) seen.set(token.mint, token);
            // The wallet's own matches first, then what the search found.
            const own = text ? untrack(() => knownMatches(text)).filter((token) => held(token.mint)) : [];
            results = [...own, ...result.tokens.filter((token) => !own.some((mine) => mine.mint === token.mint))];
          }
          searchFailed = !result.ok && !results?.length;
          if (!result.ok && !results) results = [];
        } catch {
          if (request === searchRequest) searchFailed = !results?.length;
        } finally {
          if (request === searchRequest) searching = false;
        }
      },
      text ? 250 : 0,
    );
    return () => clearTimeout(timer);
  });

  function chooseReceive(token: TokenListing) {
    receive = { mint: token.mint, symbol: token.mint === SOL ? 'SOL' : token.symbol, name: token.name, logo: token.logo, verified: token.verified };
    if (pay?.mint === token.mint) payPick = null;
    query = '';
    step = 'form';
  }

  function openPicker(which: 'pay' | 'receive') {
    failure = null;
    if (which === 'receive') {
      results = null;
      query = '';
    }
    step = which;
  }

  // Warnings shown before swapping, not reasons to stop it: a token anyone could have named, a trade
  // that moves the price.
  const checks = $derived.by(() => {
    const list: SwapCheck[] = [];
    if (receive && receive.mint !== SOL && !receive.verified) list.push({ id: 'unverified', symbol: receive.symbol });
    if (quote && quote.priceImpactPct > 5) list.push({ id: 'impact', percent: Math.round(quote.priceImpactPct * 10) / 10 });
    return list;
  });
  let busy = $state(false);

  // For the result screen: the quote swapped at, and the swap as built, checked and sent once the
  // background has it.
  let swapping = $state<SwapQuoteView | null>(null);
  let review = $state<SwapReview | null>(null);
  let signature = $state<string | null>(null);
  // `sending`: being built, checked, test-run and signed. `swapped`: sent, and shown as done at once:
  // it was test-run, and the node ran it once more before taking it. Followed meanwhile, it's shown
  // as failed or expired if that's how it ends. `stopped`: never sent, for `stopped`'s reason.
  let outcome = $state<'sending' | 'swapped' | 'failed' | 'expired' | 'stopped'>('sending');
  let outcomeDetail = $state<string | undefined>();
  let stopped = $state<SwapFailure | null>(null);

  // Straight to the result screen, which waits while the background builds the swap, checks it,
  // test-runs it and only then signs and sends it, all in one go.
  async function swap(event?: SubmitEvent) {
    event?.preventDefault();
    if (!quote || busy) return;
    busy = true;
    swapping = quote;
    review = null;
    signature = null;
    stopped = null;
    outcome = 'sending';
    step = 'result';
    try {
      const result = await sendToBackground({ type: 'swap:execute', quoteId: swapping.id });
      if (result.ok) {
        review = result.review;
        signature = result.signature;
        outcome = 'swapped';
      } else {
        stopped = result.failure;
        outcome = 'stopped';
      }
    } catch {
      stopped = { reason: 'network', failure: 'unreachable' };
      outcome = 'stopped';
    } finally {
      busy = false;
    }
  }

  $effect(() => {
    if (step !== 'result' || !signature) return;
    return followSent(signature, (status) => {
      if (status.status !== 'confirmed') {
        outcome = status.status;
        outcomeDetail = 'detail' in status ? status.detail : undefined;
      }
      // The fee is paid either way: the balances change.
      if (status.status !== 'expired') onswapped();
    });
  });

  onMount(() => () => quoteRequest++);

  const explorer = $derived(signature ? `https://solscan.io/tx/${signature}` : null);
  const worth = (mint: string | undefined, value: string) => {
    const price = mint ? held(mint)?.price : null;
    return price != null ? Number(value) * price : null;
  };
  const percent = (value: number) => (value < 0.01 ? '<0.01%' : `${value.toFixed(2)}%`);
  const rate = (view: SwapQuoteView) => {
    const ratio = Number(view.outAmount) / Number(view.inAmount);
    return `1 ${labelOf(pay)} ≈ ${formatAmount(String(ratio))} ${labelOf(receive)}`;
  };

  function failureText(problem: SwapFailure): string {
    switch (problem.reason) {
      case 'locked':
        return 'The wallet is locked.';
      case 'wallet-changed':
        return 'The active wallet changed. Start this swap again.';
      case 'mainnet-only':
        return 'Swaps work on Mainnet only.';
      case 'same-token':
        return 'Pick two different coins.';
      case 'unknown-token':
        return "zandr can't find this token on Solana.";
      case 'invalid-amount':
        return 'Enter a valid amount.';
      case 'insufficient':
        return `You don't have that much ${labelOf(pay)}.`;
      case 'no-route':
        return 'No route for this swap. Try another amount or coin.';
      case 'expired':
        return 'That price expired. Here is a fresh one.';
      case 'insufficient-sol':
        return `Not enough SOL to pay for the swap. Keep up to ${problem.needed} SOL for fees.`;
      case 'unsafe':
        return `zandr stopped this swap and signed nothing: ${problem.detail}`;
      case 'simulation':
        return `This swap would fail: ${problem.detail}`;
      case 'network':
        if (problem.failure === 'forbidden') return 'The RPC endpoint refused. Set one up in Network settings.';
        if (problem.failure === 'rate-limited') return 'Too many requests right now. Try again in a moment.';
        if (problem.failure === 'unreachable') return "Couldn't reach the network. Check your connection.";
        return `The network refused: ${problem.detail ?? 'no reason given'}`;
    }
  }

  function checkText(check: SwapCheck): { title: string; text: string } {
    if (check.id === 'unverified') {
      return {
        title: `${check.symbol ?? 'This token'} isn't verified`,
        text: 'Anyone can make a token with any name and logo. Make sure this is the token you mean, by its address.',
      };
    }
    return {
      title: `This swap moves the price ${check.percent}%`,
      text: 'There isn’t much of this token to trade, so you get noticeably less than its market price.',
    };
  }
</script>

<div class="screen flow" {@attach toTop(step)}>
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={back}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>{step === 'pay' ? 'You pay' : step === 'receive' ? 'You receive' : 'Swap'}</h2>
    <span class="spacer"></span>
  </div>

  {#snippet coinRow(coin: Coin, hidden = false)}
    <li>
      <button type="button" class="pick-row" class:hidden onclick={() => choosePay(coin)}>
        <CoinLogo logo={coin.logo} label={coin.symbol ?? coin.name} />
        <span class="what">
          <strong class="symbol"><span>{coin.symbol ?? 'Unknown token'}</span>{#if coin.verified}<Verified />{/if}</strong>
          <span class="sub">
            <span>{formatAmount(coin.balance)}</span>
            {#if !coin.native}<span class="mint">· {shortAddress(coin.mint)}</span>{/if}
          </span>
        </span>
        {#if coin.value !== null}
          <span class="worth">{formatUsd(coin.value)}</span>
        {/if}
      </button>
    </li>
  {/snippet}

  {#if network !== 'mainnet'}
    <div class="center">
      <p class="center-title">Swaps work on Mainnet only</p>
      <p class="center-text">There are no markets on Devnet. Switch the network in Settings to swap.</p>
    </div>
  {:else if step === 'pay'}
    <ul class="pick">
      {#each listed as coin (mintOf(coin))}
        {@render coinRow(coin)}
      {/each}
      {#if listed.length && unlisted.length}
        <li class="divider" role="separator"></li>
      {/if}
      {#each unlisted as coin (mintOf(coin))}
        {@render coinRow(coin, true)}
      {/each}
    </ul>
  {:else if step === 'receive'}
    <div class="search">
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <circle cx="11" cy="11" r="6.5" />
          <path d="m20 20-4.4-4.4" />
        </g>
      </svg>
      <!-- svelte-ignore a11y_autofocus: the screen is only for searching -->
      <input
        id="token-search"
        type="search"
        bind:value={query}
        placeholder="Search name, symbol or address"
        autocomplete="off"
        spellcheck="false"
        aria-label="Search tokens"
        autofocus
      />
      {#if query}
        <button
          type="button"
          class="clear"
          aria-label="Clear search"
          onclick={() => {
            query = '';
            document.getElementById('token-search')?.focus();
          }}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M6 6l12 12M18 6 6 18" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" />
          </svg>
        </button>
      {/if}
    </div>
    {#if results === null}
      <p class="hint">{query.trim() ? 'Searching…' : 'Loading tokens…'}</p>
    {:else if searchFailed}
      <p class="hint">Couldn't load tokens. Try again in a moment.</p>
    {:else if results.length === 0 && !searching}
      <p class="hint">No tokens found.</p>
    {:else}
      <ul class="pick">
        {#each results as token (token.mint)}
          <li>
            <button type="button" class="pick-row" onclick={() => chooseReceive(token)}>
              <CoinLogo logo={held(token.mint)?.logo ?? token.logo} label={token.mint === SOL ? 'SOL' : (token.symbol ?? token.name)} />
              <span class="what">
                <strong class="symbol">
                  <span>{token.mint === SOL ? 'SOL' : (token.symbol ?? 'Unknown token')}</span>{#if token.verified}<Verified />{/if}
                </strong>
                <span class="sub">
                  <span>{token.mint === SOL ? 'Solana' : (token.name ?? 'Unknown token')}</span>
                  {#if token.mint !== SOL}<span class="mint">· {shortAddress(token.mint)}</span>{/if}
                </span>
              </span>
              {#if held(token.mint)}
                <span class="worth owned">{formatAmount(held(token.mint)!.balance)}</span>
              {/if}
            </button>
          </li>
        {/each}
      </ul>
      {#if searching}
        <p class="hint">Searching for more…</p>
      {/if}
    {/if}
  {:else if step === 'form'}
    <form class="swap-form" onsubmit={swap}>
      <div class="pair">
        <div class="card" class:invalid={amount.trim() && !amountValid}>
          <div class="card-row">
            <span class="label" id="pay-label">You pay</span>
            <span class="quick">
              <button type="button" class="chip" disabled={!payCoin} onclick={half}>Half</button>
              <button type="button" class="chip" class:on={max} disabled={!payCoin} onclick={setMax}>Max</button>
            </span>
          </div>
          <div class="amount-row">
            <button type="button" class="token" disabled={!sellable.length} aria-label="Choose the coin to pay with" onclick={() => openPicker('pay')}>
              {#if pay}
                <CoinLogo logo={logoOf(pay)} label={labelOf(pay)} size={28} />
                <span class="token-symbol">{labelOf(pay)}</span>
                {#if pay.verified}<Verified />{/if}
              {:else}
                <span class="token-loading" aria-label="Loading coins"></span>
              {/if}
              <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
                <path d="m6 9 6 6 6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </button>
            <input
              value={amount}
              onbeforeinput={blockLetters}
              oninput={typed}
              inputmode="decimal"
              placeholder="0"
              autocomplete="off"
              spellcheck="false"
              aria-labelledby="pay-label"
            />
          </div>
          <div class="card-row foot">
            {#key shortAlarm}
              <span class="balance" class:short>Balance {formatAmount(balance)} {labelOf(pay)}</span>
            {/key}
            {#if amountValid && worth(pay?.mint, max ? balance : amount) !== null}
              <span>≈ {formatUsd(worth(pay?.mint, max ? balance : amount)!)}</span>
            {/if}
          </div>
        </div>

        <!-- Between the two cards: swaps what's sold and what's bought. -->
        <button type="button" class="flip" aria-label="Switch coins" onclick={flip} disabled={!pay || !receive}>
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M8 4v16m0 0-4-4m4 4 4-4M16 20V4m0 0-4 4m4-4 4 4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </button>

        <div class="card">
          <div class="card-row">
            <span class="label">You receive</span>
          </div>
          <div class="amount-row">
            <button type="button" class="token" aria-label="Choose the coin to receive" onclick={() => openPicker('receive')}>
              {#if receive}
                <CoinLogo logo={logoOf(receive)} label={labelOf(receive)} size={28} />
                <span class="token-symbol">{labelOf(receive)}</span>
                {#if receive.verified}<Verified />{/if}
              {:else}
                <span class="token-symbol muted">Select</span>
              {/if}
              <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
                <path d="m6 9 6 6 6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </button>
            <output class="out" class:pending={quoting && !quote}>
              {#if quote}
                {formatAmount(quote.outAmount)}
              {:else if quoting}
                <span class="out-loading" aria-label="Getting a price"></span>
              {:else}
                0
              {/if}
            </output>
          </div>
          <div class="card-row foot">
            <span>{receive && held(receive.mint) ? `Balance ${formatAmount(held(receive.mint)!.balance)} ${labelOf(receive)}` : ''}</span>
            {#if quote && worth(receive?.mint, quote.outAmount) !== null}
              <span>≈ {formatUsd(worth(receive?.mint, quote.outAmount)!)}</span>
            {/if}
          </div>
        </div>
      </div>

      {#if quote}
        <dl class="terms">
          <div>
            <dt>At least</dt>
            <dd>{formatAmount(quote.minOutAmount)} {labelOf(receive)}</dd>
          </div>
          <div>
            <dt>Rate</dt>
            <dd>{rate(quote)}</dd>
          </div>
          <div>
            <dt>Price impact</dt>
            <dd class:high={quote.priceImpactPct > 5}>{percent(quote.priceImpactPct)}</dd>
          </div>
          <div>
            <dt>Route</dt>
            <dd>{quote.route.join(' › ') || 'Direct'}</dd>
          </div>
          {#if quote.fee}
            <div>
              <dt>zandr fee (0.85%)</dt>
              <dd>{formatAmount(quote.fee)} SOL</dd>
            </div>
          {/if}
        </dl>
      {/if}

      {#each checks as check (check.id)}
        {@const text = checkText(check)}
        <div class="warning" role="alert">
          <strong>{text.title}</strong>
          <p>{text.text}</p>
        </div>
      {/each}

      <!-- Not enough of the coin: the balance above says so. -->
      {#if failure && failure.reason !== 'insufficient'}
        <p class="error" role="alert">{failureText(failure)}</p>
      {/if}

      <!-- Swaps right away: the background checks the transaction before it signs anything. -->
      <button type="submit" class="primary" disabled={!quote || busy}>Swap</button>
    </form>
  {:else if step === 'result' && swapping}
    <div class="center result">
      <span class="center-icon" class:ok={outcome === 'swapped'} class:bad={outcome === 'failed' || outcome === 'expired' || outcome === 'stopped'}>
        {#if outcome === 'sending'}
          <span class="spinner" aria-hidden="true"></span>
        {:else}
          <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d={outcome === 'swapped' ? 'M5 12.5 9.5 17 19 7.5' : 'M6 6l12 12M18 6 6 18'}
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        {/if}
      </span>
      <p class="center-title" role="status">
        {outcome === 'sending' ? 'Swapping…' : outcome === 'swapped' ? 'Swapped' : "Didn't go through"}
      </p>
      <p class="center-text">
        {#if outcome === 'stopped' && stopped}
          {stopped.reason === 'expired' ? 'That price expired before the swap went out. Nothing was sent.' : failureText(stopped)}
        {:else if outcome === 'failed'}
          The network ran it and it failed{outcomeDetail ? ` (${outcomeDetail})` : ''}. Only the network fee was charged.
        {:else if outcome === 'expired'}
          The network didn't take it in time. Nothing left your wallet.
        {:else}
          {swapping.inAmount} {labelOf(pay)} for about {formatAmount(review?.outAmount ?? swapping.outAmount)} {labelOf(receive)}
        {/if}
      </p>
      {#if explorer && outcome !== 'expired'}
        <a class="explorer" href={explorer} target="_blank" rel="noopener noreferrer">View on Solscan</a>
      {/if}
    </div>
    {#if outcome === 'stopped'}
      <!-- Back to the form, for a fresh price. -->
      <button type="button" class="primary done" onclick={back}>Back</button>
    {:else}
      <button type="button" class="primary done" onclick={onback}>Done</button>
    {/if}
  {/if}
</div>

<style>
  .swap-form {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 12px;
  }

  .swap-form .primary {
    margin-top: auto;
  }

  /* The two cards with the switch button over the seam between them. */
  .pair {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .flip {
    position: absolute;
    top: 50%;
    left: 50%;
    z-index: 1;
    display: grid;
    place-items: center;
    width: 38px;
    height: 38px;
    border: 4px solid var(--bg);
    border-radius: 50%;
    background: var(--raised);
    color: var(--fg);
    cursor: pointer;
    transform: translate(-50%, -50%);
    transition: background-color 0.2s var(--ease);
  }

  .flip:hover:not(:disabled) {
    background: var(--raised-hover);
  }

  .flip:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .flip:disabled {
    cursor: default;
    color: var(--muted);
  }

  .out {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    font-size: 30px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    letter-spacing: -0.03em;
    text-align: right;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .out-loading {
    display: inline-block;
    width: 96px;
    height: 28px;
    border-radius: 8px;
    background: var(--fill);
    vertical-align: middle;
    animation: pulse 1.4s ease-in-out infinite;
  }

  .balance {
    display: inline-block;
    transition: color 0.5s var(--ease);
  }

  .balance.short {
    color: var(--down);
    animation: shake 0.42s cubic-bezier(0.36, 0.07, 0.19, 0.97);
  }

  @keyframes shake {
    20%,
    60% {
      transform: translateX(-3px);
    }

    40%,
    80% {
      transform: translateX(3px);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .balance.short {
      animation: none;
    }
  }

  @keyframes pulse {
    50% {
      opacity: 0.45;
    }
  }

  .muted {
    color: var(--muted);
  }

  .terms {
    margin: 0;
    padding: 0 4px;
  }

  .terms div {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    padding: 3px 0;
    font-size: 13px;
  }

  .terms dt {
    color: var(--muted);
  }

  .terms dd {
    margin: 0;
    overflow: hidden;
    text-align: right;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  .terms .high {
    color: var(--down);
  }

  /* A pill on the screen's fill. Its height is fixed: in the screen's column it would otherwise
     give way to a long list. */
  .search {
    display: flex;
    flex: none;
    align-items: center;
    gap: 10px;
    height: 40px;
    /* Right under the title bar, like every screen's content; as far from the list's first logo
       as from the title. */
    margin: 0 0 6px;
    padding: 0 6px 0 14px;
    border-radius: 999px;
    background: var(--fill);
    color: var(--muted);
    transition:
      background-color 0.2s var(--ease),
      box-shadow 0.2s var(--ease);
  }

  .search:focus-within {
    background: var(--fill-strong);
    box-shadow: inset 0 0 0 1px rgba(var(--ink), 0.12);
  }

  .search svg {
    flex: none;
  }

  .search input {
    flex: 1;
    min-width: 0;
    height: 100%;
    padding: 0;
    border: 0;
    background: none;
    appearance: none;
    caret-color: var(--fg);
    color: var(--fg);
    font-size: 15px;
    outline: none;
  }

  .search input::placeholder {
    color: rgba(var(--ink), 0.35);
  }

  /* The browser's own clear button gives way to ours. */
  .search input::-webkit-search-cancel-button {
    display: none;
  }

  .clear {
    display: grid;
    flex: none;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: rgba(var(--ink), 0.1);
    color: var(--fg);
    cursor: pointer;
    transition: background-color 0.15s var(--ease);
  }

  .clear:hover {
    background: rgba(var(--ink), 0.18);
  }

  .clear:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .hint {
    margin: 24px 0 0;
    color: var(--muted);
    font-size: 14px;
    text-align: center;
  }

  .owned {
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

</style>
