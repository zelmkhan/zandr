<script lang="ts">
  import { onMount } from 'svelte';
  import { browser } from 'wxt/browser';
  import { sendToBackground, type ConnectedApp } from '@/lib/messages';
  import SiteIcon from '@/components/SiteIcon.svelte';

  let apps = $state<ConnectedApp[] | null>(null);
  let failed = $state(false);
  let removing = $state<string | null>(null);

  async function load() {
    try {
      apps = (await sendToBackground({ type: 'connections:list' })).apps;
      failed = false;
    } catch {
      failed = true;
    }
  }

  // Sites connect and disconnect while this is open too.
  onMount(() => {
    load();
    const sync = (changes: Record<string, unknown>, area: string) => {
      if (area === 'local' && 'connections' in changes) load();
    };
    browser.storage.onChanged.addListener(sync);
    return () => browser.storage.onChanged.removeListener(sync);
  });

  async function disconnect(origin: string) {
    removing = origin;
    try {
      await sendToBackground({ type: 'connections:remove', origin });
      await load();
    } finally {
      removing = null;
    }
  }

  const hostOf = (origin: string) => new URL(origin).host;
</script>

<h1 class="section-title">Connected apps</h1>
<p class="section-lead">
  Sites that can see your wallet's address and ask you to approve transactions. They can't move anything without your approval.
</p>

{#if failed}
  <p class="error">Couldn't load the list. Reopen this page to try again.</p>
{:else if apps && apps.length === 0}
  <div class="card empty">
    <strong>No connected apps</strong>
    <span>A site asks to connect when you use it, and shows up here once you allow it.</span>
  </div>
{:else if apps}
  <div class="card rows">
    {#each apps as app (app.origin)}
      <div class="row">
        <div class="app">
          <span class="initial" aria-hidden="true"><SiteIcon origin={app.origin} icon={app.icon} /></span>
          <span class="row-text">
            <strong title={app.origin}>{hostOf(app.origin)}</strong>
            <span>{app.wallets.length ? app.wallets.join(', ') : 'Unlock zandr to see which wallets'}</span>
          </span>
        </div>
        <button type="button" class="button compact secondary" disabled={removing === app.origin} onclick={() => disconnect(app.origin)}>
          Disconnect
        </button>
      </div>
    {/each}
  </div>
{/if}

<style>
  .app {
    display: flex;
    align-items: center;
    gap: 14px;
    min-width: 0;
  }

  .app strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* The site's own icon, with no tile behind it (components/SiteIcon). */
  .initial {
    display: grid;
    flex: none;
    overflow: hidden;
    place-items: center;
    width: 40px;
    height: 40px;
    border-radius: 10px;
    font-size: 16px;
    font-weight: 600;
  }

  .secondary {
    flex: none;
    background: var(--fill);
    color: var(--fg);
  }

  .secondary:hover:not(:disabled) {
    background: var(--fill-strong);
  }

  .empty {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-top: 24px;
    padding: 28px 24px;
    text-align: center;
  }

  .empty strong {
    font-size: 15px;
    font-weight: 600;
  }

  .empty span {
    color: var(--muted);
    font-size: 13px;
  }

  .error {
    margin-top: 24px;
  }
</style>
