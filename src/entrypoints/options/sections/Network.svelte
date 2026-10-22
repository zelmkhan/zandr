<script lang="ts">
  import { NETWORKS, RpcError, checkRpcUrl, probeRpc, rpcUrl, type NetworkId, type RpcFailure, type RpcProbe } from '@/lib/network';
  import { updatePreferences, type Preferences } from '@/lib/preferences';

  let { preferences }: { preferences: Preferences } = $props();

  const network = $derived(preferences.network);
  const custom = $derived(preferences.rpc[network]);
  const endpoint = $derived(rpcUrl(network, preferences));

  // Editing a custom endpoint: opened by choosing Custom, closed by saving or cancelling.
  let editing = $state(false);

  // The node in use: the default one (zandr's on mainnet, Solana's on devnet), public services
  // (mainnet only), or the user's own.
  const node = $derived(editing || custom ? 'custom' : network === 'mainnet' && preferences.publicServices ? 'public' : 'default');
  // Public services are mainnet's: devnet's choice leaves them as they are.
  const services = (on: boolean): Partial<Preferences> => (network === 'mainnet' ? { publicServices: on } : {});
  let draft = $state('');
  let error = $state('');
  let busy = $state(false);

  // The last connection check of the endpoint in use; only shown while it's still that endpoint.
  type Check =
    | { url: string; state: 'checking' }
    | { url: string; state: 'ok'; probe: RpcProbe }
    | { url: string; state: 'failed'; reason: RpcFailure };
  let check = $state<Check | null>(null);
  const shown = $derived(check?.url === endpoint ? check : null);

  const failures: Record<RpcFailure, { status: string; error: string }> = {
    forbidden: {
      status: 'Refuses requests from browser apps',
      error: 'This endpoint refuses requests from browser apps. It may need an API key in the URL.',
    },
    unreachable: { status: 'Not responding', error: "Couldn't reach this URL." },
    'not-rpc': { status: "Doesn't answer like a Solana RPC", error: "This URL doesn't answer like a Solana RPC." },
  };

  const reasonOf = (cause: unknown): RpcFailure => (cause instanceof RpcError ? cause.reason : 'unreachable');

  function chooseNetwork(id: NetworkId) {
    editing = false;
    error = '';
    updatePreferences({ network: id });
  }

  function useDefault() {
    editing = false;
    error = '';
    updatePreferences({ rpc: { ...preferences.rpc, [network]: null }, ...services(false) });
  }

  function usePublic() {
    editing = false;
    error = '';
    updatePreferences({ rpc: { ...preferences.rpc, mainnet: null }, publicServices: true });
  }

  function startCustom() {
    editing = true;
    draft = custom ?? '';
    error = '';
  }

  // A custom endpoint is saved only once it answers, and from the network it's meant for: an
  // endpoint on another network would quietly show the wrong balances and send to the wrong chain.
  async function saveCustom(event: SubmitEvent) {
    event.preventDefault();
    const url = draft.trim();
    const invalid = checkRpcUrl(url);
    if (invalid) {
      error = invalid;
      return;
    }

    busy = true;
    error = '';
    try {
      const probe = await probeRpc(url);
      if (probe.network !== network) {
        const expected = NETWORKS[network].label;
        error = probe.network
          ? `This endpoint is on ${NETWORKS[probe.network].label}, not ${expected}.`
          : `This endpoint isn't on Solana ${expected}.`;
        return;
      }
      // Your own node in place of public services, so Jupiter goes through zandr's server again.
      await updatePreferences({ rpc: { ...preferences.rpc, [network]: url }, ...services(false) });
      check = { url, state: 'ok', probe };
      editing = false;
    } catch (cause) {
      error = failures[reasonOf(cause)].error;
    } finally {
      busy = false;
    }
  }

  async function checkConnection() {
    const url = endpoint;
    check = { url, state: 'checking' };
    try {
      check = { url, state: 'ok', probe: await probeRpc(url) };
    } catch (cause) {
      check = { url, state: 'failed', reason: reasonOf(cause) };
    }
  }
</script>

<h1 class="section-title">Network</h1>
<p class="section-lead">Which Solana network zandr uses, and the RPC node it talks to it through.</p>

