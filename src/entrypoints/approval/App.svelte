<script lang="ts">
  // What a site asks, taken apart by the background, for the user to approve or turn down:
  // connecting, signing transactions (and sending them), or signing a message.
  import { onMount } from 'svelte';
  import { fade } from 'svelte/transition';
  import SiteIcon from '@/components/SiteIcon.svelte';
  import { monogram, shortAddress, wrongPassword } from '@/lib/format';
  import { sendToBackground, type ApprovalView } from '@/lib/messages';
  import Verified from '@/components/Verified.svelte';
  import CoinLogo from '../popup/CoinLogo.svelte';

  // The request this window is for, as the background named it.
  const id = location.hash.slice(1);

  let approval = $state<ApprovalView | null>(null);
  // zandr itself failed, or the network refused what was signed: said, and the window stays.
  let problem = $state<{ title: string; text: string } | null>(null);
  let busy = $state(false);
  let acknowledged = $state(false);
  // A window that pops up under the pointer could catch a click meant for the site: approving
  // works only once it has been on screen for a moment.
  let armed = $state(false);
  $effect(() => {
    if (!approval) return;
    armed = false;
    const timer = setTimeout(() => (armed = true), 600);
    return () => clearTimeout(timer);
  });

  let password = $state('');
  let passwordInput = $state<HTMLInputElement>();
  let passwordError = $state('');

  // The host as Chrome reports it: internationalized names in their xn-- form, so a lookalike
  // can't pass for the real thing.
  const url = $derived(approval ? new URL(approval.origin) : null);
  const host = $derived(url?.host ?? '');
  const local = $derived(url?.protocol === 'http:');

  const transactions = $derived(approval?.transactions ?? []);
  const blocked = $derived(transactions.some((tx) => tx.blocked) || !!approval?.message?.blocked);
  const dangerous = $derived(transactions.some((tx) => tx.warnings.some((warning) => warning.level === 'danger')));

  const asks = $derived.by(() => {
    if (!approval) return '';
    if (approval.kind === 'connect') return 'wants to connect to your wallet';
    if (approval.kind === 'message') return 'asks you to sign a message';
    const count = transactions.length;
    const what = count > 1 ? `${count} transactions` : 'a transaction';
    return approval.send ? `asks you to approve ${what}` : `asks you to sign ${what}`;
  });

  const action = $derived.by(() => {
    if (!approval) return '';
    if (approval.kind === 'connect') return busy ? 'Connecting…' : 'Connect';
    if (approval.kind === 'message') return busy ? 'Signing…' : 'Sign';
    if (approval.send) return busy ? 'Sending…' : 'Approve';
    return busy ? 'Signing…' : 'Approve';
  });

  async function load() {
    try {
      const result = await sendToBackground({ type: 'approval:get', id });
      // Answered already: on another window, or by the site going away.
      if (!result.ok) return window.close();
      approval = result.approval;
      if (approval.namesPending) awaitNames();
    } catch {
      problem = { title: 'Something went wrong', text: "zandr couldn't read this request. Close this window and try again on the site." };
    }
  }

  // Tokens' names still being looked up: asked for again, the background answering once they're
  // there. Only the transactions are taken: the window doesn't start over (nor wait to arm again)
  // for a name.
  async function awaitNames() {
    const shown = approval;
    try {
      for (let attempt = 0; attempt < 10 && approval === shown && shown?.namesPending; attempt++) {
        const result = await sendToBackground({ type: 'approval:get', id, names: true }).catch(() => null);
        if (!result?.ok || approval !== shown || result.approval.wallet?.address !== shown.wallet?.address) break;
        shown.transactions = result.approval.transactions;
        shown.namesPending = result.approval.namesPending;
      }
    } finally {
      // Not coming after all: the tokens show by address.
      if (shown?.namesPending) shown.namesPending = false;
    }
  }

  onMount(() => {
    load();
    // The request waits in the background; this keeps it awake while the window is open.
    const timer = setInterval(() => sendToBackground({ type: 'approval:ping' }).catch(() => {}), 20_000);
    return () => clearInterval(timer);
  });

  async function decide(approved: boolean) {
    if (busy || (approved && !armed)) return;
    busy = true;
    try {
      const result = await sendToBackground({ type: 'approval:decide', id, approved, acknowledged });
      if (result.ok || result.error === 'gone') return window.close();
      if (result.error === 'failed') {
        problem = { title: "Couldn't send", text: `The network refused the transaction${result.detail ? `: ${result.detail}` : '.'}` };
      } else {
        // Locked in the meantime, or no longer what was shown: look again.
        approval = null;
        acknowledged = false;
        await load();
      }
    } catch {
      problem = { title: 'Something went wrong', text: "zandr couldn't finish. Nothing was signed; try again on the site." };
    } finally {
      busy = false;
    }
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
      if (result.unlocked) {
        password = '';
        approval = null;
        busy = false;
        await load();
      } else if (result.erased) {
        password = '';
        problem = { title: 'Wallets erased', text: wrongPassword(result) };
        sendToBackground({ type: 'approval:decide', id, approved: false, acknowledged: false }).catch(() => {});
      } else {
        passwordError = wrongPassword(result);
        passwordInput?.select();
      }
    } catch {
      passwordError = "Couldn't unlock. Please try again.";
    } finally {
      busy = false;
    }
  }

  function focus(node: HTMLElement) {
    node.focus();
  }

  const display = (amount: string) => amount.replace(/^-/, '−');
