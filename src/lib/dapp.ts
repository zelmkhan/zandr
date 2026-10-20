// Websites connecting to zandr through the Wallet Standard, and what they may ask: to know the
// address, and to have transactions and messages signed. Requests arrive from zandr's content
// script; the site's origin is the one Chrome reports for the tab, never one the page claims.
// Nothing reaches a key until the user approves in zandr's own window, after zandr has taken the
// request apart and test-run it. Background only.
import { base58, base64 } from '@scure/base';
import { rpcEndpoints } from '@/lib/api';
import type { ApprovalView, ConnectedApp, DappRequest, DappResponse, ResponseMap, TxSummary, TxWarning } from '@/lib/messages';
import { loadPreferences, type Preferences } from '@/lib/preferences';
import { signMessage } from '@/lib/secrets';
import {
  ASSOCIATED_TOKEN_PROGRAM,
  COMPUTE_BUDGET_PROGRAM,
  SYSTEM_PROGRAM,
  TOKEN_2022_PROGRAM,
  TOKEN_PROGRAM,
  WRAPPED_SOL,
} from '@/lib/solana/addresses';
import { LookupError, decodeMessage, decodeTransaction, isWritable, resolveAccountKeys, withSignatureAt } from '@/lib/solana/message';
import { ChainError, getAccounts, parsedOf, rpc, type ParsedAccount } from '@/lib/solana/rpc';
import { knownNames, lookUpNames } from '@/lib/tokenNames';
import { formatUnits } from '@/lib/units';
import { getWallets, peekWallets, withActiveWallet } from '@/lib/vault';
import type { Network } from '@/server/api';

const CHAINS: Record<Network, string> = { mainnet: 'solana:mainnet', devnet: 'solana:devnet' };
const MAX_TRANSACTIONS = 10;
const MAX_MESSAGE_BYTES = 16 * 1024;

const PROGRAM_NAMES: Record<string, string> = {
  [SYSTEM_PROGRAM]: 'System',
  [TOKEN_PROGRAM]: 'Token',
  [TOKEN_2022_PROGRAM]: 'Token-2022',
  [ASSOCIATED_TOKEN_PROGRAM]: 'Associated token',
  [COMPUTE_BUDGET_PROGRAM]: 'Compute budget',
  MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr: 'Memo',
  Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo: 'Memo',
  JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4: 'Jupiter',
  whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc: 'Orca Whirlpools',
  '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8': 'Raydium AMM',
  CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK: 'Raydium CLMM',
  LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo: 'Meteora DLMM',
  Stake11111111111111111111111111111111111111: 'Stake',
  AddressLookupTab1e1111111111111111111111111: 'Address lookup table',
};

const short = (address: string) => `${address.slice(0, 4)}…${address.slice(-4)}`;

// At most this many tokens are looked up ahead, while a transaction is test-run.
const AHEAD_TOKENS = 30;
const error = (code: number, message: string): DappResponse => ({ ok: false, code, message });
const REJECTED = error(4001, 'The user rejected the request.');

// Sites the user connected, by origin: the wallets (opaque ids) each was connected to. Kept on
// disk so a site stays connected; the addresses themselves are only in the encrypted vault.
type Connections = Record<string, string[]>;

async function readConnections(): Promise<Connections> {
  const { connections } = await browser.storage.local.get('connections');
  return (connections as Connections | undefined) ?? {};
}

async function connectedTo(origin: string, walletId: string): Promise<boolean> {
  return (await readConnections())[origin]?.includes(walletId) ?? false;
}

// Connected sites' icons, by origin, as their pages declared them when connecting: for the list
// of connected apps. Gone with the connection.
async function readConnectionIcons(): Promise<Record<string, string>> {
  const { connectionIcons } = await browser.storage.local.get('connectionIcons');
  return (connectionIcons as Record<string, string> | undefined) ?? {};
}

