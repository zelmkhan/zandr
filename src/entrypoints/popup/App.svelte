<script lang="ts">
  import { onMount, tick } from 'svelte';
  import { scale } from 'svelte/transition';
  import { browser } from 'wxt/browser';
  import { LIVE_PING_MS, LIVE_PORT, sendToBackground, type Account, type PortfolioEntry } from '@/lib/messages';
  import {
    DEFAULT_PREFERENCES,
    MIN_COIN_VALUE_CHOICES,
    loadPreferences,
    updatePreferences,
    type Preferences,
  } from '@/lib/preferences';
  import { formatUsd, monogram, shortAddress, wrongPassword } from '@/lib/format';
  import Activity from './Activity.svelte';
  import AddressBook from './AddressBook.svelte';
  import Coins from './Coins.svelte';
  import DeFi from './DeFi.svelte';
  import Notices from './Notices.svelte';
  import { clear, notify } from './noticeStore.svelte';
  import { problemReason } from './problems';
  import Receive from './Receive.svelte';
  import Reclaim from './Reclaim.svelte';
  import Send from './Send.svelte';
  import Swap from './Swap.svelte';
  import Wallets from './Wallets.svelte';
  import type { View } from './mount';

  let { view }: { view: View } = $props();

  // Preferences are read before anything is shown, so a hidden balance never flashes on open.
  let preferences = $state<Preferences>(structuredClone(DEFAULT_PREFERENCES));
  let status = $state(
    loadPreferences().then((saved) => {
      preferences = saved;
      return sendToBackground({ type: 'wallet:getStatus' });
    }),
  );

  // The header shows the account once unlocked, and it sits outside the {#await} below.
  let account = $state<Account | null>(null);
  $effect(() => {
    const current = status;
    current.then(
      (next) => {
        if (current === status) account = next.account;
      },
      () => {},
    );
  });

  let password = $state('');
  let passwordInput = $state<HTMLInputElement>();
  let error = $state('');
  let busy = $state(false);

  function focus(node: HTMLElement) {
    node.focus();
  }

  // No wallet here any more (erased after too many wrong passwords): setting one up again happens
  // in the onboarding tab.
  function setUpWallet() {
    browser.tabs.create({ url: browser.runtime.getURL('/onboarding.html') });
    window.close();
  }

  async function unlock(event: SubmitEvent) {
    // Never let the form navigate: a default GET submit would put the password in the URL.
    event.preventDefault();
    if (!password) {
      passwordInput?.focus();
      return;
    }

    busy = true;
    try {
      const result = await sendToBackground({ type: 'wallet:unlock', password });
      if (result.unlocked || result.erased) {
        password = '';
        status = sendToBackground({ type: 'wallet:getStatus' });
      } else {
        error = wrongPassword(result);
        passwordInput?.select();
      }
    } catch {
      error = "Couldn't unlock. Please try again.";
    } finally {
      busy = false;
    }
  }

  // The open wallet's coins: what the background has cached, then each update it stores under
  // `key` in session storage.
  let holdings = $state<{ key: string; network: string; address: string; entry: PortfolioEntry | null } | null>(null);
  const address = $derived(account?.address ?? null);
  const network = $derived(preferences.network);
  // Only what belongs to the wallet and network on screen: another wallet's coins never show,
  // not even for a moment after a switch.
  const entry = $derived(holdings?.address === address && holdings?.network === network ? holdings.entry : null);
  const portfolio = $derived(entry?.portfolio ?? null);

  // Coins on screen whose last refresh failed: they may be out of date, and the notice says why.
  // (Nothing on screen yet: the coins area itself explains.)
  $effect(() => {
    const problem = portfolio ? entry?.problem : null;
    if (!problem) return clear('portfolio');
    notify('portfolio', "Couldn't refresh your coins", `${problemReason(problem)} Balances may be out of date; zandr keeps trying.`);
  });

  let portfolioRequest = 0;

  // `refresh`: fetch anew even if what's cached is recent, as after a transfer.
  async function loadPortfolio(refresh = false) {
    const request = ++portfolioRequest;
    try {
      const response = await sendToBackground({ type: 'portfolio:get', refresh });
      if (request !== portfolioRequest) return;
      if ('error' in response) {
        status = sendToBackground({ type: 'wallet:getStatus' });
        return;
      }
      // An update stored while this answer was on its way is newer: keep it.
      const shown = holdings?.key === response.key ? holdings.entry : null;
      holdings = { ...response, entry: shown && shown.checkedAt > (response.entry?.checkedAt ?? 0) ? shown : response.entry };
    } catch {
      // The background is unavailable; the next poll tries again.
    }
  }

  // While a wallet is open: its coins now, again after a switch of wallet or network, every 30
  // seconds while in view, and on coming back into view.
  $effect(() => {
    if (!address || !network) return;
    loadPortfolio();
    const timer = setInterval(() => document.visibilityState === 'visible' && loadPortfolio(), 30_000);
    const onVisible = () => document.visibilityState === 'visible' && loadPortfolio();
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });

  // While a wallet is on screen, the background watches its coins live and stores each change,
  // which shows up here through storage (below). This view holds a port open for as long as it
  // wants that, and pings over it so the background stays awake. If the background restarts, the
  // port closes: open another.
  $effect(() => {
    if (!address || !network) return;
    let port: ReturnType<typeof browser.runtime.connect> | null = null;
    let reopen: ReturnType<typeof setTimeout> | undefined;
    let done = false;

    const open = () => {
      port = browser.runtime.connect({ name: LIVE_PORT });
      port.onDisconnect.addListener(() => {
        port = null;
        if (!done) reopen = setTimeout(open, 1000);
      });
    };
    open();
    const ping = setInterval(() => {
      try {
        port?.postMessage('ping');
      } catch {
        // Closing right now: onDisconnect opens another.
      }
    }, LIVE_PING_MS);

    return () => {
      done = true;
      clearInterval(ping);
      clearTimeout(reopen);
      port?.disconnect();
    };
  });

  // Popup and side panel can be open at once: a change made in one shows up in the other.
  onMount(() => {
    const sync = (changes: Record<string, { newValue?: unknown }>, area: string) => {
      if (area === 'local' && changes.preferences) loadPreferences().then((saved) => (preferences = saved));
      if (area !== 'session') return;
      // Locked by auto-lock or from another view: show the lock screen here too.
      if (changes.session && changes.session.newValue === undefined) status = sendToBackground({ type: 'wallet:getStatus' });
      if (holdings && changes[holdings.key]) holdings = { ...holdings, entry: (changes[holdings.key]!.newValue as PortfolioEntry | undefined) ?? null };
    };
    browser.storage.onChanged.addListener(sync);
    return () => browser.storage.onChanged.removeListener(sync);
  });

  function toggleBalance() {
    preferences.hideBalance = !preferences.hideBalance;
    updatePreferences({ hideBalance: preferences.hideBalance });
  }

  // What the home screen lists below the actions: the coins, or the wallet's activity.
  let tab = $state<'coins' | 'defi' | 'activity'>('coins');

  function showTab(next: 'coins' | 'defi' | 'activity') {
    tab = next;
    filterOpen = false;
  }

  // Filter next to "Coins": a dropdown with the minimum value a coin needs to be listed.
  let filterOpen = $state(false);
  let filterAnchor = $state<HTMLElement>();
  let filterButton = $state<HTMLButtonElement>();

  function filterChoices() {
    return [...(filterAnchor?.querySelectorAll<HTMLElement>('[role="menuitemradio"]') ?? [])];
  }

  async function setFilter(open: boolean) {
    filterOpen = open;
    // The current choice takes focus, so arrows move on from it.
    if (open) {
      await tick();
      filterAnchor?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
    }
  }

  function filterButtonKeys(event: KeyboardEvent) {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    event.stopPropagation();
    setFilter(true);
  }

  // As in the wallet menu, but the choices sit in a row, so left and right move between them too.
  function filterKeys(event: KeyboardEvent) {
    if (!filterOpen) return;
    const choices = filterChoices();
    const index = choices.indexOf(document.activeElement as HTMLElement);

    if (event.key === 'Escape') {
      setFilter(false);
      filterButton?.focus();
    } else if (event.key === 'Tab') {
      setFilter(false);
    } else if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
      event.preventDefault();
      const step = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : choices.length - 1;
      choices[(index + step) % choices.length]?.focus();
    }
  }

  // The coin list hides what's worth less (see Coins.svelte).
  function setMinCoinValue(value: number) {
    preferences.minCoinValue = value;
    updatePreferences({ minCoinValue: value });
    setFilter(false);
    filterButton?.focus();
  }


  // Clicking the address in the header copies the full one; its icon turns into a check for a moment.
  let copied = $state(false);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  async function copyAddress() {
    if (!account) return;
    try {
      await navigator.clipboard.writeText(account.address);
    } catch {
      return;
    }
    copied = true;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = false), 1500);
  }

  // Wallet menu behind the three dots: the same dropdown as the website's channel picker.
  let menuOpen = $state(false);
  let menuAnchor = $state<HTMLElement>();
  let moreButton = $state<HTMLButtonElement>();

  function menuItems() {
    return [...(menuAnchor?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])];
  }

  async function setMenu(open: boolean) {
    menuOpen = open;
    // The first item takes focus once the menu is visible, so arrows work straight away.
    if (open) {
      await tick();
      menuItems()[0]?.focus();
    }
  }

  function moreKeys(event: KeyboardEvent) {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    // Don't let the menu's own key handler also move on from the item just focused.
    event.stopPropagation();
    setMenu(true);
  }

  // Arrows move between items, Escape backs out to the button, Tab leaves and closes.
  function menuKeys(event: KeyboardEvent) {
    if (!menuOpen) return;
    const items = menuItems();
    const index = items.indexOf(document.activeElement as HTMLElement);

    if (event.key === 'Escape') {
      setMenu(false);
      moreButton?.focus();
    } else if (event.key === 'Tab') {
      setMenu(false);
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const step = event.key === 'ArrowDown' ? 1 : items.length - 1;
      items[(index + step) % items.length]?.focus();
    }
  }

  function closeOnOutsideClick(event: MouseEvent) {
    const target = event.target as Node;
    if (menuOpen && !menuAnchor?.contains(target)) setMenu(false);
    if (filterOpen && !filterAnchor?.contains(target)) setFilter(false);
  }

  // Side panel mode is Chrome-only. The browser window this view is in, to open the panel in.
  const hasSidePanel = browser.sidePanel !== undefined;
  let windowId: number | undefined;
  browser.windows.getCurrent().then((window) => (windowId = window.id));

  // "Side panel mode" in the popup opens the panel right away and closes the popup; "Popup mode"
  // in the panel closes the panel. Either way the toolbar button follows the setting.
  function toggleSidePanel() {
    setMenu(false);
    preferences.sidePanel = !preferences.sidePanel;
    const saved = updatePreferences({ sidePanel: preferences.sidePanel });

    if (preferences.sidePanel && view === 'popup' && windowId !== undefined) {
      // open() needs the click's user gesture, so it's called before anything is awaited. The
      // popup closes only once the setting is saved: closing it cancels a write in progress.
      Promise.all([browser.sidePanel.open({ windowId }), saved]).then(() => window.close());
    } else if (!preferences.sidePanel && view === 'sidepanel') {
      saved.then(() => window.close());
    }
  }

  // The extension's options page, in its own tab; Chrome reuses the tab if it's already open.
  function openSettings() {
    setMenu(false);
    browser.runtime.openOptionsPage();
  }

  function openNetworkSettings() {
    browser.tabs.create({ url: `${browser.runtime.getURL('/options.html')}#network` });
  }

  // Screens of the unlocked wallet beyond the home one.
  let screen = $state<'home' | 'addressBook' | 'wallets' | 'receive' | 'send' | 'swap' | 'reclaim'>('home');

  // After switching or adding a wallet: show the newly active one on the home screen.
  function walletSwitched() {
    status = sendToBackground({ type: 'wallet:getStatus' });
    screen = 'home';
  }

  function openAddressBook() {
    setMenu(false);
    screen = 'addressBook';
  }

  async function lockWallet() {
    setMenu(false);
    screen = 'home';
    await sendToBackground({ type: 'wallet:lock' });
    status = sendToBackground({ type: 'wallet:getStatus' });
  }