</script>

<div class="layout">
  <header>
    {#if approval?.wallet}
      <div class="account" in:fade={{ duration: 150 }}>
        <span class="avatar" aria-hidden="true">{monogram(approval.wallet.name, approval.wallet.address)}</span>
        <div class="identity">
          <span class="name">{approval.wallet.name}</span>
          <span class="address" title={approval.wallet.address}>{shortAddress(approval.wallet.address)}</span>
        </div>
      </div>
    {:else}
      <span class="wordmark">zandr</span>
    {/if}
    {#if approval}
      <span class="network" class:test={approval.network === 'devnet'}>{approval.network === 'mainnet' ? 'Mainnet' : 'Devnet'}</span>
    {/if}
  </header>

  <main class="flow">
    {#if problem}
      <div class="center">
        <span class="center-icon bad">
          <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 8v5m0 3.5h.01M12 3 2.5 20h19L12 3Z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </span>
        <p class="center-title">{problem.title}</p>
        <p class="center-text">{problem.text}</p>
      </div>
    {:else if !approval}
      <div class="center">
        <span class="spinner" aria-hidden="true"></span>
        <p class="center-text">Checking the request…</p>
      </div>
    {:else}
      <div class="body" in:fade={{ duration: 150 }}>
        <div class="site" class:big={approval.kind === 'connect' || approval.locked}>
          <span class="site-icon" aria-hidden="true"><SiteIcon origin={approval.origin} icon={approval.icon} /></span>
          <p class="site-host">
            {host}
            {#if local}
              <span class="tag">Local</span>
            {/if}
          </p>
          <p class="site-asks">{asks}</p>
        </div>

        {#if approval.locked}
          <form id="unlock" class="unlock" onsubmit={unlock}>
            <label for="password">Unlock zandr to continue</label>
            <input
              id="password"
              type="password"
              placeholder="Password"
              autocomplete="current-password"
              bind:value={password}
              bind:this={passwordInput}
              oninput={() => (passwordError = '')}
              aria-invalid={passwordError ? 'true' : undefined}
              {@attach focus}
            />
            {#if passwordError}
              <p class="error" role="alert">{passwordError}</p>
            {/if}
          </form>
        {:else if approval.kind === 'connect'}
          <ul class="details perms">
            <li>
              <span class="mark yes" aria-hidden="true">
                <svg width="14" height="14" viewBox="0 0 24 24"><path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
              </span>
              See this wallet's address and balance
            </li>
            <li>
              <span class="mark yes" aria-hidden="true">
                <svg width="14" height="14" viewBox="0 0 24 24"><path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
              </span>
              Ask you to approve transactions
            </li>
            <li>
              <span class="mark no" aria-hidden="true">
                <svg width="14" height="14" viewBox="0 0 24 24"><path d="m7 7 10 10M17 7 7 17" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" /></svg>
              </span>
              Move funds without your approval
            </li>
          </ul>
          <p class="note">Connect only to sites you trust. You can disconnect any time in Settings, under Connected apps.</p>
        {:else if approval.kind === 'message' && approval.message}
          {#if approval.message.blocked}
            <div class="warning">
              <strong>zandr won't sign this</strong>
              <p>{approval.message.blocked}</p>
            </div>
          {:else}
            <div class="card message">
              <span class="label">Message</span>
              {#if approval.message.text !== null}
                <p class="message-text">{approval.message.text}</p>
              {:else}
                <p class="message-hex">{approval.message.hex}</p>
              {/if}
            </div>
            <p class="note">Signing proves this wallet is yours. It can't move your funds and costs nothing.</p>
          {/if}
        {:else}
          {#each transactions as tx, index}
            <section class="tx">
              {#if transactions.length > 1}
                <p class="tx-title">Transaction {index + 1} of {transactions.length}</p>
              {/if}
              {#if tx.blocked}
                <div class="warning">
                  <strong>zandr won't sign this</strong>
                  <p>{tx.blocked}</p>
                </div>
              {:else}
                <div class="card changes">
                  <span class="label">Estimated changes</span>
                  {#if tx.changes.length}
                    <ul>
                      {#each tx.changes as change}
                        <li>
                          {#if approval?.namesPending && change.mint && !change.symbol}
                            <span class="logo-pending pending"></span>
                            <span class="change-what" title={change.mint}><span class="name-pending pending"></span></span>
                          {:else}
                            <CoinLogo logo={change.logo} label={change.symbol ?? change.mint} size={32} />
                            <span class="change-what" title={change.mint ?? undefined}>
                              <span>{change.symbol ?? shortAddress(change.mint ?? '')}</span>
                              {#if change.verified}<Verified />{/if}
                            </span>
                          {/if}
                          <span class="change-amount" class:up={change.amount.startsWith('+')} class:down={change.amount.startsWith('-')}>
                            {display(change.amount)}
                          </span>
                        </li>
                      {/each}
                    </ul>
                  {:else}
                    <p class="nothing">{tx.failure ? 'Unknown: the test run failed.' : 'No change to your balances.'}</p>
                  {/if}
                </div>

                {#each tx.warnings as warning}
                  <div class="warning" class:caution={warning.level === 'caution'}>
                    <strong>{warning.title}</strong>
                    <p>{warning.text}</p>
                  </div>
                {/each}

                <dl class="details">
                  <div>
                    <dt>Network fee</dt>
                    <dd>{tx.payer ? `${tx.fee} SOL` : 'Paid by the site'}</dd>
                  </div>
                  {#if tx.programs.length}
                    <div>
                      <dt>Programs</dt>
                      <dd>{tx.programs.join(', ')}</dd>
                    </div>
                  {/if}
                </dl>
              {/if}
            </section>
          {/each}

          {#if dangerous && !blocked}
            <label class="check">
              <input type="checkbox" bind:checked={acknowledged} />
              I understand what this transaction does and want to sign it anyway.
            </label>
          {/if}
        {/if}
      </div>
    {/if}
  </main>

  {#if problem}
    <footer class="single">
      <button type="button" class="secondary" onclick={() => window.close()}>Close</button>
    </footer>
  {:else if approval}
    <footer class:single={blocked}>
      <button type="button" class="secondary" disabled={busy && !approval.locked} onclick={() => decide(false)}>
        {approval.kind === 'connect' || approval.locked ? 'Cancel' : 'Reject'}
      </button>
      {#if approval.locked}
        <button type="submit" form="unlock" class="primary" disabled={busy}>{busy ? 'Decrypting…' : 'Unlock'}</button>
      {:else if !blocked}
        <button type="button" class="primary" disabled={busy || (dangerous && !acknowledged)} onclick={() => decide(true)}>
          {action}
        </button>
      {/if}
    </footer>
  {/if}
</div>

<style>
  .layout {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: radial-gradient(120% 55% at 50% -12%, var(--glow), transparent 70%);
  }

  header {
    position: relative;
    flex: none;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    height: 58px;
    padding: 0 16px;
  }

  header::after {
    content: '';
    position: absolute;
    right: 0;
    bottom: 0;
    left: 0;
    height: 1px;
    background: var(--divider);
  }

  .wordmark {
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.035em;
  }

  .account {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }

  .avatar {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: var(--fill);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .identity {
    display: flex;
    flex-direction: column;
    min-width: 0;
    line-height: 1.25;
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
    color: var(--muted);
    font-size: 13px;
  }

  .network {
    flex: none;
    height: 24px;
    padding: 0 10px;
    border-radius: 999px;
    background: var(--fill);
    color: var(--muted);
    font-size: 12px;
    font-weight: 600;
    line-height: 24px;
  }

  /* Devnet stands out: its coins aren't worth anything, and a site may expect otherwise. */
  .network.test {
    background: rgba(240, 179, 90, 0.12);
    color: var(--caution);
  }

  main {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow-y: auto;
    padding: 0 16px;
    scrollbar-width: none;
  }

  .body {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-bottom: 16px;
  }

  /* Who's asking: the host, big and first, as Chrome reports it. */
  .site {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 20px 0 8px;
    text-align: center;
  }

  .site.big {
    padding: 36px 0 16px;
  }

  /* The site's own icon, with no tile behind it (components/SiteIcon). */
  .site-icon {
    display: grid;
    overflow: hidden;
    place-items: center;
    width: 48px;
    height: 48px;
    margin-bottom: 12px;
    border-radius: 12px;
    font-size: 20px;
    font-weight: 600;
  }

  .site.big .site-icon {
    width: 64px;
    height: 64px;
    margin-bottom: 16px;
    border-radius: 16px;
    font-size: 26px;
  }

  .site-host {
    display: flex;
    align-items: center;
    gap: 6px;
    max-width: 100%;
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.015em;
    overflow-wrap: anywhere;
  }

  .site.big .site-host {
    font-size: 21px;
  }

  .tag {
    flex: none;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--fill);
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0;
  }

  .site-asks {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 14px;
  }

  /* What connecting allows, and what it never does. */
  .perms {
    list-style: none;
  }

  .perms li {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 0;
    font-size: 14px;
  }

  .perms li + li {
    border-top: 1px solid var(--divider);
  }

  .mark {
    display: grid;
    flex: none;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 50%;
  }

  .mark.yes {
    background: rgba(38, 208, 168, 0.12);
    color: var(--up);
  }

  .mark.no {
    background: rgba(240, 87, 93, 0.12);
    color: var(--down);
  }

  .note {
    margin: 0;
    padding: 0 4px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.45;
    text-align: center;
  }

  .message {
    gap: 8px;
  }

  /* The message as it is, wrapped, scrolling past a few lines. */
  .message-text,
  .message-hex {
    max-height: 220px;
    margin: 0;
    overflow-y: auto;
    font-size: 14px;
    line-height: 1.5;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    scrollbar-width: thin;
  }

  .message-hex {
    color: var(--muted);
    font-family: ui-monospace, 'SF Mono', Menlo, monospace;
    font-size: 12px;
  }

  .tx {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .tx + .tx {
    margin-top: 6px;
  }

  .tx-title {
    margin: 0;
    font-size: 13px;
    font-weight: 600;
  }

  .changes ul {
    margin: 6px 0 -4px;
    padding: 0;
    list-style: none;
  }

  .changes li {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 0;
  }

  .changes li + li {
    border-top: 1px solid var(--divider);
  }

  .change-what {
    display: flex;
    flex: 1;
    align-items: center;
    gap: 4px;
    min-width: 0;
    font-size: 15px;
    font-weight: 600;
  }

  .change-what > span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* A token whose name is still being looked up. */
  .pending {
    background: var(--fill);
    animation: pulse 1.4s ease-in-out infinite;
  }

  .logo-pending {
    flex: none;
    width: 32px;
    height: 32px;
    border-radius: 50%;
  }

  .name-pending {
    width: 72px;
    height: 14px;
    border-radius: 6px;
  }

  @keyframes pulse {
    50% {
      opacity: 0.45;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .pending {
      animation: none;
    }
  }

  .change-amount {
    flex: none;
    max-width: 60%;
    overflow: hidden;
    font-size: 15px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .change-amount.up {
    color: var(--up);
  }

  .change-amount.down {
    color: var(--down);
  }

  .nothing {
    margin: 8px 0 2px;
    color: var(--muted);
    font-size: 14px;
  }

  /* Worth a look, not a stop: amber instead of red. */
  .warning.caution {
    border-color: rgba(240, 179, 90, 0.3);
    background: rgba(240, 179, 90, 0.07);
  }

  .warning.caution strong {
    color: var(--caution);
  }

  .details dd {
    min-width: 0;
    overflow-wrap: anywhere;
  }

  /* The unlock form: the wallet's own password field. */
  .unlock {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-top: 8px;
  }

  .unlock label {
    color: var(--muted);
    font-size: 14px;
    text-align: center;
  }

  .unlock input {
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

  .unlock input:placeholder-shown {
    font-family: 'Geist Password Empty', 'Geist Variable', system-ui, sans-serif;
  }

  .unlock input::placeholder {
    color: var(--muted);
    font-size: 18px;
    letter-spacing: -0.01em;
  }

  .unlock input[aria-invalid='true'] {
    border-color: var(--danger);
  }

  .error {
    margin: 0;
    color: var(--danger);
    font-size: 14px;
    line-height: 1.45;
    text-align: center;
  }

  footer {
    position: relative;
    flex: none;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    padding: 12px 16px 16px;
  }

  footer.single {
    grid-template-columns: 1fr;
  }

  /* What scrolls under the buttons fades out instead of being cut off. */
  footer::before {
    content: '';
    position: absolute;
    top: -20px;
    right: 0;
    left: 0;
    height: 20px;
    background: linear-gradient(transparent, var(--bg));
    pointer-events: none;
  }

  .primary,
  .secondary {
    height: 48px;
    border: 0;
    border-radius: 999px;
    font-size: 16px;
    font-weight: 600;
    letter-spacing: -0.01em;
    cursor: pointer;
    transition:
      background-color 0.2s var(--ease),
      opacity 0.2s var(--ease),
      transform 0.12s var(--ease);
  }

  .primary {
    background: var(--accent);
    color: var(--on-accent);
  }

  .primary:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .secondary {
    background: var(--fill);
    color: var(--fg);
  }

  .secondary:hover:not(:disabled) {
    background: var(--fill-strong);
  }

  .primary:active:not(:disabled),
  .secondary:active:not(:disabled) {
    transform: scale(0.985);
  }

  .primary:disabled,
  .secondary:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .primary:focus-visible,
  .secondary:focus-visible {
    outline: 2px solid var(--hairline-strong);
    outline-offset: 3px;
  }
</style>
