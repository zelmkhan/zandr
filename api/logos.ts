// zandr's logo server: GET /v1/logo/<mint> answers with the token's logo, fetched here from
// wherever its creator put it. The wallet loads every token's logo from here, so the hosts behind
// them (any server a scam token names) never see who looks, and logos load from one fast place.
// What's fetched is checked to be an image, of bounded size, and cached; the server fetches only
// public https addresses, checked at every connection and redirect, so a token can't point it at
// anything internal. Nothing is logged.
import { lookup as dnsLookup, type LookupAddress } from 'node:dns';
import type { ServerResponse } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { BlockList, isIP } from 'node:net';
import type { Api } from '../src/server/api.ts';

const MINT = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const MAX_BYTES = 1024 * 1024;
const FETCH_TIMEOUT_MS = 8_000;
const MAX_REDIRECTS = 3;
// Logos found are kept a day, here and in browsers; tokens without one, an hour; ones whose host
// turned the server away for now (rate limits, errors, timeouts), five minutes.
const FOUND_MS = 24 * 60 * 60 * 1000;
const MISSING_MS = 60 * 60 * 1000;
const RETRY_MS = 5 * 60 * 1000;

// IPFS gateways to try, in order, after the one the logo names: the public ones busy pump.fun
// tokens use (ipfs.io and its siblings) often turn servers away.
const IPFS_GATEWAYS = ['https://ipfs.filebase.io/ipfs/', 'https://4everland.io/ipfs/', 'https://gateway.pinata.cloud/ipfs/'];
const CACHE_BYTES = 64 * 1024 * 1024;
// Fetches from creators' hosts at once, everyone together.
const MAX_FETCHING = 16;

// Per client: a wallet opens with all its coins' logos at once; after that the browser has them.
const BURST = 300;
const PER_SECOND = 20;

// Addresses that aren't the public internet: this machine, private and shared networks
// (Railway's own included), link-local (cloud metadata), multicast and reserved ranges.
const blocked = new BlockList();
for (const [network, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
] as const) {
  blocked.addSubnet(network, prefix, 'ipv4');
}
// (IPv4-mapped IPv6 addresses aren't listed here: Node's BlockList would then match every IPv4
// address. isPublic checks the IPv4 address inside them instead.)
for (const [network, prefix] of [
  ['::', 128],
  ['::1', 128],
  ['64:ff9b::', 96],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
] as const) {
  blocked.addSubnet(network, prefix, 'ipv6');
}

function isPublic({ address, family }: LookupAddress): boolean {
  if (family !== 6) return !blocked.check(address, 'ipv4');
  const mapped = /^::ffff:(.+)$/i.exec(address);
  if (!mapped) return !blocked.check(address, 'ipv6');
  // An IPv4 address in IPv6 dress: public if the IPv4 one is, and written as one.
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(mapped[1]!) && !blocked.check(mapped[1]!, 'ipv4');
}

// DNS for the fetches: a name that resolves to anything but public addresses fails. It runs for
// the very connection that's made, so a name can't resolve one way when checked and another when
// used.
function publicLookup(hostname: string, options: { all?: boolean }, callback: (...args: unknown[]) => void) {
  dnsLookup(hostname, { all: true }, (error, addresses) => {
    if (error) return callback(error);
    if (!addresses.length || !addresses.every(isPublic)) return callback(new Error('Not a public address'));
    if (options.all) return callback(null, addresses);
    callback(null, addresses[0]!.address, addresses[0]!.family);
  });
}

type Fetched = { status: number; location: string | null; body: Buffer | null };
// What fetching a logo came to: the image, none there, or none for now.
type Outcome = { body: Buffer; type: string } | 'missing' | 'later';

function get(url: URL): Promise<Fetched> {
  return new Promise((resolve, reject) => {
    const request = httpsRequest(
      url,
      {
        method: 'GET',
        lookup: publicLookup as never,
        timeout: FETCH_TIMEOUT_MS,
        headers: { Accept: 'image/*', 'User-Agent': 'zandr-logos/1' },
      },
      (response) => {
        const status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          response.resume();
          return resolve({ status, location: response.headers.location ?? null, body: null });
        }
        if (status !== 200) {
          response.resume();
          return resolve({ status, location: null, body: null });
        }
        const chunks: Buffer[] = [];
        let size = 0;
        response.on('data', (chunk: Buffer) => {
          size += chunk.length;
          if (size > MAX_BYTES) return request.destroy(new Error('Too large'));
          chunks.push(chunk);
        });
        response.on('end', () => resolve({ status, location: null, body: Buffer.concat(chunks) }));
        response.on('error', reject);
      },
    );
    request.on('timeout', () => request.destroy(new Error('Timed out')));
    request.on('error', reject);
    request.end();
  });
}

