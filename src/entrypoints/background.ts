import type { Browser } from 'wxt/browser';
import {
  ERASE_CHOICES,
  LIVE_PORT,
  PASSWORD_MIN_LENGTH,
  WALLET_NAME_MAX_LENGTH,
  type Request,
  type Response,
  type SendIntent,
} from '@/lib/messages';
import { eraseAfter, setEraseAfter, wasErased, wrongPassword } from '@/lib/guard';
import { addContact, removeContact } from '@/lib/addressBook';
import { createWallet, exportPhrase, exportPrivateKey, importWallet, removeWallet, reorderWallets } from '@/lib/wallets';
import { getPortfolio } from '@/lib/portfolio';
import { holdLive, rewatch } from '@/lib/live';
import { EXCHANGE_TOKENS_ALARM, refreshExchangeTokens } from '@/lib/exchangeTokens';
import { getActivity } from '@/lib/activity';
import { reclaimExecute, reclaimPlan } from '@/lib/reclaim';
import {
  announceChange,
  dappRequest,
  decideApproval,
  getApproval,
  handleDapp,
  listConnections,
  removeConnection,
  windowClosed,
} from '@/lib/dapp';
import { inspectRecipient, prepareSend, submitSend } from '@/lib/send';
import { sendStatus } from '@/lib/sent';
import { checkedPageIcon } from '@/lib/dappChannel';
import { executeSwap, swapQuote, swapTokens } from '@/lib/swap';
import { loadPreferences } from '@/lib/preferences';
import { addressOf, canonicalSecret, checkSecret, generatePhrase } from '@/lib/secrets';
import {
  AUTO_LOCK_ALARM,
  LockedError,
  TamperedError,
  changePassword,
  clearAddressBook,
  createVault,
  expireSession,
  getSession,
  getWallets,
  hasVault,
  lock,
  peekSession,
  readAddressBook,
  switchWallet,
  unlock,
  withPassword,
} from '@/lib/vault';

const EXTENSION_URL = browser.runtime.getURL('/');
const ONBOARDING_URL = browser.runtime.getURL('/onboarding.html');

// MV3 builds (Chrome) have `action`, MV2 builds (Firefox) have `browserAction`.
const toolbarButton = browser.action ?? browser.browserAction;

// Without a wallet there is nothing for the popup to show, so the toolbar button opens the
// onboarding page in a full tab instead: an empty popup makes clicks reach onClicked. With a
// wallet it opens the popup, or the side panel if the user chose side panel mode (Chrome only).
async function syncToolbarButton() {
  const hasWallet = await hasVault();
  const sidePanel = hasWallet && browser.sidePanel !== undefined && (await loadPreferences()).sidePanel;

  await toolbarButton.setPopup({ popup: hasWallet && !sidePanel ? 'popup.html' : '' });
  await browser.sidePanel?.setPanelBehavior({ openPanelOnActionClick: sidePanel });
}

// The toolbar icon is the mark in one color: black on light browser themes (the manifest's), white
// on dark ones. Chrome can't pick by theme itself, and a service worker can't see the theme, so a
// hidden page watches it and reports here.
const LIGHT_ICON = { 16: '/icon/16.png', 32: '/icon/32.png' };
const DARK_ICON = { 16: '/icon/dark/16.png', 32: '/icon/dark/32.png' };
const THEME_URL = browser.runtime.getURL('/offscreen.html');

async function watchTheme() {
  if (!browser.offscreen) return;
  const open = await browser.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [THEME_URL] });
  if (open.length) return;
  await browser.offscreen
    .createDocument({ url: THEME_URL, reasons: ['MATCH_MEDIA'], justification: "Matches the toolbar icon to the browser's light or dark theme." })
    // Created meanwhile by another wake-up.
    .catch(() => {});
}

// Switches to the onboarding tab if one is already open, otherwise opens a new one.
// getContexts is Chrome-only; elsewhere a click always opens a new tab.
async function openOnboarding() {
  // Clicks only get here without a wallet; never offer onboarding over an existing one.
  if (await hasVault()) return;

  const [open] =
    (await browser.runtime.getContexts?.({ contextTypes: ['TAB'], documentUrls: [ONBOARDING_URL] })) ?? [];

  if (open) {
    await browser.tabs.update(open.tabId, { active: true });
    await browser.windows.update(open.windowId, { focused: true });
  } else {
    await browser.tabs.create({ url: ONBOARDING_URL });
  }
}

