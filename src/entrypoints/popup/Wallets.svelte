<script lang="ts">
  // The wallet switcher, opened from the avatar: every wallet in the vault, the active one
  // highlighted, adding more (a new one with a recovery phrase of its own, or an import), and per
  // wallet a menu to see its private key or remove it.
  import { onDestroy, onMount, tick } from 'svelte';
  import { flip } from 'svelte/animate';
  import { scale } from 'svelte/transition';
  import { monogram, shortAddress, wrongPassword } from '@/lib/format';
  import {
    WALLET_NAME_MAX_LENGTH,
    sendToBackground,
    type SecretCheck,
    type WalletAddResult,
    type WalletSecret,
    type WalletSummary,
  } from '@/lib/messages';

  // onswitched: another wallet is now active (go home). onchanged: the list changed in place.
  let { onback, onswitched, onchanged }: { onback: () => void; onswitched: () => void; onchanged: () => void } = $props();

  // A new wallet takes two steps: its recovery phrase, written down (create), then its name
  // (create-name).
  type Mode = 'list' | 'add' | 'create' | 'create-name' | 'phrase' | 'key' | 'export' | 'show-phrase' | 'remove';
  let mode = $state<Mode>('list');

  let wallets = $state<WalletSummary[]>([]);
  let activeId = $state('');

  async function load() {
    const result = await sendToBackground({ type: 'wallets:list' });
    if ('wallets' in result) ({ wallets, activeId } = result);
  }

  onMount(load);

  // A wallet's menu (three dots). It opens upward when there's no room below in the popup.
  let menuFor = $state<string | null>(null);
  let menuUp = $state(false);

  async function toggleMenu(id: string, event: MouseEvent) {
    if (menuFor === id) {
      menuFor = null;
      return;
    }
    const button = (event.currentTarget as HTMLElement).getBoundingClientRect();
    menuUp = button.bottom + 112 > innerHeight;
    menuFor = id;
    await tick();
    document.querySelector<HTMLElement>('.row-menu [role="menuitem"]:not(:disabled)')?.focus();
  }

  function closeMenuOutside(event: MouseEvent) {
    if (menuFor && !(event.target as Element).closest('.row-actions')) menuFor = null;
  }

  // The wallet a private key, recovery phrase or removal screen is about.
  let target = $state<WalletSummary | null>(null);

  function open(next: 'export' | 'show-phrase' | 'remove', wallet: WalletSummary) {
    menuFor = null;
    target = wallet;
    password = '';
    understood = false;
    privateKey = '';
    shownWords = [];
    error = null;
    mode = next;
  }

  // Both ask for the password again, even though the wallet is unlocked.
  let password = $state('');
  let understood = $state(false);
  let privateKey = $state('');
  let keyCopied = $state(false);

  async function showKey(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    error = null;
    try {
      const result = await sendToBackground({ type: 'wallets:exportKey', id: target!.id, password });
      password = '';
      if (result.ok) privateKey = result.key;
      else error = { field: 'secret', message: wrongPassword(result) };
    } catch {
      error = { field: 'secret', message: "Couldn't show the key. Please try again." };
    } finally {
      busy = false;
    }
  }

  // A wallet's recovery phrase, for one that came by it: and every wallet it restores.
  let shownWords = $state<string[]>([]);
  let phraseWallets = $state<string[]>([]);
  let shownCopied = $state(false);

  async function showPhrase(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    error = null;
    try {
      const result = await sendToBackground({ type: 'wallets:exportPhrase', id: target!.id, password });
      password = '';
      if (result.ok) {
        shownWords = result.words;
        phraseWallets = result.wallets;
        shownCopied = false;
      } else if (result.error === 'no-phrase') {
        error = { field: 'secret', message: 'This wallet came by its private key: it has no recovery phrase.' };
      } else {
        error = { field: 'secret', message: wrongPassword(result) };
      }
    } catch {
      error = { field: 'secret', message: "Couldn't show the phrase. Please try again." };
    } finally {
      busy = false;
    }
  }

  async function copyShownPhrase() {
    try {
      await navigator.clipboard.writeText(shownWords.join(' '));
      shownCopied = true;
    } catch {
      // The browser refused; the button stays as it was.
    }
  }

  async function copyKey() {
    try {
      await navigator.clipboard.writeText(privateKey);
      keyCopied = true;
    } catch {
      // The browser refused; the button stays as it was.
    }
  }

  async function remove(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    error = null;
    try {
      const result = await sendToBackground({ type: 'wallets:remove', id: target!.id, password });
      password = '';
      if (result.ok) {
        await load();
        onchanged();
        mode = 'list';
      } else {
        error = { field: 'secret', message: result.error === 'last-wallet' ? "Your only wallet can't be removed." : wrongPassword(result) };
      }
    } catch {
      error = { field: 'secret', message: "Couldn't remove the wallet. Please try again." };
    } finally {
      busy = false;
    }
  }

  // The key and the phrase never outlive the screen that showed them.
  onDestroy(() => {
    privateKey = '';
    shownWords = [];
  });
  $effect(() => {
    if (mode !== 'export') privateKey = '';
    if (mode !== 'show-phrase') shownWords = [];
  });

  // The address under a wallet's name copies it, without switching to it; its icon turns into a
  // check for a moment, as in the header.
  let copiedId = $state<string | null>(null);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  async function copyAddress(wallet: WalletSummary) {
    try {
      await navigator.clipboard.writeText(wallet.address);
    } catch {
      return;
    }
    copiedId = wallet.id;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copiedId = null), 1500);
  }

  onDestroy(() => clearTimeout(copiedTimer));

  async function choose(id: string) {
    if (id !== activeId) await sendToBackground({ type: 'wallets:switch', id });
    onswitched();
  }

  // Reordering. A wallet's avatar is its handle: dragged up or down, the rows it passes make room,
  // and dropped, the new order is kept (in the vault). Pressed without a drag, it picks the wallet,
  // as the rest of its row does. Arrow keys move it a place at a time.
  let list = $state<HTMLUListElement>();
  type Drag = { id: string; from: number; to: number; startY: number; offset: number; moved: boolean; tops: number[]; height: number; step: number };
  let drag = $state<Drag | null>(null);

  function grab(event: PointerEvent, id: string) {
    if (event.button !== 0 || !list || wallets.length < 2) return;
    const rects = [...list.children].map((row) => row.getBoundingClientRect());
    const from = wallets.findIndex((wallet) => wallet.id === id);
    const step = rects.length > 1 ? rects[1]!.top - rects[0]!.top : rects[0]!.height;
    drag = { id, from, to: from, startY: event.clientY, offset: 0, moved: false, tops: rects.map((rect) => rect.top), height: rects[from]!.height, step };
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }

  function pull(event: PointerEvent) {
    if (!drag) return;
    // Let go outside the window, where the release went unseen: settled where it was shown.
    if (event.buttons === 0) return release();
    const offset = event.clientY - drag.startY;
    // A small slip of the hand is still a press.
    if (!drag.moved && Math.abs(offset) < 4) return;
    drag.moved = true;
    // Kept within the list.
    const top = drag.tops[drag.from]!;
    drag.offset = Math.max(drag.tops[0]! - top, Math.min(offset, drag.tops.at(-1)! - top));
    // Its place: after every row still above it. A row it started below stays above until it's
    // passed; one it started above, once it's reached (dragged all the way either way, it's level
    // with the first or last row).
    const middle = top + drag.offset + drag.height / 2;
    const from = drag.from;
    drag.to = drag.tops.filter((rowTop, i) => {
      const rowMiddle = rowTop + drag!.height / 2;
      return i < from ? rowMiddle < middle : i > from && rowMiddle <= middle;
    }).length;
  }

  // How far a row stands aside while another is dragged past it.
  function aside(index: number): number {
    if (!drag || !drag.moved || index === drag.from) return 0;
    if (drag.from < drag.to && index > drag.from && index <= drag.to) return -drag.step;
    if (drag.to < drag.from && index >= drag.to && index < drag.from) return drag.step;
    return 0;
  }

  async function moveTo(from: number, to: number) {
    if (from === to) return;
    const next = [...wallets];
    next.splice(to, 0, ...next.splice(from, 1));
    wallets = next;
    await sendToBackground({ type: 'wallets:reorder', ids: next.map((wallet) => wallet.id) }).catch(() => load());
  }

  // The drag over: dropped where it shows. Also when the press ends unseen (the window lost the
  // pointer, or its focus): nothing stays caught mid-drag.
  function release() {
    if (!drag) return;
    const { id, from, to, moved } = drag;
    drag = null;
    if (!moved) choose(id);
    else moveTo(from, to);
  }

  function interrupt() {
    if (drag?.moved) release();
    else drag = null;
  }

  function nudge(event: KeyboardEvent, index: number) {
    const to = event.key === 'ArrowUp' ? index - 1 : event.key === 'ArrowDown' ? index + 1 : null;
    if (to === null || to < 0 || to >= wallets.length) return;
    event.preventDefault();
    moveTo(index, to);
  }

  // Adding a wallet.
  let name = $state('');
  let secretText = $state('');
  let error = $state<{ field: 'name' | 'secret'; message: string } | null>(null);
  let busy = $state(false);

  function start(next: Mode) {
    mode = next;
    name = `Wallet ${wallets.length + 1}`;
    secretText = '';
    error = null;
    if (next === 'create') newPhrase();
  }

  // A new wallet's recovery phrase: a fresh one each time the create flow starts, kept while going
  // between its two steps, hidden until asked for, and dropped when leaving the flow.
  let words = $state<string[]>([]);
  let revealed = $state(false);
  let saved = $state(false);
  let phraseCopied = $state(false);

  async function newPhrase() {
    words = [];
    revealed = saved = phraseCopied = false;
    try {
      ({ words } = await sendToBackground({ type: 'phrase:generate' }));
    } catch {
      error = { field: 'secret', message: "Couldn't make a recovery phrase. Please try again." };
    }
  }

  async function copyPhrase() {
    try {
      await navigator.clipboard.writeText(words.join(' '));
      phraseCopied = true;
    } catch {
      // The browser refused; the button stays as it was.
    }
  }

  onDestroy(() => (words = []));
  $effect(() => {
    if (mode !== 'create' && mode !== 'create-name') words = [];
  });

  const secretErrors: Record<Exclude<SecretCheck, { ok: true }>['error'], (index?: number) => string> = {
    'word-count': () => 'A recovery phrase has 12 or 24 words.',
    'unknown-word': (index) => `Word #${(index ?? 0) + 1} isn't in the recovery phrase word list. Check its spelling.`,
    checksum: () => "These words don't form a valid recovery phrase. Check their spelling and order.",
    'invalid-key': () => "This isn't a valid Solana private key. Check that you copied all of it.",
  };

  function explain(result: Extract<WalletAddResult, { ok: false }>): { field: 'name' | 'secret'; message: string } {
    if (result.error === 'secret') {
      const check = result.check as Extract<SecretCheck, { ok: false }>;
      return { field: 'secret', message: secretErrors[check.error]('index' in check ? check.index : undefined) };
    }
    if (result.error === 'name') return { field: 'name', message: `Give it a name of up to ${WALLET_NAME_MAX_LENGTH} characters.` };
    return { field: 'secret', message: `This wallet is already added as “${result.conflict}”.` };
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    error = null;
    try {
      let result: WalletAddResult;
      if (mode === 'create-name') {
        result = await sendToBackground({ type: 'wallets:create', name, words });
      } else {
        const secret: WalletSecret =
          mode === 'phrase'
            ? { kind: 'phrase', words: secretText.trim().toLowerCase().split(/\s+/) }
            : { kind: 'privateKey', key: secretText.trim() };
        result = await sendToBackground({ type: 'wallets:import', secret, name });
      }
      // A new wallet becomes the active one.
      if (result.ok) onswitched();
      else error = explain(result);
    } catch {
      error = { field: 'secret', message: "Couldn't add the wallet. Please try again." };
    } finally {
      busy = false;
    }
  }

  const titles: Record<Mode, string> = {
    list: 'Wallets',
    add: 'Add wallet',
    create: 'New wallet',
    'create-name': 'New wallet',
    phrase: 'Import recovery phrase',
    key: 'Import private key',
    export: 'Private key',
    'show-phrase': 'Recovery phrase',
    remove: 'Remove wallet',
  };

  function back() {
    if (mode === 'list') onback();
    else if (mode === 'create-name') mode = 'create';
    else mode = mode === 'add' || mode === 'export' || mode === 'show-phrase' || mode === 'remove' ? 'list' : 'add';
  }
