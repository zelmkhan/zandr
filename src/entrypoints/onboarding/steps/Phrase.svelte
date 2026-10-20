<script lang="ts">
  let { words, onnext }: { words: string[]; onnext: () => void } = $props();

  // Hidden until asked for, in case someone is looking at the screen.
  let revealed = $state(false);
  let saved = $state(false);
  let copied = $state(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(words.join(' '));
      copied = true;
    } catch {
      // The browser refused (e.g. the page lost focus); the button simply stays as it was.
    }
  }
</script>

<h1 class="title">Your recovery phrase</h1>
<p class="lead">
  Write these {words.length} words down in order and keep them somewhere safe and offline. Never share them, and never type
  them into a website.
</p>

<div class="card phrase-card">
  <div class="head">
    <span>Recovery phrase</span>
    <button type="button" class="text-button copy" onclick={copy} disabled={!revealed}>
      {#if copied}
        <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        Copied
      {:else}
        <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
          <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="8" y="8" width="13" height="13" rx="2.5" />
            <path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8" />
          </g>
        </svg>
        Copy
      {/if}
    </button>
  </div>

  <div class="phrase">
    <ol class="words" class:concealed={!revealed} aria-hidden={!revealed}>
      {#each words as word, index}
        <li><span class="index">{index + 1}</span><span class="word">{word}</span></li>
      {/each}
    </ol>

    {#if !revealed}
      <button type="button" class="reveal" onclick={() => (revealed = true)}>
        <span class="reveal-icon">
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z" />
              <circle cx="12" cy="12" r="3" />
            </g>
          </svg>
        </span>
        <strong>Reveal recovery phrase</strong>
        <span>Make sure no one can see your screen</span>
      </button>
    {/if}
  </div>
</div>

<!-- Other apps can read the clipboard, and clipboard sync can carry it to the cloud. -->
{#if copied}
  <p class="help" role="status">Paste it somewhere safe and offline, then copy something else over it.</p>
{/if}

<label class="check">
  <input type="checkbox" bind:checked={saved} disabled={!revealed} />
  <span>I've written down my recovery phrase</span>
</label>

<button type="button" class="button" disabled={!saved} onclick={onnext}>Continue</button>

<style>
  .phrase-card {
    margin-top: 28px;
    padding: 4px 12px 12px;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 40px;
    padding-left: 4px;
  }

  .head > span {
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

  .copy {
    margin-right: -4px;
  }

  .phrase {
    position: relative;
  }

  .concealed {
    user-select: none;
  }

  .concealed .word {
    filter: blur(6px);
  }

  .reveal {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    border: 0;
    border-radius: 10px;
    background: var(--veil);
    backdrop-filter: blur(2px);
    cursor: pointer;
  }

  .reveal-icon {
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    margin-bottom: 8px;
    border-radius: 50%;
    background: var(--fill-strong);
    transition: background-color 0.2s var(--ease);
  }

  .reveal:hover .reveal-icon {
    background: rgba(var(--ink), 0.2);
  }

  .reveal strong {
    font-size: 15px;
    font-weight: 600;
  }

  .reveal span:last-child {
    color: var(--muted);
    font-size: 13px;
  }

  .reveal:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }
</style>
