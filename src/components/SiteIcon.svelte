<script lang="ts">
  // A site's icon, filling the box the page gives it, with no tile behind it. Best first: the large
  // icon the site's page declares (an SVG, an Apple touch icon or the like, sharp at this size);
  // else the browser's own copy of its favicon (Chrome's favicon cache, through the favicon
  // permission); else its first letter on a disc (Firefox, or nothing loads).
  let { origin, icon = null }: { origin: string; icon?: string | null } = $props();

  const favicon = $derived(
    import.meta.env.BROWSER === 'firefox' ? null : `${location.origin}/_favicon/?pageUrl=${encodeURIComponent(origin)}&size=64`,
  );
  // The ones that failed to load, by address: a site that gets another icon starts over.
  let failed = $state<string[]>([]);
  const shown = $derived(icon && !failed.includes(icon) ? icon : favicon && !failed.includes(favicon) ? favicon : null);
  const initial = $derived((new URL(origin).hostname.replace(/^www\./, '')[0] ?? '?').toUpperCase());
</script>

{#if shown}
  {#key shown}
    <img src={shown} alt="" referrerpolicy="no-referrer" onerror={() => (failed = [...failed, shown])} />
  {/key}
{:else}
  <span class="letter">{initial}</span>
{/if}

<style>
  /* An icon drawn on a square of its own gets the box's rounded corners. */
  img {
    width: 100%;
    height: 100%;
    border-radius: inherit;
    object-fit: contain;
  }

  .letter {
    display: grid;
    place-items: center;
    width: 100%;
    height: 100%;
    border-radius: 50%;
    background: var(--fill);
  }
</style>