// Only our own extension pages may talk to the background. Content scripts share
// our runtime.id but run inside untrusted web pages, so sender.url is the page's
// URL and they fail this check. dApp requests will get their own restricted channel.
function isTrustedSender(sender: Browser.runtime.MessageSender): boolean {
  return sender.id === browser.runtime.id && !!sender.url?.startsWith(EXTENSION_URL);
}

// A transfer as the page describes it, checked field by field: the background never trusts a page.
function sendIntent(value: unknown): SendIntent {
  const intent = value as Partial<SendIntent> | null;
  if (
    typeof intent !== 'object' ||
    intent === null ||
    typeof intent.from !== 'string' ||
    typeof intent.to !== 'string' ||
    typeof intent.amount !== 'string' ||
    (intent.mint !== null && typeof intent.mint !== 'string') ||
    intent.to.length > 100 ||
    intent.amount.length > 100
  ) {
    throw new Error('Invalid transfer');
  }
  return { from: intent.from, mint: intent.mint, to: intent.to, amount: intent.amount };
}

const short = (value: unknown, max = 100): value is string => typeof value === 'string' && value.length <= max;

// A web page, through zandr's content script in the tab's top frame: its origin, as Chrome reports
// it, if it's one sites may connect from (https, or a local development server).
function siteOrigin(sender: Browser.runtime.MessageSender): string | null {
  if (sender.id !== browser.runtime.id || sender.tab?.id === undefined || sender.frameId !== 0 || !sender.url) return null;
  try {
    const url = new URL(sender.origin ?? sender.url);
    const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
    return url.protocol === 'https:' || (url.protocol === 'http:' && local) ? url.origin : null;
  } catch {
    return null;
  }
}

function isRequest(message: unknown): message is Request {
  return (
    typeof message === 'object' &&
    message !== null &&
    typeof (message as { type?: unknown }).type === 'string'
  );
}

