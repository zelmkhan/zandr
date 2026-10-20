<script lang="ts">
  import { browser } from 'wxt/browser';
  import { scale } from 'svelte/transition';

  let { outcome, address = '' }: { outcome: 'created' | 'imported' | 'existing'; address?: string } = $props();

  const titles = {
    created: 'Your wallet is ready',
    imported: 'Your wallet is imported',
    existing: 'zandr is already set up',
  };

  // Opens the wallet's popup right away; if the browser won't (older Chrome, side panel mode),
  // the hint below explains where to find it.
  let openFailed = $state(false);
  async function openWallet() {
    try {
      await browser.action.openPopup();
    } catch {
      openFailed = true;
    }
  }

  let copied = $state(false);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;
  async function copyAddress() {
    try {
      await navigator.clipboard.writeText(address);
    } catch {
      return;
    }
    copied = true;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = false), 1500);
  }
</script>

<div class="badge">
  <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
</div>

<h1 class="title">{titles[outcome]}</h1>
<p class="lead">
  {outcome === 'existing'
    ? 'A wallet is already set up on this device. Open zandr to use it.'
    : 'Your keys are encrypted and stored on this device. You can start using zandr right away.'}
</p>

{#if address}
  <!-- After an import, this is the moment to check it's the wallet you meant. -->
  <div class="card address">
    <div>
      <span>Your Solana address</span>
      <code>{address}</code>
    </div>
    <button type="button" class="text-button" aria-label="Copy address" onclick={copyAddress}>
      {#key copied}
        <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" in:scale={{ duration: 200, start: 0.5 }}>
          <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            {#if copied}
              <path d="M5 12.5 9.5 17 19 7.5" />
            {:else}
              <rect x="8" y="8" width="13" height="13" rx="2.5" />
              <path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8" />
            {/if}
          </g>
        </svg>
      {/key}
    </button>
  </div>
{/if}

<button type="button" class="button" onclick={openWallet}>Open zandr</button>
{#if openFailed}
  <p class="help" role="status">
    Click the zandr icon in your browser's toolbar. Pin it from the extensions menu to keep it one click away.
  </p>
{/if}

<style>
  /* A soft halo around the check: the one celebratory moment in the flow. */
  .badge {
    display: grid;
    place-items: center;
    width: 52px;
    height: 52px;
    margin-bottom: 24px;
    border-radius: 50%;
    background: var(--fg);
    box-shadow: 0 0 0 8px rgba(var(--ink), 0.06);
    color: var(--bg);
  }

  .address {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-top: 28px;
    padding: 14px 10px 14px 16px;
  }

  .address div {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
  }

  .address span {
    color: var(--muted);
    font-size: 12px;
  }

  code {
    font-family: inherit;
    font-size: 13px;
    font-weight: 500;
    letter-spacing: -0.01em;
    word-break: break-all;
  }

  .address .text-button {
    flex: none;
    width: 36px;
    height: 36px;
    justify-content: center;
    padding: 0;
  }
</style>
