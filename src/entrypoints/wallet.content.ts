// The wallet a web page sees: zandr, registered the Wallet Standard way, so any Solana app that
// lists wallets finds it. Runs in the page's own world, so it holds nothing: every request goes
// through the bridge to the background, and nothing is signed until the user approves it there.
import { base58, base64 } from '@scure/base';
import icon from '@/assets/wallet-icon.png?inline';
import { CHANNEL, MATCHES } from '@/lib/dappChannel';

type Answer =
  | { ok: true; accounts?: string[]; transactions?: string[]; signatures?: string[]; signature?: string }
  | { ok: false; code: number; message: string };

type Listener = (properties: { accounts?: readonly ZandrAccount[] }) => void;
type TransactionInput = { account: { address: string }; transaction: Uint8Array; chain?: string; options?: Record<string, unknown> };
type MessageInput = { account: { address: string }; message: Uint8Array };

const CHAINS = ['solana:mainnet', 'solana:devnet'] as const;
const FEATURES = ['solana:signAndSendTransaction', 'solana:signTransaction', 'solana:signMessage'] as const;
const VERSIONS = ['legacy', 0] as const;

// Errors carry the codes apps know from other wallets: 4001 rejected, 4100 not connected.
class WalletError extends Error {
  readonly code: number;

  constructor(message: string, code: number) {
    super(message);
    this.name = 'WalletError';
    this.code = code;
  }
}

class ZandrAccount {
  readonly #address: string;
  readonly #publicKey: Uint8Array;

  constructor(address: string) {
    this.#address = address;
    this.#publicKey = base58.decode(address);
    Object.freeze(this);
  }

  get address() {
    return this.#address;
  }

  get publicKey() {
    return this.#publicKey.slice();
  }

  get chains() {
    return CHAINS.slice();
  }

  get features() {
    return FEATURES.slice();
  }
}

// How a wallet announces itself to apps, per the Wallet Standard: an event apps may already be
// listening for, and an answer to the one apps send when they start later.
class RegisterWalletEvent extends Event {
  readonly #detail: (api: { register: (wallet: unknown) => unknown }) => void;

  get detail() {
    return this.#detail;
  }

  constructor(callback: (api: { register: (wallet: unknown) => unknown }) => void) {
    super('wallet-standard:register-wallet', { bubbles: false, cancelable: false, composed: false });
    this.#detail = callback;
  }

  // No one else on the page gets to stop the announcement.
  override preventDefault(): never {
    throw new Error('preventDefault cannot be called');
  }

  override stopImmediatePropagation(): never {
    throw new Error('stopImmediatePropagation cannot be called');
  }

  override stopPropagation(): never {
    throw new Error('stopPropagation cannot be called');
  }
}