// Errors are logged, so they must never carry a secret or a password.
async function handle(request: Request): Promise<Response> {
  switch (request.type) {
    case 'theme:set':
      await toolbarButton.setIcon({ path: request.dark === true ? DARK_ICON : LIGHT_ICON });
      return { ok: true };

    case 'wallet:getStatus': {
      const account = await getSession();
      const hasWallet = await hasVault();
      return { hasWallet, locked: !account, account, erased: !hasWallet && (await wasErased()) };
    }

    case 'wallet:unlock':
      if (typeof request.password !== 'string') throw new Error('Invalid password');
      // Erased by an earlier wrong password, from another view: nothing to unlock any more.
      if (!(await hasVault())) return { unlocked: false, attemptsLeft: null, erased: await wasErased() };
      return (await unlock(request.password)) ? { unlocked: true } : { unlocked: false, ...(await wrongPassword()) };

    case 'wallet:lock':
      await lock();
      return { locked: true };

    case 'wallet:changePassword': {
      // The page checks these too, but the background never trusts a page with them.
      const { current, next } = request;
      if (typeof current !== 'string' || typeof next !== 'string') throw new Error('Invalid password');
      if (next.length < PASSWORD_MIN_LENGTH || next === current) throw new Error('Invalid new password');
      return (await changePassword(current, next)) ? { changed: true } : { changed: false, ...(await wrongPassword()) };
    }

    case 'security:getEraseAfter':
      return { eraseAfter: await eraseAfter() };

    case 'security:setEraseAfter': {
      const { eraseAfter: count, password } = request;
      if ((count !== null && !ERASE_CHOICES.includes(count)) || typeof password !== 'string') throw new Error('Invalid setting');
      if (!(await hasVault())) return { ok: false, error: 'no-wallet' };
      if ((await withPassword(password, () => true)) === null) return { ok: false, error: 'wrong-password', ...(await wrongPassword()) };
      await setEraseAfter(count);
      return { ok: true };
    }

    case 'wallets:list':
      return (await getWallets()) ?? { error: 'locked' };

    case 'wallets:switch':
      if (typeof request.id !== 'string') throw new Error('Invalid wallet');
      await switchWallet(request.id);
      return { ok: true };

    case 'wallets:create':
      if (typeof request.name !== 'string') throw new Error('Invalid name');
      if (!Array.isArray(request.words) || !request.words.every((word) => typeof word === 'string')) throw new Error('Invalid phrase');
      return createWallet(request.name, request.words);

    case 'wallets:import':
      if (typeof request.name !== 'string') throw new Error('Invalid name');
      return importWallet(request.secret, request.name);

    case 'wallets:exportKey':
      if (typeof request.id !== 'string' || typeof request.password !== 'string') throw new Error('Invalid request');
      return exportPrivateKey(request.id, request.password);

    case 'wallets:exportPhrase':
      if (typeof request.id !== 'string' || typeof request.password !== 'string') throw new Error('Invalid request');
      return exportPhrase(request.id, request.password);

    case 'wallets:remove':
      if (typeof request.id !== 'string' || typeof request.password !== 'string') throw new Error('Invalid request');
      return removeWallet(request.id, request.password);

    case 'wallets:reorder':
      if (!Array.isArray(request.ids) || request.ids.length > 100 || !request.ids.every((id) => typeof id === 'string')) throw new Error('Invalid request');
      return reorderWallets(request.ids);

    case 'portfolio:get': {
      // The open wallet polls this, so it doesn't count as activity: a side panel left open
      // still locks on time.
      const account = await peekSession();
      return account ? getPortfolio(account.address, request.refresh === true) : { error: 'locked' };
    }

    case 'activity:get': {
      // Polled like the coins: doesn't count as activity either.
      const account = await peekSession();
      if (!account) return { error: 'locked' };
      const mode = request.mode === 'refresh' || request.mode === 'more' ? request.mode : 'cached';
      return getActivity(account.address, mode);
    }

    case 'reclaim:plan':
      return reclaimPlan();

    case 'reclaim:execute': {
      const addresses = (list: unknown): list is string[] =>
        Array.isArray(list) && list.every((address) => typeof address === 'string' && address.length <= 64);
      if (!addresses(request.close) || !addresses(request.burn)) throw new Error('Invalid accounts');
      return reclaimExecute(request.close, request.burn, request.acknowledged === true);
    }

    case 'send:prepare':
      return prepareSend(sendIntent(request.intent));

    case 'send:inspect':
      if (typeof request.to !== 'string') throw new Error('Invalid address');
      await inspectRecipient(request.to.trim());
      return { ok: true };

    case 'send:submit': {
      const { maxFee } = request;
      if (typeof maxFee !== 'string') {
        throw new Error('Invalid transfer');
      }
      return submitSend(sendIntent(request.intent), maxFee);
    }

    case 'swap:tokens':
      if (!short(request.query, 64)) throw new Error('Invalid query');
      return swapTokens(request.query);

    case 'swap:quote':
      if (!short(request.inputMint) || !short(request.outputMint) || !short(request.amount)) throw new Error('Invalid swap');
      return swapQuote(request.inputMint, request.outputMint, request.amount);

    case 'swap:execute':
      if (!short(request.quoteId)) {
        throw new Error('Invalid swap');
      }
      return executeSwap(request.quoteId);

    case 'send:status':
      if (typeof request.signature !== 'string' || !/^[1-9A-HJ-NP-Za-km-z]{64,90}$/.test(request.signature)) throw new Error('Invalid signature');
      return sendStatus(request.signature, request.wait === true);

    case 'approval:get':
      if (typeof request.id !== 'string') throw new Error('Invalid approval');
      return getApproval(request.id, request.names === true);

    case 'approval:decide':
      if (typeof request.id !== 'string' || typeof request.approved !== 'boolean') throw new Error('Invalid approval');
      return decideApproval(request.id, request.approved, request.acknowledged === true);

    case 'approval:ping':
      return { ok: true };

    case 'connections:list':
      return listConnections();

    case 'connections:remove':
      if (typeof request.origin !== 'string') throw new Error('Invalid origin');
      await removeConnection(request.origin);
      return { ok: true };

    case 'addressBook:list':
      try {
        const contacts = await readAddressBook();
        return { contacts: contacts.sort((a, b) => a.name.localeCompare(b.name)) };
      } catch (error) {
        if (error instanceof LockedError) return { error: 'locked' };
        if (error instanceof TamperedError) return { error: 'tampered' };
        throw error;
      }

    case 'addressBook:add':
      if (typeof request.name !== 'string' || typeof request.address !== 'string') throw new Error('Invalid contact');
      return addContact(request.name, request.address);

    case 'addressBook:remove':
      if (typeof request.id !== 'string') throw new Error('Invalid contact');
      await removeContact(request.id);
      return { ok: true };

    case 'addressBook:clear':
      await clearAddressBook();
      return { ok: true };

    case 'phrase:generate':
      return { words: generatePhrase() };

    case 'onboarding:checkSecret':
      return checkSecret(request.secret);

    case 'onboarding:createWallet': {
      // The page checks these too, but the background never trusts a page with them.
      const { secret, password } = request;
      const name = typeof request.name === 'string' ? request.name.trim() : '';
      if (typeof password !== 'string' || password.length < PASSWORD_MIN_LENGTH) throw new Error('Invalid password');
      if (!name || name.length > WALLET_NAME_MAX_LENGTH) throw new Error('Invalid wallet name');
      if (!checkSecret(secret).ok) throw new Error('Invalid wallet secret');

      const canonical = canonicalSecret(secret);
      const address = addressOf(canonical);
      const keyring = { id: crypto.randomUUID(), secret: canonical };
      const wallet = { id: crypto.randomUUID(), name, address, keyring: keyring.id, account: 0 };
      await createVault({ keyrings: [keyring], wallets: [wallet] }, password);
      await syncToolbarButton();
      return { address };
    }
  }
}