// Only https on its usual port: no other schemes, and no probing of other ports. A host given as
// an IP address is checked here, since no DNS lookup runs for it.
function fetchable(url: URL): boolean {
  if (url.protocol !== 'https:' || url.port !== '' || url.username || url.password) return false;
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const family = isIP(host);
  return family === 0 || isPublic({ address: host, family });
}

async function fetchFrom(source: string): Promise<Outcome> {
  let url: URL;
  try {
    url = new URL(source);
  } catch {
    return 'missing';
  }
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (!fetchable(url)) return 'missing';
    let fetched: Fetched;
    try {
      fetched = await get(url);
    } catch {
      return 'later';
    }
    if (fetched.location) {
      url = new URL(fetched.location, url);
      continue;
    }
    if (fetched.status === 429 || fetched.status >= 500) return 'later';
    if (!fetched.body) return 'missing';
    const type = imageType(fetched.body);
    return type ? { body: fetched.body, type } : 'missing';
  }
  return 'missing';
}

// The same file on other IPFS gateways, if the address is one: /ipfs/<cid>/… on a gateway's own
// host, or <cid>.ipfs.<gateway>.
function ipfsMirrors(source: string): string[] {
  let url: URL;
  try {
    url = new URL(source);
  } catch {
    return [];
  }
  const path = /^\/ipfs\/([A-Za-z0-9]+)(\/.*)?$/.exec(url.pathname);
  const subdomain = /^([a-z0-9]+)\.ipfs\./.exec(url.hostname);
  const file = path ? `${path[1]}${path[2] ?? ''}` : subdomain ? `${subdomain[1]}${url.pathname === '/' ? '' : url.pathname}` : null;
  return file ? IPFS_GATEWAYS.map((gateway) => gateway + file).filter((mirror) => new URL(mirror).host !== url.host) : [];
}

// The logo where it is, else on another IPFS gateway. None for now if any try was turned away.
async function fetchImage(source: string): Promise<Outcome> {
  let outcome: Outcome = 'missing';
  for (const candidate of [source, ...ipfsMirrors(source)]) {
    const result = await fetchFrom(candidate);
    if (typeof result !== 'string') return result;
    if (result === 'later') outcome = 'later';
  }
  return outcome;
}

// What the bytes are, whatever the host said: a raster format or SVG, or nothing to serve.
function imageType(bytes: Buffer): string | null {
  if (bytes.length < 12) return null;
  if (bytes[0] === 0x89 && bytes.toString('latin1', 1, 4) === 'PNG') return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.toString('latin1', 0, 4) === 'GIF8') return 'image/gif';
  if (bytes.toString('latin1', 0, 4) === 'RIFF' && bytes.toString('latin1', 8, 12) === 'WEBP') return 'image/webp';
  if (bytes.toString('latin1', 4, 12) === 'ftypavif') return 'image/avif';
  const head = bytes.subarray(0, 1024).toString('utf8').replace(/^﻿/, '').trimStart().toLowerCase();
  if (head.startsWith('<svg') || ((head.startsWith('<?xml') || head.startsWith('<!--')) && head.includes('<svg'))) return 'image/svg+xml';
  return null;
}

type Logo = { body: Buffer | null; type: string; expires: number };