// `icon`: the site's icon, kept along with the connection when there's one.
async function setConnection(origin: string, walletIds: string[], icon?: string | null) {
  const [connections, icons] = await Promise.all([readConnections(), readConnectionIcons()]);
  if (walletIds.length) connections[origin] = walletIds;
  else delete connections[origin];
  if (!walletIds.length) delete icons[origin];
  else if (icon) icons[origin] = icon;
  await browser.storage.local.set({ connections, connectionIcons: icons });
}

// Tells open pages to check which account they see: after a wallet switch, or a site being
// disconnected. zandr can't see tabs' addresses (that takes the "tabs" permission), so every tab
// is told; the bridge passes it on only to a page that was given an address.
export async function announceChange() {
  const tabs = await browser.tabs.query({});
  await Promise.all(
    tabs.map((tab) => (tab.id === undefined ? null : browser.tabs.sendMessage(tab.id, { type: 'dapp:changed' }, { frameId: 0 }).catch(() => {}))),
  );
}

export async function listConnections(): Promise<ResponseMap['connections:list']> {
  const connections = await readConnections();
  // Names only while unlocked; then sites connected only to wallets since removed are left out.
  const wallets = await getWallets();
  const icons = await readConnectionIcons();
  const names = new Map((wallets?.wallets ?? []).map((wallet) => [wallet.id, wallet.name]));
  const apps: ConnectedApp[] = Object.entries(connections)
    .map(([origin, ids]) => ({ origin, wallets: ids.map((id) => names.get(id)).filter((name): name is string => !!name), icon: icons[origin] ?? null }))
    .filter((app) => !wallets || app.wallets.length > 0);
  return { apps: apps.sort((a, b) => a.origin.localeCompare(b.origin)) };
}

export async function removeConnection(origin: string) {
  await setConnection(origin, []);
  await announceChange();
}

// Requests waiting for the user in an approval window, one per site at a time.
type Pending = {
  id: string;
  origin: string;
  // The site's icon, as its page declared it with the request.
  icon: string | null;
  request: DappRequest;
  windowId?: number;
  resolve: (response: DappResponse) => void;
  // Worked out for one wallet; done again if another becomes active. Started as the request comes
  // in (`analyzing`), so it runs while the window opens.
  analysis?: { walletId: string } & Analysis;
  analyzing?: { walletId: string; promise: Promise<Analysis> };
};

// `naming`: done once tokens' names still being looked up are there (nameTokens).
type Analysis = { view: Partial<ApprovalView>; signers: number[]; wires: Uint8Array[]; naming?: Promise<void> };

const pending = new Map<string, Pending>();

// Answers the site. The window closes, unless it has something left to tell the user.
function finish(id: string, response: DappResponse, close = true) {
  const entry = pending.get(id);
  if (!entry) return;
  pending.delete(id);
  entry.resolve(response);
  if (close && entry.windowId !== undefined) browser.windows.remove(entry.windowId).catch(() => {});
}

// Closing the window says no.
export function windowClosed(windowId: number) {
  for (const entry of pending.values()) if (entry.windowId === windowId) finish(entry.id, REJECTED);
}

// The approval window: a small window by the top right of the browser window in use.
async function openWindow(id: string): Promise<number | undefined> {
  const width = 360;
  const height = 620;
  const current = await browser.windows.getLastFocused().catch(() => null);
  const left = current?.left !== undefined && current.width ? Math.max(current.left + current.width - width - 16, 0) : undefined;
  const top = current?.top !== undefined ? current.top + 64 : undefined;
  const created = await browser.windows.create({ url: `${browser.runtime.getURL('/approval.html')}#${id}`, type: 'popup', width, height, left, top, focused: true });
  return created?.id;
}

