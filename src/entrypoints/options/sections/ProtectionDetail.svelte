<script lang="ts">
  import { exchangeCoverage, type ExchangeCoverage } from '@/lib/exchanges';
  import { updatePreferences, type Preferences, type ProtectionId } from '@/lib/preferences';
  import { PROTECTIONS } from './protections';

  let { id, preferences, onback }: { id: ProtectionId; preferences: Preferences; onback: () => void } = $props();

  const info = $derived(PROTECTIONS[id]);
  const on = $derived(preferences.protection[id]);

  // The exchanges the exchange check covers, and how far.
  let exchanges = $state<ExchangeCoverage[]>([]);
  $effect(() => {
    if (id === 'exchangeSupport') exchangeCoverage().then((found) => (exchanges = found));
  });

  const BADGES: Record<ExchangeCoverage['status'], string> = { full: 'Full check', traded: 'Traded tokens', partial: 'Partial', addresses: 'Addresses only' };
  // As the history writes days.
  const dayFormat = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
  const day = (iso: string) => dayFormat.format(new Date(iso));
  function detail(exchange: ExchangeCoverage): string {
    if (exchange.status === 'addresses') return 'Its wallets are recognized; its token list isn’t public';
    const tokens = `${exchange.tokens} token${exchange.tokens === 1 ? '' : 's'}${exchange.status === 'traded' ? ' it trades, by CoinGecko' : ''}`;
    return `${tokens}${exchange.updated ? ` · updated ${day(exchange.updated)}` : ''}${exchange.status === 'partial' ? ' · some tokens unknown' : ''}`;
  }

</script>

<button type="button" class="back" onclick={onback}>
  <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
  Security
</button>

<h1 class="section-title">{info.title}</h1>
<p class="section-lead">{info.lead}</p>

<!-- Honest about where this stands, so nobody counts on a check that isn't running yet. -->
{#if !info.live}
  <div class="notice" role="note">
    <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
      <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="12" cy="12" r="9.5" />
        <path d="M12 16.5v-5m0-3.5h.01" />
      </g>
    </svg>
    <p>
      <strong>In development.</strong> zandr doesn't have its exchange data yet, so this check doesn't run. Your choice
      here is saved and applies as soon as it does.
    </p>
  </div>
{/if}

<div class="card rows">
  <label class="row">
    <span class="row-text">
      <strong>Protection</strong>
      <span>{on ? 'On: risky transfers like these are stopped.' : 'Off: transfers like these go through unchecked.'}</span>
    </span>
    <input
      type="checkbox"
      class="switch"
      checked={on}
      onchange={(event) => updatePreferences({ protection: { ...preferences.protection, [id]: event.currentTarget.checked } })}
    />
  </label>
</div>

<h2 class="group-title">How it works</h2>
<ol class="steps">
  {#each info.steps as step, index}
    <li>
      <span class="step-number">{index + 1}</span>
      <div>
        <strong>{step.title}</strong>
        <span>{step.text}</span>
      </div>
    </li>
  {/each}
</ol>

{#if id === 'exchangeSupport'}
  <h2 class="group-title">Exchanges</h2>
  <p class="group-lead">
    The exchanges this check knows on Solana, and how far. Token lists come from the exchanges themselves and are kept up to
    date by zandr's server.
  </p>
  <div class="card rows">
    {#each exchanges as exchange (exchange.name)}
      <div class="row exchange">
        {#if exchange.logo}
          <img class="mark" src={exchange.logo} alt="" width="32" height="32" />
        {:else}
          <span class="mark letter" aria-hidden="true">{exchange.name.slice(0, 1)}</span>
        {/if}
        <div class="exchange-text">
          <strong>{exchange.name}</strong>
          <span>{detail(exchange)}</span>
        </div>
        <span class="badge" class:live={exchange.status === 'full'}>{BADGES[exchange.status]}</span>
      </div>
    {/each}
  </div>
{/if}

{#if info.limits.length}
  <h2 class="group-title">What it can't catch</h2>
  <ul class="limits">
    {#each info.limits as limit}
      <li>{limit}</li>
    {/each}
  </ul>
{/if}

<style>
  .notice {
    display: flex;
    gap: 10px;
    margin-top: 20px;
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--fill);
    color: var(--muted);
  }

  .notice svg {
    flex: none;
    margin-top: 2px;
  }

  .notice p {
    margin: 0;
    font-size: 13px;
    line-height: 1.5;
  }

  .notice strong {
    color: var(--fg);
    font-weight: 600;
  }

  .notice + .rows {
    margin-top: 16px;
  }

  /* Numbered steps, threaded like the onboarding's step list. */
  .steps {
    display: flex;
    flex-direction: column;
    gap: 18px;
    margin: 14px 0 0;
    padding: 0;
    list-style: none;
  }

  .steps li {
    display: flex;
    gap: 14px;
  }

  .step-number {
    display: grid;
    flex: none;
    place-items: center;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--fill);
    font-size: 13px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }

  .steps div {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-top: 3px;
  }

  .steps strong {
    font-size: 14px;
    font-weight: 600;
  }

  .steps div span {
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .exchange {
    justify-content: flex-start;
    gap: 12px;
    padding-top: 12px;
    padding-bottom: 12px;
  }

  .exchange-text {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .exchange strong {
    font-size: 14px;
    font-weight: 500;
  }

  .exchange-text span {
    color: var(--muted);
    font-size: 12px;
  }

  .letter {
    display: grid;
    place-items: center;
    background: var(--fill);
    color: var(--muted);
    font-size: 14px;
    font-weight: 600;
  }

  /* As app icons: the exchange's logo on its own color, a hairline keeping dark ones in shape. */
  .mark {
    flex: none;
    width: 32px;
    height: 32px;
    border: 1px solid rgba(var(--ink), 0.08);
    border-radius: 9px;
  }

  .badge.live {
    background: rgba(var(--ink), 0.12);
    color: var(--fg);
  }

  .limits {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin: 12px 0 0;
    padding: 0 0 0 18px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .limits li::marker {
    color: rgba(var(--ink), 0.3);
  }

  @media (max-width: 560px) {
    .exchange {
      flex-direction: row;
      align-items: center;
    }
  }
</style>