export default defineBackground(() => {
  // Set on install, update and every browser start, so the button never depends on a
  // setting left over from an earlier session.
  browser.runtime.onInstalled.addListener(syncToolbarButton);
  browser.runtime.onStartup.addListener(syncToolbarButton);
  toolbarButton.onClicked.addListener(openOnboarding);
  watchTheme();
  // Side panel mode and the auto-lock time are preferences: apply changes right away. Reading
  // the session re-times auto-lock for an unlocked wallet. A wallet created, or erased after too
  // many wrong passwords, changes what the toolbar button opens.
  browser.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    if ('preferences' in changes || 'vault' in changes) syncToolbarButton();
    if ('preferences' in changes) getSession();
    // A custom RPC endpoint set or cleared: live coins come from it from now on.
    if ('preferences' in changes) rewatch();
    // Sites see whichever wallet is active: a switch may change what they're connected to.
    if ('activeWallet' in changes) announceChange();
  });

  // Closing an approval window says no to its request.
  browser.windows.onRemoved.addListener(windowClosed);

  // Auto-lock: the alarm fires when the session's time is up; a session that ran out while
  // the alarm couldn't fire is caught here on startup.
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === AUTO_LOCK_ALARM) lock();
    if (alarm.name === EXCHANGE_TOKENS_ALARM) refreshExchangeTokens();
  });

  // The exchanges' token lists, kept fresh from zandr's server: on every start, if they're due, and
  // every 12 hours.
  browser.alarms.get(EXCHANGE_TOKENS_ALARM).then((alarm) => {
    if (!alarm) browser.alarms.create(EXCHANGE_TOKENS_ALARM, { periodInMinutes: 12 * 60 });
  });
  refreshExchangeTokens();
  expireSession();

  // The encrypted vault lives in storage.local, which content scripts can read by default.
  // zandr's run on every site: keep the vault out of their reach.
  browser.storage.local.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });

  // An open popup or side panel watching the wallet's coins live; never a website.
  browser.runtime.onConnect.addListener((port) => {
    if (port.name === LIVE_PORT && port.sender && isTrustedSender(port.sender)) holdLive(port);
  });

  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    // Websites, through the content script: their own channel, with only what sites may ask.
    const origin = isTrustedSender(sender) ? null : siteOrigin(sender);
    if (origin) {
      const request = dappRequest(message);
      if (!request) return;
      handleDapp(request, origin, checkedPageIcon((message as { icon?: unknown } | null)?.icon, origin)).then(sendResponse, (error) => {
        console.error('Site request failed', request.type, error);
        sendResponse({ ok: false, code: -32603, message: 'zandr ran into an error.' });
      });
      return true;
    }

    if (!isTrustedSender(sender) || !isRequest(message)) return;

    handle(message).then(sendResponse, (error) => {
      console.error('Request failed', message.type, error);
      sendResponse(undefined);
    });
    return true; // keep the channel open for the async response
  });
});
