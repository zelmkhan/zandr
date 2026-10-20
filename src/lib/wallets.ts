// Adding wallets to the vault: a new one with a recovery phrase of its own, or an imported phrase
// or key. Background only: never import this from a page.
import { wrongPassword } from '@/lib/guard';
import { WALLET_NAME_MAX_LENGTH, type ResponseMap, type WalletAddResult, type WalletSecret } from '@/lib/messages';
import { addressOf, canonicalSecret, checkSecret, privateKeyOf } from '@/lib/secrets';
import { switchWallet, updateVault, withPassword, type Keyring, type VaultContents, type WalletEntry } from '@/lib/vault';

function validName(input: string): string | null {
  const name = input.trim();
  return name && name.length <= WALLET_NAME_MAX_LENGTH ? name : null;
}

const summary = ({ id, name, address }: WalletEntry) => ({ id, name, address });

// What a wallet-adding step builds from the vault's contents: the new wallet (and its keyring
// if that's new too), or why there's none.
type Made = { entry: WalletEntry; keyring?: Keyring } | Extract<WalletAddResult, { ok: false }>;

// Adds the wallet `make` builds, unless its address is already in the vault, and makes it the
// active one.
async function addWallet(make: (contents: VaultContents) => Made): Promise<WalletAddResult> {
  const outcome: { result: WalletAddResult } = { result: { ok: false, error: 'duplicate' } };
  await updateVault((contents) => {
    const made = make(contents);
    if ('ok' in made) {
      outcome.result = made;
      return contents;
    }

    const existing = contents.wallets.find((wallet) => wallet.address === made.entry.address);
    if (existing) {
      outcome.result = { ok: false, error: 'duplicate', conflict: existing.name };
      return contents;
    }

    outcome.result = { ok: true, wallet: summary(made.entry) };
    return {
      keyrings: made.keyring ? [...contents.keyrings, made.keyring] : contents.keyrings,
      wallets: [...contents.wallets, made.entry],
    };
  });

  if (outcome.result.ok) await switchWallet(outcome.result.wallet.id);
  return outcome.result;
}

// A new wallet with its own recovery phrase: `words`, freshly generated (phrase:generate) and
// written down by the user before this. Every new wallet gets a phrase of its own rather than the
// next account of one already in the vault, so it can be created whatever the vault holds, an
// imported private key alone included, and each phrase recovers just its own wallet.
export function createWallet(nameInput: string, words: string[]): Promise<WalletAddResult> {
  return importWallet({ kind: 'phrase', words }, nameInput);
}

// A wallet by its recovery phrase (its first account) or private key. A phrase already in the
// vault is reused rather than stored twice.
export function importWallet(secret: WalletSecret, nameInput: string): Promise<WalletAddResult> {
  const name = validName(nameInput);
  if (!name) return Promise.resolve({ ok: false, error: 'name' });

  const check = checkSecret(secret);
  if (!check.ok) return Promise.resolve({ ok: false, error: 'secret', check });

  const canonical = canonicalSecret(secret);
  const address = addressOf(canonical);
  const same = (other: WalletSecret) =>
    other.kind === canonical.kind &&
    (other.kind === 'phrase' && canonical.kind === 'phrase'
      ? other.words.join(' ') === canonical.words.join(' ')
      : other.kind === 'privateKey' && canonical.kind === 'privateKey' && other.key === canonical.key);

  return addWallet((contents) => {
    const known = contents.keyrings.find((keyring) => same(keyring.secret));
    const keyring = known ?? { id: crypto.randomUUID(), secret: canonical };
    const entry = { id: crypto.randomUUID(), name, address, keyring: keyring.id, account: 0 };
    return known ? { entry } : { entry, keyring };
  });
}

// A wallet's private key, once the password checks out.
export async function exportPrivateKey(id: string, password: string): Promise<ResponseMap['wallets:exportKey']> {
  const key = await withPassword(password, (contents) => {
    const wallet = contents.wallets.find((item) => item.id === id);
    const keyring = contents.keyrings.find((item) => item.id === wallet?.keyring);
    if (!wallet || !keyring) throw new Error('No such wallet');
    return privateKeyOf(keyring.secret, wallet.account);
  });
  return key === null ? { ok: false, error: 'wrong-password', ...(await wrongPassword()) } : { ok: true, key };
}

// The recovery phrase a wallet comes from, once the password checks out, and the names of every
// wallet in the vault made from it: the phrase restores them all. A wallet imported by its private
// key alone has none.
export async function exportPhrase(id: string, password: string): Promise<ResponseMap['wallets:exportPhrase']> {
  const found = await withPassword(password, (contents) => {
    const wallet = contents.wallets.find((item) => item.id === id);
    const keyring = contents.keyrings.find((item) => item.id === wallet?.keyring);
    if (!wallet || !keyring) throw new Error('No such wallet');
    if (keyring.secret.kind !== 'phrase') return { phrase: null };
    return { phrase: { words: [...keyring.secret.words], wallets: contents.wallets.filter((item) => item.keyring === keyring.id).map((item) => item.name) } };
  });
  // Null: the password was wrong.
  if (found === null) return { ok: false, error: 'wrong-password', ...(await wrongPassword()) };
  if (!found.phrase) return { ok: false, error: 'no-phrase' };
  return { ok: true, ...found.phrase };
}

// Removes a wallet from the vault once the password checks out, and its phrase or key too if no
// other wallet uses it. The only wallet can't be removed.
export async function removeWallet(id: string, password: string): Promise<ResponseMap['wallets:remove']> {
  if ((await withPassword(password, () => true)) === null) return { ok: false, error: 'wrong-password', ...(await wrongPassword()) };

  const outcome: { result: { ok: true } | { ok: false; error: 'last-wallet' } } = { result: { ok: true } };
  await updateVault((contents) => {
    if (!contents.wallets.some((wallet) => wallet.id === id)) throw new Error('No such wallet');
    if (contents.wallets.length === 1) {
      outcome.result = { ok: false, error: 'last-wallet' };
      return contents;
    }

    const wallets = contents.wallets.filter((wallet) => wallet.id !== id);
    const keyrings = contents.keyrings.filter((keyring) => wallets.some((wallet) => wallet.keyring === keyring.id));
    return { keyrings, wallets };
  });
  return outcome.result;
}

// Puts the wallets in the order given (`ids`: every wallet's, once), as the vault keeps them and
// the wallet list shows them. No password: the order gives nothing away.
export async function reorderWallets(ids: string[]): Promise<ResponseMap['wallets:reorder']> {
  await updateVault((contents) => {
    const byId = new Map(contents.wallets.map((wallet) => [wallet.id, wallet]));
    if (ids.length !== byId.size || new Set(ids).size !== ids.length || !ids.every((id) => byId.has(id))) throw new Error('Not the same wallets');
    if (ids.every((id, i) => contents.wallets[i]!.id === id)) return contents;
    return { ...contents, wallets: ids.map((id) => byId.get(id)!) };
  });
  return { ok: true };
}