<div class="card rows">
  <div class="row">
    <div class="row-text">
      <strong>Network</strong>
      <span>
        {network === 'devnet' ? 'A network for testing: its tokens have no real value.' : 'The main Solana network, where tokens have real value.'}
      </span>
    </div>
    <div class="segmented" role="group" aria-label="Network">
      {#each Object.keys(NETWORKS) as NetworkId[] as id}
        <button type="button" aria-pressed={network === id} onclick={() => chooseNetwork(id)}>{NETWORKS[id].label}</button>
      {/each}
    </div>
  </div>
</div>

<h2 class="group-title">RPC endpoint for {NETWORKS[network].label}</h2>
<div class="card rows">
  <div class="row">
    <div class="row-text">
      <strong>{node === 'custom' ? 'Custom' : node === 'public' ? 'Public' : network === 'mainnet' ? 'Private' : 'Default'}</strong>
      {#if node === 'public'}
        <span>Helius, with Jupiter and logos asked directly</span>
      {:else}
        <span class="url">{endpoint}</span>
      {/if}
    </div>
    <div class="segmented" role="group" aria-label="RPC endpoint">
      <!-- zandr's node keeps no record of who asks what; devnet's default is Solana's public one. -->
      <button type="button" aria-pressed={node === 'default'} onclick={useDefault}>{network === 'mainnet' ? 'Private' : 'Default'}</button>
      {#if network === 'mainnet'}
        <button type="button" aria-pressed={node === 'public'} onclick={usePublic}>Public</button>
      {/if}
      <button type="button" aria-pressed={node === 'custom'} onclick={startCustom}>Custom</button>
    </div>
  </div>

  {#if editing}
    <form class="row edit" onsubmit={saveCustom}>
      <label class="field">
        <span class="label">Custom RPC URL</span>
        <input
          class="input"
          bind:value={draft}
          oninput={() => (error = '')}
          placeholder="https://"
          aria-label="Custom RPC URL"
          aria-invalid={error ? 'true' : undefined}
          autocomplete="off"
          spellcheck="false"
        />
      </label>
      {#if error}
        <p class="error" role="alert">{error}</p>
      {/if}
      <div class="edit-actions">
        <button type="button" class="text-button" onclick={() => (editing = false)}>Cancel</button>
        <button class="button compact" disabled={!draft.trim() || busy}>{busy ? 'Checking…' : 'Check and save'}</button>
      </div>
    </form>
  {/if}

  <div class="row">
    <div class="row-text">
      <strong>Connection</strong>
      <span class="status" class:ok={shown?.state === 'ok'} class:failed={shown?.state === 'failed'} role="status">
        {#if !shown}
          Not checked yet
        {:else if shown.state === 'checking'}
          Checking…
        {:else if shown.state === 'failed'}
          {failures[shown.reason].status}
        {:else}
          Connected · {shown.probe.network ? NETWORKS[shown.probe.network].label : 'unknown network'} · v{shown.probe.version}
          · {shown.probe.latencyMs} ms
        {/if}
      </span>
    </div>
    <button type="button" class="text-button" onclick={checkConnection} disabled={shown?.state === 'checking'}>Check</button>
  </div>
</div>

<p class="note">
  Your RPC provider can see the addresses zandr looks up and the transactions it sends. Use one you trust. On Mainnet, Private
  goes through zandr's server, which passes requests on to its RPC provider and logs none of them. Public goes to Helius and
  Jupiter directly; only the exchanges' token lists still come from zandr's server, whole, so it learns nothing about your wallet.
</p>

<style>
  .url {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .edit {
    flex-direction: column;
    align-items: stretch;
    gap: 0;
  }

  .edit-actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 14px;
  }

  .status {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* A status dot: steady white when connected, red when not. */
  .status.ok::before,
  .status.failed::before {
    content: '';
    flex: none;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--fg);
  }

  .status.failed {
    color: var(--danger);
  }

  .status.failed::before {
    background: var(--danger);
  }

  .note {
    margin: 14px 0 0;
    color: rgba(var(--ink), 0.4);
    font-size: 12px;
    line-height: 1.5;
  }
</style>
