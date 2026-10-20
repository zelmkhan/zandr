// The encrypted wallet on disk and the unlocked session in memory. Background only: never
// import this from a page.
//
// On disk (storage.local): the recovery phrases and private keys of every wallet, encrypted with
// AES-256-GCM under a key derived from the password with scrypt (N = 2^17, r = 8, p = 1, OWASP's
// minimum: 128 MiB of memory per guess, which makes GPU cracking expensive). Salt and IV are
// random on every write. Addresses and wallet names are inside the ciphertext too, so the disk
// doesn't reveal whose wallets these are. The KDF parameters are stored with the vault, so they
// can be raised later without breaking existing wallets.
//
// While unlocked (storage.session): only the derived vault key, never the phrase. Session
// storage lives in memory, is never written to disk, is cleared when the browser closes, and
// by default is readable by the extension's own pages and background but not by content
// scripts. An alarm wipes it after the auto-lock time (a preference) since the last activity,
// even if nothing else wakes the background by then.
import { scryptAsync } from '@noble/hashes/scrypt.js';
import { base64 } from '@scure/base';
import { DEFAULT_WALLET_NAME, type Account, type Contact, type WalletSecret, type WalletSummary } from '@/lib/messages';
import { passwordAccepted, passwordRejected } from '@/lib/guard';
import { loadPreferences } from '@/lib/preferences';

const SCRYPT = { N: 2 ** 17, r: 8, p: 1 };
async function autoLockAt(): Promise<number> {
  return Date.now() + (await loadPreferences()).autoLockMinutes * 60 * 1000;
}
export const AUTO_LOCK_ALARM = 'auto-lock';

type Vault = {
  version: 1;
  kdf: { name: 'scrypt'; N: number; r: number; p: number; salt: string };
  iv: string;
  ciphertext: string;
};

// What the ciphertext holds. A keyring is a recovery phrase or a private key; each wallet is
// one address from a keyring: account N of a phrase, or the key's only address (N = 0).
export type Keyring = { id: string; secret: WalletSecret };
export type WalletEntry = WalletSummary & { keyring: string; account: number };
export type VaultContents = { keyrings: Keyring[]; wallets: WalletEntry[] };

// The first vaults held a single wallet: read as a list of one.
type SingleWalletContents = Partial<Account> & { secret: WalletSecret };

function parseContents(plaintext: Bytes): VaultContents {
  const parsed = JSON.parse(decoder.decode(plaintext)) as VaultContents | SingleWalletContents;
  if ('wallets' in parsed) return parsed;
  const { secret, address, name = DEFAULT_WALLET_NAME } = parsed;
  return {
    keyrings: [{ id: 'keyring-1', secret }],
    wallets: [{ id: 'wallet-1', name, address: address!, keyring: 'keyring-1', account: 0 }],
  };
}

// The address book: encrypted apart from the vault, so reading or editing it never decrypts the
// recovery phrase, but under a key derived from the vault key, so only the password opens it.
// AES-GCM authenticates it too: an entry changed or slipped in outside zandr fails to decrypt
// instead of being trusted.
type AddressBookBlob = { version: 1; iv: string; ciphertext: string };

export class LockedError extends Error {
  constructor() {
    super('The wallet is locked');
  }
}

export class TamperedError extends Error {
  constructor() {
    super('The address book failed verification');
  }
}

// The wallet list lives in the session too, so the switcher never has to decrypt a phrase.
type Session = { key: string; wallets: WalletSummary[]; activeId: string; expiresAt: number };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function readVault(): Promise<Vault | undefined> {
  const { vault } = await browser.storage.local.get('vault');
  return vault as Vault | undefined;
}

export async function hasVault(): Promise<boolean> {
  return (await readVault()) !== undefined;
}

// The libraries type their output as possibly shared memory, which WebCrypto refuses; it is
// always a plain ArrayBuffer. Narrowing the type avoids copying key material around.
type Bytes = Uint8Array<ArrayBuffer>;
const decode64 = (text: string) => base64.decode(text) as Bytes;

