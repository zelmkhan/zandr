// Solana networks and RPC endpoints, for the settings page and, later, everything that talks
// to the chain.
export type NetworkId = 'mainnet' | 'devnet';

// zandr's server (api/): the default mainnet node and tokens' logos.
export const ZANDR_API = 'https://api.zandr.xyz';

// Mainnet's default node is zandr's own RPC proxy (api/rpc.ts): it forwards the wallet's requests
// to zandr's RPC provider, whose key stays on the server. Solana's public mainnet node refuses
// extensions. Devnet's public node takes them.
export const NETWORKS: Record<NetworkId, { label: string; rpc: string; genesisHash: string }> = {
  mainnet: {
    label: 'Mainnet',
    rpc: `${ZANDR_API}/rpc/mainnet`,
    genesisHash: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
  },
  devnet: {
    label: 'Devnet',
    rpc: 'https://api.devnet.solana.com',
    genesisHash: 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG',
  },
};

// The URL to use for a network: the custom one if set, otherwise zandr's default.
export function rpcUrl(network: NetworkId, custom: Record<NetworkId, string | null>): string {
  return custom[network] ?? NETWORKS[network].rpc;
}

// An error message for a URL that can't be an RPC endpoint, or null if it looks fine.
// Plain http only for a node on this machine: anywhere else it could be read or tampered with.
export function checkRpcUrl(input: string): string | null {
  let url: URL;
  try {
    url = new URL(input.trim());
  } catch {
    return 'Enter a full URL, like https://rpc.example.com';
  }
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
  if (url.protocol === 'https:' || (url.protocol === 'http:' && local)) return null;
  return 'Use an https:// URL. Plain http is only allowed for a node on this machine.';
}

export type RpcProbe = { network: NetworkId | null; version: string; latencyMs: number };

// Why an endpoint didn't work. "forbidden" is common: many nodes, Solana's own public mainnet
// one included, refuse requests from browsers and extensions, or want an API key.
export type RpcFailure = 'forbidden' | 'unreachable' | 'not-rpc';

export class RpcError extends Error {
  constructor(
    readonly reason: RpcFailure,
    readonly status?: number,
  ) {
    super(`RPC ${reason}${status ? ` (HTTP ${status})` : ''}`);
  }
}

// Asks the endpoint which chain it serves (by genesis hash) and its version. Rejects with an
// RpcError if it doesn't answer like a Solana RPC within a few seconds.
export async function probeRpc(url: string): Promise<RpcProbe> {
  const started = performance.now();
  const call = async (method: string) => {
    let response: Response;
    try {
      response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method }),
        signal: AbortSignal.timeout(8000),
      });
    } catch {
      throw new RpcError('unreachable');
    }
    if (response.status === 401 || response.status === 403) throw new RpcError('forbidden', response.status);

    const body = await response.json().catch(() => null);
    if (!response.ok || !body || body.error || body.result === undefined) throw new RpcError('not-rpc', response.status);
    return body.result;
  };

  const [genesisHash, version] = await Promise.all([call('getGenesisHash'), call('getVersion')]);
  const network = (Object.keys(NETWORKS) as NetworkId[]).find((id) => NETWORKS[id].genesisHash === genesisHash) ?? null;
  return { network, version: version['solana-core'] ?? 'unknown', latencyMs: Math.round(performance.now() - started) };
}
