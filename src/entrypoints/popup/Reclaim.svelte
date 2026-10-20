<script lang="ts">
  // Getting back the SOL that the wallet's token accounts hold as rent: every empty account, and
  // any junk the user picks (worth under a dollar, or with no price), its tokens burned first. The
  // background finds them, checks each again and test-runs every transaction before signing.
  import { onMount } from 'svelte';
  import { formatAmount, formatUsd, shortAddress } from '@/lib/format';
  import {
    RECLAIM_BATCH,
    RECLAIM_FEE_PER_TRANSACTION,
    RECLAIM_JUNK_MAX_USD,
    sendToBackground,
    type ReclaimAccount,
    type ReclaimFailure,
  } from '@/lib/messages';
  import { formatUnits, parseUnits } from '@/lib/units';
  import type { Network } from '@/server/api';
  import Verified from '@/components/Verified.svelte';
  import CoinLogo from './CoinLogo.svelte';
  import { followSent } from './followSent';

  let { network, onback, onreclaimed }: { network: Network; onback: () => void; onreclaimed: () => void } = $props();

  type Plan = { empty: ReclaimAccount[]; junk: ReclaimAccount[]; pricesKnown: boolean };
  let plan = $state<Plan | null>(null);
  let failure = $state<ReclaimFailure | null>(null);
  let busy = $state(false);
  // Empty accounts to close: all of them unless the user leaves some out. Junk to burn: nothing
  // until the user picks it.
  let closingPicked = $state<string[]>([]);
  let picked = $state<string[]>([]);
  let acknowledged = $state(false);

  // Once sent: the transactions, followed until they land. Shown as done at once: the node ran each
  // once more before taking it. Shown as failed or expired instead if one ends that way.
  let signatures = $state<string[]>([]);
  let result = $state<{ reclaimed: string; burned: number; skipped: number } | null>(null);
  let outcome = $state<'reclaimed' | 'failed' | 'expired'>('reclaimed');

  async function load() {
    plan = null;
    failure = null;
    picked = [];
    closingPicked = [];
    acknowledged = false;
    try {
      const answer = await sendToBackground({ type: 'reclaim:plan' });
      if (answer.ok) {
        plan = answer;
        closingPicked = answer.empty.map((account) => account.address);
      } else failure = answer.failure;
    } catch {
      failure = { reason: 'network', failure: 'unreachable' };
    }
  }

  onMount(load);

  const closing = $derived(plan?.empty.filter((account) => closingPicked.includes(account.address)) ?? []);
  const burning = $derived(plan?.junk.filter((account) => picked.includes(account.address)) ?? []);
  const lamports = (accounts: ReclaimAccount[]) => accounts.reduce((sum, account) => sum + (parseUnits(account.sol, 9) ?? 0n), 0n);
  const total = $derived(plan ? formatUnits(lamports(closing) + lamports(burning), 9) : '0');
  const count = $derived(closing.length + burning.length);
  const fee = $derived.by(() => {
    if (!plan) return '0';
    const transactions = Math.ceil(closing.length / RECLAIM_BATCH.close) + Math.ceil(burning.length / RECLAIM_BATCH.burn);
    return formatUnits(BigInt(transactions * RECLAIM_FEE_PER_TRANSACTION), 9);
  });
  const nothing = $derived(!!plan && !plan.empty.length && !plan.junk.length);
  const allPicked = $derived(!!plan && plan.junk.length > 0 && picked.length === plan.junk.length);
  const allClosing = $derived(!!plan && plan.empty.length > 0 && closingPicked.length === plan.empty.length);

  function toggleClosing(address: string) {
    closingPicked = closingPicked.includes(address) ? closingPicked.filter((one) => one !== address) : [...closingPicked, address];
  }

  function toggleAllClosing() {
    closingPicked = allClosing ? [] : (plan?.empty.map((account) => account.address) ?? []);
  }

  function toggle(address: string) {
    picked = picked.includes(address) ? picked.filter((one) => one !== address) : [...picked, address];
    if (!picked.length) acknowledged = false;
  }

  function toggleAll() {
    picked = allPicked ? [] : (plan?.junk.map((account) => account.address) ?? []);
    if (!picked.length) acknowledged = false;
  }

  async function reclaim() {
    if (!plan || busy || !count || (burning.length && !acknowledged)) return;
    busy = true;
    failure = null;
    try {
      const answer = await sendToBackground({
        type: 'reclaim:execute',
        close: closing.map((account) => account.address),
        burn: burning.map((account) => account.address),
        acknowledged,
      });
      if (answer.ok) {
        signatures = answer.signatures;
        result = answer;
        outcome = 'reclaimed';
      } else {
        failure = answer.failure;
      }
    } catch {
      failure = { reason: 'network', failure: 'unreachable' };
    } finally {
      busy = false;
    }
  }

  // Each transaction followed until it lands; the balances refreshed once all have.
  $effect(() => {
    if (!signatures.length) return;
    const sent = [...signatures];
    const landed = new Set<string>();
    const stops = sent.map((signature) =>
      followSent(signature, (status) => {
        if (status.status !== 'confirmed') {
          outcome = status.status;
          return;
        }
        landed.add(signature);
        if (landed.size === sent.length) onreclaimed();
      }),
    );
    return () => stops.forEach((stop) => stop());
  });

  function failureText(failure: ReclaimFailure): string {
    switch (failure.reason) {
      case 'locked':
        return 'zandr locked meanwhile. Unlock it and try again.';
      case 'nothing':
        return 'Those accounts changed meanwhile and none can be closed now.';
      case 'unacknowledged':
        return 'Confirm that the picked tokens will be destroyed.';
      case 'prices':
        return "Token prices couldn't be checked, so nothing was burned. Try again in a moment.";
      case 'simulation':
        return `The network's test run didn't go as it should, so nothing was signed: ${failure.detail}`;
      default:
        return failure.failure === 'rate-limited'
          ? 'The RPC endpoint is busy. Try again in a moment.'
          : failure.failure === 'forbidden'
            ? 'The RPC endpoint refused. Set one up in Network settings.'
            : "Couldn't reach the network. Check your connection and try again.";
    }
  }

  const label = (account: ReclaimAccount) => account.symbol ?? shortAddress(account.mint);
  const explorer = $derived(signatures[0] ? `https://solscan.io/tx/${signatures[0]}${network === 'devnet' ? '?cluster=devnet' : ''}` : null);
