<script lang="ts">
  // The open wallet's address to receive at: as a QR code, in full, and to copy.
  import encodeQR from 'qr';
  import { scale } from 'svelte/transition';
  import type { Account } from '@/lib/messages';

  let { account, onback }: { account: Account; onback: () => void } = $props();

  // The QR code holds the bare address, which every wallet and exchange can scan. It's drawn as
  // one SVG path of its dark modules, built here rather than inserted as markup.
  const qr = $derived.by(() => {
    const modules = encodeQR(account.address, 'raw', { ecc: 'medium' });
    let path = '';
    modules.forEach((row, y) => row.forEach((dark, x) => dark && (path += `M${x} ${y}h1v1h-1z`)));
    return { size: modules.length, path };
  });

  // In groups of four, told apart by tone: easier to check against what the sender pasted, and still
  // one piece, with nothing that could pass for a space.
  const groups = $derived(account.address.match(/.{1,4}/g) ?? []);

  // As with the address in the header: the icon turns into a check for a moment.
  let copied = $state(false);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  async function copy() {
    try {
      await navigator.clipboard.writeText(account.address);
    } catch {
      return;
    }
    copied = true;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = false), 1500);
  }
</script>

<div class="screen">
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={onback}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>Receive</h2>
    <span class="spacer"></span>
  </div>

  <div class="receive">
    <!-- Dark on white whatever the theme: what scanners read best. -->
    <div class="qr">
      <svg viewBox="0 0 {qr.size} {qr.size}" role="img" aria-label="QR code of your address" shape-rendering="crispEdges">
        <path d={qr.path} fill="#000000" />
      </svg>
    </div>

    <p class="name">{account.name}</p>
    <p class="address" title={account.address}>
      {#each groups as group, i (i)}
        <span>{group}</span>
      {/each}
    </p>

    <!-- The mistake that loses funds for good: coins sent from another network. -->
    <div class="note">
      <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="9.5" />
          <path d="M12 16.5v-5M12 7.5h.01" />
        </g>
      </svg>
      <p>Only receive SOL and Solana tokens here. Coins sent from another network, like Ethereum or Bitcoin, will be lost.</p>
    </div>

    <button type="button" class="primary copy" onclick={copy}>
      {#key copied}
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true" in:scale={{ duration: 200, start: 0.5 }}>
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
      Copy address
    </button>
  </div>
</div>

<style>
  .receive {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding-top: 8px;
  }

  .qr {
    padding: 12px;
    border-radius: 20px;
    background: #ffffff;
  }

  .qr svg {
    display: block;
    width: 176px;
    height: 176px;
  }

  .name {
    margin: 18px 0 0;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

  .address {
    max-width: 270px;
    margin: 6px 0 0;
    font-size: 15px;
    font-weight: 500;
    letter-spacing: 0.02em;
    line-height: 1.45;
    text-align: center;
  }

  .address span {
    display: inline-block;
  }

  .address span:nth-child(even) {
    opacity: 0.5;
  }

  .note {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    align-self: stretch;
    margin-top: 18px;
    padding: 12px;
    border-radius: 12px;
    background: var(--fill);
    color: var(--muted);
  }

  .note svg {
    flex: none;
    margin-top: 1px;
  }

  .note p {
    margin: 0;
    font-size: 12px;
    line-height: 1.45;
  }

  .copy {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    align-self: stretch;
    margin-top: auto;
  }
</style>
