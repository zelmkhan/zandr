// JSON-RPC calls to the Solana node the wallet sends through. Background only.

// Why a call failed: the node refused it, limited it, couldn't be reached, or answered with an
// error of its own (`detail` has its message).
export type RpcFailure = 'forbidden' | 'rate-limited' | 'unreachable' | 'rejected';

export class ChainError extends Error {
  readonly reason: RpcFailure;
  readonly detail: string | undefined;

  constructor(reason: RpcFailure, detail?: string) {
    super(detail ? `RPC ${reason}: ${detail}` : `RPC ${reason}`);
    this.reason = reason;
    this.detail = detail;
  }
}

// A request turned away for going too fast is tried twice more, a moment later each time.
export async function rpc<T>(url: string, method: string, params: unknown[]): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await call<T>(url, method, params);
    } catch (error) {
      if (attempt === 2 || !(error instanceof ChainError) || error.reason !== 'rate-limited') throw error;
      await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
    }
  }
}

async function call<T>(url: string, method: string, params: unknown[]): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new ChainError('unreachable');
  }
  if (response.status === 401 || response.status === 403) throw new ChainError('forbidden');
  if (response.status === 429) throw new ChainError('rate-limited');

  const body = (await response.json().catch(() => null)) as { result?: T; error?: { code?: number; message?: string } } | null;
  if (body?.error) {
    if (body.error.code === 429 || body.error.code === -32429) throw new ChainError('rate-limited');
    throw new ChainError('rejected', String(body.error.message ?? 'Unknown error').slice(0, 300));
  }
  if (!response.ok || !body || !('result' in body)) throw new ChainError(response.status >= 500 ? 'unreachable' : 'rejected');
  return body.result as T;
}

// The parsed shape of the accounts zandr reads, as the node's jsonParsed encoding gives them.
export type ParsedAccount = {
  owner: string;
  executable: boolean;
  lamports: number;
  data: { parsed?: { type?: string; info?: Record<string, unknown> } } | [string, string];
};

export async function getAccounts(url: string, addresses: string[]): Promise<(ParsedAccount | null)[]> {
  const result = await rpc<{ value: (ParsedAccount | null)[] }>(url, 'getMultipleAccounts', [
    addresses,
    { encoding: 'jsonParsed', commitment: 'confirmed' },
  ]);
  return result.value;
}

export function parsedOf(account: ParsedAccount | null): { type?: string; info?: Record<string, unknown> } | undefined {
  return account && !Array.isArray(account.data) ? account.data.parsed : undefined;
}
