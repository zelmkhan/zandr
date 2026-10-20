// Solana addresses: decoding, the programs zandr talks to, and derived addresses.
import { ed25519 } from '@noble/curves/ed25519.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { base58 } from '@scure/base';

export const SYSTEM_PROGRAM = '11111111111111111111111111111111';
export const TOKEN_PROGRAM = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
export const TOKEN_2022_PROGRAM = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
export const ASSOCIATED_TOKEN_PROGRAM = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
export const COMPUTE_BUDGET_PROGRAM = 'ComputeBudget111111111111111111111111111111';
// SOL as a token, for swaps and token lists.
export const WRAPPED_SOL = 'So11111111111111111111111111111111111111112';

// The 32 bytes of an address, or null if the text isn't one.
export function decodeAddress(address: string): Uint8Array | null {
  try {
    const bytes = base58.decode(address);
    return bytes.length === 32 ? bytes : null;
  } catch {
    return null;
  }
}

// Whether the address is an ed25519 public key, one some private key can sign for. Addresses
// derived from a program are deliberately off the curve: no key exists for them.
export function isOnCurve(address: Uint8Array): boolean {
  try {
    ed25519.Point.fromBytes(address);
    return true;
  } catch {
    return false;
  }
}

// The program-derived address for these seeds: the first hash, from bump 255 down, that is off
// the curve, as the runtime's find_program_address does.
export function findProgramAddress(seeds: Uint8Array[], program: string): string {
  const marker = new TextEncoder().encode('ProgramDerivedAddress');
  const programBytes = base58.decode(program);
  for (let bump = 255; bump >= 0; bump--) {
    const hash = sha256(concat([...seeds, Uint8Array.of(bump), programBytes, marker]));
    if (!isOnCurve(hash)) return base58.encode(hash);
  }
  throw new Error('No program address for these seeds');
}

// The token account a wallet holds a token in, by convention: what wallets and exchanges send to.
export function associatedTokenAddress(owner: string, mint: string, tokenProgram: string): string {
  return findProgramAddress([base58.decode(owner), base58.decode(tokenProgram), base58.decode(mint)], ASSOCIATED_TOKEN_PROGRAM);
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
