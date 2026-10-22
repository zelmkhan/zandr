// zandr's API as the background reaches it: in-process for now (src/server), over HTTP later.
// Background only.
import { createApi } from '@/server';
import { JUPITER_PUBLIC } from '@/server/jupiter';
import type { Api, Network } from '@/server/api';
import { exchangeTokenLists } from '@/lib/exchangeTokens';
import { NETWORKS, ZANDR_API, fetchNode, rpcUrl, type NetworkId } from '@/lib/network';
import type { Preferences } from '@/lib/preferences';

// The RPC endpoint of each network: the custom one if set, otherwise the default (Helius's on
// mainnet with public services).
export function rpcEndpoints(preferences: Preferences): Record<Network, string> {
  const ids = Object.keys(NETWORKS) as NetworkId[];
  return Object.fromEntries(ids.map((id) => [id, rpcUrl(id, preferences)])) as Record<Network, string>;
}

// zandr's server allows each wallet 40 requests to Jupiter at once, then 4 a second: kept to 20
// per 10 seconds here.
const JUPITER_VIA_ZANDR = { url: `${ZANDR_API}/jupiter`, rate: { requests: 20, perMs: 10_000 }, fallback: JUPITER_PUBLIC.url };

// Logos for public services: through wsrv.nl, an open image proxy, sized for the largest the
// wallet shows (48 px) on a 2x screen, SVGs as PNGs. An IPFS one comes from a gateway that lets the
// proxy in (ipfs.io, which most tokens name, turns it away), and from another should that fail.
const IPFS_GATEWAYS = ['https://ipfs.filebase.io/ipfs/', 'https://4everland.io/ipfs/'] as const;

function proxied(source: string, fallback?: string): string {
  const query = new URLSearchParams({ url: source, w: '96', h: '96', output: 'png' });
  // Where wsrv.nl redirects should the source fail.
  if (fallback) query.set('default', fallback);
  return `https://wsrv.nl/?${query}`;
}

// The file an IPFS address names, whichever gateway it's on: /ipfs/<cid>/… on the gateway's own
// host, or <cid>.ipfs.<gateway>.
function ipfsFile(source: string): string | null {
  const url = new URL(source);
  const path = /^\/ipfs\/([A-Za-z0-9]+)(\/.*)?$/.exec(url.pathname);
  if (path) return `${path[1]}${path[2] ?? ''}`;
  const subdomain = /^([a-z0-9]+)\.ipfs\./.exec(url.hostname);
  return subdomain ? `${subdomain[1]}${url.pathname === '/' ? '' : url.pathname}` : null;
}

export function publicLogo(source: string): string {
  const file = ipfsFile(source);
  return file ? proxied(IPFS_GATEWAYS[0] + file, proxied(IPFS_GATEWAYS[1] + file)) : proxied(source);
}

// One API for as long as the RPC endpoints and services stay the same, so its token and price
// caches last.
let current: { key: string; api: Api } | undefined;

export function getApi(preferences: Preferences): Api {
  const rpc = rpcEndpoints(preferences);
  const key = JSON.stringify({ rpc, publicServices: preferences.publicServices });
  // Tokens' logos from zandr's server, so no token's creator sees who looks at its logo. Jupiter
  // through zandr's server too, under its paid key's rate limit; straight to Jupiter's public API
  // while that server can't answer, and logos through the image proxy meanwhile, as zandr's node
  // is the public one then (fetchNode). With public services, none of it goes through zandr's
  // server: Jupiter's public API, and logos through the image proxy.
  if (current?.key !== key) {
    current = {
      key,
      api: preferences.publicServices
        ? createApi({ rpc, logos: publicLogo, exchangeTokens: exchangeTokenLists, jupiter: JUPITER_PUBLIC, fetch: fetchNode })
        : createApi({ rpc, logos: `${ZANDR_API}/v1/logo`, fallbackLogos: publicLogo, exchangeTokens: exchangeTokenLists, jupiter: JUPITER_VIA_ZANDR, fetch: fetchNode }),
    };
  }
  return current.api;
}