</script>

<svelte:document onclick={closeOnOutsideClick} />

<div class="layout" class:unlocked={account !== null}>
  <header>
    {#if account}
      <div class="account">
        <!-- Empty for now; opens the wallet switcher. -->
        <button type="button" class="avatar" aria-label="Wallets" onclick={() => (screen = 'wallets')}>{monogram(account.name, account.address)}</button>
        <div class="identity">
          <span class="name">{account.name}</span>
          <button type="button" class="address" title={account.address} aria-label="Copy address" onclick={copyAddress}>
            {shortAddress(account.address)}
            <!-- The menu's copy icon, popping into a check once copied and back after. -->
            {#key copied}
              <svg width="13" height="13" viewBox="0 0 24 24" aria-hidden="true" in:scale={{ duration: 200, start: 0.5 }}>
                <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  {#if copied}
                    <path d="M5 12.5 9.5 17 19 7.5" />
                  {:else}
                    <rect x="8" y="8" width="13" height="13" rx="2.5" />
                    <path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8" />
                  {/if}
                </g>
              </svg>
            {/key}
          </button>
        </div>
      </div>

      <!-- svelte-ignore a11y_no_static_element_interactions: keys only bubble here from the button and items -->
      <div class="menu-anchor" bind:this={menuAnchor} onkeydown={menuKeys}>
        <button
          type="button"
          class="more"
          aria-label="More options"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          bind:this={moreButton}
          onclick={() => setMenu(!menuOpen)}
          onkeydown={moreKeys}
        >
          <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
            <g fill="currentColor">
              <circle cx="12" cy="4" r="1.75" />
              <circle cx="12" cy="12" r="1.75" />
              <circle cx="12" cy="20" r="1.75" />
            </g>
          </svg>
        </button>

        <div class="dropdown menu" class:open={menuOpen} role="menu" aria-label="Wallet">
          <button type="button" role="menuitem" tabindex="-1" onclick={openSettings}>
            <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
              <path
                d="M21 5h-7M10 5H3m18 7h-9m-4 0H3m18 7h-5m-4 0H3M14 3v4m-6 3v4m8 3v4"
                fill="none"
                stroke="currentColor"
                stroke-width="1.75"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
            Settings
          </button>
          <button type="button" role="menuitem" tabindex="-1" onclick={openAddressBook}>
            <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
              <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                <path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H19v20H7.5A2.5 2.5 0 0 1 5 19.5v-15Z" />
                <path d="M5 19.5A2.5 2.5 0 0 1 7.5 17H19" />
                <circle cx="12" cy="9" r="2.5" />
              </g>
            </svg>
            Address book
          </button>
          <!-- Offers the mode you're not in: the side panel from the popup, the popup from the panel. -->
          {#if hasSidePanel}
            <button type="button" role="menuitem" tabindex="-1" onclick={toggleSidePanel}>
              <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="3" y="4" width="18" height="16" rx="2.5" />
                  {#if preferences.sidePanel}
                    <!-- A popup hanging from the window's top-right corner. -->
                    <rect x="12" y="7" width="6" height="8" rx="1.25" />
                  {:else}
                    <path d="M15 4v16" />
                  {/if}
                </g>
              </svg>
              {preferences.sidePanel ? 'Popup mode' : 'Side panel mode'}
            </button>
          {/if}
          <button type="button" role="menuitem" tabindex="-1" onclick={lockWallet}>
            <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
              <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                <rect x="4" y="11" width="16" height="10" rx="2.5" />
                <path d="M8 11V7.5a4 4 0 0 1 8 0V11" />
              </g>
            </svg>
            Lock wallet
          </button>
        </div>
      </div>
    {:else}
      zandr
    {/if}
  </header>

  <main>
    {#await status then { locked, hasWallet, erased }}
      {#if !hasWallet}
        <div class="erased">
          <span class="erased-icon">
            <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
              <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                <path d="M12 3 4.5 6v5.5c0 4.4 3.1 8.2 7.5 9.5 4.4-1.3 7.5-5.1 7.5-9.5V6L12 3Z" />
                <path d="m9.5 9.5 5 5m0-5-5 5" />
              </g>
            </svg>
          </span>
          <p class="erased-title">{erased ? 'Wallets erased' : 'No wallet yet'}</p>
          <p class="erased-text">
            {erased
              ? 'After too many wrong passwords in a row, zandr erased every wallet and its data on this device. Your coins are still on the blockchain: restore each wallet with its recovery phrase or private key.'
              : 'Create a wallet or import one to start.'}
          </p>
          <button type="button" class="primary" onclick={setUpWallet}>Set up a wallet</button>
        </div>
      {:else if locked}
        <div class="unlock">
          <form onsubmit={unlock}>
            <label for="password">Enter your password</label>
            <input
              id="password"
              type="password"
              placeholder="Password"
              autocomplete="current-password"
              bind:value={password}
              bind:this={passwordInput}
              oninput={() => (error = '')}
              aria-invalid={error ? 'true' : undefined}
              {@attach focus}
            />
            {#if error}
              <p class="error" role="alert">{error}</p>
            {/if}
            <!-- Checking the password takes a moment: the key derivation is deliberately slow. -->
            <button type="submit" class="primary" disabled={busy}>{busy ? 'Decrypting…' : 'Unlock'}</button>
            <button type="button" class="link">Forgot password</button>
          </form>
        </div>
      {:else if screen === 'addressBook'}
        <AddressBook onback={() => (screen = 'home')} />
      {:else if screen === 'reclaim' && account}
        <Reclaim {network} onback={() => (screen = 'home')} onreclaimed={() => loadPortfolio(true)} />
      {:else if screen === 'receive' && account}
        <Receive {account} onback={() => (screen = 'home')} />
      {:else if screen === 'send' && account}
        <Send
          {account}
          coins={portfolio?.coins ?? null}
          minValue={preferences.minCoinValue}
          {network}
          onback={() => (screen = 'home')}
          onsent={() => loadPortfolio(true)}
        />
      {:else if screen === 'swap' && account}
        <Swap
          {account}
          coins={portfolio?.coins ?? null}
          minValue={preferences.minCoinValue}
          {network}
          onback={() => (screen = 'home')}
          onswapped={() => loadPortfolio(true)}
        />
      {:else if screen === 'wallets'}
        <Wallets
          onback={() => (screen = 'home')}
          onswitched={walletSwitched}
          onchanged={() => (status = sendToBackground({ type: 'wallet:getStatus' }))}
        />
      {:else}
        <div class="summary">
          <!-- A placeholder until the first balance arrives, a dash if it couldn't load. -->
          <p class="balance" class:hidden={preferences.hideBalance} class:unknown={!portfolio && entry?.problem}>
            {#if preferences.hideBalance}
              ••••••
            {:else if portfolio}
              {formatUsd(portfolio.value)}
            {:else if entry?.problem}
              —
            {:else}
              <span class="balance-skeleton"></span>
            {/if}
          </p>

          <!-- The icon shows what a click does: crossed out hides the balance, open shows it. -->
          <button
            type="button"
            class="eye"
            aria-label={preferences.hideBalance ? 'Show balance' : 'Hide balance'}
            onclick={toggleBalance}
          >
            <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
              <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                {#if preferences.hideBalance}
                  <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z" />
                  <circle cx="12" cy="12" r="3" />
                {:else}
                  <path d="M10.7 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-2.1 3" />
                  <path d="M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6" />
                  <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
                  <path d="m2 2 20 20" />
                {/if}
              </g>
            </svg>
          </button>
        </div>

        <!-- TODO: wire up explore; until then its button looks and moves like the others but leads nowhere. -->
        <div class="actions">
          <button type="button" class="action">
            <span class="circle">
              <svg class="icon-explore" width="21" height="21" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
                  <circle cx="11" cy="11" r="6.5" />
                  <path d="m20 20-4.4-4.4" />
                </g>
              </svg>
            </span>
            Explore
          </button>
          <button type="button" class="action" onclick={() => (screen = 'receive')}>
            <span class="circle">
              <svg class="icon-receive" width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M18 6 6 18m0-10v10h10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </span>
            Receive
          </button>
          <button type="button" class="action" onclick={() => (screen = 'send')}>
            <span class="circle">
              <svg class="icon-send" width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M6 18 18 6M8 6h10v10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </span>
            Send
          </button>
          <button type="button" class="action" onclick={() => (screen = 'swap')}>
            <span class="circle">
              <svg class="icon-swap" width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path class="top" d="M4 8h16m-4-4 4 4-4 4" />
                  <path class="bottom" d="M20 16H4m4-4-4 4 4 4" />
                </g>
              </svg>
            </span>
            Swap
          </button>
        </div>

        <div class="coins-bar">
          <!-- The lit one is shown; the other is a tap away. -->
          <div class="tabs" role="tablist" aria-label="Wallet">
            <button type="button" role="tab" class="tab" aria-selected={tab === 'coins'} onclick={() => showTab('coins')}>Coins</button>
            <button type="button" role="tab" class="tab" aria-selected={tab === 'defi'} onclick={() => showTab('defi')}>DeFi</button>
            <button type="button" role="tab" class="tab" aria-selected={tab === 'activity'} onclick={() => showTab('activity')}>
              Activity
            </button>
          </div>

          <div class="tools">
            {#if tab === 'coins'}
              <!-- Closing empty token accounts for the SOL they hold. Drawn like the filter beside it. -->
              <button type="button" class="reclaim" aria-label="Reclaim SOL from empty token accounts" title="Reclaim SOL" onclick={() => (screen = 'reclaim')}>
                <svg width="19" height="19" viewBox="0 0 24 24" aria-hidden="true">
                  <!-- Three arrows round a triangle (Lucide's "recycle", ISC). -->
                  <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M7 19H4.815a1.83 1.83 0 0 1-1.57-.881 1.785 1.785 0 0 1-.004-1.784L7.196 9.5" />
                    <path d="M11 19h8.203a1.83 1.83 0 0 0 1.556-.89 1.784 1.784 0 0 0 0-1.775l-1.226-2.12" />
                    <path d="m14 16-3 3 3 3" />
                    <path d="M8.293 13.596 7.196 9.5 3.1 10.598" />
                    <path d="m9.344 5.811 1.093-1.892A1.83 1.83 0 0 1 11.985 3a1.784 1.784 0 0 1 1.546.888l3.943 6.843" />
                    <path d="m13.378 9.633 4.096 1.098 1.097-4.096" />
                  </g>
                </svg>
              </button>
              <!-- svelte-ignore a11y_no_static_element_interactions: keys only bubble here from the button and choices -->
              <div class="filter-anchor" bind:this={filterAnchor} onkeydown={filterKeys}>
                <!-- Lit while a minimum is set, so hidden coins never go unnoticed. -->
                <button
                  type="button"
                  class="filter"
                  class:active={preferences.minCoinValue > 0}
                  aria-label="Filter coins"
                  aria-haspopup="menu"
                  aria-expanded={filterOpen}
                  bind:this={filterButton}
                  onclick={() => setFilter(!filterOpen)}
                  onkeydown={filterButtonKeys}
                >
                  <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M3 6h18M6 12h12m-8 6h4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
                  </svg>
                </button>

                <div class="dropdown filter-menu" class:open={filterOpen}>
                  <p class="filter-label" id="min-coin-value">Minimum value</p>
                  <div class="choices" role="menu" aria-labelledby="min-coin-value">
                    {#each MIN_COIN_VALUE_CHOICES as value (value)}
                      <button
                        type="button"
                        role="menuitemradio"
                        tabindex="-1"
                        aria-checked={preferences.minCoinValue === value}
                        onclick={() => setMinCoinValue(value)}
                      >
                        {value === 0 ? 'None' : `>${formatUsd(value)}`}
                      </button>
                    {/each}
                  </div>
                </div>
              </div>
            {/if}
          </div>
        </div>

        {#if tab === 'coins'}
          <Coins {entry} hideBalance={preferences.hideBalance} minValue={preferences.minCoinValue} onsettings={openNetworkSettings} />
        {:else if tab === 'defi'}
          <DeFi />
        {:else}
          <!-- Anew for each wallet and network: another wallet's history never shows, not even briefly. -->
          {#key `${network}:${address}`}
            <Activity {network} hideBalance={preferences.hideBalance} onsettings={openNetworkSettings} />
          {/key}
        {/if}
      {/if}
    {:catch}
      <p class="message muted">Background service is unavailable</p>
    {/await}
  </main>

  <Notices />
</div>

<style>
  .layout {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    /* Soft ivory light falling from the top edge. */
    background: radial-gradient(120% 55% at 50% -12%, var(--glow), transparent 70%);
  }

  header {
    position: relative;
    flex: none;
    display: flex;
    align-items: center;
    justify-content: center;
    height: 58px;
    padding: 0 16px;
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.035em;
  }

  /* Divider that fades out toward both edges; solid and darker once unlocked. */
  header::after {
    content: '';
    position: absolute;
    right: 0;
    bottom: 0;
    left: 0;
    height: 1px;
    background: linear-gradient(90deg, transparent, var(--hairline-strong), transparent);
    opacity: 0.6;
  }

  .unlocked header {
    justify-content: space-between;
    gap: 12px;
  }

  .unlocked header::after {
    background: var(--divider);
    opacity: 1;
  }

  .account {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }

  /* Pulled right so the dots line up with the content edge, not the hover circle's. */
  .menu-anchor {
    position: relative;
    flex: none;
    margin-right: -8px;
  }

  .more {
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: none;
    color: var(--muted);
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .more:hover {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .more:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .menu-anchor:has(.open) .more {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  /* Same panel, items and motion as the website's channel picker. */
  .dropdown {
    position: absolute;
    top: calc(100% + 8px);
    right: 0;
    z-index: 2;
    padding: 6px;
    border: 1px solid var(--hairline);
    border-radius: 16px;
    background: var(--menu);
    box-shadow: 0 16px 40px var(--shadow);
    opacity: 0;
    visibility: hidden;
    transform: translateY(-4px);
    transition:
      opacity 0.15s var(--ease),
      transform 0.15s var(--ease),
      visibility 0s 0.15s;
  }

  .dropdown.open {
    opacity: 1;
    visibility: visible;
    transform: none;
    transition-delay: 0s;
  }

  .menu {
    display: flex;
    flex-direction: column;
    min-width: 190px;
  }

  .menu button {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border: 0;
    border-radius: 10px;
    background: none;
    color: var(--muted);
    font-size: 15px;
    font-weight: 500;
    letter-spacing: normal;
    text-align: left;
    white-space: nowrap;
    cursor: pointer;
    outline: none;
    transition:
      color 0.15s var(--ease),
      background-color 0.15s var(--ease);
  }

  .menu button:hover,
  .menu button:focus-visible {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .menu svg {
    flex: none;
  }


  /* Same round hover target as the dots in the header. */
  .eye {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: none;
    color: var(--muted);
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .eye:hover {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .eye:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  /* The active wallet, by two letters (monogram). */
  .avatar {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: var(--fill);
    color: var(--fg);
    font: inherit;
    font-size: 13px;
    font-weight: 600;
    letter-spacing: -0.01em;
    cursor: pointer;
    transition: background-color 0.2s var(--ease);
  }

  .avatar:hover {
    background: var(--fill-strong);
  }

  .avatar:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  .identity {
    display: flex;
    flex-direction: column;
    min-width: 0;
    line-height: 1.25;
    letter-spacing: 0;
  }

  .name {
    overflow: hidden;
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .address {
    display: flex;
    align-self: flex-start;
    align-items: center;
    gap: 5px;
    padding: 0;
    border: 0;
    background: none;
    color: var(--muted);
    font-size: 13px;
    font-weight: 400;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  .address:hover {
    color: var(--fg);
  }

  .address:focus-visible {
    border-radius: 4px;
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  main {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow-y: auto;
    /* Room at the end for the notices, while there are any. */
    padding: 0 16px calc(22px + var(--notices-height, 0px));
    /* Scrolls by wheel and touch, without a scrollbar. */
    scrollbar-width: none;
  }

  .message {
    margin: auto;
  }

  /* Four evenly spread buttons, each centered in its quarter of the width. */
  .actions {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    justify-items: center;
    margin-top: 32px;
  }

  .action {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 0;
    border: 0;
    background: none;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  /* Only the label dims; the icon in the circle stays bright. */
  .circle {
    color: var(--fg);
  }

  .action:hover {
    color: var(--fg);
  }

  /* Same fill as the avatar. */
  .circle {
    display: grid;
    place-items: center;
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: var(--fill);
    transition:
      background-color 0.2s var(--ease),
      transform 0.12s var(--ease);
  }

  .action:hover .circle {
    background: var(--fill-strong);
  }

  /* On hover or keyboard focus, each icon acts out its button with a little spring: the
     magnifier looks around, Receive's arrow comes in, Send's goes out, Swap's trade places. */
  .circle svg,
  .icon-swap path {
    transition: transform 0.4s cubic-bezier(0.34, 1.56, 0.64, 1);
  }

  .action:hover .icon-explore,
  .action:focus-visible .icon-explore {
    transform: rotate(-14deg) scale(1.1);
  }

  .action:hover .icon-receive,
  .action:focus-visible .icon-receive {
    transform: translate(-2px, 2px);
  }

  .action:hover .icon-send,
  .action:focus-visible .icon-send {
    transform: translate(2px, -2px);
  }

  .action:hover .icon-swap .top,
  .action:focus-visible .icon-swap .top {
    transform: translateX(2.5px);
  }

  .action:hover .icon-swap .bottom,
  .action:focus-visible .icon-swap .bottom {
    transform: translateX(-2.5px);
  }

  .action:active .circle {
    transform: scale(0.95);
  }

  .action:focus-visible {
    outline: none;
  }

  .action:focus-visible .circle {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  .coins-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 32px;
  }

  .tabs {
    display: flex;
    gap: 18px;
  }

  /* Headings that switch: the shown one bright, the other muted. */
  .tab {
    padding: 0;
    border: 0;
    background: none;
    /* Darker than the usual muted gray, so the shown tab clearly leads. */
    color: rgba(var(--ink), 0.35);
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.01em;
    line-height: 1.5;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  .tab:hover,
  .tab[aria-selected='true'] {
    color: var(--fg);
  }

  .tab:focus-visible {
    border-radius: 6px;
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  /* Pulled right like the header's dots, so the two icons line up. The button is taller than
     the title; trimmed above and below, it doesn't push the title down. */
  /* Pulled right so the last button's icon lines up with the content edge, not its hover circle. */
  .tools {
    display: flex;
    flex: none;
    align-items: center;
    margin: -5px -8px -5px 0;
  }

  .filter-anchor {
    position: relative;
    flex: none;
  }

  /* As the filter: gray, white under the pointer. */
  .reclaim {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: none;
    color: var(--muted);
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .reclaim:hover {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .reclaim:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }



  /* Same round hover target as the eye and the dots. */
  .filter {
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: none;
    color: var(--muted);
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .filter:hover,
  .filter[aria-expanded='true'] {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .filter.active {
    color: var(--fg);
  }

  .filter:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  /* Anchored to a 36px button: sized by its row of choices instead. */
  .filter-menu {
    width: max-content;
  }

  .filter-label {
    margin: 0;
    padding: 0 6px 3px;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
  }

  /* One row of equal buttons, each as wide as the widest label. */
  .choices {
    display: grid;
    grid-auto-columns: 1fr;
    grid-auto-flow: column;
    gap: 4px;
  }

  .choices button {
    height: 36px;
    padding: 0 12px;
    border: 0;
    border-radius: 10px;
    background: none;
    color: var(--muted);
    font-size: 14px;
    font-weight: 500;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    cursor: pointer;
    outline: none;
    transition:
      color 0.15s var(--ease),
      background-color 0.15s var(--ease);
  }

  .choices button:hover,
  .choices button:focus-visible {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .choices button[aria-checked='true'] {
    background: var(--fill-strong);
    color: var(--fg);
  }

  /* The tight tracking suits digits but runs the dots together. */
  .balance.hidden {
    letter-spacing: 0.1em;
  }

  .balance.unknown {
    color: var(--muted);
  }

  .balance-skeleton {
    display: block;
    width: 120px;
    height: 36px;
    border-radius: 10px;
    background: var(--fill);
    animation: pulse 1.4s ease-in-out infinite;
  }

  @keyframes pulse {
    50% {
      opacity: 0.45;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .balance-skeleton {
      animation: none;
    }
  }

  /* The balance sits at the center, nudged left a little so the pair with the eye reads as
     centered; the eye hangs off its right side without pushing it over. */
  .summary {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    column-gap: 4px;
    margin-top: 32px;
    transform: translateX(-8px);
  }

  .summary .balance {
    grid-column: 2;
  }

  .summary .eye {
    grid-column: 3;
    justify-self: start;
  }

  .balance {
    margin: 0;
    font-size: 36px;
    font-weight: 600;
    line-height: 1;
    letter-spacing: -0.04em;
    font-variant-numeric: tabular-nums;
  }

  .error {
    margin: -2px 0 0;
    color: var(--danger);
    font-size: 15px;
    text-align: center;
  }

  input[aria-invalid='true'] {
    border-color: var(--danger);
  }

  .unlock {
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  /* Nothing left to unlock: why, and the way back. */
  .erased {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding-top: 72px;
    text-align: center;
  }

  .erased-icon {
    display: grid;
    place-items: center;
    width: 56px;
    height: 56px;
    margin-bottom: 18px;
    border-radius: 50%;
    background: rgba(240, 87, 93, 0.12);
    color: var(--down);
  }

  .erased-title {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.015em;
  }

  .erased-text {
    max-width: 290px;
    margin: 8px 0 0;
    color: var(--muted);
    font-size: 14px;
    line-height: 1.5;
  }

  .erased .primary {
    align-self: stretch;
  }

  /* Empty upper half, so the form starts just below the middle. */
  .unlock::before {
    content: '';
    flex: 1;
  }

  form {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-top: 16px;
  }

  label {
    margin-bottom: 6px;
    text-align: center;
    font-size: 20px;
    font-weight: 500;
    letter-spacing: -0.015em;
  }

  input {
    height: 52px;
    padding: 0 18px;
    border: 1px solid var(--hairline);
    border-radius: var(--radius);
    background: var(--input);
    caret-color: var(--fg);
    font-family: 'Geist Password', 'Geist Variable', system-ui, sans-serif;
    font-size: 28px;
    letter-spacing: 1px;
    outline: none;
  }

  input:placeholder-shown {
    font-family: 'Geist Password Empty', 'Geist Variable', system-ui, sans-serif;
  }

  input::placeholder {
    color: var(--muted);
    font-size: 18px;
    letter-spacing: -0.01em;
  }

  .primary {
    margin-top: auto;
    height: 48px;
    border: 0;
    border-radius: 999px;
    background: var(--accent);
    color: var(--on-accent);
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.01em;
    cursor: pointer;
    transition:
      background-color 0.2s var(--ease),
      transform 0.12s var(--ease);
  }

  .primary:hover {
    background: var(--accent-hover);
  }

  .primary:active {
    transform: scale(0.985);
  }

  /* The label says what's happening; the cursor stays as it is. */
  .primary:disabled {
    opacity: 0.6;
    cursor: default;
  }

  .primary:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 3px;
  }

  .link {
    align-self: center;
    padding: 6px 8px;
    border: 0;
    background: none;
    color: var(--muted);
    font-size: 18px;
    letter-spacing: 0.01em;
    cursor: pointer;
    transition: color 0.2s var(--ease);
  }

  .link:hover,
  .link:focus-visible {
    color: var(--fg);
  }

  .link:focus-visible {
    outline: none;
    text-decoration: underline;
    text-underline-offset: 4px;
  }

  .muted {
    color: var(--muted);
  }
</style>