function ask(origin: string, request: DappRequest, icon: string | null): Promise<DappResponse> {
  if ([...pending.values()].some((entry) => entry.origin === origin)) {
    return Promise.resolve(error(-32002, 'A request from this site is already waiting for approval in zandr.'));
  }
  const id = crypto.randomUUID();
  return new Promise((resolve) => {
    const entry: Pending = { id, origin, icon, request, resolve };
    pending.set(id, entry);
    startAnalysis(entry);
    openWindow(id).then(
      (windowId) => {
        const entry = pending.get(id);
        if (entry && windowId !== undefined) entry.windowId = windowId;
      },
      () => finish(id, error(-32603, "zandr couldn't open its approval window.")),
    );
  });
}

const activeAddress = (wallets: NonNullable<Awaited<ReturnType<typeof peekWallets>>>) =>
  wallets.wallets.find((wallet) => wallet.id === wallets.activeId)!.address;

// A site's request, from the content script. `origin` is the tab's, as Chrome reports it; `icon`
// the site's, as its page declares it (checkedPageIcon).
export async function handleDapp(request: DappRequest, origin: string, icon: string | null = null): Promise<DappResponse> {
  const wallets = await peekWallets();
  const preferences = await loadPreferences();

  switch (request.type) {
    case 'dapp:connect':
      if (wallets && (await connectedTo(origin, wallets.activeId))) return { ok: true, accounts: [activeAddress(wallets)] };
      // Asked quietly (a page loading): no window, just "not connected". Locked counts too: the
      // address can't be known without the password.
      if (request.silent) return { ok: true, accounts: [] };
      return ask(origin, request, icon);

    case 'dapp:disconnect': {
      const connections = await readConnections();
      const left = wallets ? (connections[origin] ?? []).filter((id) => id !== wallets.activeId) : [];
      await setConnection(origin, left);
      // The site's other tabs follow.
      await announceChange();
      return { ok: true };
    }

    case 'dapp:signTransactions':
    case 'dapp:signAndSendTransactions':
      if (request.transactions.length === 0 || request.transactions.length > MAX_TRANSACTIONS) return error(-32602, 'Send 1 to 10 transactions.');
      if (request.chain !== null && request.chain !== CHAINS[preferences.network]) {
        return error(-32602, `zandr is on ${preferences.network === 'mainnet' ? 'Mainnet' : 'Devnet'}, this app on ${request.chain}. Switch networks in zandr's settings.`);
      }
      if (wallets && !(await connectedTo(origin, wallets.activeId))) return error(4100, 'This site is not connected to zandr.');
      return ask(origin, request, icon);

    case 'dapp:signMessage':
      if (base64.decode(request.message).length > MAX_MESSAGE_BYTES) return error(-32602, 'The message is too long.');
      if (wallets && !(await connectedTo(origin, wallets.activeId))) return error(4100, 'This site is not connected to zandr.');
      return ask(origin, request, icon);
  }
}

// --- What the approval window shows ---

type Simulation = { err: unknown; logs: string[] | null; accounts?: (ParsedAccount | null)[] | null };

function whyFailed(simulation: Simulation): string {
  const said = (simulation.logs ?? []).findLast((line) => /^Program log: (Error|error)/.test(line));
  return (said?.replace(/^Program log: (Error: )?/, '') ?? JSON.stringify(simulation.err)).slice(0, 160);
}

