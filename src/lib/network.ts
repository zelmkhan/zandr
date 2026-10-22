// Solana networks and RPC endpoints, for the settings page and, later, everything that talks
// to the chain.
import type { Preferences } from '@/lib/preferences';

export type NetworkId = 'mainnet' | 'devnet';

// zandr's server (api/): the default mainnet node and tokens' logos.
export const ZANDR_API = 'https://api.zandr.xyz';

// Public services, for those who'd rather nothing about their wallet went through zandr's server:
// Helius's mainnet node under a key meant to be public, with Jupiter's public API and logos through
// an open image proxy (lib/api.ts). Only the exchanges' token lists still come from zandr's server,
// fetched whole (lib/exchangeTokens.ts).
export const PUBLIC_RPC_MAINNET = 'https://mainnet.helius-rpc.com/?api-key=c987b612-49bb-4f4d-b716-cf82ae436e53';

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

// While zandr's node can't answer (down, failing, or over its limits), Helius's public one stands
// in for it, for ten minutes at a time; then zandr's is tried again. Background only: the time is
// kept in memory, so a background woken afresh tries zandr's first.
const STAND_IN_MS = 10 * 60_000;
let zandrDownUntil = 0;

// The node a request meant for `url` goes to now.
export function nodeFor(url: string): string {
  return url === NETWORKS.mainnet.rpc && Date.now() < zandrDownUntil ? PUBLIC_RPC_MAINNET : url;
}

// zandr's node didn't answer: not running (Railway answers in its place, marking it), its provider
// unreachable (a 502 from it), or over its limits.
const unanswered = (response: Response) =>
  response.headers.get('x-railway-fallback') === 'true' || response.status === 502 || response.status === 503 || response.status === 504 || response.status === 429;

// fetch, with the public node standing in for zandr's. A request zandr's couldn't answer goes to
// the public one at once, with a timeout of its own (the first one's may be what ran out).
export const fetchNode: typeof fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url !== NETWORKS.mainnet.rpc) return fetch(input, init);
  if (Date.now() >= zandrDownUntil) {
    try {
      const response = await fetch(url, init);
      if (!unanswered(response)) return response;
    } catch {
      // Unreachable, or timed out.
    }
    zandrDownUntil = Date.now() + STAND_IN_MS;
  }
  return fetch(PUBLIC_RPC_MAINNET, { ...init, signal: AbortSignal.timeout(15_000) });
};

// The URL to use for a network: the custom one if set, otherwise Helius's with public services on
// mainnet, otherwise the default.
export function rpcUrl(network: NetworkId, preferences: Pick<Preferences, 'rpc' | 'publicServices'>): string {
  return preferences.rpc[network] ?? (network === 'mainnet' && preferences.publicServices ? PUBLIC_RPC_MAINNET : NETWORKS[network].rpc);
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
