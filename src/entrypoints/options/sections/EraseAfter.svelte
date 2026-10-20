<script lang="ts">
  // Erasing zandr after too many wrong passwords (lib/guard.ts): off unless the user turns it on,
  // knowing what it means. Every change takes the password.
  import { onMount } from 'svelte';
  import RevealButton from '@/components/RevealButton.svelte';
  import { wrongPassword } from '@/lib/format';
  import { ERASE_CHOICES, sendToBackground } from '@/lib/messages';

  let { onback }: { onback: () => void } = $props();

  // The setting as saved: a count, null when off, undefined until read.
  let saved = $state<number | null | undefined>(undefined);
  let choice = $state(10);
  let understood = $state(false);
  let password = $state('');
  let visible = $state(false);
  let busy = $state(false);
  let error = $state('');
  let done = $state<string | null>(null);

  onMount(async () => {
    try {
      saved = (await sendToBackground({ type: 'security:getEraseAfter' })).eraseAfter;
      if (saved !== null) choice = saved;
    } catch {
      error = "Couldn't read this setting. Please reopen the page.";
    }
  });

  async function save(next: number | null) {
    busy = true;
    error = '';
    try {
      const result = await sendToBackground({ type: 'security:setEraseAfter', eraseAfter: next, password });
      // Don't keep it around once it's done its job.
      password = '';
      if (result.ok) {
        saved = next;
        understood = false;
        done = next === null ? 'Off. Wrong passwords no longer erase anything.' : `On. ${next} wrong passwords in a row erase everything in zandr on this device.`;
      } else if (result.error === 'wrong-password') {
        error = wrongPassword(result, 'The password is wrong');
      } else {
        error = 'Set up a wallet first.';
      }
    } catch {
      error = "Couldn't save the setting. Please try again.";
    } finally {
      busy = false;
    }
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    save(choice);
  }
</script>

<button type="button" class="back" onclick={onback}>
  <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
  Security
</button>

<h1 class="section-title">Erase after wrong passwords</h1>
<p class="section-lead">
  Someone who gets hold of this device could try password after password. With this on, zandr erases every wallet, the
  address book and its settings here after too many wrong passwords in a row, wherever it asks for your password.
</p>

<div class="warning" role="note">
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M10.3 3.9 2.2 18a2 2 0 0 0 1.7 3h16.2a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
      <path d="M12 9.5v4.5m0 3h.01" />
    </g>
  </svg>
  <p>
    <strong>Only turn this on if you know what you're doing.</strong> If you forget your password, or someone types wrong ones
    on purpose, everything in zandr on this device is erased for good. Your coins stay on the blockchain, but you'll need each
    wallet's recovery phrase or private key to get them back.
  </p>
</div>

{#if done}
  <div class="card done" role="status">
    <div>
      <strong>Saved</strong>
      <span>{done}</span>
    </div>
    <button type="button" class="button compact" onclick={onback}>Done</button>
  </div>
{:else if saved !== undefined}
  <form class="card form" onsubmit={submit}>
    <p class="state">
      {#if saved === null}
        <strong>Off.</strong> Wrong passwords don't erase anything.
      {:else}
        <strong>On.</strong> {saved} wrong passwords in a row erase everything in zandr on this device.
      {/if}
    </p>

    <div class="field">
      <span class="label" id="erase-after">Erase after this many wrong passwords in a row</span>
      <div class="segmented" role="group" aria-labelledby="erase-after">
        {#each ERASE_CHOICES as count (count)}
          <button type="button" aria-pressed={choice === count} onclick={() => ((choice = count), (error = ''))}>{count}</button>
        {/each}
      </div>
    </div>

    {#if saved === null}
      <label class="check">
        <input type="checkbox" bind:checked={understood} />
        <span>I have the recovery phrase or private key of every wallet in zandr.</span>
      </label>
    {/if}

    <label class="field">
      <span class="label">Password</span>
      <span class="secret">
        <input
          class="input"
          type={visible ? 'text' : 'password'}
          bind:value={password}
          oninput={() => (error = '')}
          aria-label="Password"
          aria-invalid={error ? 'true' : undefined}
          autocomplete="current-password"
        />
        <RevealButton {visible} ontoggle={() => (visible = !visible)} />
      </span>
    </label>

    {#if error}
      <p class="error" role="alert">{error}</p>
    {/if}

    <div class="actions">
      {#if saved !== null}
        <button type="button" class="text-button" disabled={!password || busy} onclick={() => save(null)}>Turn off</button>
      {/if}
      <!-- Checking the password takes a moment: the key derivation is deliberately slow. -->
      <button class="button compact danger" disabled={!password || busy || (saved === null && !understood) || choice === saved}>
        {busy ? 'Checking…' : saved === null ? 'Turn on' : 'Save'}
      </button>
    </div>
  </form>
{/if}

<style>
  .warning {
    display: flex;
    gap: 12px;
    margin-top: 20px;
    padding: 14px 16px;
    border: 1px solid rgba(240, 87, 93, 0.35);
    border-radius: 14px;
    background: rgba(240, 87, 93, 0.08);
    color: var(--down);
  }

  .warning svg {
    flex: none;
    margin-top: 1px;
  }

  .warning p {
    margin: 0;
    color: rgba(var(--ink), 0.85);
    font-size: 13px;
    line-height: 1.55;
  }

  .warning strong {
    color: var(--down);
    font-weight: 600;
  }

  .form {
    display: flex;
    flex-direction: column;
    gap: 20px;
    margin-top: 16px;
    padding: 20px;
  }

  .state {
    margin: 0;
    color: var(--muted);
    font-size: 14px;
  }

  .state strong {
    color: var(--fg);
    font-weight: 600;
  }

  .field .segmented {
    align-self: flex-start;
  }

  .field .segmented button {
    min-width: 56px;
    white-space: nowrap;
  }

  .form .check {
    margin-top: 0;
  }

  .form .error {
    margin-top: -8px;
  }

  .actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 16px;
  }

  .danger:not(:disabled) {
    background: var(--danger);
    color: var(--on-danger);
  }

  .danger:hover:not(:disabled) {
    background: var(--danger-hover);
  }

  .done {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-top: 16px;
    padding: 16px 16px 16px 18px;
  }

  .done div {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 2px;
  }

  .done strong {
    font-size: 15px;
    font-weight: 600;
  }

  .done span {
    color: var(--muted);
    font-size: 13px;
  }
</style>