</script>

<svelte:document onclick={closeMenuOutside} onkeydown={(event) => event.key === 'Escape' && (menuFor = null)} />

<svelte:window onblur={interrupt} />

<div class="screen">
  <div class="bar">
    <button type="button" class="icon-button" aria-label="Back" onclick={back}>
      <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h2>{titles[mode]}</h2>
    {#if mode === 'list'}
      <button type="button" class="icon-button" aria-label="Add wallet" onclick={() => (mode = 'add')}>
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
        </svg>
      </button>
    {:else}
      <span class="spacer"></span>
    {/if}
  </div>

  {#if mode === 'list'}
    <ul class="list wallets" class:sorting={drag?.moved} bind:this={list}>
      {#each wallets as wallet, index (wallet.id)}
        <!-- The active wallet is highlighted. The row switches to a wallet (its name is the button,
             stretched over the row), the address copies it and the dots open its menu. With more
             than one wallet, the avatar moves it up or down the list. -->
        <li
          class:active={wallet.id === activeId}
          class:dragged={drag?.moved && drag.id === wallet.id}
          style:transform={drag?.moved ? `translateY(${drag.id === wallet.id ? drag.offset : aside(index)}px)` : null}
          animate:flip={{ duration: 180 }}
        >
          {#if wallets.length > 1}
            <button
              type="button"
              class="initial handle"
              aria-label="Move {wallet.name} up or down"
              onpointerdown={(event) => grab(event, wallet.id)}
              onpointermove={pull}
              onpointerup={release}
              onlostpointercapture={interrupt}
              onpointercancel={interrupt}
              onkeydown={(event) => nudge(event, index)}
            >
              <span class="letters">{monogram(wallet.name, wallet.address)}</span>
              <svg class="arrows" width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 4v16M8 8l4-4 4 4M8 16l4 4 4-4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </button>
          {:else}
            <span class="initial" aria-hidden="true">{monogram(wallet.name, wallet.address)}</span>
          {/if}
          <span class="who">
            <button type="button" class="pick" aria-current={wallet.id === activeId ? 'true' : undefined} onclick={() => choose(wallet.id)}>
              {wallet.name}
            </button>
            <button type="button" class="address" title={wallet.address} aria-label="Copy the address of {wallet.name}" onclick={() => copyAddress(wallet)}>
              {shortAddress(wallet.address)}
              {#key copiedId === wallet.id}
                <svg width="13" height="13" viewBox="0 0 24 24" aria-hidden="true" in:scale={{ duration: 200, start: 0.5 }}>
                  <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    {#if copiedId === wallet.id}
                      <path d="M5 12.5 9.5 17 19 7.5" />
                    {:else}
                      <rect x="8" y="8" width="13" height="13" rx="2.5" />
                      <path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8" />
                    {/if}
                  </g>
                </svg>
              {/key}
            </button>
          </span>

          <div class="row-actions">
            <button
              type="button"
              class="icon-button small dots"
              aria-label="{wallet.name} options"
              aria-haspopup="menu"
              aria-expanded={menuFor === wallet.id}
              onclick={(event) => toggleMenu(wallet.id, event)}
            >
              <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="currentColor">
                  <circle cx="12" cy="4" r="1.75" />
                  <circle cx="12" cy="12" r="1.75" />
                  <circle cx="12" cy="20" r="1.75" />
                </g>
              </svg>
            </button>

            {#if menuFor === wallet.id}
              <div class="row-menu" class:up={menuUp} role="menu" aria-label="{wallet.name} options" transition:scale={{ duration: 120, start: 0.96 }}>
                <!-- The phrase only for a wallet that came by it; one imported by its key has only the key. -->
                {#if wallet.source === 'phrase'}
                  <button type="button" role="menuitem" onclick={() => open('show-phrase', wallet)}>
                    <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                      <path d="M4 6h16M4 12h16M4 18h10" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" />
                    </svg>
                    Show recovery phrase
                  </button>
                {/if}
                <button type="button" role="menuitem" onclick={() => open('export', wallet)}>
                  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                    <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                      <path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4m2-2-9.6 9.6" />
                      <circle cx="7.5" cy="15.5" r="5.5" />
                    </g>
                  </svg>
                  Show private key
                </button>
                <button type="button" role="menuitem" class="danger" disabled={wallets.length === 1} onclick={() => open('remove', wallet)}>
                  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M4 7h16m-10 4v6m4-6v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.75"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                  Remove wallet
                </button>
              </div>
            {/if}
          </div>
        </li>
      {/each}
    </ul>
  {:else if mode === 'add'}
    <!-- Three ways in, laid out like the onboarding's choices. -->
    <ul class="list">
      {#each [{ id: 'create', title: 'Create new wallet', text: 'With a new recovery phrase of its own' }, { id: 'phrase', title: 'Import recovery phrase', text: 'A wallet you have, by its 12 or 24 words' }, { id: 'key', title: 'Import private key', text: 'A single wallet, by its private key' }] as option}
        <li>
          <button type="button" class="wallet" onclick={() => start(option.id as Mode)}>
            <span class="initial" aria-hidden="true">
              <svg width="18" height="18" viewBox="0 0 24 24">
                <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  {#if option.id === 'create'}
                    <path d="M12 5v14M5 12h14" />
                  {:else if option.id === 'phrase'}
                    <path d="M4 6h16M4 12h16M4 18h10" />
                  {:else}
                    <path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4m2-2-9.6 9.6" />
                    <circle cx="7.5" cy="15.5" r="5.5" />
                  {/if}
                </g>
              </svg>
            </span>
            <span class="who">
              <strong>{option.title}</strong>
              <span>{option.text}</span>
            </span>
            <svg class="chevron" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
              <path d="m9 6 6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
        </li>
      {/each}
    </ul>
  {:else if mode === 'export' && target}
    <div class="warning">
      <span class="warning-icon">
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M10.3 4.2 2.6 17.5A2 2 0 0 0 4.3 20.5h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0ZM12 9.5v4m0 3.5h.01"
            fill="none"
            stroke="currentColor"
            stroke-width="1.75"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <p>
        <strong>Anyone with this key controls “{target.name}”.</strong> Never share it or type it into a website. zandr will
        never ask for it.
      </p>
    </div>

    {#if privateKey}
      <div class="key-box">
        <code>{privateKey}</code>
      </div>
      <button type="button" class="primary" onclick={copyKey}>{keyCopied ? 'Copied' : 'Copy private key'}</button>
      <p class="note">It's hidden again when you leave this screen.</p>
    {:else}
      <form class="form" onsubmit={showKey}>
        <label class="field">
          <span>Password</span>
          <input
            type="password"
            bind:value={password}
            oninput={() => (error = null)}
            aria-invalid={error ? 'true' : undefined}
            autocomplete="current-password"
          />
        </label>
        {#if error}
          <p class="error" role="alert">{error.message}</p>
        {/if}
        <button type="submit" class="primary" disabled={!password || busy}>{busy ? 'Decrypting…' : 'Show private key'}</button>
      </form>
    {/if}
  {:else if mode === 'show-phrase' && target}
    <div class="warning">
      <span class="warning-icon">
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M10.3 4.2 2.6 17.5A2 2 0 0 0 4.3 20.5h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0ZM12 9.5v4m0 3.5h.01"
            fill="none"
            stroke="currentColor"
            stroke-width="1.75"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      <p>
        <strong>Anyone with this phrase controls “{target.name}”</strong>, and every other wallet made from it. Never share it or
        type it into a website. zandr will never ask for it.
      </p>
    </div>

    {#if shownWords.length}
      <div class="phrase-card">
        <div class="phrase-head">
          <span>Recovery phrase</span>
          <button type="button" class="copy" onclick={copyShownPhrase}>{shownCopied ? 'Copied' : 'Copy'}</button>
        </div>
        <div class="phrase">
          <ol class="words">
            {#each shownWords as word, index (index)}
              <li><span class="index">{index + 1}</span><span class="word">{word}</span></li>
            {/each}
          </ol>
        </div>
      </div>
      {#if phraseWallets.length > 1}
        <p class="note">It restores all of these wallets: {phraseWallets.join(', ')}.</p>
      {/if}
      <!-- Other apps can read the clipboard, and clipboard sync can carry it to the cloud. -->
      {#if shownCopied}
        <p class="note" role="status">Paste it somewhere safe and offline, then copy something else over it.</p>
      {/if}
      <p class="note">It's hidden again when you leave this screen.</p>
    {:else}
      <form class="form" onsubmit={showPhrase}>
        <label class="field">
          <span>Password</span>
          <input
            type="password"
            bind:value={password}
            oninput={() => (error = null)}
            aria-invalid={error ? 'true' : undefined}
            autocomplete="current-password"
          />
        </label>
        {#if error}
          <p class="error" role="alert">{error.message}</p>
        {/if}
        <button type="submit" class="primary" disabled={!password || busy}>{busy ? 'Decrypting…' : 'Show recovery phrase'}</button>
      </form>
    {/if}
  {:else if mode === 'remove' && target}
    <form class="form" onsubmit={remove}>
      <div class="warning">
        <span class="warning-icon">
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M4 7h16m-10 4v6m4-6v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"
              fill="none"
              stroke="currentColor"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <p>
          <strong>“{target.name}” will be removed from zandr on this device.</strong> Its funds stay on the blockchain, but
          getting it back takes its recovery phrase or private key.
        </p>
      </div>

      <label class="check">
        <input type="checkbox" bind:checked={understood} />
        <span>I have this wallet's recovery phrase or private key</span>
      </label>

      <label class="field">
        <span>Password</span>
        <input
          type="password"
          bind:value={password}
          oninput={() => (error = null)}
          aria-invalid={error ? 'true' : undefined}
          autocomplete="current-password"
        />
      </label>
      {#if error}
        <p class="error" role="alert">{error.message}</p>
      {/if}
      <button type="submit" class="primary destructive" disabled={!understood || !password || busy}>
        {busy ? 'Removing…' : 'Remove wallet'}
      </button>
    </form>
  {:else if mode === 'create'}
    <div class="form">
      <div class="warning">
        <span class="warning-icon">
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M10.3 4.2 2.6 17.5A2 2 0 0 0 4.3 20.5h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0ZM12 9.5v4m0 3.5h.01"
              fill="none"
              stroke="currentColor"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <p>
          <strong>This wallet gets a recovery phrase of its own.</strong> Write the words down in order and keep them offline.
          Lose them, and this wallet can't be recovered.
        </p>
      </div>

      <div class="phrase-card">
        <div class="phrase-head">
          <span>Recovery phrase</span>
          <button type="button" class="copy" onclick={copyPhrase} disabled={!revealed}>{phraseCopied ? 'Copied' : 'Copy'}</button>
        </div>
        <div class="phrase">
          <ol class="words" class:concealed={!revealed} aria-hidden={!revealed}>
            {#each words as word, index (index)}
              <li><span class="index">{index + 1}</span><span class="word">{word}</span></li>
            {/each}
          </ol>
          {#if !revealed}
            <button type="button" class="reveal" disabled={!words.length} onclick={() => (revealed = true)}>
              <strong>Reveal recovery phrase</strong>
              <span>Make sure no one can see your screen</span>
            </button>
          {/if}
        </div>
      </div>

      <!-- Other apps can read the clipboard, and clipboard sync can carry it to the cloud. -->
      {#if phraseCopied}
        <p class="note" role="status">Paste it somewhere safe and offline, then copy something else over it.</p>
      {/if}
      {#if error}
        <p class="error" role="alert">{error.message}</p>
      {/if}

      <label class="check">
        <input type="checkbox" bind:checked={saved} disabled={!revealed} />
        <span>I've written down this wallet's recovery phrase</span>
      </label>

      <button type="button" class="primary" disabled={!saved || !words.length} onclick={() => (mode = 'create-name')}>Continue</button>
    </div>
  {:else}
    <form class="form" onsubmit={submit}>
      <label class="field">
        <span>Name</span>
        <input
          bind:value={name}
          oninput={() => (error = null)}
          maxlength={WALLET_NAME_MAX_LENGTH}
          aria-invalid={error?.field === 'name' ? 'true' : undefined}
          autocomplete="off"
          spellcheck="false"
        />
      </label>

      {#if mode === 'create-name'}
        <p class="note">Its recovery phrase is encrypted with your password and stays on this device.</p>
      {:else}
        <label class="field">
          <span>{mode === 'phrase' ? 'Recovery phrase' : 'Private key'}</span>
          <textarea
            bind:value={secretText}
            oninput={() => (error = null)}
            rows={mode === 'phrase' ? 4 : 3}
            placeholder={mode === 'phrase' ? '12 or 24 words, separated by spaces' : 'Base58 key or a JSON byte array'}
            aria-invalid={error?.field === 'secret' ? 'true' : undefined}
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
          ></textarea>
        </label>
        <p class="note">It's encrypted with your password and stays on this device.</p>
      {/if}

      {#if error}
        <p class="error" role="alert">{error.message}</p>
      {/if}

      <button type="submit" class="primary" disabled={!name.trim() || (mode !== 'create-name' && !secretText.trim()) || busy}>
        {busy ? 'Adding…' : mode === 'create-name' ? 'Create wallet' : 'Import wallet'}
      </button>
    </form>
  {/if}
</div>

<style>
  /* Prefixed with .screen to outrank screen.css's shared list rules (Svelte doesn't raise the
     specificity of its scoped selectors). */
  .screen .list li {
    padding: 0;
  }

  /* Wallet rows: highlighted when active, no dividers between the rounded rows. The dots sit
     right under the header's dots and the add button. */
  .screen .wallets li {
    position: relative;
    display: flex;
    align-items: center;
    gap: 14px;
    margin: 0 -8px;
    padding: 13px 2px 13px 8px;
    border-radius: 14px;
    transition: background-color 0.2s var(--ease);
  }

  .screen .wallets li + li {
    margin-top: 4px;
    border-top: 0;
  }

  .screen .wallets li:hover {
    background: rgba(var(--ink), 0.035);
  }

  .screen .wallets li.active {
    background: var(--fill);
  }

  /* The row switches to its wallet; the dots beside it open its menu. */
  .wallet {
    display: flex;
    flex: 1;
    align-items: center;
    gap: 12px;
    min-width: 0;
    padding: 10px 8px;
    border: 0;
    border-radius: 12px;
    background: none;
    text-align: left;
    cursor: pointer;
  }

  /* Option rows on the add screen keep their full width. */
  .list:not(.wallets) .wallet {
    width: 100%;
    margin: 0 -8px;
    box-sizing: content-box;
    transition: background-color 0.2s var(--ease);
  }

  .list:not(.wallets) .wallet:hover {
    background: rgba(var(--ink), 0.04);
  }

  .wallet:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  .active .initial {
    background: var(--fill-strong);
  }

  /* Wallet rows a size up from other lists: each one is a whole wallet. */
  .screen .wallets .initial {
    width: 44px;
    height: 44px;
    font-size: 15px;
  }

  /* The avatar as the handle to move a wallet: pointed at, its letters dim and arrows show. */
  .handle {
    position: relative;
    z-index: 2;
    padding: 0;
    border: 0;
    color: var(--fg);
    font-family: inherit;
    font-weight: 600;
    letter-spacing: -0.01em;
    cursor: grab;
    touch-action: none;
  }

  .handle .letters,
  .handle .arrows {
    transition: opacity 0.15s var(--ease);
  }

  .handle .arrows {
    position: absolute;
    inset: 0;
    margin: auto;
    opacity: 0;
  }

  .handle:hover .letters,
  .handle:focus-visible .letters,
  .dragged .handle .letters {
    opacity: 0.15;
  }

  .handle:hover .arrows,
  .handle:focus-visible .arrows,
  .dragged .handle .arrows {
    opacity: 1;
  }

  .handle:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 2px;
  }

  /* While a wallet is dragged: it rides above the others, which slide aside to make room. */
  .sorting {
    user-select: none;
  }

  .sorting li {
    transition:
      transform 0.18s var(--ease),
      background-color 0.2s var(--ease);
  }

  .sorting li.dragged {
    z-index: 4;
    background: var(--raised);
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.45);
    transition: background-color 0.2s var(--ease);
  }

  .sorting li.dragged .handle {
    cursor: grabbing;
  }

  .screen .wallets .who {
    gap: 2px;
  }

  /* The name switches to the wallet, and its click area covers the whole row. The address and
     the dots come later and are positioned too, so they sit above it and get their own clicks. */
  .pick {
    overflow: hidden;
    max-width: 100%;
    padding: 0;
    border: 0;
    background: none;
    color: inherit;
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
    text-align: left;
    text-overflow: ellipsis;
    white-space: nowrap;
    cursor: pointer;
    outline: none;
  }

  .pick::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: 14px;
  }

  .pick:focus-visible::after {
    outline: 2px solid var(--hairline-strong);
  }

  .address {
    position: relative;
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

  .row-actions {
    position: relative;
    flex: none;
  }

  /* The same dropdown as the header's menu. */
  .row-menu {
    position: absolute;
    top: calc(100% + 4px);
    right: 0;
    z-index: 3;
    display: flex;
    flex-direction: column;
    min-width: 190px;
    padding: 6px;
    border: 1px solid var(--hairline);
    border-radius: 16px;
    background: var(--menu);
    box-shadow: 0 16px 40px var(--shadow);
    transform-origin: top right;
  }

  .row-menu.up {
    top: auto;
    bottom: calc(100% + 4px);
    transform-origin: bottom right;
  }

  .row-menu button {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border: 0;
    border-radius: 10px;
    background: none;
    color: var(--muted);
    font-size: 14px;
    font-weight: 500;
    text-align: left;
    white-space: nowrap;
    cursor: pointer;
    outline: none;
    transition:
      color 0.15s var(--ease),
      background-color 0.15s var(--ease);
  }

  .row-menu button:hover:not(:disabled),
  .row-menu button:focus-visible {
    background: rgba(var(--ink), 0.07);
    color: var(--fg);
  }

  .row-menu .danger:hover:not(:disabled),
  .row-menu .danger:focus-visible {
    color: var(--danger);
  }

  .row-menu button:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* Private key and removal screens. */
  .warning {
    display: flex;
    gap: 12px;
    margin-bottom: 4px;
  }

  .warning-icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: rgba(240, 140, 126, 0.12);
    color: var(--danger);
  }

  .warning p {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .warning strong {
    color: var(--fg);
    font-weight: 600;
  }

  .key-box {
    margin: 14px 0;
    padding: 14px;
    border-radius: 12px;
    background: var(--fill);
  }

  .key-box code {
    font-family: inherit;
    font-size: 13px;
    font-weight: 500;
    line-height: 1.55;
    word-break: break-all;
    user-select: all;
  }

  .note:last-child {
    margin-top: 10px;
    text-align: center;
  }

  .check {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    color: rgba(var(--ink), 0.9);
    font-size: 13px;
    line-height: 1.45;
    cursor: pointer;
  }

  .check input {
    flex: none;
    width: 16px;
    height: 16px;
    margin: 1px 0 0;
    accent-color: var(--fg);
  }

  .destructive:not(:disabled) {
    background: var(--danger);
    color: var(--on-danger);
  }

  .destructive:hover:not(:disabled) {
    background: var(--danger-hover);
  }

  .chevron {
    flex: none;
    color: var(--muted);
  }

  .note {
    margin: -4px 0 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.45;
  }

  .field textarea {
    word-break: break-word;
  }

  .check:has(input:disabled) {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* A new wallet's recovery phrase: numbered words, blurred under a veil until revealed. */
  .phrase-card {
    padding: 2px 10px 10px;
    border: 1px solid rgba(var(--ink), 0.09);
    border-radius: 14px;
    background: rgba(var(--ink), 0.035);
  }

  .phrase-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 36px;
    padding-left: 2px;
  }

  .phrase-head > span {
    color: var(--muted);
    font-size: 12px;
    font-weight: 500;
  }

  .copy {
    margin-right: -4px;
    padding: 4px 8px;
    border: 0;
    border-radius: 8px;
    background: none;
    color: var(--muted);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .copy:hover:not(:disabled) {
    background: rgba(var(--ink), 0.05);
    color: var(--fg);
  }

  .copy:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .phrase {
    position: relative;
  }

  .words {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 6px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .words li {
    display: flex;
    align-items: center;
    gap: 6px;
    height: 34px;
    padding: 0 8px;
    border-radius: 9px;
    background: var(--inset);
  }

  .words .index {
    flex: none;
    min-width: 14px;
    color: rgba(var(--ink), 0.35);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .words .word {
    overflow: hidden;
    font-size: 13px;
    font-weight: 500;
    text-overflow: ellipsis;
  }

  .concealed {
    user-select: none;
  }

  .concealed .word {
    filter: blur(5px);
  }

  .reveal {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    border: 0;
    border-radius: 9px;
    background: var(--veil);
    backdrop-filter: blur(2px);
    cursor: pointer;
  }

  .reveal strong {
    font-size: 14px;
    font-weight: 600;
  }

  .reveal span {
    color: var(--muted);
    font-size: 12px;
  }

  .reveal:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }
</style>