// What a transaction does to the wallet, and what to watch out for. `blocked` when it can't be
// signed at all. `unnamed`: tokens it moves whose names aren't known yet (nameTokens).
async function summarize(
  url: string,
  preferences: Preferences,
  wire: Uint8Array,
  from: string,
): Promise<{ summary: TxSummary; signer: number; unnamed?: string[] }> {
  const blank: TxSummary = { changes: [], fee: '0', payer: false, programs: [], warnings: [], failure: null, blocked: null };
  let transaction;
  try {
    transaction = decodeTransaction(wire);
  } catch {
    return { summary: { ...blank, blocked: "zandr can't read this transaction." }, signer: -1 };
  }
  const { message } = transaction;
  const signer = message.staticKeys.slice(0, message.signers).indexOf(from);
  if (signer < 0) return { summary: { ...blank, blocked: "It doesn't need this wallet's signature." }, signer };

  let keys: string[];
  try {
    keys = await resolveAccountKeys(url, message, preferences.network);
  } catch (cause) {
    if (cause instanceof LookupError) return { summary: { ...blank, blocked: "It refers to an address table that isn't one." }, signer };
    throw cause;
  }

  // Instructions that hand over control of the wallet's things, at the top level.
  const warnings: TxWarning[] = [];
  let units = 200_000n * BigInt(Math.max(message.instructions.length, 1));
  let price = 0n;
  for (const instruction of message.instructions) {
    const program = keys[instruction.program];
    const account = (index: number) => keys[instruction.accounts[index] ?? -1];
    const data = instruction.data;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    if (program === COMPUTE_BUDGET_PROGRAM) {
      if (data[0] === 2 && data.length === 5) units = BigInt(view.getUint32(1, true));
      if (data[0] === 3 && data.length === 9) price = view.getBigUint64(1, true);
    } else if (program === SYSTEM_PROGRAM && data.length >= 4 && view.getUint32(0, true) === 1 && account(0) === from) {
      warnings.push({
        level: 'danger',
        title: 'Hands your wallet account to a program',
        text: 'It reassigns this wallet’s account to another program, which could then take everything in it. Wallet drainers do exactly this.',
      });
    } else if (program === TOKEN_PROGRAM || program === TOKEN_2022_PROGRAM) {
      const op = data[0];
      if ((op === 4 && account(2) === from) || (op === 13 && account(3) === from)) {
        const delegate = account(op === 4 ? 1 : 2) ?? '';
        warnings.push({
          level: 'danger',
          title: `Lets ${short(delegate)} spend your tokens`,
          text: 'It approves another address to move tokens out of one of your token accounts, now or any time later, without asking you again.',
        });
      } else if (op === 6 && account(1) === from) {
        warnings.push({
          level: 'danger',
          title: 'Hands over one of your token accounts',
          text: 'It gives control of one of your token accounts, and what’s in it, to someone else.',
        });
      } else if (op === 9 && account(2) === from && account(1) !== from) {
        warnings.push({
          level: 'caution',
          title: 'Sends a closed account’s SOL elsewhere',
          text: `It closes one of your token accounts and sends the SOL it held to ${short(account(1) ?? '')}, not to you.`,
        });
      }
    }
  }
  const programs = [...new Set(message.instructions.map((instruction) => keys[instruction.program]!))].map(
    (program) => PROGRAM_NAMES[program] ?? short(program),
  );
  const fee = 5_000n * BigInt(message.signers) + (price * units + 999_999n) / 1_000_000n;

  // The test run: the wallet and every account the transaction may write to, before and after.
  const watched = [...new Set([from, ...keys.filter((_, index) => isWritable(message, index))])].slice(0, 64);
  const reading = getAccounts(url, watched);
  // While the test runs, the tokens it may move are looked up: those of the token accounts it
  // writes to, the pools' included, so a token bought is likely among them.
  reading.then((accounts) => lookAhead(preferences, accounts)).catch(() => {});
  const [before, { value: simulation }] = await Promise.all([
    reading,
    rpc<{ value: Simulation }>(url, 'simulateTransaction', [
      base64.encode(wire),
      { encoding: 'base64', sigVerify: false, replaceRecentBlockhash: true, commitment: 'confirmed', accounts: { addresses: watched, encoding: 'jsonParsed' } },
    ]),
  ]);
  if (simulation.err) {
    warnings.push({ level: 'caution', title: 'This transaction would fail', text: `The network's test run failed: ${whyFailed(simulation)}` });
    return { summary: { changes: [], fee: formatUnits(fee, 9), payer: signer === 0, programs, warnings, failure: whyFailed(simulation), blocked: null }, signer };
  }

  // SOL: what the wallet's balance moves by, the fee aside (the test run takes it too).
  const after = simulation.accounts ?? [];
  const lamports = (account: ParsedAccount | null | undefined) => BigInt(account?.lamports ?? 0);
  const at = watched.indexOf(from);
  let sol = lamports(after[at]) - lamports(before[at]);
  if (signer === 0) sol += fee;

  // Tokens: every account the wallet owns among those written, by mint.
  const tokens = new Map<string, { change: bigint; decimals: number }>();
  watched.forEach((_, index) => {
    for (const [state, sign] of [
      [before[index], -1n],
      [after[index], 1n],
    ] as const) {
      const info = parsedOf(state ?? null);
      const amount = (info?.info?.tokenAmount as { amount?: string; decimals?: number } | undefined) ?? undefined;
      if (info?.type !== 'account' || info.info?.owner !== from || typeof info.info?.mint !== 'string' || !amount?.amount) continue;
      const entry = tokens.get(info.info.mint) ?? { change: 0n, decimals: amount.decimals ?? 0 };
      entry.change += sign * BigInt(amount.amount);
      tokens.set(info.info.mint, entry);
    }
  });

  const signed = (value: bigint, decimals: number) => `${value < 0n ? '-' : '+'}${formatUnits(value < 0n ? -value : value, decimals)}`;
  const moved = [...tokens].filter(([, entry]) => entry.change !== 0n);
  // Names and logos, as far as they're known by now: the window doesn't wait for the rest. SOL's
  // logo is wrapped SOL's.
  const mints = [...moved.map(([mint]) => mint), ...(sol !== 0n ? [WRAPPED_SOL] : [])];
  const names = await knownNames(preferences.network, mints);
  const changes = [
    ...(sol !== 0n ? [{ mint: null, symbol: 'SOL', logo: names.get(WRAPPED_SOL)?.logo ?? null, verified: true, amount: signed(sol, 9) }] : []),
    ...moved.map(([mint, entry]) => {
      const token = names.get(mint);
      return { mint, symbol: token?.symbol ?? null, logo: token?.logo ?? null, verified: token?.verified ?? false, amount: signed(entry.change, entry.decimals) };
    }),
  ];
  const unnamed = preferences.network === 'mainnet' ? mints.filter((mint) => !names.has(mint)) : [];
  return { summary: { changes, fee: formatUnits(fee, 9), payer: signer === 0, programs, warnings, failure: null, blocked: null }, signer, unnamed };
}

