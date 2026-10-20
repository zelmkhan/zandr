<script lang="ts">
  // Show/hide button inside a password field; the field goes in a `.secret` wrapper (ui.css).
  let { visible, ontoggle }: { visible: boolean; ontoggle: () => void } = $props();
</script>

<button type="button" class="reveal" aria-label={visible ? 'Hide passwords' : 'Show passwords'} onclick={ontoggle}>
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
      {#if visible}
        <path d="M10.7 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-2.1 3" />
        <path d="M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6" />
        <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
        <path d="m2 2 20 20" />
      {:else}
        <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z" />
        <circle cx="12" cy="12" r="3" />
      {/if}
    </g>
  </svg>
</button>

<style>
  .reveal {
    position: absolute;
    top: 50%;
    right: 6px;
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    border: 0;
    border-radius: 8px;
    background: none;
    color: var(--muted);
    cursor: pointer;
    transform: translateY(-50%);
    transition: color 0.2s var(--ease);
  }

  .reveal:hover {
    color: var(--fg);
  }

  .reveal:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }
</style>
