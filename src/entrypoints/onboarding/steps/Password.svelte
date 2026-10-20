<script lang="ts">
  import RevealButton from '@/components/RevealButton.svelte';
  import StrengthMeter from '@/components/StrengthMeter.svelte';
  import { PASSWORD_MIN_LENGTH } from '@/lib/messages';

  let { action, onsubmit }: { action: string; onsubmit: (password: string) => Promise<void> } = $props();

  let password = $state('');
  let confirm = $state('');
  let visible = $state(false);
  let error = $state('');
  let busy = $state(false);


  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (password.length < PASSWORD_MIN_LENGTH) {
      error = `Use at least ${PASSWORD_MIN_LENGTH} characters.`;
      return;
    }
    if (password !== confirm) {
      error = "The passwords don't match.";
      return;
    }

    busy = true;
    error = '';
    try {
      await onsubmit(password);
    } catch {
      error = "Couldn't set up your wallet. Please try again.";
    } finally {
      busy = false;
    }
  }
</script>

<form onsubmit={submit}>
  <h1 class="title">Create a password</h1>
  <p class="lead">It unlocks zandr on this device and encrypts your keys. It can't be used to recover your wallet.</p>

  <div class="fields">
    <label class="field">
      <span class="label">Password</span>
      <span class="secret">
        <input
          class="input"
          type={visible ? 'text' : 'password'}
          bind:value={password}
          oninput={() => (error = '')}
          aria-label="Password"
          aria-invalid={error && password.length < PASSWORD_MIN_LENGTH ? 'true' : undefined}
          autocomplete="new-password"
        />
        <RevealButton {visible} ontoggle={() => (visible = !visible)} />
      </span>
      <StrengthMeter {password} />
    </label>

    <label class="field">
      <span class="label">Confirm password</span>
      <input
        class="input"
        type={visible ? 'text' : 'password'}
        bind:value={confirm}
        oninput={() => (error = '')}
        aria-label="Confirm password"
        aria-invalid={error && password.length >= PASSWORD_MIN_LENGTH ? 'true' : undefined}
        autocomplete="new-password"
      />
    </label>
  </div>

  {#if error}
    <p class="error" role="alert">{error}</p>
  {/if}

  <!-- Encrypting takes a moment: the key derivation is deliberately slow to resist guessing. -->
  <button class="button" disabled={!password || !confirm || busy}>{busy ? 'Encrypting…' : action}</button>
</form>

<style>
  .fields {
    display: flex;
    flex-direction: column;
    gap: 20px;
    margin-top: 28px;
  }
</style>
