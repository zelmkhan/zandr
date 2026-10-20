<script lang="ts">
  let { oncreate, onimport }: { oncreate: () => void; onimport: () => void } = $props();
</script>

<h1 class="title">Welcome to zandr</h1>
<p class="lead">Create a new wallet, or bring one you already have.</p>

<!-- One grouped card, the two choices as rows inside it. -->
<div class="card choices">
  <button type="button" class="choice" onclick={oncreate}>
    <span class="icon">
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
      </svg>
    </span>
    <span class="text">
      <strong>Create a new wallet</strong>
      <span>A self-custody wallet with a new recovery phrase</span>
    </span>
    <svg class="chevron" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
      <path d="m9 6 6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </button>

  <button type="button" class="choice" onclick={onimport}>
    <span class="icon">
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path
          d="M12 4v11m-5-5 5 5 5-5M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </span>
    <span class="text">
      <strong>Import a wallet</strong>
      <span>With a recovery phrase or a private key</span>
    </span>
    <svg class="chevron" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
      <path d="m9 6 6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </button>
</div>

<style>
  .choices {
    display: flex;
    flex-direction: column;
    margin-top: 32px;
    overflow: hidden;
  }

  .choice {
    display: flex;
    align-items: center;
    gap: 14px;
    width: 100%;
    padding: 16px 16px 16px 14px;
    border: 0;
    background: none;
    text-align: left;
    cursor: pointer;
    transition: background-color 0.2s var(--ease);
  }

  .choice + .choice {
    border-top: 1px solid var(--field-border);
  }

  .choice:hover {
    background: rgba(var(--ink), 0.035);
  }

  .choice:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: -2px;
  }

  .icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: var(--fill);
    transition: background-color 0.2s var(--ease);
  }

  .choice:hover .icon {
    background: var(--fill-strong);
  }

  .text {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  strong {
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .text span {
    color: var(--muted);
    font-size: 13px;
  }

  .chevron {
    flex: none;
    color: var(--muted);
    transition:
      color 0.2s var(--ease),
      transform 0.2s var(--ease);
  }

  .choice:hover .chevron {
    color: var(--fg);
    transform: translateX(2px);
  }
</style>
