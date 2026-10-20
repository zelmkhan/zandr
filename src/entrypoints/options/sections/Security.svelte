<script lang="ts">
  import { sendToBackground } from '@/lib/messages';
  import { AUTO_LOCK_CHOICES, updatePreferences, type Preferences } from '@/lib/preferences';
  import ChangePassword from './ChangePassword.svelte';
  import EraseAfter from './EraseAfter.svelte';
  import ProtectionDetail from './ProtectionDetail.svelte';
  import { PROTECTIONS, PROTECTION_ORDER, type SecurityPage } from './protections';

  let {
    preferences,
    hasWallet,
    detail,
    onopen,
  }: {
    preferences: Preferences;
    hasWallet: boolean;
    detail: SecurityPage | null;
    onopen: (detail: SecurityPage | null) => void;
  } = $props();

  // Erasing after wrong passwords, as saved: read again each time the list shows, since its own
  // page changes it.
  let eraseAfter = $state<number | null>(null);
  $effect(() => {
    if (detail || !hasWallet) return;
    sendToBackground({ type: 'security:getEraseAfter' }).then(
      (result) => (eraseAfter = result.eraseAfter),
      () => {},
    );
  });
</script>

{#if detail === 'password'}
  <ChangePassword onback={() => onopen(null)} />
{:else if detail === 'erase'}
  <EraseAfter onback={() => onopen(null)} />
{:else if detail}
  <ProtectionDetail id={detail} {preferences} onback={() => onopen(null)} />
{:else}
  <h1 class="section-title">Security</h1>
  <p class="section-lead">Keeping zandr locked while you're away, and stopping risky transfers before they happen.</p>

  <div class="card rows">
    <div class="row">
      <div class="row-text">
        <strong>Auto-lock</strong>
        <span>Lock zandr after this long without activity. Unlocking takes your password.</span>
      </div>
      <div class="segmented" role="group" aria-label="Auto-lock after">
        {#each AUTO_LOCK_CHOICES as minutes}
          <button
            type="button"
            aria-pressed={preferences.autoLockMinutes === minutes}
            onclick={() => updatePreferences({ autoLockMinutes: minutes })}
          >
            {minutes < 60 ? `${minutes} min` : '1 hour'}
          </button>
        {/each}
      </div>
    </div>

    <div class="row">
      <div class="row-text">
        <strong>Password</strong>
        <span>{hasWallet ? 'Unlocks zandr on this device and encrypts your keys.' : 'Set up a wallet first.'}</span>
      </div>
      <button type="button" class="button compact secondary" disabled={!hasWallet} onclick={() => onopen('password')}>
        Change
      </button>
    </div>

    <div class="row">
      <div class="row-text">
        <strong>Erase after wrong passwords</strong>
        <span>
          {#if !hasWallet}
            Set up a wallet first.
          {:else if eraseAfter === null}
            Off. Erases every wallet here after too many wrong passwords. Only for those who know what it means.
          {:else}
            On: {eraseAfter} wrong passwords in a row erase everything in zandr on this device.
          {/if}
        </span>
      </div>
      <button type="button" class="button compact secondary" disabled={!hasWallet} onclick={() => onopen('erase')}>
        {eraseAfter === null ? 'Set up' : 'Change'}
      </button>
    </div>
  </div>

  <h2 class="group-title">Transfer protection</h2>
  <p class="group-lead">Checks zandr runs before a transfer leaves your wallet. We recommend keeping them all on.</p>

  <!-- Each opens its own page: what it stops, how, and what it can't catch. -->
  <div class="card rows">
    {#each PROTECTION_ORDER as id}
      <button type="button" class="row link-row" onclick={() => onopen(id)}>
        <span class="row-text">
          <strong>
            {PROTECTIONS[id].title}
            {#if !PROTECTIONS[id].live}
              <span class="badge">In development</span>
            {/if}
          </strong>
          <span>{PROTECTIONS[id].summary}</span>
        </span>
        <span class="row-end">
          <span class="state" class:off={!preferences.protection[id]}>{preferences.protection[id] ? 'On' : 'Off'}</span>
          <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
            <path d="m9 6 6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </span>
      </button>
    {/each}
  </div>
{/if}

<style>
  .secondary {
    flex: none;
    background: var(--fill);
    color: var(--fg);
  }

  .secondary:hover:not(:disabled) {
    background: var(--fill-strong);
  }

  .link-row {
    width: 100%;
    border-right: 0;
    border-bottom: 0;
    border-left: 0;
    background: none;
    text-align: left;
    cursor: pointer;
    transition: background-color 0.2s var(--ease);
  }

  .link-row:first-child {
    border-top: 0;
    border-radius: 16px 16px 0 0;
  }

  .link-row:last-child {
    border-radius: 0 0 16px 16px;
  }

  .link-row:hover {
    background: rgba(var(--ink), 0.03);
  }

  .link-row:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: -2px;
  }

  .row-end {
    display: flex;
    flex: none;
    align-items: center;
    gap: 6px;
    color: var(--muted);
    transition: color 0.2s var(--ease);
  }

  .link-row:hover .row-end {
    color: var(--fg);
  }

  .state {
    font-size: 13px;
  }

  .state.off {
    color: var(--danger);
  }

  @media (max-width: 560px) {
    .link-row {
      flex-direction: row;
      align-items: center;
    }
  }
</style>
