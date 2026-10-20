import { ApiError, type ApiService } from './api.ts';

export type Fetch = typeof fetch;

const TIMEOUT_MS = 10_000;

// Fetches JSON from a service, turning every way it can fail into an ApiError. `seen`: shown each
// response as it arrives, for what its headers say.
export async function fetchJson(fetcher: Fetch, service: ApiService, url: string, init?: RequestInit, seen?: (response: Response) => void): Promise<unknown> {
  let response: Response;
  try {
    response = await fetcher(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch {
    throw new ApiError('unreachable', service);
  }
  seen?.(response);

  if (response.status === 401 || response.status === 403) throw new ApiError('forbidden', service);
  if (response.status === 429) throw new ApiError('rate-limited', service);
  if (!response.ok) {
    // A service that refuses with a reason ({ error: "..." }) gets it passed on.
    const body: unknown = await response.json().catch(() => null);
    const said = isObject(body) && typeof body.error === 'string' ? body.error.replace(/[\p{Cc}\p{Cf}]/gu, '').slice(0, 160) : undefined;
    throw new ApiError(response.status >= 500 && !said ? 'unreachable' : 'bad-response', service, said);
  }

  try {
    return await response.json();
  } catch {
    throw new ApiError('bad-response', service);
  }
}

export function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