</script>

<div class="screen flow">
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={onback}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>Reclaim SOL</h2>
    <span class="spacer"></span>
  </div>

  {#if signatures.length && result}
    <div class="center">
      <span class="center-icon" class:ok={outcome === 'reclaimed'} class:bad={outcome === 'failed' || outcome === 'expired'}>
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d={outcome === 'reclaimed' ? 'M5 12.5 9.5 17 19 7.5' : 'M6 6l12 12M18 6 6 18'}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <p class="center-title" role="status">
        {outcome === 'reclaimed' ? 'SOL reclaimed' : "Didn't go through"}
      </p>
      <p class="center-text">
        {#if outcome === 'failed' || outcome === 'expired'}
          Some accounts may not have closed. Open this screen again to see what's left.
        {:else}
          {formatAmount(result.reclaimed)} SOL is back in your wallet{result.burned
            ? `, ${result.burned} ${result.burned === 1 ? 'token' : 'tokens'} burned`
            : ''}.
          {#if result.skipped}
            {result.skipped} {result.skipped === 1 ? 'account was' : 'accounts were'} left as they were: they can't be closed now, or
            turned out to be worth more.
          {/if}
        {/if}
      </p>
      {#if explorer && outcome !== 'expired'}
        <a class="explorer" href={explorer} target="_blank" rel="noopener noreferrer">View on Solscan</a>
      {/if}
    </div>
    <button type="button" class="primary bottom" onclick={onback}>Done</button>
  {:else if !plan && !failure}
    <div class="center">
      <span class="center-icon"><span class="spinner" aria-hidden="true"></span></span>
      <p class="center-text">Looking through your token accounts…</p>
    </div>
  {:else if !plan && failure}
    <div class="center">
      <span class="center-icon bad">
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 8v5m0 3.5h.01M12 3 2.5 20h19L12 3Z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </span>
      <p class="center-title">Couldn't look</p>
      <p class="center-text">{failureText(failure)}</p>
    </div>
    <button type="button" class="primary bottom" onclick={load}>Try again</button>
  {:else if plan && nothing}
    <div class="center">
      <span class="center-icon ok">
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </span>
      <p class="center-title">Nothing to reclaim</p>
      <p class="center-text">
        {plan.pricesKnown
          ? 'Your wallet has no empty token accounts, and no tokens worth so little that burning them is worth it.'
          : "Your wallet has no empty token accounts. Token prices couldn't be checked, so no tokens are offered for burning."}
      </p>
    </div>
    <button type="button" class="primary bottom" onclick={onback}>Done</button>
  {:else if plan}
    <div class="sum">
      <p class="sum-amount" class:none={!count}>+{formatAmount(total)} SOL</p>
      <p class="sum-usd">
        {count ? `from ${count} token ${count === 1 ? 'account' : 'accounts'}` : 'Pick accounts below'}
      </p>
    </div>

    {#if plan.empty.length}
      <section>
        <h3>
          Empty accounts <span>{plan.empty.length}</span>
          <button type="button" class="all" onclick={toggleAllClosing}>{allClosing ? 'Clear' : 'Select all'}</button>
        </h3>
        <p class="lead">Nothing in them. If a token comes back later, a new account opens for it.</p>
        <ul class="accounts">
          {#each plan.empty as account (account.address)}
            <li>
              <label class="pick">
                <input type="checkbox" checked={closingPicked.includes(account.address)} onchange={() => toggleClosing(account.address)} />
                <CoinLogo logo={account.logo} label={account.symbol ?? account.mint} size={32} />
                <span class="what">
                  <strong class="symbol"><span>{label(account)}</span>{#if account.verified}<Verified />{/if}</strong>
                  <span>{shortAddress(account.address)}</span>
                </span>
                <span class="worth">+{formatAmount(account.sol)} SOL</span>
              </label>
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    {#if plan.junk.length}
      <section>
        <h3>
          Junk tokens <span>{plan.junk.length}</span>
          <button type="button" class="all" onclick={toggleAll}>{allPicked ? 'Clear' : 'Select all'}</button>
        </h3>
        <p class="lead">Worth under {formatUsd(RECLAIM_JUNK_MAX_USD)}, or with no price. Burning destroys them for good.</p>
        <ul class="accounts">
          {#each plan.junk as account (account.address)}
            <li>
              <label class="pick">
                <input type="checkbox" checked={picked.includes(account.address)} onchange={() => toggle(account.address)} />
                <CoinLogo logo={account.logo} label={account.symbol ?? account.mint} size={32} />
                <span class="what">
                  <strong class="symbol"><span>{label(account)}</span>{#if account.verified}<Verified />{/if}</strong>
                  <span>{formatAmount(account.balance ?? '0')} · {account.value === null ? 'No price' : formatUsd(account.value)}</span>
                </span>
                <span class="worth">+{formatAmount(account.sol)} SOL</span>
              </label>
            </li>
          {/each}
        </ul>
      </section>
    {:else if !plan.pricesKnown}
      <p class="lead">Token prices couldn't be checked, so no tokens are offered for burning now.</p>
    {/if}

    <dl class="details">
      <div>
        <dt>Network fee</dt>
        <dd>≈ {fee} SOL</dd>
      </div>
    </dl>

    {#if burning.length}
      <label class="check">
        <input type="checkbox" bind:checked={acknowledged} />
        I understand the {burning.length} {burning.length === 1 ? 'token' : 'tokens'} I picked will be destroyed and can't be recovered.
      </label>
    {/if}

    {#if failure}
      <p class="error" role="alert">{failureText(failure)}</p>
    {/if}

    <button type="button" class="primary bottom" disabled={busy || !count || (burning.length > 0 && !acknowledged)} onclick={reclaim}>
      {busy
        ? 'Reclaiming…'
        : burning.length
          ? `Burn ${burning.length} and reclaim ${formatAmount(total)} SOL`
          : `Reclaim ${formatAmount(total)} SOL`}
    </button>
  {/if}
</div>

<style>
  .sum-amount.none {
    color: var(--muted);
  }

  .sum + section {
    margin-top: 14px;
  }

  section + section {
    margin-top: 18px;
  }

  h3 {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 0;
    font-size: 14px;
    font-weight: 600;
  }

  h3 span {
    color: var(--muted);
    font-weight: 500;
  }

  .all {
    margin-left: auto;
    padding: 2px 0;
    border: 0;
    background: none;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  .all:hover,
  .all:focus-visible {
    color: var(--fg);
  }

  .lead {
    margin: 4px 0 10px;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.45;
  }

  .accounts {
    margin: 0;
    padding: 4px 16px;
    border-radius: 18px;
    background: var(--fill);
    list-style: none;
  }

  .accounts li,
  .pick {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 0;
  }

  .accounts li:has(.pick) {
    padding: 0;
  }

  .pick {
    flex: 1;
    min-width: 0;
    cursor: pointer;
  }

  .pick input {
    flex: none;
    width: 16px;
    height: 16px;
    margin: 0;
    accent-color: var(--fg);
    cursor: pointer;
  }

  .accounts li + li {
    border-top: 1px solid var(--divider);
  }

  .accounts .what strong {
    font-size: 14px;
  }

  .accounts .what span {
    font-size: 12px;
  }

  .accounts .worth {
    color: var(--up);
    font-size: 14px;
  }

  .details {
    margin: 18px 0 14px;
  }

  .check {
    margin-bottom: 14px;
  }

  .error {
    margin: 0 0 14px;
  }

  /* At the bottom, however long the lists. */
  .bottom {
    flex: none;
    margin-top: auto;
  }
</style>