export default defineContentScript({
  matches: MATCHES,
  world: 'MAIN',
  runAt: 'document_start',
  main() {
    // Taken before the page's own scripts run, so the page can't swap them out later.
    const post = window.postMessage.bind(window);
    const listen = window.addEventListener.bind(window);
    const origin = location.origin;
    const waiting = new Map<string, (answer: Answer) => void>();

    let accounts: ZandrAccount[] = [];
    // The page connected: it follows wallet switches in zandr until it disconnects.
    let following = false;
    const listeners = new Set<Listener>();

    listen('message', (event: MessageEvent) => {
      if (event.source !== window) return;
      const data = event.data as { channel?: unknown; to?: unknown; id?: unknown; response?: Answer; event?: unknown } | null;
      if (typeof data !== 'object' || data === null || data.channel !== CHANNEL || data.to !== 'page') return;
      if (data.event === 'changed') {
        refresh();
        return;
      }
      const resolve = typeof data.id === 'string' ? waiting.get(data.id) : undefined;
      if (!resolve || !data.response) return;
      waiting.delete(data.id as string);
      resolve(data.response);
    });

    async function ask(request: Record<string, unknown>): Promise<Extract<Answer, { ok: true }>> {
      const id = crypto.randomUUID();
      const answer = await new Promise<Answer>((resolve) => {
        waiting.set(id, resolve);
        post({ channel: CHANNEL, to: 'zandr', id, request }, origin);
      });
      if (!answer.ok) throw new WalletError(answer.message, answer.code);
      return answer;
    }

    function setAccounts(addresses: string[]) {
      if (addresses.length === accounts.length && addresses.every((address, i) => address === accounts[i]!.address)) return;
      accounts = addresses.map((address) => accounts.find((account) => account.address === address) ?? new ZandrAccount(address));
      for (const listener of [...listeners]) {
        try {
          listener({ accounts: accounts.slice() });
        } catch (error) {
          console.error(error);
        }
      }
    }

    // zandr switched wallets, or the site was disconnected in its settings.
    async function refresh() {
      if (!following) return;
      try {
        setAccounts((await ask({ type: 'dapp:connect', silent: true })).accounts ?? []);
      } catch {
        // Kept as it was; the next request will say what's wrong.
      }
    }

    // Requests are for the account the page was given; anything else is a page out of date.
    function checkAccount(input: { account?: { address?: unknown } } | undefined) {
      if (!accounts.length || input?.account?.address !== accounts[0]!.address) {
        throw new WalletError('This account is not connected to zandr.', 4100);
      }
    }

    function chainOf(inputs: TransactionInput[]): string | null {
      const chains = new Set(inputs.map((input) => input.chain ?? null));
      if (chains.size > 1) throw new WalletError('All transactions must be for the same network.', -32602);
      return [...chains][0] ?? null;
    }

    const bytes = (value: unknown, what: string) => {
      if (!(value instanceof Uint8Array)) throw new WalletError(`The ${what} must be a Uint8Array.`, -32602);
      return base64.encode(value);
    };

    async function connect(input?: { silent?: boolean }) {
      const answer = await ask({ type: 'dapp:connect', silent: input?.silent === true });
      if (answer.accounts?.length) following = true;
      setAccounts(answer.accounts ?? []);
      return { accounts: accounts.slice() };
    }

    async function disconnect() {
      following = false;
      setAccounts([]);
      await ask({ type: 'dapp:disconnect' });
    }

    async function signTransaction(...inputs: TransactionInput[]) {
      if (!inputs.length) return [];
      inputs.forEach(checkAccount);
      const answer = await ask({
        type: 'dapp:signTransactions',
        transactions: inputs.map((input) => bytes(input.transaction, 'transaction')),
        chain: chainOf(inputs),
      });
      return (answer.transactions ?? []).map((transaction) => ({ signedTransaction: base64.decode(transaction) }));
    }

    async function signAndSendTransaction(...inputs: TransactionInput[]) {
      if (!inputs.length) return [];
      inputs.forEach(checkAccount);
      const options = inputs[0]!.options ?? {};
      const answer = await ask({
        type: 'dapp:signAndSendTransactions',
        transactions: inputs.map((input) => bytes(input.transaction, 'transaction')),
        chain: chainOf(inputs),
        options: { skipPreflight: options.skipPreflight === true, maxRetries: options.maxRetries },
      });
      return (answer.signatures ?? []).map((signature) => ({ signature: base58.decode(signature) }));
    }

    // One approval per message.
    async function signMessage(...inputs: MessageInput[]) {
      const outputs = [];
      for (const input of inputs) {
        checkAccount(input);
        const message = bytes(input.message, 'message');
        const answer = await ask({ type: 'dapp:signMessage', message });
        outputs.push({ signedMessage: input.message.slice(), signature: base64.decode(answer.signature ?? ''), signatureType: 'ed25519' as const });
      }
      return outputs;
    }

    const wallet = Object.freeze({
      version: '1.0.0' as const,
      name: 'Zandr',
      icon: icon as `data:image/png;base64,${string}`,
      chains: CHAINS.slice(),
      get accounts() {
        return accounts.slice();
      },
      features: Object.freeze({
        'standard:connect': { version: '1.0.0', connect },
        'standard:disconnect': { version: '1.0.0', disconnect },
        'standard:events': {
          version: '1.0.0',
          on(event: string, listener: Listener) {
            if (event !== 'change') return () => {};
            listeners.add(listener);
            return () => void listeners.delete(listener);
          },
        },
        'solana:signAndSendTransaction': { version: '1.0.0', supportedTransactionVersions: VERSIONS, signAndSendTransaction },
        'solana:signTransaction': { version: '1.0.0', supportedTransactionVersions: VERSIONS, signTransaction },
        'solana:signMessage': { version: '1.0.0', signMessage },
      }),
    });

    const register = ({ register }: { register: (wallet: unknown) => unknown }) => register(wallet);
    try {
      window.dispatchEvent(new RegisterWalletEvent(register));
    } catch (error) {
      console.error('zandr: wallet-standard:register-wallet event could not be dispatched', error);
    }
    listen('wallet-standard:app-ready', (event) => {
      const api = (event as CustomEvent<{ register: (wallet: unknown) => unknown }>).detail;
      if (api && typeof api.register === 'function') register(api);
    });
  },
});
