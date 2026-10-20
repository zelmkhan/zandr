<script lang="ts">
  // A coin's logo in a circle. The first letter of its symbol shows until the logo has loaded,
  // and stays when there's no logo or it fails to load.
  let { logo, label, size = 40 }: { logo: string | null; label: string | null; size?: number } = $props();

  // Which logo URL loaded, and which failed: a coin row that gets another logo starts over.
  let loaded = $state<string | null>(null);
  let failed = $state<string | null>(null);
  const usable = $derived(logo !== null && failed !== logo);
  const shown = $derived(usable && loaded === logo);
  const initial = $derived([...(label ?? '?')][0]!.toUpperCase());
</script>

<span class="logo" style:width="{size}px" style:height="{size}px" style:font-size="{Math.round(size * 0.38)}px">
  {#if !shown}
    {initial}
  {/if}
  {#if usable}
    <img
      src={logo}
      alt=""
      class:shown
      referrerpolicy="no-referrer"
      loading="lazy"
      onload={() => (loaded = logo)}
      onerror={() => (failed = logo)}
    />
  {/if}
</span>

<style>
  .logo {
    position: relative;
    display: grid;
    flex: none;
    place-items: center;
    overflow: hidden;
    /* A dark gray ring, so logos on a black or transparent ground keep their round edge. */
    border: 1px solid rgba(var(--ink), 0.05);
    border-radius: 50%;
    background: var(--fill);
    color: var(--muted);
    font-weight: 600;
  }

  /* Over the letter, invisible until it has loaded; then it fades in and the letter goes. */
  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    opacity: 0;
    transition: opacity 0.2s var(--ease);
  }

  img.shown {
    opacity: 1;
  }
</style>