// The password is normalized so that the same characters typed on another keyboard or OS,
// which may compose accents differently, still unlock the wallet.
async function deriveKey(password: string, kdf: Vault['kdf']): Promise<Bytes> {
  const { N, r, p, salt } = kdf;
  return (await scryptAsync(encoder.encode(password.normalize('NFKC')), decode64(salt), { N, r, p, dkLen: 32 })) as Bytes;
}

function aesKey(raw: Bytes): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

// Encrypts under a password with a fresh salt and IV and today's KDF parameters. Returns the
// derived key too, for the session; the caller wipes it.
async function seal(plaintext: Bytes, password: string): Promise<{ vault: Vault; key: Bytes }> {
  const kdf = { name: 'scrypt' as const, ...SCRYPT, salt: base64.encode(crypto.getRandomValues(new Uint8Array(32))) };
  const key = await deriveKey(password, kdf);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  try {
    const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await aesKey(key), plaintext);
    return { vault: { version: 1, kdf, iv: base64.encode(iv), ciphertext: base64.encode(new Uint8Array(ciphertext)) }, key };
  } catch (error) {
    key.fill(0);
    throw error;
  }
}

// Decrypts with a password: the plaintext and the derived key, or null if the password is wrong
// (AES-GCM authentication fails). The caller wipes both. Every password zandr asks for is checked
// here, so here is where wrong ones are counted (lib/guard.ts): with the guard on, the last one
// allowed erases everything.
async function open(vault: Vault, password: string): Promise<{ plaintext: Bytes; key: Bytes } | null> {
  const key = await deriveKey(password, vault.kdf);
  let plaintext: Bytes;
  try {
    const iv = decode64(vault.iv);
    plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await aesKey(key), decode64(vault.ciphertext)));
  } catch (error) {
    key.fill(0);
    if (!(error instanceof DOMException && error.name === 'OperationError')) throw error;
    await passwordRejected();
    return null;
  }
  await passwordAccepted();
  return { plaintext, key };
}

// A key just for the address book, derived from the vault key (HKDF), so the two never share a key.
async function addressBookKey(vaultKey: Bytes): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey('raw', vaultKey, 'HKDF', false, ['deriveKey']);
  const params = { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: encoder.encode('zandr address book v1') };
  return crypto.subtle.deriveKey(params, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function sealAddressBook(contacts: Contact[], vaultKey: Bytes): Promise<AddressBookBlob> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(contacts));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await addressBookKey(vaultKey), plaintext);
  return { version: 1, iv: base64.encode(iv), ciphertext: base64.encode(new Uint8Array(ciphertext)) };
}

async function openAddressBook(blob: AddressBookBlob, vaultKey: Bytes): Promise<Contact[]> {
  try {
    const iv = decode64(blob.iv);
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await addressBookKey(vaultKey), decode64(blob.ciphertext));
    return JSON.parse(decoder.decode(plaintext)) as Contact[];
  } catch (error) {
    if (error instanceof DOMException && error.name === 'OperationError') throw new TamperedError();
    throw error;
  }
}

async function readAddressBookBlob(): Promise<AddressBookBlob | undefined> {
  const { addressBook } = await browser.storage.local.get('addressBook');
  return addressBook as AddressBookBlob | undefined;
}

// What's worth showing at once when the wallet is opened again, kept between sessions: the coins
// and history as last fetched, by key. Encrypted like the address book, under its own key from the
// vault key, so nothing about the wallets can be read on disk without the password; anything that
// doesn't decrypt (written under another password, or changed) counts as nothing kept.
type CacheBlob = { version: 1; iv: string; ciphertext: string };
type CacheEntries = Record<string, { at: number; value: unknown }>;

// Entries kept, the most recently written: a few wallets on both networks.
const CACHE_LIMIT = 16;

async function cacheKey(vaultKey: Bytes): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey('raw', vaultKey, 'HKDF', false, ['deriveKey']);
  const params = { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: encoder.encode('zandr cache v1') };
  return crypto.subtle.deriveKey(params, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function openCache(vaultKey: Bytes): Promise<CacheEntries> {
  const { cache } = await browser.storage.local.get('cache');
  const blob = cache as CacheBlob | undefined;
  if (!blob) return {};
  try {
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: decode64(blob.iv) }, await cacheKey(vaultKey), decode64(blob.ciphertext));
    return JSON.parse(decoder.decode(plaintext)) as CacheEntries;
  } catch {
    return {};
  }
}

