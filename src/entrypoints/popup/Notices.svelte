<script lang="ts">
  import { flip } from 'svelte/animate';
  import { fade, fly } from 'svelte/transition';
  import { close, notices } from './noticeStore.svelte';

  // How much of the view's bottom the notices cover, for the view to leave room for: the end of
  // a list can still be scrolled clear of them.
  let height = $state(0);
  $effect(() => {
    document.documentElement.style.setProperty('--notices-height', `${height}px`);
  });
</script>

<!-- Over the bottom edge of the view, newest last; the rest of the view stays clickable. -->
<div class="notices" aria-live="polite" bind:clientHeight={height}>
  {#each notices() as notice (notice.key)}
    <div class="notice" role="status" animate:flip={{ duration: 200 }} in:fly={{ y: 16, duration: 250 }} out:fade={{ duration: 150 }}>
      <svg class="notice-icon" width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 3 2.5 20h19L12 3Z" />
          <path d="M12 10v4m0 3h.01" />
        </g>
      </svg>
      <div class="notice-text">
        <strong>{notice.title}</strong>
        <span>{notice.text}</span>
      </div>
      <button type="button" class="notice-close" aria-label="Close" onclick={() => close(notice.key)}>
        <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M6 6l12 12M18 6 6 18" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" />
        </svg>
      </button>
    </div>
  {/each}
</div>

<style>
  .notices {
    position: absolute;
    right: 12px;
    bottom: 12px;
    left: 12px;
    z-index: 20;
    display: flex;
    flex-direction: column;
    gap: 8px;
    pointer-events: none;
  }

  .notice {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px 8px 12px 14px;
    border-radius: 14px;
    background: var(--notice);
    box-shadow: 0 10px 28px var(--shadow);
    color: var(--on-notice);
    pointer-events: auto;
  }

  .notice-icon {
    flex: none;
    margin-top: 1px;
  }

  .notice-text {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    line-height: 1.35;
    overflow-wrap: anywhere;
  }

  .notice-text strong {
    font-size: 14px;
    font-weight: 600;
  }

  .notice-text span {
    font-size: 13px;
    opacity: 0.8;
  }

  .notice-close {
    display: grid;
    flex: none;
    place-items: center;
    width: 28px;
    height: 28px;
    margin: -4px 0 -4px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: none;
    color: inherit;
    cursor: pointer;
    transition: background-color 0.15s var(--ease);
  }

  .notice-close:hover {
    background: rgba(0, 0, 0, 0.1);
  }

  .notice-close:focus-visible {
    outline: 2px solid currentColor;
  }
</style>
