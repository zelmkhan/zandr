// What an address is to an exchange, told by what it does, not by any label: the exchanges' own
// wallets are listed (exchangeWallets.json, through hotWallets.ts), and a deposit address is one
// that passes on what it receives to one of them. Exchanges give each user their own deposit addresses, too many to list,
// but every deposit is swept on to a hot wallet within minutes, and the sweep is in the deposit
// address's own history. A brand-new deposit address, never swept yet, can't be told apart from
// a wallet.
import { ApiError, type AddressInfo, type Network } from './api.ts';
import { readTransaction } from './activity.ts';
import type { Fetch } from './http.ts';
import { getSignatures, getTransaction } from './rpc.ts';

const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
// The latest transactions looked at: enough to see sweeps, few enough to answer in a second or two.
const LOOK_AT = 12;
const PARALLEL = 2;
// A deposit address stays one; an address with no sweeps yet may make one soon.
const KNOWN_FOR = 12 * 60 * 60 * 1000;
const UNKNOWN_FOR = 30 * 60 * 1000;
const CACHE_LIMIT = 50_000;

export type ExchangeDeps = { fetch: Fetch; rpc: Record<Network, string>; hotWallets: Record<string, string> };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// A busy node gets three more tries: public nodes allow only a few transactions read a second.
async function patiently<T>(attempt: () => Promise<T>): Promise<T> {
  for (const wait of [1500, 4000, 8000]) {
    try {
      return await attempt();
    } catch (error) {
      if (!(error instanceof ApiError) || error.reason !== 'rate-limited') throw error;
      await sleep(wait);
    }
  }
  return attempt();
}

export function createExchanges(deps: ExchangeDeps) {
  const known = new Map<string, { info: AddressInfo; until: number }>();

  function remember(info: AddressInfo) {
    known.delete(info.address);
    known.set(info.address, { info, until: Date.now() + (info.exchange ? KNOWN_FOR : UNKNOWN_FOR) });
    if (known.size > CACHE_LIMIT) known.delete(known.keys().next().value!);
    return info;
  }

  return async function addressInfo(request: { network: Network; address: string }): Promise<AddressInfo> {
    const { network, address } = request;
    if (!Object.hasOwn(deps.rpc, network) || typeof address !== 'string' || !ADDRESS.test(address)) {
      throw new ApiError('invalid-request', 'rpc');
    }
    const none: AddressInfo = { address, exchange: null, kind: null, sweeps: 0, looked: 0 };
    if (network !== 'mainnet') return none;
    const hot = deps.hotWallets[address];
    if (hot) return { ...none, exchange: hot, kind: 'hot-wallet' };
    const cached = known.get(address);
    if (cached && cached.until > Date.now()) return cached.info;

    // Its latest transactions, read for what it sent where: sweeps are the ones it sent to a hot wallet.
    const url = deps.rpc[network];
    const signatures = await patiently(() => getSignatures(deps.fetch, url, address, { limit: LOOK_AT }));
    const readings = new Array(signatures.length);
    let next = 0;
    let unread = 0;
    await Promise.all(
      Array.from({ length: Math.min(PARALLEL, signatures.length) }, async () => {
        while (next < signatures.length) {
          const index = next++;
          // One transaction the node won't return doesn't sink the rest.
          const transaction = await patiently(() => getTransaction(deps.fetch, url, signatures[index]!.signature)).catch(() => {
            unread++;
            return null;
          });
          readings[index] = transaction ? readTransaction(transaction, address) : null;
        }
      }),
    );
    // Most of them unread: no answer, rather than one remembered as "not an exchange's".
    if (unread * 2 > signatures.length) throw new ApiError('unreachable', 'rpc');

    const sweeps = new Map<string, number>();
    let elsewhere = 0;
    for (const reading of readings) {
      if (reading?.kind !== 'send' || !reading.counterparty) continue;
      const exchange = deps.hotWallets[reading.counterparty];
      if (exchange) sweeps.set(exchange, (sweeps.get(exchange) ?? 0) + 1);
      else elsewhere++;
    }

    // One exchange's, and mostly sweeps: a deposit address passes on what it gets, to its exchange
    // only. Sweeps to several exchanges, or sends mostly elsewhere, say nothing for sure.
    const [exchange, count] = [...sweeps].sort((a, b) => b[1] - a[1])[0] ?? [null, 0];
    const deposit = exchange !== null && sweeps.size === 1 && count >= elsewhere;
    return remember({
      address,
      exchange: deposit ? exchange : null,
      kind: deposit ? 'deposit' : null,
      sweeps: count,
      looked: signatures.length,
    });
  };
}
