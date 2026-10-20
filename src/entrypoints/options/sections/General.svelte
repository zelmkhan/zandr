<script lang="ts">
  import { browser } from 'wxt/browser';
  import { THEME_CHOICES, updatePreferences, type Preferences } from '@/lib/preferences';

  let { preferences }: { preferences: Preferences } = $props();

  // Side panels are Chrome-only.
  const hasSidePanel = browser.sidePanel !== undefined;
</script>

<h1 class="section-title">General</h1>
<p class="section-lead">How zandr opens and what it shows.</p>

<div class="card rows">
  <div class="row">
    <div class="row-text">
      <strong>Theme</strong>
      <span>Dark, light, or the same as your system.</span>
    </div>
    <div class="segmented" role="group" aria-label="Theme">
      {#each THEME_CHOICES as theme}
        <button type="button" aria-pressed={preferences.theme === theme} onclick={() => updatePreferences({ theme })}>
          {theme === 'dark' ? 'Dark' : theme === 'light' ? 'Light' : 'System'}
        </button>
      {/each}
    </div>
  </div>

  {#if hasSidePanel}
    <div class="row">
      <div class="row-text">
        <strong>Open zandr in</strong>
        <span>Where the toolbar button opens your wallet.</span>
      </div>
      <div class="segmented" role="group" aria-label="Open zandr in">
        <button type="button" aria-pressed={!preferences.sidePanel} onclick={() => updatePreferences({ sidePanel: false })}>
          Popup
        </button>
        <button type="button" aria-pressed={preferences.sidePanel} onclick={() => updatePreferences({ sidePanel: true })}>
          Side panel
        </button>
      </div>
    </div>
  {/if}

  <label class="row">
    <span class="row-text">
      <strong>Hide balance</strong>
      <span>Show dots instead of amounts, for when others can see your screen.</span>
    </span>
    <input
      type="checkbox"
      class="switch"
      checked={preferences.hideBalance}
      onchange={(event) => updatePreferences({ hideBalance: event.currentTarget.checked })}
    />
  </label>
</div>
