// zandr's API as the background reaches it: in-process for now (src/server), over HTTP later.
// Background only.
import { createApi } from '@/server';
import { JUPITER_PUBLIC } from '@/server/jupiter';
import type { Api, Network } from '@/server/api';
import { exchangeTokenLists } from '@/lib/exchangeTokens';
import { NETWORKS, ZANDR_API, rpcUrl, type NetworkId } from '@/lib/network';
import type { Preferences } from '@/lib/preferences';

// The RPC endpoint of each network: the custom one if set, otherwise zandr's default.
export function rpcEndpoints(preferences: Preferences): Record<Network, string> {
  const ids = Object.keys(NETWORKS) as NetworkId[];
  return Object.fromEntries(ids.map((id) => [id, rpcUrl(id, preferences.rpc)])) as Record<Network, string>;
}

// zandr's server allows each wallet 40 requests to Jupiter at once, then 4 a second: kept to 20
// per 10 seconds here.
const JUPITER_VIA_ZANDR = { url: `${ZANDR_API}/jupiter`, rate: { requests: 20, perMs: 10_000 }, fallback: JUPITER_PUBLIC.url };

// One API for as long as the RPC endpoints stay the same, so its token and price caches last.
let current: { rpc: string; api: Api } | undefined;

export function getApi(preferences: Preferences): Api {
  const rpc = rpcEndpoints(preferences);
  const key = JSON.stringify(rpc);
  // Tokens' logos from zandr's server, so no token's creator sees who looks at its logo. Jupiter
  // through zandr's server too, under its paid key's rate limit; straight to Jupiter's public API
  // while that server can't answer.
  if (current?.rpc !== key) {
    current = {
      rpc: key,
      api: createApi({ rpc, logos: `${ZANDR_API}/v1/logo`, exchangeTokens: exchangeTokenLists, jupiter: JUPITER_VIA_ZANDR }),
    };
  }
  return current.api;
}