// Starts looking up the tokens of these token accounts, those not known already.
async function lookAhead(preferences: Preferences, accounts: (ParsedAccount | null)[]) {
  const mints = new Set<string>();
  for (const account of accounts) {
    const info = parsedOf(account);
    if (info?.type === 'account' && typeof info.info?.mint === 'string') mints.add(info.info.mint);
  }
  const known = await knownNames(preferences.network, [...mints]);
  const unknown = [...mints].filter((mint) => !known.has(mint)).slice(0, AHEAD_TOKENS);
  if (unknown.length) await lookUpNames(preferences, unknown);
}

// Names the tokens a window shows by address for now, once the token list answers. The window
// asks again while `namesPending`. The answer may take a while: the token list limits how often
// it's asked.
function nameTokens(view: Partial<ApprovalView>, preferences: Preferences, mints: string[]): Promise<void> {
  view.namesPending = true;
  return lookUpNames(preferences, mints)
    .then((names) => {
      for (const change of (view.transactions ?? []).flatMap((tx) => tx.changes)) {
        const name = names.get(change.mint ?? WRAPPED_SOL);
        if (!name) continue;
        // SOL takes only wrapped SOL's logo.
        if (change.mint === null) change.logo = name.logo;
        else Object.assign(change, { symbol: name.symbol, logo: name.logo, verified: name.verified });
      }
    })
    .catch(() => {})
    .finally(() => (view.namesPending = false));
}

