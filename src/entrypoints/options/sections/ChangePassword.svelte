<script lang="ts">
  import RevealButton from '@/components/RevealButton.svelte';
  import StrengthMeter from '@/components/StrengthMeter.svelte';
  import { wrongPassword } from '@/lib/format';
  import { PASSWORD_MIN_LENGTH, sendToBackground } from '@/lib/messages';

  let { onback }: { onback: () => void } = $props();

  let current = $state('');
  let next = $state('');
  let confirm = $state('');
  let visible = $state(false);
  let busy = $state(false);
  let done = $state(false);
  // Which field the error is about, so that one is outlined.
  let error = $state<{ field: 'current' | 'next' | 'confirm' | null; message: string } | null>(null);

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (next.length < PASSWORD_MIN_LENGTH) {
      error = { field: 'next', message: `Use at least ${PASSWORD_MIN_LENGTH} characters.` };
      return;
    }
    if (next === current) {
      error = { field: 'next', message: 'Choose a password different from the current one.' };
      return;
    }
    if (next !== confirm) {
      error = { field: 'confirm', message: "The new passwords don't match." };
      return;
    }

    busy = true;
    error = null;
    try {
      const result = await sendToBackground({ type: 'wallet:changePassword', current, next });
      if (!result.changed) {
        error = { field: 'current', message: wrongPassword(result, 'The current password is wrong') };
        return;
      }
      // Don't keep any of them around once they've done their job.
      current = next = confirm = '';
      done = true;
    } catch {
      error = { field: null, message: "Couldn't change the password. Please try again." };
    } finally {
      busy = false;
    }
  }
</script>

<button type="button" class="back" onclick={onback}>
  <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
  Security
</button>

<h1 class="section-title">Change password</h1>
<p class="section-lead">
  Your keys are re-encrypted with the new password. Your recovery phrase doesn't change and still restores your wallet.
</p>

{#if done}
  <div class="card done" role="status">
    <span class="badge-icon">
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </span>
    <div>
      <strong>Password changed</strong>
      <span>Use your new password the next time you unlock zandr.</span>
    </div>
    <button type="button" class="button compact" onclick={onback}>Done</button>
  </div>
{:else}
  <form class="card form" onsubmit={submit}>
    <label class="field">
      <span class="label">Current password</span>
      <span class="secret">
        <input
          class="input"
          type={visible ? 'text' : 'password'}
          bind:value={current}
          oninput={() => (error = null)}
          aria-label="Current password"
          aria-invalid={error?.field === 'current' ? 'true' : undefined}
          autocomplete="current-password"
        />
        <RevealButton {visible} ontoggle={() => (visible = !visible)} />
      </span>
    </label>

    <label class="field">
      <span class="label">New password</span>
      <input
        class="input"
        type={visible ? 'text' : 'password'}
        bind:value={next}
        oninput={() => (error = null)}
        aria-label="New password"
        aria-invalid={error?.field === 'next' ? 'true' : undefined}
        autocomplete="new-password"
      />
      <StrengthMeter password={next} />
    </label>

    <label class="field">
      <span class="label">Confirm new password</span>
      <input
        class="input"
        type={visible ? 'text' : 'password'}
        bind:value={confirm}
        oninput={() => (error = null)}
        aria-label="Confirm new password"
        aria-invalid={error?.field === 'confirm' ? 'true' : undefined}
        autocomplete="new-password"
      />
    </label>

    {#if error}
      <p class="error" role="alert">{error.message}</p>
    {/if}

    <div class="actions">
      <!-- Re-encrypting takes a moment: the key derivation is deliberately slow to resist guessing. -->
      <button class="button compact" disabled={!current || !next || !confirm || busy}>
        {busy ? 'Re-encrypting…' : 'Change password'}
      </button>
    </div>
  </form>
{/if}

<style>
  .form {
    display: flex;
    flex-direction: column;
    gap: 20px;
    margin-top: 24px;
    padding: 20px;
  }

  .form .error {
    margin-top: -8px;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
  }

  .done {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-top: 24px;
    padding: 16px 16px 16px 18px;
  }

  .badge-icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: var(--fg);
    color: var(--bg);
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

  .done div span {
    color: var(--muted);
    font-size: 13px;
  }
</style>
