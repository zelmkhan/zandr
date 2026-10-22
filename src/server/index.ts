// zandr's API. It runs inside the extension's background for now and will move to zandr's
// server, unchanged. So this folder uses nothing but fetch and standard web APIs, imports nothing
// from outside itself (scripts/check-server.mjs enforces that), and takes its settings from
// createApi's config, as a server would from its environment. The extension sees only the
// contract in api.ts.
import { getActivity } from './activity.ts';
import { createExchanges } from './exchanges.ts';
import { HOT_WALLETS } from './hotWallets.ts';
import { ApiError, type Api, type Network, type TokenSummary } from './api.ts';
import type { Fetch } from './http.ts';
import shipped from './exchangeTokens.json' with { type: 'json' };
import { exchangeVerdict, type ExchangeTokenList } from './exchangeTokens.ts';
import { createJupiter, iconSource, type JupiterConfig, type Logos } from './jupiter.ts';
import { getAssetImage } from './rpc.ts';
import { getPortfolio } from './portfolio.ts';

const ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

export type ApiConfig = {
  // The RPC endpoint of each network.
  rpc: Record<Network, string>;
  // Jupiter's API with a key and its rate limit, instead of the public one.
  jupiter?: JupiterConfig;
  // Exchanges' hot wallets, address → exchange, instead of the list in hotWallets.ts.
  hotWallets?: Record<string, string>;
  // zandr's logo server (`…/v1/logo`, by mint), or an image proxy (a logo's URL through it, from
  // where its creator put it): tokens' logos come from there, so no token's creator learns who
  // looks at it. Without either, only verified tokens get a logo.
  logos?: Logos;
  // The logos while Jupiter's requests go to its fallback: zandr's server, logo server included,
  // can't answer.
  fallbackLogos?: Logos;
  // The exchanges' token lists to go by, fresher than the snapshot that ships
  // (exchangeTokens.json), if there are any: asked for at each transfer check.
  exchangeTokens?: () => ExchangeTokenList[] | Promise<ExchangeTokenList[]>;
  fetch?: Fetch;
};

export function createApi(config: ApiConfig): Api {
  // A wrapper, not fetch itself: called detached from its global, fetch throws in some runtimes.
  const fetcher: Fetch = config.fetch ?? ((input, init) => fetch(input, init));
  const jupiter = createJupiter(fetcher, config.jupiter, config.logos, config.fallbackLogos);
  const addressInfo = createExchanges({ fetch: fetcher, rpc: config.rpc, hotWallets: config.hotWallets ?? HOT_WALLETS });

  return {
    getPortfolio: (request) => getPortfolio({ fetch: fetcher, rpc: config.rpc, jupiter }, request),

    getActivity: (request) => getActivity({ fetch: fetcher, rpc: config.rpc, jupiter }, request),

    getAddressInfo: (request) => addressInfo(request),

    async getTransferCheck({ network, to, mint }) {
      if (network !== 'mainnet' || typeof to !== 'string' || !ADDRESS.test(to) || (mint !== null && (typeof mint !== 'string' || !ADDRESS.test(mint)))) {
        throw new ApiError('invalid-request', 'rpc');
      }
      const { exchange, kind } = await addressInfo({ network, address: to });
      if (!exchange) return { exchange, kind, listed: null };
      const lists = (await config.exchangeTokens?.()) ?? (shipped as { lists: ExchangeTokenList[] }).lists;
      return { exchange, kind, listed: exchangeVerdict(lists, exchange, mint) };
    },

    async getLogoSources({ mints }) {
      if (!Array.isArray(mints) || mints.length > 100 || mints.some((mint) => typeof mint !== 'string' || !ADDRESS.test(mint))) {
        throw new ApiError('invalid-request', 'tokens');
      }
      const found = await jupiter.iconSources(mints);
      const missing = mints.filter((mint) => !found.get(mint));
      const onChain = await Promise.all(missing.map((mint) => getAssetImage(fetcher, config.rpc.mainnet, mint).catch(() => null)));
      missing.forEach((mint, i) => found.set(mint, iconSource(onChain[i])));
      return Object.fromEntries(found);
    },

    async getTokens({ network, mints }, options) {
      if (!Array.isArray(mints) || mints.length > 100 || mints.some((mint) => typeof mint !== 'string')) {
        throw new ApiError('invalid-request', 'tokens');
      }
      if (network !== 'mainnet') return Object.fromEntries(mints.map((mint) => [mint, null]));

      const infos = await jupiter.tokenInfo(mints, options);
      const summary = (mint: string): TokenSummary | null => {
        const info = infos.get(mint);
        return info ? { name: info.name, symbol: info.symbol, logo: info.logo, verified: info.verified, decimals: info.decimals } : null;
      };
      return Object.fromEntries(mints.map((mint) => [mint, summary(mint)]));
    },

    async searchTokens({ network, query }, options) {
      if (network !== 'mainnet' || typeof query !== 'string' || !query.trim() || query.length > 64) throw new ApiError('invalid-request', 'tokens');
      return (await jupiter.search(query.trim(), options?.signal)).map(({ mint, name, symbol, logo, verified, decimals }) => ({ mint, name, symbol, logo, verified, decimals }));
    },

    async buildSwap({ network, inputMint, outputMint, amount, slippageBps, user }) {
      const valid =
        network === 'mainnet' &&
        [inputMint, outputMint, user].every((address) => typeof address === 'string' && ADDRESS.test(address)) &&
        inputMint !== outputMint &&
        typeof amount === 'string' &&
        /^[1-9]\d{0,29}$/.test(amount) &&
        Number.isInteger(slippageBps) &&
        slippageBps >= 1 &&
        slippageBps <= 5_000;
      if (!valid) throw new ApiError('invalid-request', 'tokens');
      return jupiter.build(inputMint, outputMint, amount, slippageBps, user);
    },
  };
}
