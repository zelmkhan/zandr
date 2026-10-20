<script lang="ts">
  // Full-page onboarding, opened from the toolbar button while there is no wallet yet:
  // create a new self-custody wallet, or import one by recovery phrase or private key.
  import { onMount } from 'svelte';
  import { DEFAULT_WALLET_NAME, sendToBackground, type WalletSecret } from '@/lib/messages';
  import { rise } from './rise';
  import Done from './steps/Done.svelte';
  import ImportWallet from './steps/ImportWallet.svelte';
  import Name from './steps/Name.svelte';
  import Notice from './steps/Notice.svelte';
  import Password from './steps/Password.svelte';
  import Phrase from './steps/Phrase.svelte';
  import Welcome from './steps/Welcome.svelte';

  const flows = {
    create: ['notice', 'phrase', 'name', 'password', 'done'],
    import: ['import', 'name', 'password', 'done'],
  } as const;

  type Flow = keyof typeof flows;
  // existing: the page was opened while a wallet is already set up.
  type Step = 'welcome' | 'existing' | (typeof flows)[Flow][number];

  // How each step is listed in the brand panel beside the form.
  const labels: Partial<Record<Step, { title: string; caption: string }>> = {
    notice: { title: 'Before you start', caption: 'How self-custody works' },
    phrase: { title: 'Recovery phrase', caption: 'Write down your 12 words' },
    import: { title: 'Your wallet', caption: 'Recovery phrase or private key' },
    name: { title: 'Name', caption: 'How it appears in zandr' },
    password: { title: 'Password', caption: 'Unlocks zandr on this device' },
  };

  let flow = $state<Flow | null>(null);
  let step = $state<Step>('welcome');
  // The new phrase or the imported phrase or key; dropped as soon as the background has it.
  let secret = $state.raw<WalletSecret | null>(null);
  let name = $state(DEFAULT_WALLET_NAME);
  let address = $state('');

  const steps: readonly Step[] = $derived(flow ? flows[flow] : []);
  const position = $derived(steps.indexOf(step));
  // The steps shown in the list and counted in the progress bar: all but the final one.
  const listed = $derived(steps.slice(0, -1));
  const words = $derived(secret?.kind === 'phrase' ? secret.words : []);

  // Never offer to create a wallet over an existing one; the background refuses that too.
  onMount(async () => {
    const { hasWallet } = await sendToBackground({ type: 'wallet:getStatus' });
    if (hasWallet) go('existing');
  });

  function go(target: Step) {
    step = target;
    scrollTo(0, 0);
  }

  function start(next: Flow) {
    flow = next;
    go(flows[next][0]);
  }

  function back() {
    if (position > 0) return go(steps[position - 1]!);
    flow = null;
    secret = null;
    go('welcome');
  }

  function next() {
    go(steps[position + 1]!);
  }

  // One phrase per visit to the create flow: going back and forth keeps the same one.
  async function showPhrase() {
    if (!secret) {
      const { words } = await sendToBackground({ type: 'phrase:generate' });
      secret = { kind: 'phrase', words };
    }
    next();
  }

  function imported(value: WalletSecret) {
    secret = value;
    next();
  }

  function named(value: string) {
    name = value;
    next();
  }

  async function createWallet(password: string) {
    ({ address } = await sendToBackground({ type: 'onboarding:createWallet', secret: secret!, password, name }));
    secret = null;
    next();
  }
</script>

