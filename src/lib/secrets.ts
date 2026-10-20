// Recovery phrases and private keys. Background only: never import this from a page.
import { ed25519 } from '@noble/curves/ed25519.js';
import { hmac } from '@noble/hashes/hmac.js';
import { sha512 } from '@noble/hashes/sha2.js';
import { base58 } from '@scure/base';
import { generateMnemonic, mnemonicToSeedSync, validateMnemonic } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english.js';
import type { SecretCheck, WalletSecret } from '@/lib/messages';

// Account N of a phrase is m/44'/501'/N'/0', as in Phantom, Solflare and most Solana wallets,
// so an imported phrase shows the same addresses as in the wallet it came from.
const solanaPath = (account: number) => [44, 501, account, 0];

// 12 words, 128 bits of entropy, as most Solana wallets use.
export function generatePhrase(): string[] {
  return generateMnemonic(wordlist, 128).split(' ');
}

export function checkSecret(secret: WalletSecret): SecretCheck {
  if (secret.kind === 'privateKey') return parsePrivateKey(secret.key) ? { ok: true } : { ok: false, error: 'invalid-key' };

  const words = normalizeWords(secret.words);
  if (words.length !== 12 && words.length !== 24) return { ok: false, error: 'word-count' };

  const unknown = words.findIndex((word) => !wordlist.includes(word));
  if (unknown !== -1) return { ok: false, error: 'unknown-word', index: unknown };

  return validateMnemonic(words.join(' '), wordlist) ? { ok: true } : { ok: false, error: 'checksum' };
}

// The one form a valid secret is stored in: lowercase words, or the 64-byte key in base58.
export function canonicalSecret(secret: WalletSecret): WalletSecret {
  if (secret.kind === 'phrase') return { kind: 'phrase', words: normalizeWords(secret.words) };

  const bytes = parsePrivateKey(secret.key);
  if (!bytes) throw new Error('Invalid private key');
  const key = base58.encode(bytes);
  bytes.fill(0);
  return { kind: 'privateKey', key };
}

// The Solana address for a valid, canonical secret: account N of a phrase (0 is the first), or
// the one address of a private key.
export function addressOf(secret: WalletSecret, account = 0): string {
  let publicKey: Uint8Array;

  if (secret.kind === 'privateKey') {
    const bytes = parsePrivateKey(secret.key)!;
    publicKey = bytes.slice(32);
    bytes.fill(0);
  } else {
    const seed = mnemonicToSeedSync(secret.words.join(' '));
    const privateKey = deriveEd25519(seed, solanaPath(account));
    publicKey = ed25519.getPublicKey(privateKey);
    seed.fill(0);
    privateKey.fill(0);
  }

  return base58.encode(publicKey);
}

// The private key of a valid, canonical secret's wallet (account N of a phrase), as wallets
// export it: base58 of the 64-byte secret key, which Phantom, Solflare and the Solana CLI import.
export function privateKeyOf(secret: WalletSecret, account = 0): string {
  if (secret.kind === 'privateKey') return secret.key;

  const seed = mnemonicToSeedSync(secret.words.join(' '));
  const privateKey = deriveEd25519(seed, solanaPath(account));
  seed.fill(0);

  const full = new Uint8Array(64);
  full.set(privateKey);
  full.set(ed25519.getPublicKey(privateKey), 32);
  privateKey.fill(0);

  const key = base58.encode(full);
  full.fill(0);
  return key;
}

// Signs a message as the wallet (account N of a phrase, or the private key's one address). The
// key is derived, used and wiped; the signer's address comes back so the caller can check it
// signed as the wallet it meant to.
export function signMessage(secret: WalletSecret, account: number, message: Uint8Array): { signature: Uint8Array; address: string } {
  let privateKey: Uint8Array;
  if (secret.kind === 'privateKey') {
    const bytes = parsePrivateKey(secret.key)!;
    privateKey = bytes.slice(0, 32);
    bytes.fill(0);
  } else {
    const seed = mnemonicToSeedSync(secret.words.join(' '));
    privateKey = deriveEd25519(seed, solanaPath(account));
    seed.fill(0);
  }

  try {
    return { signature: ed25519.sign(message, privateKey), address: base58.encode(ed25519.getPublicKey(privateKey)) };
  } finally {
    privateKey.fill(0);
  }
}

function normalizeWords(words: string[]): string[] {
  return words.map((word) => word.trim().toLowerCase());
}

// SLIP-0010 key derivation for ed25519, which only has hardened steps. Intermediate keys are
// wiped as soon as the next one is derived.
export function deriveEd25519(seed: Uint8Array, path: number[]): Uint8Array {
  let node = hmac(sha512, new TextEncoder().encode('ed25519 seed'), seed);

  for (const index of path) {
    // 0x00 || parent key || index with the hardened bit, big-endian.
    const data = new Uint8Array(37);
    data.set(node.subarray(0, 32), 1);
    new DataView(data.buffer).setUint32(33, (index | 0x80000000) >>> 0);

    const child = hmac(sha512, node.subarray(32), data);
    node.fill(0);
    data.fill(0);
    node = child;
  }

  const key = node.slice(0, 32);
  node.fill(0);
  return key;
}

// A Solana private key is the 64-byte secret key: base58 as wallets export it, or a JSON byte
// array as in CLI keypair files. Its last 32 bytes are the public key and must match the
// first 32, so a mistyped key is rejected instead of silently importing a different wallet.
function parsePrivateKey(input: string): Uint8Array | null {
  const value = input.trim();
  let bytes: Uint8Array;

  try {
    if (value.startsWith('[')) {
      const array: unknown = JSON.parse(value);
      if (!Array.isArray(array) || !array.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)) return null;
      bytes = Uint8Array.from(array);
    } else {
      bytes = base58.decode(value);
    }
  } catch {
    return null;
  }

  if (bytes.length !== 64) return null;
  const publicKey = ed25519.getPublicKey(bytes.subarray(0, 32));
  if (publicKey.every((byte, i) => byte === bytes[i + 32])) return bytes;

  bytes.fill(0);
  return null;
}
