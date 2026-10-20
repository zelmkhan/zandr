// Exchange API keys from the environment, for the exchanges whose token lists only come with one
// (src/server/exchangeTokenSources.ts), and CoinGecko's optional demo key. Read-only keys; on zandr's server they're Railway variables,
// on a developer's machine they're in .env.exchanges.
import type { ExchangeKeys } from '../src/server/exchangeTokenSources.ts';

export function exchangeKeys(env: Record<string, string | undefined>): ExchangeKeys {
  return {
    ...(env.BYBIT_API_KEY && env.BYBIT_API_SECRET ? { bybit: { key: env.BYBIT_API_KEY, secret: env.BYBIT_API_SECRET } } : {}),
    ...(env.OKX_API_KEY && env.OKX_API_SECRET && env.OKX_API_PASSPHRASE
      ? { okx: { key: env.OKX_API_KEY, secret: env.OKX_API_SECRET, passphrase: env.OKX_API_PASSPHRASE } }
      : {}),
    ...(env.MEXC_API_KEY && env.MEXC_API_SECRET ? { mexc: { key: env.MEXC_API_KEY, secret: env.MEXC_API_SECRET } } : {}),
    ...(env.COINGECKO_API_KEY ? { coingecko: env.COINGECKO_API_KEY } : {}),
  };
}