<div class="shell">
  <!-- Brand panel: what zandr is on the first screen, then where you are in the setup. -->
  <aside class="brand">
    <span class="wordmark">zandr</span>

    <div>
      {#if flow === null}
        <h2 class="pitch">Protection from threats, and from simple human error.</h2>

        <ul class="features">
          <li>
            <span class="feature-icon">
              <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                  <path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4m2-2-9.6 9.6" />
                  <circle cx="7.5" cy="15.5" r="5.5" />
                </g>
              </svg>
            </span>
            <div>
              <strong>Self-custody</strong>
              <span>Your keys are created and stored on this device, and nowhere else.</span>
            </div>
          </li>
          <li>
            <span class="feature-icon">
              <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="4" y="11" width="16" height="10" rx="2.5" />
                  <path d="M8 11V7.5a4 4 0 0 1 8 0V11" />
                </g>
              </svg>
            </span>
            <div>
              <strong>Encrypted with your password</strong>
              <span>Memory-hard key derivation and AES-256 keep them safe at rest.</span>
            </div>
          </li>
          <li>
            <span class="feature-icon">
              <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
                <g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M10.7 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-2.1 3" />
                  <path d="M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6" />
                  <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
                  <path d="m2 2 20 20" />
                </g>
              </svg>
            </span>
            <div>
              <strong>Private by design</strong>
              <span>No accounts and no tracking. We never see your keys.</span>
            </div>
          </li>
        </ul>
      {:else}
        <ol class="stepper">
          {#each listed as item, index}
            {@const state = index < position || step === 'done' ? 'complete' : index === position ? 'current' : 'upcoming'}
            <li class={state} aria-current={state === 'current' ? 'step' : undefined}>
              <span class="marker">
                {#if state === 'complete'}
                  <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M5 12.5 9.5 17 19 7.5" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />
                  </svg>
                {:else}
                  {index + 1}
                {/if}
              </span>
              <div>
                <strong>{labels[item]?.title}</strong>
                <span>{labels[item]?.caption}</span>
              </div>
            </li>
          {/each}
        </ol>
      {/if}
    </div>

    <p class="assurance">
      <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="4" y="11" width="16" height="10" rx="2.5" />
          <path d="M8 11V7.5a4 4 0 0 1 8 0V11" />
        </g>
      </svg>
      Your keys never leave this device
    </p>
  </aside>

  <main class="content">
    <!-- On narrow screens the brand panel is hidden: the wordmark and a progress bar stand in. -->
    <div class="compact-top">
      <span class="wordmark">zandr</span>
      {#if position !== -1 && step !== 'done'}
        <span class="compact-count">Step {position + 1} of {listed.length}</span>
      {/if}
    </div>
    {#if position !== -1 && step !== 'done'}
      <div
        class="progress"
        role="progressbar"
        aria-label="Step {position + 1} of {listed.length}"
        aria-valuemin={0}
        aria-valuemax={listed.length}
        aria-valuenow={position + 1}
      >
        <span style:width="{((position + 1) / listed.length) * 100}%"></span>
      </div>
    {/if}

    {#key step}
      <div class="step" in:rise>
        {#if position !== -1 && step !== 'done'}
          <button type="button" class="back" onclick={back}>
            <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5m6-6-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
            Back
          </button>
        {/if}

        {#if step === 'welcome'}
          <Welcome oncreate={() => start('create')} onimport={() => start('import')} />
        {:else if step === 'notice'}
          <Notice onnext={showPhrase} />
        {:else if step === 'phrase'}
          <Phrase {words} onnext={next} />
        {:else if step === 'import'}
          <ImportWallet initial={secret} onnext={imported} />
        {:else if step === 'name'}
          <Name initial={name} onnext={named} />
        {:else if step === 'password'}
          <Password action={flow === 'create' ? 'Create wallet' : 'Import wallet'} onsubmit={createWallet} />
        {:else if step === 'done'}
          <Done outcome={flow === 'import' ? 'imported' : 'created'} {address} />
        {:else if step === 'existing'}
          <Done outcome="existing" />
        {/if}
      </div>
    {/key}
  </main>
</div>

<style>
  .shell {
    display: grid;
    grid-template-columns: minmax(380px, 5fr) 7fr;
    min-height: 100vh;
  }

  .wordmark {
    font-size: 22px;
    font-weight: 600;
    letter-spacing: -0.035em;
  }

  /* Brand panel: a slightly lifted surface, lit faintly from its top-left corner. */
  .brand {
    position: sticky;
    top: 0;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 48px;
    height: 100vh;
    padding: 40px 48px;
    overflow: hidden;
    border-right: 1px solid var(--divider);
    background: var(--panel);
  }

  .brand::after {
    content: '';
    position: absolute;
    inset: 0;
    background: radial-gradient(85% 55% at 0% 0%, rgba(var(--ink), 0.08), transparent 70%);
    pointer-events: none;
  }

  .brand > * {
    position: relative;
    z-index: 1;
  }

  .pitch {
    max-width: 420px;
    margin: 0;
    font-size: 34px;
    font-weight: 600;
    line-height: 1.15;
    letter-spacing: -0.03em;
    text-wrap: balance;
  }

  .features {
    display: flex;
    flex-direction: column;
    gap: 24px;
    max-width: 400px;
    margin: 40px 0 0;
    padding: 0;
    list-style: none;
  }

  .features li,
  .stepper li {
    display: flex;
    gap: 14px;
  }

  .features div,
  .stepper div {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-top: 1px;
  }

  .features strong,
  .stepper strong {
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .features div span,
  .stepper div span {
    color: var(--muted);
    font-size: 14px;
    line-height: 1.45;
  }

  .feature-icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: var(--fill);
  }

  /* Vertical step list: a line threads the markers, lit along the finished part. */
  .stepper {
    display: flex;
    flex-direction: column;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .stepper li {
    position: relative;
    padding-bottom: 32px;
  }

  .stepper li:last-child {
    padding-bottom: 0;
  }

  .stepper li:not(:last-child)::before {
    content: '';
    position: absolute;
    top: 38px;
    bottom: 6px;
    left: 15.5px;
    width: 1px;
    background: rgba(var(--ink), 0.1);
  }

  .stepper li.complete:not(:last-child)::before {
    background: rgba(var(--ink), 0.35);
  }

  .marker {
    display: grid;
    flex: none;
    place-items: center;
    width: 32px;
    height: 32px;
    border: 1px solid rgba(var(--ink), 0.14);
    border-radius: 50%;
    color: var(--muted);
    font-size: 13px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    transition:
      background-color 0.3s var(--ease),
      border-color 0.3s var(--ease),
      color 0.3s var(--ease);
  }

  .current .marker {
    border-color: var(--fg);
    background: var(--fg);
    color: var(--bg);
  }

  .complete .marker {
    border-color: transparent;
    background: var(--fill-strong);
    color: var(--fg);
  }

  .upcoming strong {
    color: var(--muted);
  }

  .assurance {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 0;
    color: var(--muted);
    font-size: 13px;
  }

  /* Form side. */
  .content {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    padding: 48px 32px;
  }

  .compact-top,
  .progress {
    display: none;
  }

  .step {
    width: 100%;
    max-width: 420px;
  }

  .back {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin: 0 0 28px -8px;
    padding: 6px 10px 6px 8px;
    border: 0;
    border-radius: 8px;
    background: none;
    color: var(--muted);
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    transition:
      color 0.2s var(--ease),
      background-color 0.2s var(--ease);
  }

  .back:hover {
    background: rgba(var(--ink), 0.05);
    color: var(--fg);
  }

  .back:focus-visible {
    outline: 2px solid var(--hairline-strong);
  }

  /* Narrow screens: one column, the brand panel swapped for a top bar with progress. */
  @media (max-width: 900px) {
    .shell {
      grid-template-columns: 1fr;
    }

    .brand {
      display: none;
    }

    .content {
      justify-content: flex-start;
      padding: 0 24px 48px;
    }

    .compact-top {
      display: flex;
      align-items: center;
      justify-content: space-between;
      width: 100%;
      max-width: 420px;
      height: 68px;
    }

    .compact-count {
      color: var(--muted);
      font-size: 13px;
      font-variant-numeric: tabular-nums;
    }

    .progress {
      display: block;
      width: 100%;
      max-width: 420px;
      height: 2px;
      margin-bottom: 32px;
      overflow: hidden;
      border-radius: 1px;
      background: rgba(var(--ink), 0.1);
    }

    .progress span {
      display: block;
      height: 100%;
      background: var(--fg);
      transition: width 0.4s var(--ease);
    }

    .step {
      padding-top: 8px;
    }
  }
</style>
