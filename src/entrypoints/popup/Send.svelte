<script lang="ts">
  // Sending a coin: how much of which coin and to whom, then a review of what zandr found out
  // about the recipient and what it costs, then sending and following it until it lands. The
  // background plans, checks and signs (lib/send.ts); this screen only asks and shows.
  import { onMount, tick } from 'svelte';
  import Verified from '@/components/Verified.svelte';
  import { formatAmount, formatUsd, monogram, shortAddress } from '@/lib/format';
  import {
    sendToBackground,
    type Account,
    type Contact,
    type SendCheck,
    type SendFailure,
    type SendIntent,
    type SendReview,
    type WalletSummary,
  } from '@/lib/messages';
  import type { Coin, Network } from '@/server/api';
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
    onsent,
  }: { account: Account; coins: Coin[] | null; minValue: number; network: Network; onback: () => void; onsent: () => void } = $props();

  const sendable = $derived((coins ?? []).filter((coin) => coin.amount !== '0'));
  // In the coin list: first the coins the home screen shows, then, past a divider, those its
  // minimum value filter hides.
  const listed = $derived(sendable.filter((coin) => isListed(coin, minValue)));
  const unlisted = $derived(sendable.filter((coin) => !isListed(coin, minValue)));

  // The form first. The coin list opens from the coin button in the amount field, the saved
  // addresses and the user's other wallets from the address book button in the recipient field.
  type Step = 'form' | 'coin' | 'contact' | 'review' | 'result';
  let step = $state<Step>('form');

  // The coin being sent: the one picked, else the first the wallet holds (SOL, usually). Taken
  // from the latest balances, so its amount is never stale.
  const keyOf = (item: Coin) => (item.native ? 'native' : item.mint);
  let picked = $state<string | null>(null);
  const coin = $derived(sendable.find((item) => keyOf(item) === picked) ?? sendable[0] ?? null);
  const symbol = $derived(coin ? (coin.symbol ?? shortAddress(coin.mint)) : '');

  let to = $state('');
  let amount = $state('');
  // "Max" sends everything; for SOL the background works out what's left after the fee.
  let max = $state(false);
  let failure = $state<SendFailure | null>(null);
  let busy = $state(false);

  // Saved addresses and the user's other wallets, to pick from and to name the recipient.
  let contacts = $state<Contact[]>([]);
  let wallets = $state<WalletSummary[]>([]);

  onMount(async () => {
    // Sending works without either.
    const [book, own] = await Promise.allSettled([sendToBackground({ type: 'addressBook:list' }), sendToBackground({ type: 'wallets:list' })]);
    if (book.status === 'fulfilled' && 'contacts' in book.value) contacts = book.value.contacts;
    if (own.status === 'fulfilled' && 'wallets' in own.value) wallets = own.value.wallets.filter((wallet) => wallet.address !== account.address);
  });

  const recipient = $derived(to.trim());
  const looksLikeAddress = $derived(/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(recipient));
  // The recipient as the user knows it: a saved contact, or one of their own wallets.
  const ownWallet = $derived(wallets.find((entry) => entry.address === recipient) ?? null);
  const known = $derived(contacts.find((entry) => entry.address === recipient) ?? ownWallet);

  // The address picker shows one list at a time: saved addresses or the user's other wallets. It
  // opens on the saved ones, unless there are none.
  let source = $state<'contacts' | 'wallets'>('contacts');
  const entries = $derived(source === 'contacts' ? contacts : wallets);

  function openPicker() {
    source = contacts.length || !wallets.length ? 'contacts' : 'wallets';
    failure = null;
    step = 'contact';
  }

  function pickAddress(address: string) {
    to = address;
    failure = null;
    step = 'form';
  }

  // Back to typing an address, in place of the saved one.
  async function clearRecipient() {
    to = '';
    failure = null;
    await tick();
    document.getElementById('recipient')?.focus();
  }

  // A pasted address that isn't saved, in groups of four, to check against where it came from.
  const groups = $derived(looksLikeAddress && !known ? (recipient.match(/.{1,4}/g) ?? []) : []);

  // As soon as an address is in, the background starts finding out whether it's an exchange's, so
  // the review has the answer at once.
  $effect(() => {
    if (!looksLikeAddress) return;
    const address = recipient;
    const timer = setTimeout(() => sendToBackground({ type: 'send:inspect', to: address }).catch(() => {}), 300);
    return () => clearTimeout(timer);
  });

  const amountValid = $derived(
    max || (/^\d*\.?\d*$/.test(amount.trim()) && Number(amount) > 0 && (amount.split('.')[1]?.length ?? 0) <= (coin?.decimals ?? 0)),
  );
  const worth = (item: Coin | null | undefined, value: string) => (item?.price != null ? Number(value) * item.price : null);

  function choose(next: Coin) {
    picked = keyOf(next);
    amount = '';
    max = false;
    failure = null;
    step = 'form';
  }

  // Half the balance, exactly: halved in the coin's smallest units and rounded down.
  function half() {
    if (!coin) return;
    const [whole = '0', fraction = ''] = coin.balance.split('.');
    const halved = (BigInt(whole + fraction) / 2n).toString().padStart(fraction.length + 1, '0');
    const head = halved.slice(0, halved.length - fraction.length);
    const tail = halved.slice(halved.length - fraction.length).slice(0, coin.decimals).replace(/0+$/, '');
    amount = tail ? `${head}.${tail}` : head;
    max = false;
    failure = null;
  }

  function setMax() {
    if (!coin) return;
    max = true;
    amount = coin.balance;
    failure = null;
  }

  function back() {
    failure = null;
    if (step === 'review' || step === 'coin' || step === 'contact') step = 'form';
    else onback();
  }

  const intent = (value: string): SendIntent => ({
    from: account.address,
    mint: coin!.native ? null : coin!.mint,
    to: recipient,
    amount: value,
  });

  // What the transfer would do, from the background: checked, nothing signed yet.
  let review = $state<SendReview | null>(null);
  // The coin under review, and how it's named, as the review has it: the picked coin can drop out
  // of the balances once it's all sent.
  const reviewed = $derived(review ? ((coins ?? []).find((item) => (item.native ? null : item.mint) === review!.coin.mint) ?? null) : null);
  const reviewSymbol = $derived(review ? (review.coin.symbol ?? (review.coin.mint ? shortAddress(review.coin.mint) : 'SOL')) : '');

  async function prepare(event?: SubmitEvent) {
    event?.preventDefault();
    if (!coin || !looksLikeAddress || !amountValid || busy) return;
    busy = true;
    failure = null;
    try {
      const result = await sendToBackground({ type: 'send:prepare', intent: intent(max ? 'max' : amount.trim()) });
      if (result.ok) {
        review = result.review;
        step = 'review';
      } else {
        failure = result.failure;
      }
    } catch {
      failure = { reason: 'network', failure: 'unreachable' };
    } finally {
      busy = false;
    }
  }

  // Sending to the wallet a token account belongs to, instead of the token account.
  function sendToOwner(owner: string) {
    to = owner;
    step = 'form';
    prepare();
  }

  // Sending, then following it until it lands. Shown as sent at once: the node ran it once more
  // before taking it. Shown as failed or expired instead if that's how it ends.
  let signature = $state<string | null>(null);
  let outcome = $state<'sent' | 'failed' | 'expired'>('sent');
  let outcomeDetail = $state<string | undefined>();

  async function send() {
    if (!review || busy) return;
    busy = true;
    failure = null;
    try {
      const result = await sendToBackground({
        type: 'send:submit',
        // Exactly what was reviewed: its coin and recipient, the amount as worked out, not "max".
        intent: { from: account.address, mint: review.coin.mint, to: review.to, amount: review.amount },
        maxFee: review.fee,
      });
      if (result.ok) {
        signature = result.signature;
        review = result.review;
        outcome = 'sent';
        step = 'result';
      } else {
        failure = result.failure;
        // Something about the recipient changed since the review: show it again.
        if (result.review) review = result.review;
      }
    } catch {
      failure = { reason: 'network', failure: 'unreachable' };
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
      if (status.status !== 'expired') onsent();
    });
  });

  const explorer = $derived(signature ? `https://solscan.io/tx/${signature}${network === 'devnet' ? '?cluster=devnet' : ''}` : null);

  function failureText(problem: SendFailure): string {
    switch (problem.reason) {
      case 'locked':
        return 'The wallet is locked.';
      case 'wallet-changed':
        return 'The active wallet changed. Start this transfer again.';
      case 'invalid-address':
        return "This isn't a valid Solana address.";
      case 'own-address':
        return "That's this wallet's own address.";
      case 'no-coin':
        return "This wallet doesn't hold this coin anymore.";
      case 'invalid-amount':
        return 'Enter a valid amount.';
      case 'insufficient':
        return `You don't have that much ${symbol}.`;
      case 'split-balance':
        return `Your ${symbol} is spread across several accounts. Send a smaller amount.`;
      case 'non-transferable':
        return "This token can't be transferred: its creator made it non-transferable.";
      case 'transfer-hook':
        return "zandr can't send this token yet: it runs a program of its own on every transfer.";
      case 'blocked':
        return 'zandr stopped this transfer: see why above.';
      case 'insufficient-sol':
        return `Not enough SOL to cover the costs. You need ${problem.needed} SOL.`;
      case 'below-minimum':
        if (!problem.leftover) return `A new address needs at least ${problem.minimum} SOL.`;
        return coin?.native
          ? `Leave at least ${problem.minimum} SOL in the wallet, or send all of it.`
          : `This would leave less than ${problem.minimum} SOL in the wallet, which the network doesn't allow. Add some SOL first.`;
      case 'simulation':
        return `This transfer would fail: ${problem.detail}`;
      case 'network':
        if (problem.failure === 'forbidden') return 'The RPC endpoint refused. Set one up in Network settings.';
        if (problem.failure === 'rate-limited') return 'The RPC endpoint is busy. Try again in a moment.';
        if (problem.failure === 'unreachable') return "Couldn't reach the network. Check your connection.";
        return `The network refused: ${problem.detail ?? 'no reason given'}`;
    }
  }

  function checkText(check: SendCheck): { title: string; text: string } {
    switch (check.id) {
      case 'program':
        if (check.kind === 'program') {
          return {
            title: 'This is a program, not a wallet',
            text: 'Programs have no owner who could send coins back. Whatever you send here is most likely lost for good.',
          };
        }
        if (check.kind === 'owned') {
          return {
            title: 'This address belongs to a program',
            text: "It's an account a program controls, not a wallet. Only that program can move what you send here.",
          };
        }
        return {
          title: 'No wallet controls this address',
          text: "It's derived from a program and has no private key. Only that program can move what you send here, if it ever does.",
        };
      case 'mint':
        return {
          title: "This is a token's mint address",
          text: `It identifies ${check.token ?? 'a token'} itself and isn't a wallet. Whatever you send here is lost.`,
        };
      case 'tokenAccount':
        return {
          title: 'This is a token account, not a wallet',
          text: `It belongs to the wallet ${shortAddress(check.owner)}. Send to that wallet instead.`,
        };
      case 'lookalike':
        return {
          title: `Looks like ${check.name}, but isn't`,
          text: `It starts and ends like ${check.name}'s address, but the middle differs: a common trick to make you send to a scammer.`,
        };
      case 'exchangeWallet':
        return {
          title: `This is ${check.exchange}'s own wallet`,
          text: `It isn't a deposit address, so ${check.exchange} won't credit what you send here to any account. Copy your deposit address from ${check.exchange} instead.`,
        };
      case 'exchangeToken':
        if (check.basis === 'trading') {
          return {
            title: `${check.exchange} doesn't trade ${reviewSymbol}`,
            text: `This is a ${check.exchange} deposit address, and ${check.exchange} doesn't list this token. It would most likely never reach your account.`,
          };
        }
        return {
          title: `${check.exchange} doesn't accept ${reviewSymbol} on Solana`,
          text: `This is a ${check.exchange} deposit address, and this token isn't on ${check.exchange}'s list. It would most likely never reach your account.`,
        };
      case 'exchangePaused':
        return {
          title: `${check.exchange} isn't taking ${check.coin ?? reviewSymbol} deposits now`,
          text: `${check.exchange} has deposits of this token on Solana turned off. What you send now may never reach your account, or only once they're back on.`,
        };
      case 'exchangeMinimum':
        return {
          title: `Below ${check.exchange}'s minimum deposit`,
          text: `${check.exchange} credits ${check.coin ?? reviewSymbol} deposits of at least ${check.minimum}. A smaller one isn't credited to your account.`,
        };
    }
  }
