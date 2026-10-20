<script lang="ts" module>
  import type { Coin } from '@/server/api';

  // Whether the home screen lists a coin under the minimum value filter. SOL always (it pays the
  // fees); other coins only above the minimum, if one is set, those without a price counting as
  // worth nothing.
  export function isListed(coin: Coin, minValue: number): boolean {
    return coin.native || minValue === 0 || (coin.value ?? 0) > minValue;
  }
</script>

<script lang="ts">
  import type { PortfolioEntry } from '@/lib/messages';
  import { formatAmount, formatChange, formatUsd, shortAddress } from '@/lib/format';
  import Verified from '@/components/Verified.svelte';
  import CoinLogo from './CoinLogo.svelte';
  import { describeProblem } from './problems';

  let {
    entry,
    hideBalance,
    minValue,
    onsettings,
  }: { entry: PortfolioEntry | null; hideBalance: boolean; minValue: number; onsettings: () => void } = $props();

  const portfolio = $derived(entry?.portfolio ?? null);
  const empty = $derived(portfolio?.coins.every((coin) => coin.amount === '0') ?? false);
  // SOL first, then the rest by what they're worth, the most first; those without a price after,
  // in the order they came.
  const shown = $derived(
    [...(portfolio?.coins ?? [])]
      .sort((a, b) => Number(b.native) - Number(a.native) || (b.value ?? -1) - (a.value ?? -1))
      .filter((coin) => isListed(coin, minValue)),
  );
</script>

<div class="coins">
  {#if !entry}
    <ul class="list" aria-busy="true" aria-label="Loading coins">
      {#each [0, 1, 2] as row (row)}
        <li class="coin">
          <span class="skeleton-logo skeleton"></span>
          <span class="what"><span class="bar"></span><span class="bar small"></span></span>
          <span class="worth"><span class="bar"></span><span class="bar small"></span></span>
        </li>
      {/each}
    </ul>
  {:else if !portfolio && entry.problem}
    {@const problem = describeProblem(entry.problem, 'coins')}
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
  {:else if portfolio && empty}
    <div class="center">
      <span class="center-icon">
        <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
            <path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1" />
            <path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4" />
          </g>
        </svg>
      </span>
      <p class="center-title">No coins yet</p>
      <p class="center-text">Fund your wallet: receive SOL or any Solana token to get started.</p>
    </div>
  {:else if portfolio}
    <!-- A failed refresh over coins already shown is a notice at the bottom (App). -->
    <ul class="list">
      {#each shown as coin (coin.native ? 'native' : coin.mint)}
        <li class="coin">
          <CoinLogo logo={coin.logo} label={coin.symbol ?? coin.name} size={39} />
          <span class="what">
            <!-- The symbol on top, so the amount below doesn't repeat it; a token without one shows
                 its mint address next to the amount instead. -->
            <!-- A symbol is anyone's to pick: only a verified token's has the badge. -->
            <strong class="symbol"><span>{coin.symbol ?? 'Unknown token'}</span>{#if coin.verified}<Verified />{/if}</strong>
            <span>{hideBalance ? '••••' : formatAmount(coin.balance)}{coin.symbol ? '' : ` ${shortAddress(coin.mint)}`}</span>
          </span>
          {#if coin.value !== null}
            <span class="worth">
              <strong>{hideBalance ? '••••' : formatUsd(coin.value)}</strong>
              {#if coin.change24h !== null}
                <span class:up={coin.change24h > 0} class:down={coin.change24h < 0}>{formatChange(coin.change24h)}</span>
              {/if}
            </span>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .coins {
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  .list {
    margin: 8px 0 0;
    padding: 0;
    list-style: none;
  }

  .coin {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 0;
  }

  .skeleton-logo {
    flex: none;
    width: 39px;
    height: 39px;
    border-radius: 50%;
  }

  .what,
  .worth {
    display: flex;
    flex-direction: column;
    gap: 3px;
    line-height: 1.25;
  }

  .what {
    flex: 1;
    min-width: 0;
  }

  .worth {
    flex: none;
    align-items: flex-end;
    font-variant-numeric: tabular-nums;
  }

  .what strong,
  .worth strong {
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  /* The symbol and its badge: the symbol gives way first. */
  .what > .symbol {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .symbol > span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .what > *,
  .worth > * {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .what > span,
  .worth > span {
    color: var(--muted);
    font-size: 13px;
  }

  .worth > .up {
    color: var(--up);
  }

  .worth > .down {
    color: var(--down);
  }

  /* Placeholders while the first coins load. */
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

  .worth .bar {
    width: 56px;
  }

  .worth .bar.small {
    width: 40px;
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

  /* An empty wallet or a failed first load: centered in the space left below "Coins". */
  .center {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 24px 24px 0;
    text-align: center;
  }

  /* Same round fill as the action buttons. */
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

  .secondary:hover {
    background: var(--fill-strong);
  }

  .secondary:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }
</style>
