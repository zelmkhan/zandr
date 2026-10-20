<script lang="ts">
  // The wallet's history, next to its coins: newest first, by day. A row opens the transaction on
  // Solscan. An address that looks like one the user knows, but isn't, is flagged: address
  // poisoning plants exactly those in a wallet's history, hoping one gets copied.
  import { onMount } from 'svelte';
  import { formatAmount, shortAddress } from '@/lib/format';
  import { sendToBackground, type ActivityItem, type ActivityView } from '@/lib/messages';
  import type { ActivityChange, Network } from '@/server/api';
  import CoinLogo from './CoinLogo.svelte';
  import { clear, notify } from './noticeStore.svelte';
  import { describeProblem, problemReason } from './problems';

  let { network, hideBalance, onsettings }: { network: Network; hideBalance: boolean; onsettings: () => void } = $props();

  let activity = $state<ActivityView | null>(null);
  let loadingMore = $state(false);
  // Why an older page didn't come, said by its button.
  let moreFailed = $state<string | null>(null);

  async function load(mode: 'cached' | 'refresh' | 'more') {
    try {
      const result = await sendToBackground({ type: 'activity:get', mode });
      if (!('error' in result)) activity = result;
    } catch {
      // The background restarting: the next refresh tries again.
    }
  }

  // What's kept shows at once, then anything newer; again every 30 seconds while in view.
  onMount(() => {
    load('cached').then(() => load('refresh'));
    const timer = setInterval(() => document.visibilityState === 'visible' && load('refresh'), 30_000);
    return () => {
      clearInterval(timer);
      clear('activity');
    };
  });

  // An older page that didn't come says so by its button, not as a failed refresh.
  async function more() {
    loadingMore = true;
    moreFailed = null;
    try {
      const result = await sendToBackground({ type: 'activity:get', mode: 'more' });
      if ('error' in result) return;
      if (result.problem && result.items.length <= (activity?.items.length ?? 0)) {
        moreFailed =
          result.problem.reason === 'rate-limited'
            ? 'The RPC endpoint is limiting requests. Try again in a few seconds, or set up a faster one in Network settings.'
            : `Couldn't load more. ${problemReason(result.problem)}`;
      } else activity = result;
    } catch {
      moreFailed = "Couldn't load more. Try again.";
    } finally {
      loadingMore = false;
    }
  }

  // A failed refresh over a history already shown: a notice. (Nothing shown yet: the screen says.)
  $effect(() => {
    const problem = activity?.loaded ? activity.problem : null;
    if (!problem) return clear('activity');
    notify('activity', "Couldn't refresh your activity", `${problemReason(problem)} Recent transactions may be missing; zandr keeps trying.`);
  });

  const dayFormat = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
  const yearFormat = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

  function dayOf(time: number | null): string {
    if (time === null) return 'Recent';
    const date = new Date(time);
    const today = new Date();
    const start = (day: Date) => new Date(day.getFullYear(), day.getMonth(), day.getDate()).getTime();
    const ago = Math.round((start(today) - start(date)) / 86_400_000);
    if (ago === 0) return 'Today';
    if (ago === 1) return 'Yesterday';
    return (date.getFullYear() === today.getFullYear() ? dayFormat : yearFormat).format(date);
  }

  const days = $derived.by(() => {
    const groups: { day: string; items: ActivityItem[] }[] = [];
    for (const item of activity?.items ?? []) {
      const day = dayOf(item.time);
      const last = groups.at(-1);
      if (last?.day === day) last.items.push(item);
      else groups.push({ day, items: [item] });
    }
    return groups;
  });

  const coin = (change: ActivityChange) => change.symbol ?? shortAddress(change.mint ?? '');
  const ins = (item: ActivityItem) => item.changes.filter((change) => !change.amount.startsWith('-'));
  const outs = (item: ActivityItem) => item.changes.filter((change) => change.amount.startsWith('-'));

  function title(item: ActivityItem): string {
    switch (item.kind) {
      case 'send':
        return 'Sent';
      case 'receive':
        return 'Received';
      case 'swap':
        return 'Swapped';
      case 'failed':
        return 'Failed';
      default:
        return item.app ?? 'App interaction';
    }
  }

  function subtitle(item: ActivityItem): string {
    const other = item.counterparty ? (item.name ?? shortAddress(item.counterparty)) : null;
    switch (item.kind) {
      case 'send':
        return item.lookalike ? 'Lookalike address' : `To ${other}`;
      case 'receive': {
        if (item.lookalike) return 'Lookalike address';
        const unverified = ins(item).some((change) => change.mint !== null && !change.verified);
        // First, so it isn't cut off: unknown tokens out of nowhere are mostly spam.
        return `${unverified ? 'Unverified token · ' : ''}From ${other}`;
      }
      case 'swap': {
        const [paid] = outs(item);
        const [got] = ins(item);
        return `${coin(paid!)} → ${coin(got!)}${item.app ? ` · ${item.app}` : ''}`;
      }
      case 'failed':
        return item.app ?? (other ? `To ${other}` : item.fee ? 'Only the fee was paid' : 'Nothing changed');
      default:
        return item.app ? 'App interaction' : item.program ? `Program ${shortAddress(item.program)}` : 'Transaction';
    }
  }

  // The coin a row is about: what left in a send, what arrived otherwise.
  function lead(item: ActivityItem): ActivityChange | null {
    if (item.kind === 'failed') return null;
    return (item.kind === 'send' ? outs(item)[0] : ins(item)[0]) ?? item.changes[0] ?? null;
  }

  // Up to two amounts: arrivals first.
  const amounts = (item: ActivityItem) => (item.kind === 'failed' ? [] : [...ins(item), ...outs(item)].slice(0, 2));

  function amountText(change: ActivityChange): string {
    if (hideBalance) return '••••';
    const negative = change.amount.startsWith('-');
    return `${negative ? '−' : '+'}${formatAmount(change.amount.slice(1))} ${coin(change)}`;
  }

  const explorer = (signature: string) => `https://solscan.io/tx/${signature}${network === 'devnet' ? '?cluster=devnet' : ''}`;
