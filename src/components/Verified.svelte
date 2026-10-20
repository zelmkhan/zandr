<script lang="ts">
  // The mark of a verified token, after its symbol: the token list vouches that this mint is the
  // token its name says. Lucide's "badge-check" (ISC), filled.
  let { size = 14 }: { size?: number } = $props();
</script>

<svg class="verified" width={size} height={size} viewBox="0 0 24 24" role="img" aria-label="Verified">
  <title>Verified token</title>
  <path
    d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"
    fill="var(--verified)"
  />
  <path d="m9 12 2 2 4-4" fill="none" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" />
</svg>

<style>
  .verified {
    flex: none;
  }
</style>