</script>

<div class="screen flow">
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={back}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>{step === 'review' ? 'Review' : step === 'coin' ? 'Select coin' : step === 'contact' ? 'Select address' : 'Send'}</h2>
    <span class="spacer"></span>
  </div>

  {#if step === 'coin'}
    {#snippet coinRow(item: Coin, hidden = false)}
      <li>
        <button type="button" class="pick-row" class:hidden onclick={() => choose(item)}>
          <CoinLogo logo={item.logo} label={item.symbol ?? item.name} />
          <span class="what">
            <strong class="symbol"><span>{item.symbol ?? 'Unknown token'}</span>{#if item.verified}<Verified />{/if}</strong>
            <span class="sub">
              <span>{formatAmount(item.balance)}</span>
              {#if !item.native}<span class="mint">· {shortAddress(item.mint)}</span>{/if}
            </span>
          </span>
          {#if item.value !== null}
            <span class="worth">{formatUsd(item.value)}</span>
          {/if}
        </button>
      </li>
    {/snippet}

    {#if sendable.length}
      <ul class="pick">
        {#each listed as item (keyOf(item))}
          {@render coinRow(item)}
        {/each}
        {#if listed.length && unlisted.length}
          <li class="divider" role="separator"></li>
        {/if}
        {#each unlisted as item (keyOf(item))}
          {@render coinRow(item, true)}
        {/each}
      </ul>
    {/if}
  {:else if step === 'contact'}
    <div class="sources" role="tablist" aria-label="Addresses">
      <button type="button" role="tab" class="source" aria-selected={source === 'contacts'} onclick={() => (source = 'contacts')}>Contacts</button>
      <button type="button" role="tab" class="source" aria-selected={source === 'wallets'} onclick={() => (source = 'wallets')}>Wallets</button>
    </div>
    {#if entries.length}
      <ul class="pick">
        {#each entries as entry (entry.id)}
          <li>
            <button type="button" class="pick-row" onclick={() => pickAddress(entry.address)}>
              <span class="initial" aria-hidden="true">{monogram(entry.name, entry.address)}</span>
              <span class="what">
                <strong>{entry.name}</strong>
                <span>{shortAddress(entry.address)}</span>
              </span>
            </button>
          </li>
        {/each}
      </ul>
    {:else}
      <p class="none">
        {source === 'contacts' ? 'No saved addresses yet. Add them in the address book.' : 'No other wallets yet. Add one in Wallets.'}
      </p>
    {/if}
  {:else if step === 'form' && coins !== null && sendable.length === 0}
    <div class="center">
      <p class="center-title">Nothing to send yet</p>
      <p class="center-text">Receive SOL or a token first.</p>
    </div>
  {:else if step === 'form'}
    <form class="send-form" onsubmit={prepare}>
      <!-- As in a swap: the coin on the left, the amount on the right, all in one card. -->
      <div class="card" class:invalid={amount.trim() && !amountValid}>
        <div class="card-row">
          <span class="label" id="amount-label">Amount</span>
          <span class="quick">
            <button type="button" class="chip" disabled={!coin} onclick={half}>Half</button>
            <button type="button" class="chip" class:on={max} disabled={!coin} onclick={setMax}>Max</button>
          </span>
        </div>
        <div class="amount-row">
          <button type="button" class="token" disabled={!coin} aria-label="Choose coin" onclick={() => ((step = 'coin'), (failure = null))}>
            {#if coin}
              <CoinLogo logo={coin.logo} label={coin.symbol ?? coin.name} size={28} />
              <span class="token-symbol">{symbol}</span>
              {#if coin.verified}<Verified />{/if}
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
            oninput={(event) => {
              amount = cleanAmount(event.currentTarget);
              max = false;
              failure = null;
            }}
            inputmode="decimal"
            placeholder="0"
            autocomplete="off"
            spellcheck="false"
            aria-labelledby="amount-label"
            aria-invalid={amount.trim() && !amountValid ? 'true' : undefined}
          />
        </div>
        {#if coin}
          <div class="card-row foot">
            <span>Balance {formatAmount(coin.balance)} {symbol}</span>
            {#if amountValid && worth(coin, max ? coin.balance : amount) !== null}
              <span>≈ {formatUsd(worth(coin, max ? coin.balance : amount)!)}</span>
            {/if}
          </div>
        {/if}
      </div>

      <div class="card" class:invalid={recipient && !looksLikeAddress}>
        <span class="label" id="recipient-label">Recipient</span>
        <!-- A saved address or one of the user's wallets shows as what it is, picked or pasted alike. -->
        {#if known}
          <div class="contact-row">
            <span class="initial" aria-hidden="true">{monogram(known.name, known.address)}</span>
            <span class="contact-who">
              <strong>{known.name}</strong>
              <span>{ownWallet ? 'Your wallet · ' : ''}{shortAddress(known.address)}</span>
            </span>
            <button type="button" class="book" aria-label="Change recipient" onclick={clearRecipient}>
              <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M6 6l12 12M18 6 6 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
              </svg>
            </button>
          </div>
        {:else}
          <div class="recipient-row">
            <textarea
              id="recipient"
              aria-labelledby="recipient-label"
              rows="2"
              bind:value={to}
              oninput={() => (failure = null)}
              placeholder="Solana address"
              autocomplete="off"
              spellcheck="false"
              aria-invalid={recipient && !looksLikeAddress ? 'true' : undefined}
            ></textarea>
            <!-- Only with something to pick from. -->
            {#if contacts.length || wallets.length}
              <button type="button" class="book" aria-label="Saved addresses and your wallets" onclick={openPicker}>
                <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                  <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H19v20H7.5A2.5 2.5 0 0 1 5 19.5v-15Z" />
                    <path d="M5 19.5A2.5 2.5 0 0 1 7.5 17H19" />
                    <circle cx="12" cy="9" r="2.5" />
                  </g>
                </svg>
              </button>
            {/if}
          </div>

          <!-- A copied address can be swapped on the way in by malware: check it before sending. A
               saved one needs no checking. -->
          {#if groups.length}
            <div class="verify">
              <code>
                {#each groups as group, i (i)}
                  <span>{group}</span>
                {/each}
              </code>
              <p>Check every character against where you copied it from. Malware can swap a copied address.</p>
            </div>
          {/if}
        {/if}
      </div>

      {#if failure}
        <p class="error" role="alert">{failureText(failure)}</p>
      {/if}

      <button type="submit" class="primary" disabled={!coin || !looksLikeAddress || !amountValid || busy}>{busy ? 'Checking…' : 'Review'}</button>
    </form>
  {:else if step === 'review' && review}
    <div class="review">
      <div class="sum">
        <CoinLogo logo={reviewed?.logo ?? review.coin.logo} label={reviewSymbol} size={48} />
        <p class="sum-amount">{review.amount} {reviewSymbol}</p>
        {#if worth(reviewed, review.amount) !== null}
          <p class="sum-usd">≈ {formatUsd(worth(reviewed, review.amount)!)}</p>
        {/if}
        {#if review.network === 'devnet'}
          <span class="badge">Devnet</span>
        {/if}
      </div>

      <dl class="details">
        <div class="to">
          <dt>To</dt>
          <dd>
            <span class="to-contact">
              <span class="initial small" aria-hidden="true">{monogram(review.contact, review.to)}</span>
              <strong>{review.contact ?? 'Address'}</strong>
            </span>
            <code>
              {#each review.to.match(/.{1,4}/g) ?? [] as group, i (i)}
                <span>{group}</span>
              {/each}
            </code>
          </dd>
        </div>
        <div>
          <dt>Network fee</dt>
          <dd>{review.fee} SOL</dd>
        </div>
        {#if review.rent}
          <!-- The recipient has no account for this token yet: the sender pays to open it, once. -->
          <div>
            <dt>Recipient's new token account</dt>
            <dd>{review.rent} SOL</dd>
          </div>
        {/if}
      </dl>

      <!-- A protection that finds something stops the transfer: Send stays off. Only turning that
           protection off in Security, deliberately, lets it through. -->
      <!-- What zandr couldn't check: said plainly, without stopping the transfer. -->
      {#each review.notes as note (note.id)}
        <div class="unchecked" role="note">
          {#if note.id === 'exchangeNoList'}
            <strong>zandr can't check {note.exchange}'s tokens</strong>
            <p>This is a {note.exchange} deposit address, but {note.exchange} publishes no list of the tokens it takes. Make sure it takes {reviewSymbol} on Solana before you send.</p>
          {:else}
            <strong>Exchange check didn't finish</strong>
            <p>zandr couldn't tell in time whether this address belongs to an exchange. If it's an exchange deposit address, make sure the exchange takes {reviewSymbol} on Solana.</p>
          {/if}
        </div>
      {/each}

      {#each review.checks as check (check.id)}
        {@const text = checkText(check)}
        <div class="warning" role="alert">
          <strong>{text.title}</strong>
          <p>{text.text}</p>
          {#if check.id === 'tokenAccount' && check.owner}
            <button type="button" class="link" onclick={() => sendToOwner(check.owner)}>Send to {shortAddress(check.owner)} instead</button>
          {/if}
        </div>
      {/each}

      {#if failure && failure.reason !== 'blocked'}
        <p class="error" role="alert">{failureText(failure)}</p>
      {/if}

      <button type="button" class="primary" onclick={send} disabled={busy || review.checks.length > 0}>{busy ? 'Sending…' : 'Send'}</button>
    </div>
  {:else if step === 'result' && review}
    <div class="center result">
      <span class="center-icon" class:ok={outcome === 'sent'} class:bad={outcome === 'failed' || outcome === 'expired'}>
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d={outcome === 'sent' ? 'M5 12.5 9.5 17 19 7.5' : 'M6 6l12 12M18 6 6 18'}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <p class="center-title" role="status">
        {outcome === 'sent' ? 'Sent' : "Didn't go through"}
      </p>
      <p class="center-text">
        {#if outcome === 'failed'}
          The network ran it and it failed{outcomeDetail ? ` (${outcomeDetail})` : ''}. Only the network fee was charged.
        {:else if outcome === 'expired'}
          The network didn't take it in time. Nothing left your wallet.
        {:else}
          {review.amount} {reviewSymbol} to {review.contact ?? shortAddress(review.to)}
        {/if}
      </p>
      {#if explorer && outcome !== 'expired'}
        <a class="explorer" href={explorer} target="_blank" rel="noopener noreferrer">View on Solscan</a>
      {/if}
    </div>
    <button type="button" class="primary done" onclick={onback}>Done</button>
  {/if}
</div>

<style>
  .send-form {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 12px;
  }

  .recipient-row textarea::placeholder {
    color: rgba(var(--ink), 0.3);
  }

  /* The address picker's two lists, switched like the home screen's tabs. */
  .sources {
    display: flex;
    gap: 16px;
    margin-bottom: 8px;
  }

  .source {
    padding: 0;
    border: 0;
    background: none;
    color: rgba(var(--ink), 0.35);
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
    line-height: 1.5;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  .source:hover,
  .source[aria-selected='true'] {
    color: var(--fg);
  }

  .source:focus-visible {
    border-radius: 6px;
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  .none {
    margin: 12px 0 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.45;
  }

  /* The address field and a saved contact take the same room, so the card keeps its height when
     one replaces the other. */
  .recipient-row,
  .contact-row {
    display: flex;
    gap: 10px;
    height: 44px;
    margin-top: 8px;
  }

  .recipient-row {
    align-items: flex-start;
  }

  .recipient-row textarea {
    flex: 1;
    min-width: 0;
    height: 100%;
    padding: 0;
    border: 0;
    background: none;
    caret-color: var(--fg);
    font-size: 15px;
    font-weight: 500;
    line-height: 1.45;
    word-break: break-all;
    resize: none;
    outline: none;
  }

  /* The address book button and the contact's clear button sit in the very same spot. */
  .book {
    display: grid;
    flex: none;
    align-self: center;
    place-items: center;
    width: 34px;
    height: 34px;
    margin-right: -6px;
    border: 0;
    border-radius: 50%;
    background: rgba(var(--ink), 0.07);
    color: var(--muted);
    cursor: pointer;
    transition:
      color 0.15s var(--ease),
      background-color 0.15s var(--ease);
  }

  .book:hover {
    background: rgba(var(--ink), 0.13);
    color: var(--fg);
  }

  .book:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .contact-row {
    align-items: center;
    gap: 12px;
  }

  /* As in the address book, a shade lighter to stand out on the card. */
  .initial {
    display: grid;
    flex: none;
    place-items: center;
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: rgba(var(--ink), 0.08);
    font-size: 14px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .initial.small {
    width: 24px;
    height: 24px;
    font-size: 9px;
  }

  .contact-who {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
    line-height: 1.25;
  }

  .contact-who > * {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .contact-who strong {
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .contact-who span {
    color: var(--muted);
    font-size: 13px;
  }

  .to-contact {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* The pasted address again, in groups of four, under a hairline. */
  .verify {
    margin-top: 12px;
    padding-top: 12px;
    border-top: 1px solid var(--divider);
  }

  .verify p {
    margin: 8px 0 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.45;
  }

  .send-form .primary {
    margin-top: auto;
  }

  .details .to {
    flex-direction: column;
    gap: 6px;
  }

  .details .to dd {
    display: flex;
    flex-direction: column;
    gap: 4px;
    text-align: left;
  }

  .details .to code {
    font-size: 13px;
  }
</style>