// What was kept under `key`, or null: also while locked.
export async function readCached<T>(key: string): Promise<T | null> {
  const vaultKey = await sessionKey().catch(() => null);
  if (!vaultKey) return null;
  try {
    return ((await openCache(vaultKey))[key]?.value as T | undefined) ?? null;
  } finally {
    vaultKey.fill(0);
  }
}

// Keeps `value` under `key`, one write at a time. Nothing is written while locked.
let cacheWrites: Promise<unknown> = Promise.resolve();

export function writeCached(key: string, value: unknown): Promise<void> {
  const write = cacheWrites.then(async () => {
    const vaultKey = await sessionKey().catch(() => null);
    if (!vaultKey) return;
    try {
      const entries = await openCache(vaultKey);
      entries[key] = { at: Date.now(), value };
      const kept = Object.fromEntries(Object.entries(entries).sort(([, a], [, b]) => b.at - a.at).slice(0, CACHE_LIMIT));
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await cacheKey(vaultKey), encoder.encode(JSON.stringify(kept)));
      const blob: CacheBlob = { version: 1, iv: base64.encode(iv), ciphertext: base64.encode(new Uint8Array(ciphertext)) };
      await browser.storage.local.set({ cache: blob });
    } finally {
      vaultKey.fill(0);
    }
  });
  cacheWrites = write.catch(() => {});
  return write;
}

// The vault key from the unlocked session; the caller wipes it. Throws when locked.
async function sessionKey(): Promise<Bytes> {
  const session = await readSession();
  if (!session) throw new LockedError();
  return decode64(session.key);
}

// Vault writes run one at a time, so two quick requests can't both pass the "no wallet yet"
// check and the second overwrite the first, or a password change race another write.
let writes: Promise<unknown> = Promise.resolve();

function serialized<T>(write: () => Promise<T>): Promise<T> {
  const task = writes.then(write);
  writes = task.catch(() => {});
  return task;
}

// Encrypts and stores a new wallet, then unlocks it. Never overwrites an existing wallet.
export function createVault(contents: VaultContents, password: string): Promise<void> {
  return serialized(async () => {
    if (await hasVault()) throw new Error('A wallet already exists');

    const plaintext = encoder.encode(JSON.stringify(contents)) as Bytes;
    const { vault, key } = await seal(plaintext, password).finally(() => plaintext.fill(0));
    try {
      await browser.storage.local.set({ vault, activeWallet: contents.wallets[0]!.id });
      // An address book or cache left from no wallet at all can't belong to this one; a note that
      // zandr erased itself before is old news.
      await browser.storage.local.remove(['addressBook', 'cache', 'erasedAt']);
      await startSession(key, contents);
    } finally {
      key.fill(0);
    }
  });
}

// Checks the password by decrypting the vault and starts a session. False on a wrong password.
export async function unlock(password: string): Promise<boolean> {
  const vault = await readVault();
  if (!vault) throw new Error('There is no wallet to unlock');

  const opened = await open(vault, password);
  if (!opened) return false;
  try {
    await startSession(opened.key, parseContents(opened.plaintext));
    return true;
  } finally {
    opened.plaintext.fill(0);
    opened.key.fill(0);
  }
}

// Re-encrypts the wallet under a new password, once the current one checks out (even while
// unlocked: whoever sits at an open computer mustn't be able to change it). The new vault has a
// fresh salt and IV and today's KDF parameters, and the session moves to the new key. False if
// the current password is wrong.
export function changePassword(current: string, next: string): Promise<boolean> {
  return serialized(async () => {
    const vault = await readVault();
    if (!vault) throw new Error('There is no wallet');

    const opened = await open(vault, current);
    if (!opened) return false;

    try {
      // The address book's key comes from the vault key, so it moves to the new password too.
      // One that already failed verification can't be carried over.
      const blob = await readAddressBookBlob();
      const contacts = blob ? await openAddressBook(blob, opened.key).catch(() => null) : null;

      const sealed = await seal(opened.plaintext, next);
      try {
        // One write, so the vault and the address book never end up under different passwords.
        const items: Record<string, unknown> = { vault: sealed.vault };
        if (contacts) items.addressBook = await sealAddressBook(contacts, sealed.key);
        await browser.storage.local.set(items);
        if (blob && !contacts) await browser.storage.local.remove('addressBook');
        // What's cached is under the old key: dropped, and written again as it's next fetched.
        await browser.storage.local.remove('cache');
        await startSession(sealed.key, parseContents(opened.plaintext));
      } finally {
        sealed.key.fill(0);
      }
      return true;
    } finally {
      opened.key.fill(0);
      opened.plaintext.fill(0);
    }
  });
}