// A message to sign: as text if it reads as text. One that is in fact a transaction is refused:
// signing it would sign the transaction, a known drainer trick.
function readMessage(bytes: Uint8Array, from: string): NonNullable<ApprovalView['message']> {
  const hex = Array.from(bytes.slice(0, 512), (byte) => byte.toString(16).padStart(2, '0')).join(' ');
  try {
    const message = decodeMessage(bytes);
    if (message.staticKeys.includes(from)) return { text: null, hex, blocked: 'This “message” is a transaction that moves this wallet’s funds. zandr won’t sign it.' };
  } catch {
    // Not a transaction: as it should be.
  }
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    // Readable text only: no control characters other than line breaks and tabs.
    if (!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f‪-‮⁦-⁩]/.test(text)) return { text, hex, blocked: null };
  } catch {
    // Not UTF-8.
  }
  return { text: null, hex, blocked: null };
}

// What a signing request would do, worked out before the window asks: the window opening and the
// test run then happen at the same time. Only while unlocked (the wallet's address is needed) and
// without counting as activity; otherwise the window's own ask starts it.
function startAnalysis(entry: Pending) {
  if (entry.request.type === 'dapp:connect' || entry.request.type === 'dapp:disconnect') return;
  void Promise.all([peekWallets(), loadPreferences()]).then(([wallets, preferences]) => {
    const active = wallets?.wallets.find((wallet) => wallet.id === wallets.activeId);
    if (!active || entry.analyzing || !pending.has(entry.id)) return;
    const promise = analyze(entry, active.address, preferences);
    // Failures surface when the window waits on it.
    promise.catch(() => {});
    entry.analyzing = { walletId: active.id, promise };
  });
}

// A message as text, or each transaction decoded, its lookup tables read and test-run.
async function analyze(entry: Pending, address: string, preferences: Preferences): Promise<Analysis> {
  const { request } = entry;
  if (request.type === 'dapp:signMessage') {
    return { view: { message: readMessage(base64.decode(request.message), address) }, signers: [], wires: [] };
  }
  if (request.type === 'dapp:connect' || request.type === 'dapp:disconnect') return { view: {}, signers: [], wires: [] };
  const url = rpcEndpoints(preferences)[preferences.network];
  const send = request.type === 'dapp:signAndSendTransactions';
  const wires = request.transactions.map((transaction) => base64.decode(transaction));
  try {
    const results = await Promise.all(wires.map((wire) => summarize(url, preferences, wire, address)));
    const view: Partial<ApprovalView> = { send, transactions: results.map((result) => result.summary) };
    const unnamed = [...new Set(results.flatMap((result) => result.unnamed ?? []))];
    const naming = unnamed.length ? nameTokens(view, preferences, unnamed) : undefined;
    return { view, signers: results.map((result) => result.signer), wires, naming };
  } catch (cause) {
    if (!(cause instanceof ChainError)) throw cause;
    // The test run couldn't happen: say so, and let the user decide without it.
    const failure = `zandr couldn't test-run it: the network ${cause.reason === 'forbidden' ? 'refused' : 'is unreachable'}.`;
    const summaries = wires.map((wire) => {
      try {
        const decoded = decodeTransaction(wire);
        const signer = decoded.message.staticKeys.slice(0, decoded.message.signers).indexOf(address);
        return {
          summary: {
            changes: [],
            fee: '?',
            payer: signer === 0,
            programs: [],
            warnings: [{ level: 'caution', title: 'Not checked', text: failure }],
            failure,
            blocked: signer < 0 ? "It doesn't need this wallet's signature." : null,
          } satisfies TxSummary,
          signer,
        };
      } catch {
        const summary: TxSummary = { changes: [], fee: '?', payer: false, programs: [], warnings: [], failure, blocked: "zandr can't read this transaction." };
        return { summary, signer: -1 };
      }
    });
    return { view: { send, transactions: summaries.map((result) => result.summary) }, signers: summaries.map((result) => result.signer), wires };
  }
}

