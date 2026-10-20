<script lang="ts">
  // Settings for the app and the network, in a full tab. Wallet settings live elsewhere.
  import { onMount } from 'svelte';
  import { browser } from 'wxt/browser';
  import { sendToBackground } from '@/lib/messages';
  import { DEFAULT_PREFERENCES, loadPreferences, type Preferences } from '@/lib/preferences';
  import About from './sections/About.svelte';
  import ConnectedApps from './sections/ConnectedApps.svelte';
  import General from './sections/General.svelte';
  import Network from './sections/Network.svelte';
  import Security from './sections/Security.svelte';
  import type { SecurityPage } from './sections/protections';

  const sections = [
    { id: 'general', label: 'General' },
    { id: 'network', label: 'Network' },
    { id: 'security', label: 'Security' },
    { id: 'apps', label: 'Connected apps' },
    { id: 'about', label: 'About' },
  ] as const;

  type SectionId = (typeof sections)[number]['id'];

  // The open section, and a page inside Security, are kept in the URL (#security/password),
  // so a reload or a link lands there and the Back button works.
  function fromHash(): { section: SectionId; detail: SecurityPage | null } {
    const [section, detail] = location.hash.slice(1).split('/');
    const known = sections.find((item) => item.id === section)?.id ?? 'general';
    const page = detail === 'password' || detail === 'erase' || (detail && detail in DEFAULT_PREFERENCES.protection) ? (detail as SecurityPage) : null;
    return { section: known, detail: known === 'security' ? page : null };
  }

  let { section: current, detail } = $state(fromHash());

  function open(id: SectionId, page: SecurityPage | null = null) {
    current = id;
    detail = page;
    history.pushState(null, '', `#${id}${page ? `/${page}` : ''}`);
    scrollTo(0, 0);
  }

  onMount(() => {
    const follow = () => ({ section: current, detail } = fromHash());
    addEventListener('popstate', follow);
    return () => removeEventListener('popstate', follow);
  });

  // Changes from the wallet (say, the eye button) or another settings tab show up here too.
  let preferences = $state<Preferences | null>(null);
  // Changing the password needs a wallet to change it for.
  let hasWallet = $state(false);
  onMount(() => {
    sendToBackground({ type: 'wallet:getStatus' }).then((status) => (hasWallet = status.hasWallet));
    loadPreferences().then((saved) => (preferences = saved));
    const sync = (changes: Record<string, unknown>, area: string) => {
      if (area === 'local' && 'preferences' in changes) loadPreferences().then((saved) => (preferences = saved));
    };
    browser.storage.onChanged.addListener(sync);
    return () => browser.storage.onChanged.removeListener(sync);
  });
</script>

<div class="shell">
  <aside class="sidebar">
    <div class="brand">
      <span class="wordmark">zandr</span>
      <span class="caption">Settings</span>
    </div>

    <nav aria-label="Settings">
      {#each sections as section}
        <button
          type="button"
          class="nav-item"
          aria-current={current === section.id ? 'page' : undefined}
          onclick={() => open(section.id)}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
              {#if section.id === 'general'}
                <path d="M21 5h-7M10 5H3m18 7h-9m-4 0H3m18 7h-5m-4 0H3M14 3v4m-6 3v4m8 3v4" />
              {:else if section.id === 'network'}
                <circle cx="12" cy="12" r="9.5" />
                <path d="M12 2.5a14 14 0 0 0 0 19 14 14 0 0 0 0-19ZM2.5 12h19" />
              {:else if section.id === 'security'}
                <rect x="4" y="11" width="16" height="10" rx="2.5" />
                <path d="M8 11V7.5a4 4 0 0 1 8 0V11" />
              {:else if section.id === 'apps'}
                <path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1" />
                <path d="M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1" />
              {:else}
                <circle cx="12" cy="12" r="9.5" />
                <path d="M12 16.5v-5m0-3.5h.01" />
              {/if}
            </g>
          </svg>
          {section.label}
        </button>
      {/each}
    </nav>
  </aside>

  <main class="content">
    {#if preferences}
      {#key current}
        <div class="section">
          {#if current === 'general'}
            <General {preferences} />
          {:else if current === 'network'}
            <Network {preferences} />
          {:else if current === 'security'}
            <Security {preferences} {hasWallet} {detail} onopen={(page) => open('security', page)} />
          {:else if current === 'apps'}
            <ConnectedApps />
          {:else}
            <About />
          {/if}
        </div>
      {/key}
    {/if}
  </main>
</div>

<style>
  .shell {
    display: grid;
    grid-template-columns: 264px 1fr;
    min-height: 100vh;
  }

  /* Sidebar: the same lifted surface as the onboarding's brand panel. */
  .sidebar {
    position: sticky;
    top: 0;
    display: flex;
    flex-direction: column;
    gap: 32px;
    height: 100vh;
    padding: 36px 20px 28px;
    border-right: 1px solid var(--divider);
    background: var(--panel);
  }

  .brand {
    display: flex;
    align-items: baseline;
    gap: 10px;
    padding: 0 12px;
  }

  .wordmark {
    font-size: 22px;
    font-weight: 600;
    letter-spacing: -0.035em;
  }

  .caption {
    color: var(--muted);
    font-size: 14px;
  }

  nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 40px;
    padding: 0 12px;
    border: 0;
    border-radius: 10px;
    background: none;
    color: var(--muted);
    font-size: 14px;
    font-weight: 500;
    text-align: left;
    cursor: pointer;
    transition:
      color 0.15s var(--ease),
      background-color 0.15s var(--ease);
  }

  .nav-item:hover {
    background: rgba(var(--ink), 0.04);
    color: var(--fg);
  }

  .nav-item[aria-current='page'] {
    background: var(--fill);
    color: var(--fg);
  }

  .nav-item:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .content {
    padding: 56px 56px 80px;
  }

  .section {
    max-width: 640px;
  }

  /* Narrow screens: the sidebar becomes a bar on top with the sections in a row. */
  @media (max-width: 760px) {
    .shell {
      grid-template-columns: 1fr;
    }

    .sidebar {
      position: static;
      gap: 16px;
      height: auto;
      padding: 20px 12px 12px;
      border-right: 0;
      border-bottom: 1px solid var(--divider);
    }

    nav {
      flex-direction: row;
      overflow-x: auto;
    }

    .nav-item {
      flex: none;
    }

    .content {
      padding: 32px 24px 64px;
    }
  }
</style>