// The active wallet is remembered unencrypted: an opaque id, telling nothing about the wallet.
async function startSession(key: Uint8Array, contents: VaultContents) {
  const wallets = contents.wallets.map(({ id, name, address }) => ({ id, name, address }));
  const { activeWallet } = await browser.storage.local.get('activeWallet');
  const activeId = wallets.find((wallet) => wallet.id === activeWallet)?.id ?? wallets[0]!.id;
  await saveSession({ key: base64.encode(key), wallets, activeId, expiresAt: await autoLockAt() });
}

async function saveSession(session: Session) {
  await browser.storage.session.set({ session });
  await browser.alarms.create(AUTO_LOCK_ALARM, { when: session.expiresAt });
}

// Locking forgets everything kept while unlocked: the vault key, and what's cached about the
// wallets (their coins), which lives in session storage too.
export async function lock() {
  await browser.storage.session.clear();
  await browser.alarms.clear(AUTO_LOCK_ALARM);
}

async function readSession(): Promise<Session | null> {
  const { session } = await browser.storage.session.get('session');
  if (!session) return null;
  if (Date.now() < (session as Session).expiresAt) return session as Session;

  await lock();
  return null;
}

// Locks a session whose time ran out while its alarm couldn't fire. For startup.
export async function expireSession() {
  await readSession();
}

// The unlocked session, or null when locked. Any request from an open page counts as activity
// and pushes auto-lock back.
async function touchSession(): Promise<Session | null> {
  const session = await readSession();
  if (!session) return null;

  const touched = { ...session, expiresAt: await autoLockAt() };
  await saveSession(touched);
  return touched;
}

function activeAccount(session: Session | null): Account | null {
  const active = session?.wallets.find((wallet) => wallet.id === session.activeId);
  return active ? { name: active.name, address: active.address } : null;
}

// The active wallet, or null when locked.
export async function getSession(): Promise<Account | null> {
  return activeAccount(await touchSession());
}

// The same, but not counted as activity: for what the open wallet does on its own, like
// refreshing balances, which mustn't keep it from auto-locking.
export async function peekSession(): Promise<Account | null> {
  return activeAccount(await readSession());
}

// All wallets and which one is active, or null when locked.
export async function getWallets(): Promise<{ wallets: WalletSummary[]; activeId: string } | null> {
  const session = await touchSession();
  return session ? { wallets: session.wallets, activeId: session.activeId } : null;
}

// The same, without counting as activity: for what sites ask on their own, like whether they're
// still connected, which mustn't keep the wallet from auto-locking.
export async function peekWallets(): Promise<{ wallets: WalletSummary[]; activeId: string } | null> {
  const session = await readSession();
  return session ? { wallets: session.wallets, activeId: session.activeId } : null;
}

export async function switchWallet(id: string): Promise<void> {
  const session = await touchSession();
  if (!session) throw new LockedError();
  if (!session.wallets.some((wallet) => wallet.id === id)) throw new Error('No such wallet');

  await saveSession({ ...session, activeId: id });
  await browser.storage.local.set({ activeWallet: id });
}

// Checks the password against the vault, for actions that ask for it even while unlocked, and
// hands the decrypted contents to `use`; they're wiped right after. Null on a wrong password.
export async function withPassword<T>(password: string, use: (contents: VaultContents) => T): Promise<T | null> {
  const vault = await readVault();
  if (!vault) throw new Error('There is no wallet');

  const opened = await open(vault, password);
  if (!opened) return null;
  try {
    return use(parseContents(opened.plaintext));
  } finally {
    opened.plaintext.fill(0);
    opened.key.fill(0);
  }
}