// How long a window asking for tokens' names (`names`) waits for them at most, before it's
// answered anyway.
const NAMES_WAIT_MS = 3_000;

export async function getApproval(id: string, names = false): Promise<ResponseMap['approval:get']> {
  let entry = pending.get(id);
  if (!entry) return { ok: false, done: true };
  if (names && entry.analysis?.naming) {
    await Promise.race([entry.analysis.naming, new Promise((resolve) => setTimeout(resolve, NAMES_WAIT_MS))]);
    // Answered meanwhile.
    entry = pending.get(id);
    if (!entry) return { ok: false, done: true };
  }
  const preferences = await loadPreferences();
  const network = preferences.network;
  const kind = entry.request.type === 'dapp:connect' ? 'connect' : entry.request.type === 'dapp:signMessage' ? 'message' : 'transactions';
  // The page's icon came with the request, or was kept with the site's connection.
  const icon = entry.icon ?? (await readConnectionIcons())[entry.origin] ?? null;
  const base = { id, origin: entry.origin, icon, kind, network } as const;

  // Opening the window counts as activity.
  const wallets = await getWallets();
  if (!wallets) return { ok: true, approval: { ...base, locked: true, wallet: null } };
  const active = wallets.wallets.find((wallet) => wallet.id === wallets.activeId)!;
  const wallet = { name: active.name, address: active.address };
  const connected = await connectedTo(entry.origin, active.id);

  if (kind === 'connect') {
    // Connected already, as it turns out once unlocked: nothing to ask.
    if (connected) {
      finish(id, { ok: true, accounts: [active.address] });
      return { ok: false, done: true };
    }
    return { ok: true, approval: { ...base, locked: false, wallet } };
  }
  if (!connected) {
    finish(id, error(4100, 'This site is not connected to the wallet now active in zandr.'));
    return { ok: false, done: true };
  }

  // Worked out as the request came in, if the wallet was unlocked then; else now.
  if (entry.analysis?.walletId !== active.id) {
    const running = entry.analyzing?.walletId === active.id ? entry.analyzing.promise : analyze(entry, active.address, preferences);
    entry.analysis = { walletId: active.id, ...(await running) };
  }
  return { ok: true, approval: { ...base, locked: false, wallet, ...entry.analysis!.view } };
}

