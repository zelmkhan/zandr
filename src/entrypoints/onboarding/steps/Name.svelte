<script lang="ts">
  import { untrack } from 'svelte';
  import { WALLET_NAME_MAX_LENGTH } from '@/lib/messages';

  let { initial, onnext }: { initial: string; onnext: (name: string) => void } = $props();

  // Read once: every visit to this step mounts it anew.
  let name = $state(untrack(() => initial));
  const valid = $derived(name.trim() !== '');

  // Focused with the default name selected, so typing replaces it.
  function select(node: HTMLInputElement) {
    node.focus();
    node.select();
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (valid) onnext(name.trim());
  }
</script>

<form onsubmit={submit}>
  <h1 class="title">Name your wallet</h1>
  <p class="lead">It appears at the top of zandr, so you always know which wallet you're in.</p>

  <label class="field name">
    <span class="label">Wallet name</span>
    <input
      class="input"
      bind:value={name}
      maxlength={WALLET_NAME_MAX_LENGTH}
      placeholder="Main wallet"
      aria-label="Wallet name"
      autocomplete="off"
      spellcheck="false"
      {@attach select}
    />
  </label>
  <p class="help">Only you can see it. Up to {WALLET_NAME_MAX_LENGTH} characters.</p>

  <button class="button" disabled={!valid}>Continue</button>
</form>

<style>
  .name {
    margin-top: 28px;
  }
</style>