// The vault's plaintext, decrypted with the key it's encrypted under; the caller wipes it.
async function openWithKey(vault: Vault, key: Bytes): Promise<Bytes> {
  const iv = decode64(vault.iv);
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await aesKey(key), decode64(vault.ciphertext)));
}

// The active wallet and its phrase or key, for signing while unlocked: decrypted with the
// session's key, handed to `use`, and wiped right after. Counts as activity.
export async function withActiveWallet<T>(use: (wallet: WalletEntry, secret: WalletSecret) => T): Promise<T> {
  const session = await touchSession();
  if (!session) throw new LockedError();
  const vault = await readVault();
  if (!vault) throw new Error('There is no wallet');

  const key = decode64(session.key);
  let plaintext: Bytes | undefined;
  try {
    plaintext = await openWithKey(vault, key);
    const contents = parseContents(plaintext);
    const wallet = contents.wallets.find((entry) => entry.id === session.activeId);
    const keyring = wallet && contents.keyrings.find((entry) => entry.id === wallet.keyring);
    if (!wallet || !keyring) throw new Error('The active wallet is missing from the vault');
    return use(wallet, keyring.secret);
  } finally {
    plaintext?.fill(0);
    key.fill(0);
  }
}

// Decrypts the vault with the session's key, changes it and re-encrypts it under the same key,
// as one queued write; the session's wallet list follows. If `change` returns the contents it
// was given, nothing is written. This is the one time the phrases are decrypted while unlocked.
export function updateVault(change: (contents: VaultContents) => VaultContents): Promise<VaultContents> {
  return serialized(async () => {
    const key = await sessionKey();
    const vault = await readVault();
    if (!vault) throw new Error('There is no wallet');

    let plaintext: Bytes | undefined;
    try {
      plaintext = await openWithKey(vault, key);
      const contents = parseContents(plaintext);
      const changed = change(contents);
      if (changed === contents) return contents;

      const next = encoder.encode(JSON.stringify(changed)) as Bytes;
      try {
        const nextIv = crypto.getRandomValues(new Uint8Array(12));
        const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nextIv }, await aesKey(key), next);
        await browser.storage.local.set({
          vault: { ...vault, iv: base64.encode(nextIv), ciphertext: base64.encode(new Uint8Array(ciphertext)) },
        });
      } finally {
        next.fill(0);
      }

      // The session follows; if the active wallet is gone, the first one takes over.
      const session = await readSession();
      if (session) {
        const wallets = changed.wallets.map(({ id, name, address }) => ({ id, name, address }));
        const activeId = wallets.some((wallet) => wallet.id === session.activeId) ? session.activeId : wallets[0]!.id;
        await saveSession({ ...session, wallets, activeId });
        await browser.storage.local.set({ activeWallet: activeId });
      }
      return changed;
    } finally {
      plaintext?.fill(0);
      key.fill(0);
    }
  });
}

// The saved addresses. Only while unlocked: throws LockedError, or TamperedError if the stored
// address book was changed outside zandr.
export async function readAddressBook(): Promise<Contact[]> {
  const key = await sessionKey();
  try {
    const blob = await readAddressBookBlob();
    return blob ? await openAddressBook(blob, key) : [];
  } finally {
    key.fill(0);
  }
}

// Reads, changes and re-encrypts the address book as one queued write. If `change` returns the
// list it was given, nothing is written.
export function updateAddressBook(change: (contacts: Contact[]) => Contact[]): Promise<Contact[]> {
  return serialized(async () => {
    const key = await sessionKey();
    try {
      const blob = await readAddressBookBlob();
      const contacts = blob ? await openAddressBook(blob, key) : [];
      const changed = change(contacts);
      if (changed !== contacts) await browser.storage.local.set({ addressBook: await sealAddressBook(changed, key) });
      return changed;
    } finally {
      key.fill(0);
    }
  });
}

// For an address book that failed verification: unreadable, so it can only be thrown away.
export function clearAddressBook(): Promise<void> {
  return serialized(async () => {
    (await sessionKey()).fill(0);
    await browser.storage.local.remove('addressBook');
  });
}
