<script lang="ts">
  import { browser } from 'wxt/browser';

  // version_name carries the full label (say, 0.0.1-beta); version is the bare number Chrome
  // compares for updates.
  const { version, version_name } = browser.runtime.getManifest();
</script>

<h1 class="section-title">About</h1>
<p class="section-lead">zandr is a Solana wallet that protects your funds from threats and from simple human error.</p>

<div class="card rows">
  <div class="row">
    <div class="row-text"><strong>Version</strong></div>
    <span class="value">{version_name ?? version}</span>
  </div>
</div>

<style>
  .value {
    color: var(--muted);
    font-size: 14px;
    font-variant-numeric: tabular-nums;
  }
</style>
