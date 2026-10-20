<script lang="ts">
  import { untrack } from 'svelte';
  import { sendToBackground, type WalletSecret } from '@/lib/messages';

  let { initial, onnext }: { initial: WalletSecret | null; onnext: (secret: WalletSecret) => void } = $props();

  // Coming back from the password step keeps what was typed. Read once: every visit to this
  // step mounts it anew.
  const start = untrack(() => initial);
  let kind = $state<WalletSecret['kind']>(start?.kind ?? 'phrase');
  let words = $state<string[]>(start?.kind === 'phrase' ? [...start.words] : Array(12).fill(''));
  let key = $state(start?.kind === 'privateKey' ? start.key : '');

  let error = $state('');
  let invalidWord = $state(-1);
  let busy = $state(false);

  const complete = $derived(kind === 'phrase' ? words.every((word) => word.trim()) : key.trim() !== '');

  const errors = {
    'word-count': 'A recovery phrase has 12 or 24 words.',
    checksum: "These words don't form a valid recovery phrase. Check their spelling and order.",
    'invalid-key': "This isn't a valid Solana private key. Check that you copied all of it.",
  };

  function choose(next: WalletSecret['kind']) {
    kind = next;
    clearError();
  }

  function clearError() {
    error = '';
    invalidWord = -1;
  }

  function setLength(count: number) {
    words = Array.from({ length: count }, (_, i) => words[i] ?? '');
  }

  // Pasting a whole phrase into any box spreads it over all of them.
  function paste(event: ClipboardEvent) {
    const parts = event.clipboardData?.getData('text').trim().split(/\s+/) ?? [];
    if (parts.length < 2) return;

    event.preventDefault();
    words = Array.from({ length: parts.length > 12 ? 24 : 12 }, (_, i) => parts[i] ?? '');
    clearError();
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    const secret: WalletSecret =
      kind === 'phrase' ? { kind, words: words.map((word) => word.trim().toLowerCase()) } : { kind, key: key.trim() };

    busy = true;
    clearError();
    try {
      const check = await sendToBackground({ type: 'onboarding:checkSecret', secret });
      if (check.ok) return onnext(secret);

      if (check.error === 'unknown-word') {
        invalidWord = check.index;
        error = `Word #${check.index + 1} isn't in the recovery phrase word list. Check its spelling.`;
      } else {
        error = errors[check.error];
      }
    } catch {
      error = "Couldn't check it right now. Please try again.";
    } finally {
      busy = false;
    }
  }
</script>

<form onsubmit={submit}>
  <h1 class="title">Import a wallet</h1>
  <p class="lead">Enter the recovery phrase or the private key of a Solana wallet you already have. It stays on this device.</p>

  <div class="segmented" role="group" aria-label="Import with">
    <button type="button" aria-pressed={kind === 'phrase'} onclick={() => choose('phrase')}>Recovery phrase</button>
    <button type="button" aria-pressed={kind === 'privateKey'} onclick={() => choose('privateKey')}>Private key</button>
  </div>

  {#if kind === 'phrase'}
    <div class="card phrase-card">
      <div class="head">
        <span>{words.length} words · paste the whole phrase into any box</span>
        <button type="button" class="text-button" onclick={() => setLength(words.length === 12 ? 24 : 12)}>
          {words.length === 12 ? 'Use 24 words' : 'Use 12 words'}
        </button>
      </div>

      <ol class="words">
        {#each words as _, i}
          <li>
            <span class="index">{i + 1}</span>
            <input
              bind:value={words[i]}
              onpaste={paste}
              oninput={clearError}
              aria-label="Word {i + 1}"
              aria-invalid={invalidWord === i ? 'true' : undefined}
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
            />
          </li>
        {/each}
      </ol>
    </div>
  {:else}
    <label class="field key-field">
      <span class="label">Private key</span>
      <textarea
        class="input key"
        bind:value={key}
        oninput={clearError}
        aria-label="Private key"
        aria-invalid={error ? 'true' : undefined}
        rows="3"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
      ></textarea>
    </label>
    <p class="help">A base58 key exported from a wallet, or the byte array from a Solana CLI keypair file.</p>
  {/if}

  {#if error}
    <p class="error" role="alert">{error}</p>
  {/if}

  <button class="button" disabled={!complete || busy}>Continue</button>
</form>

<style>
  .segmented {
    margin-top: 28px;
  }

  .phrase-card {
    margin-top: 16px;
    padding: 4px 12px 12px;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    height: 40px;
    padding-left: 4px;
  }

  .head > span {
    overflow: hidden;
    color: var(--muted);
    font-size: 13px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .head .text-button {
    flex: none;
    margin-right: -4px;
  }

  .key-field {
    margin-top: 16px;
  }

  .key {
    height: auto;
    padding: 12px 16px;
    line-height: 1.5;
    word-break: break-all;
    resize: none;
  }
</style>