</script>

<div class="activity">
  {#if !activity || (!activity.loaded && !activity.problem)}
    <ul class="list" aria-busy="true" aria-label="Loading activity">
      {#each [0, 1, 2] as row (row)}
        <li class="row">
          <span class="skeleton-logo skeleton"></span>
          <span class="what"><span class="bar"></span><span class="bar small"></span></span>
          <span class="amounts"><span class="bar"></span></span>
        </li>
      {/each}
    </ul>
  {:else if !activity.loaded && activity.problem}
    {@const problem = describeProblem(activity.problem, 'activity')}
    <div class="center" role="alert">
      <span class="center-icon">
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <path d="m2 2 20 20" />
            <path d="M5.78 5.78A7 7 0 0 0 9 19h8.5a4.5 4.5 0 0 0 1.31-.19" />
            <path d="M21.53 16.5A4.5 4.5 0 0 0 17.5 10h-1.79A7 7 0 0 0 10 5.07" />
          </g>
        </svg>
      </span>
      <p class="center-title">{problem.title}</p>
      <p class="center-text">{problem.text}</p>
      {#if problem.settings}
        <button type="button" class="secondary" onclick={onsettings}>Network settings</button>
      {/if}
    </div>
  {:else if activity.items.length === 0}
    <div class="center">
      <span class="center-icon">
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="9" />
            <path d="M12 7.5V12l3 2" />
          </g>
        </svg>
      </span>
      <p class="center-title">No activity yet</p>
      <p class="center-text">Coins you send, receive and swap will show up here.</p>
    </div>
  {:else}
    {#each days as { day, items } (day)}
      <section class="day">
        <h3>{day}</h3>
        <ul class="list">
          {#each items as item (item.signature)}
            {@const change = lead(item)}
            <li>
              <a
                class="row"
                class:flagged={item.lookalike}
                href={explorer(item.signature)}
                target="_blank"
                rel="noopener noreferrer"
                title={item.lookalike
                  ? `${item.counterparty} looks like an address you know, but it's a different one. Never copy addresses from your history.`
                  : undefined}
              >
                <span class="icon">
                  {#if item.kind === 'failed'}
                    <span class="glyph failed" aria-hidden="true">
                      <svg width="18" height="18" viewBox="0 0 24 24"><path d="m7 7 10 10M17 7 7 17" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" /></svg>
                    </span>
                  {:else if change}
                    <CoinLogo logo={change.logo} label={change.symbol ?? change.mint} size={39} />
                  {:else}
                    <span class="glyph" aria-hidden="true">
                      <svg width="18" height="18" viewBox="0 0 24 24">
                        <g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round">
                          <rect x="4" y="4" width="6.5" height="6.5" rx="1.6" />
                          <rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6" />
                          <rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6" />
                          <rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6" />
                        </g>
                      </svg>
                    </span>
                  {/if}
                  {#if change && item.kind !== 'app'}
                    <span class="badge" aria-hidden="true">
                      <svg width="11" height="11" viewBox="0 0 24 24">
                        <g fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
                          {#if item.kind === 'send'}
                            <path d="M7 17 17 7M9 7h8v8" />
                          {:else if item.kind === 'receive'}
                            <path d="M17 7 7 17m8 0H7V9" />
                          {:else}
                            <path d="M4 8h14l-3.5-3.5M20 16H6l3.5 3.5" />
                          {/if}
                        </g>
                      </svg>
                    </span>
                  {/if}
                </span>
                <span class="what">
                  <strong>{title(item)}</strong>
                  <span class:warn={item.lookalike}>
                    {#if item.lookalike}
                      <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M12 3 2.5 20h19L12 3Zm0 6v5m0 3h.01" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" />
                      </svg>
                    {/if}
                    {subtitle(item)}
                  </span>
                </span>
                {#if amounts(item).length}
                  <span class="amounts">
                    {#each amounts(item) as amount, index}
                      <span class:up={!amount.amount.startsWith('-')} class:second={index > 0}>{amountText(amount)}</span>
                    {/each}
                  </span>
                {/if}
              </a>
            </li>
          {/each}
        </ul>
      </section>
    {/each}

    {#if activity.more}
      {#if moreFailed}
        <p class="more-failed" role="alert">{moreFailed}</p>
      {/if}
      <button type="button" class="secondary more" class:after-failure={moreFailed} disabled={loadingMore} onclick={more}>
        {loadingMore ? 'Loading…' : moreFailed ? 'Try again' : 'Show more'}
      </button>
    {/if}
  {/if}
</div>

<style>
  .activity {
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  .day h3 {
    margin: 14px 0 2px;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

  .list {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .activity > .list {
    margin-top: 8px;
  }

  /* As a coin row, and a link: hovering lights it edge to edge of the content. */
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    margin: 0 -8px;
    padding: 10px 8px;
    border-radius: 12px;
    color: inherit;
    text-decoration: none;
    transition: background-color 0.2s var(--ease);
  }

  a.row:hover {
    background: rgba(var(--ink), 0.04);
  }

  a.row:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .icon {
    position: relative;
    flex: none;
    width: 39px;
    height: 39px;
  }

  .glyph {
    display: grid;
    place-items: center;
    width: 39px;
    height: 39px;
    border-radius: 50%;
    background: var(--fill);
    color: var(--muted);
  }

  .glyph.failed {
    background: rgba(240, 87, 93, 0.12);
    color: var(--down);
  }

  /* What happened, on the coin's logo: out, in, or swapped. */
  .badge {
    position: absolute;
    right: -3px;
    bottom: -3px;
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border: 2px solid var(--bg);
    border-radius: 50%;
    background: var(--raised);
    color: var(--fg);
  }

  .what,
  .amounts {
    display: flex;
    flex-direction: column;
    gap: 3px;
    line-height: 1.25;
  }

  .what {
    flex: 1;
    min-width: 0;
  }

  .what strong {
    overflow: hidden;
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .what span {
    display: flex;
    align-items: center;
    gap: 4px;
    overflow: hidden;
    color: var(--muted);
    font-size: 13px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .what span svg {
    flex: none;
  }

  .what .warn {
    color: var(--down);
    font-weight: 500;
  }

  .amounts {
    flex: none;
    align-items: flex-end;
    max-width: 50%;
    font-variant-numeric: tabular-nums;
  }

  .amounts span {
    max-width: 100%;
    overflow: hidden;
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .amounts .up {
    color: var(--up);
  }

  .amounts .second {
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

  .amounts .second.up {
    color: var(--up);
  }

  .more {
    align-self: center;
    margin: 12px 0 4px;
  }

  .more.after-failure {
    margin-top: 8px;
  }

  .more-failed {
    margin: 16px 12px 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.45;
    text-align: center;
  }

  /* Placeholders while the first page loads, as the coins'. */
  .skeleton-logo {
    flex: none;
    width: 39px;
    height: 39px;
    border-radius: 50%;
  }

  .skeleton,
  .bar {
    background: var(--fill);
    animation: pulse 1.4s ease-in-out infinite;
  }

  .bar {
    display: block;
    width: 96px;
    height: 14px;
    border-radius: 6px;
  }

  .bar.small {
    width: 64px;
    height: 11px;
  }

  .amounts .bar {
    width: 64px;
  }

  @keyframes pulse {
    50% {
      opacity: 0.45;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .skeleton,
    .bar {
      animation: none;
    }
  }

  /* An empty history or a failed first load: centered in the space left below the tabs. */
  .center {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 24px 24px 0;
    text-align: center;
  }

  .center-icon {
    display: grid;
    place-items: center;
    width: 48px;
    height: 48px;
    margin-bottom: 14px;
    border-radius: 50%;
    background: var(--fill);
    color: var(--muted);
  }

  .center-title {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .center-text {
    max-width: 250px;
    margin: 6px 0 0;
    color: var(--muted);
    font-size: 14px;
    line-height: 1.45;
  }

  .secondary {
    height: 36px;
    margin-top: 16px;
    padding: 0 16px;
    border: 0;
    border-radius: 999px;
    background: var(--fill);
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.2s var(--ease);
  }

  .secondary:hover:not(:disabled) {
    background: var(--fill-strong);
  }

  .secondary:disabled {
    cursor: default;
    opacity: 0.6;
  }

  .secondary:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }
</style>