export function createLogos(api: Api) {
  // ---- Cache: newest last; the oldest go first past CACHE_BYTES. ----
  const cache = new Map<string, Logo>();
  let cached = 0;

  function remember(mint: string, logo: Logo) {
    const old = cache.get(mint);
    if (old) cached -= old.body?.length ?? 0;
    cache.delete(mint);
    cache.set(mint, logo);
    cached += logo.body?.length ?? 0;
    while ((cached > CACHE_BYTES || cache.size > 50_000) && cache.size) {
      const [oldest, entry] = cache.entries().next().value!;
      cache.delete(oldest);
      cached -= entry.body?.length ?? 0;
    }
  }

  // ---- Sources: mints asked for within a moment of each other are looked up together. Null if
  // the token has no logo, undefined if the lookup failed. ----
  let batch: { mint: string; resolve: (source: string | null | undefined) => void }[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;

  function sourceOf(mint: string): Promise<string | null | undefined> {
    return new Promise((resolve) => {
      batch.push({ mint, resolve });
      if (batch.length >= 100) flush();
      else timer ??= setTimeout(flush, 40);
    });
  }

  function flush() {
    clearTimeout(timer);
    timer = undefined;
    const waiting = batch;
    batch = [];
    const mints = [...new Set(waiting.map((entry) => entry.mint))];
    api.getLogoSources({ mints }).then(
      (sources) => waiting.forEach(({ mint, resolve }) => resolve(sources[mint] ?? null)),
      () => waiting.forEach(({ resolve }) => resolve(undefined)),
    );
  }

  // ---- Loading, once per mint at a time. ----
  const loading = new Map<string, Promise<Logo | null>>();
  let fetching = 0;

  function load(mint: string): Promise<Logo | null> {
    const running = loading.get(mint);
    if (running) return running;
    const promise = (async (): Promise<Logo | null> => {
      const source = await sourceOf(mint);
      if (source === undefined) return { body: null, type: '', expires: Date.now() + RETRY_MS };
      if (source === null) return { body: null, type: '', expires: Date.now() + MISSING_MS };
      // Too many fetches under way: no answer now, and none remembered, so a later ask tries again.
      if (fetching >= MAX_FETCHING) return null;
      fetching++;
      try {
        const image = await fetchImage(source).catch((): Outcome => 'later');
        if (typeof image !== 'string') return { ...image, expires: Date.now() + FOUND_MS };
        return { body: null, type: '', expires: Date.now() + (image === 'later' ? RETRY_MS : MISSING_MS) };
      } finally {
        fetching--;
      }
    })().then((logo) => {
      if (logo) remember(mint, logo);
      return logo;
    });
    loading.set(mint, promise);
    promise.finally(() => loading.delete(mint));
    return promise;
  }

  // ---- Limits ----
  const clients = new Map<string, { tokens: number; at: number }>();

  function allowed(client: string): boolean {
    const now = Date.now();
    const entry = clients.get(client) ?? { tokens: BURST, at: now };
    entry.tokens = Math.min(BURST, entry.tokens + ((now - entry.at) / 1000) * PER_SECOND);
    entry.at = now;
    clients.set(client, entry);
    if (clients.size > 100_000) clients.delete(clients.keys().next().value!);
    if (entry.tokens < 1) return false;
    entry.tokens -= 1;
    return true;
  }

  // ---- HTTP ----

  // Served as an image only: opened on its own, an SVG can't run anything.
  const IMAGE_HEADERS = {
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; sandbox",
    'Cross-Origin-Resource-Policy': 'cross-origin',
  };

  async function handle(response: ServerResponse, mint: string, client: string) {
    if (!MINT.test(mint)) {
      response.writeHead(404, { ...IMAGE_HEADERS, 'Cache-Control': 'no-store' });
      return response.end();
    }
    let logo = cache.get(mint);
    if (logo && logo.expires <= Date.now()) logo = undefined;
    if (!logo) {
      if (!allowed(client)) {
        response.writeHead(429, { ...IMAGE_HEADERS, 'Cache-Control': 'no-store' });
        return response.end();
      }
      logo = (await load(mint)) ?? undefined;
    }

    if (!logo) {
      response.writeHead(503, { ...IMAGE_HEADERS, 'Cache-Control': 'no-store' });
      return response.end();
    }
    const maxAge = Math.max(0, Math.floor((logo.expires - Date.now()) / 1000));
    if (!logo.body) {
      response.writeHead(404, { ...IMAGE_HEADERS, 'Cache-Control': `public, max-age=${maxAge}` });
      return response.end();
    }
    response.writeHead(200, {
      ...IMAGE_HEADERS,
      'Content-Type': logo.type,
      'Content-Length': logo.body.length,
      'Cache-Control': `public, max-age=${maxAge}`,
    });
    response.end(logo.body);
  }

  return { handle };
}