export async function decideApproval(id: string, approved: boolean, acknowledged: boolean): Promise<ResponseMap['approval:decide']> {
  const entry = pending.get(id);
  if (!entry) return { ok: false, error: 'gone' };
  if (!approved) {
    finish(id, REJECTED);
    return { ok: true };
  }
  const wallets = await getWallets();
  if (!wallets) return { ok: false, error: 'locked' };
  const active = wallets.wallets.find((wallet) => wallet.id === wallets.activeId)!;
  const { request } = entry;

  if (request.type === 'dapp:connect') {
    const connections = await readConnections();
    await setConnection(entry.origin, [...new Set([...(connections[entry.origin] ?? []), active.id])], entry.icon);
    finish(id, { ok: true, accounts: [active.address] });
    return { ok: true };
  }

  // Signing only what was shown, for the wallet it was shown for.
  const analysis = entry.analysis;
  if (!analysis || analysis.walletId !== active.id || !(await connectedTo(entry.origin, active.id))) return { ok: false, error: 'gone' };

  if (request.type === 'dapp:signMessage') {
    if (analysis.view.message?.blocked) return { ok: false, error: 'blocked' };
    const bytes = base64.decode(request.message);
    const signature = await withActiveWallet((wallet, secret) => {
      const signed = signMessage(secret, wallet.account, bytes);
      if (signed.address !== active.address) throw new Error('The key does not belong to the active wallet');
      return signed.signature;
    });
    finish(id, { ok: true, signature: base64.encode(signature) });
    return { ok: true };
  }

  const summaries = analysis.view.transactions ?? [];
  if (summaries.some((summary) => summary.blocked)) return { ok: false, error: 'blocked' };
  if (summaries.some((summary) => summary.warnings.some((warning) => warning.level === 'danger')) && !acknowledged) {
    return { ok: false, error: 'unacknowledged' };
  }

  const signed = await withActiveWallet((wallet, secret) =>
    analysis.wires.map((wire, index) => {
      const transaction = decodeTransaction(wire);
      const result = signMessage(secret, wallet.account, transaction.messageBytes);
      if (result.address !== active.address) throw new Error('The key does not belong to the active wallet');
      return { wire: withSignatureAt(transaction, analysis.signers[index]!, result.signature), signature: result.signature };
    }),
  );

  if (request.type === 'dapp:signTransactions') {
    finish(id, { ok: true, transactions: signed.map((transaction) => base64.encode(transaction.wire)) });
    return { ok: true };
  }

  const options = request.type === 'dapp:signAndSendTransactions' ? request.options : {};
  const preferences = await loadPreferences();
  const url = rpcEndpoints(preferences)[preferences.network];
  const signatures: string[] = [];
  try {
    for (const transaction of signed) {
      await rpc<string>(url, 'sendTransaction', [
        base64.encode(transaction.wire),
        {
          encoding: 'base64',
          skipPreflight: options.skipPreflight === true,
          preflightCommitment: 'confirmed',
          ...(typeof options.maxRetries === 'number' ? { maxRetries: options.maxRetries } : {}),
        },
      ]);
      signatures.push(base58.encode(transaction.signature));
    }
  } catch (cause) {
    const detail = cause instanceof ChainError ? (cause.detail ?? cause.reason) : 'unknown error';
    // Sent ones are out; the site hears of the failure, and the window shows it.
    finish(id, error(-32603, `The network refused the transaction: ${detail}`), false);
    return { ok: false, error: 'failed', detail };
  }
  finish(id, { ok: true, signatures });
  return { ok: true };
}

// The shape of a site's request, checked: it comes from a web page.
export function dappRequest(value: unknown): DappRequest | null {
  const request = value as Record<string, unknown> | null;
  if (typeof request !== 'object' || request === null || typeof request.type !== 'string') return null;
  const isBase64 = (text: unknown) => {
    if (typeof text !== 'string' || text.length > 4 * 1024 * 1024) return false;
    try {
      base64.decode(text);
      return true;
    } catch {
      return false;
    }
  };
  const chain = request.chain === null || request.chain === undefined ? null : typeof request.chain === 'string' && request.chain.length < 64 ? request.chain : undefined;
  switch (request.type) {
    case 'dapp:connect':
      return { type: 'dapp:connect', silent: request.silent === true };
    case 'dapp:disconnect':
      return { type: 'dapp:disconnect' };
    case 'dapp:signTransactions':
    case 'dapp:signAndSendTransactions': {
      const transactions = request.transactions;
      if (!Array.isArray(transactions) || !transactions.every(isBase64) || chain === undefined) return null;
      if (request.type === 'dapp:signTransactions') return { type: 'dapp:signTransactions', transactions, chain };
      const options = (typeof request.options === 'object' && request.options !== null ? request.options : {}) as Record<string, unknown>;
      return {
        type: 'dapp:signAndSendTransactions',
        transactions,
        chain,
        options: {
          skipPreflight: options.skipPreflight === true,
          ...(Number.isInteger(options.maxRetries) && (options.maxRetries as number) >= 0 && (options.maxRetries as number) <= 10 ? { maxRetries: options.maxRetries as number } : {}),
        },
      };
    }
    case 'dapp:signMessage':
      return isBase64(request.message) ? { type: 'dapp:signMessage', message: request.message as string } : null;
    default:
      return null;
  }
}
