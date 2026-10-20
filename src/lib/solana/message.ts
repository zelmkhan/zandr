// Reading transactions built elsewhere (a swap from Jupiter): legacy or v0 messages, with
// address lookup tables, decoded byte by byte so they can be checked before anything is signed.
import { base58 } from '@scure/base';
import { concat } from '@/lib/solana/addresses';
import { getAccounts, parsedOf } from '@/lib/solana/rpc';
import type { Network } from '@/server/api';

const LOOKUP_TABLE_PROGRAM = 'AddressLookupTab1e1111111111111111111111111';

export type DecodedInstruction = { program: number; accounts: number[]; data: Uint8Array };
export type Lookup = { table: string; writable: number[]; readonly: number[] };

export type DecodedMessage = {
  version: 'legacy' | 0;
  signers: number;
  readonlySigners: number;
  readonlyUnsigned: number;
  staticKeys: string[];
  blockhash: string;
  instructions: DecodedInstruction[];
  lookups: Lookup[];
};

export type DecodedTransaction = { signatures: Uint8Array[]; message: DecodedMessage; messageBytes: Uint8Array };

class Reader {
  private offset = 0;
  private readonly bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  get position() {
    return this.offset;
  }

  get done() {
    return this.offset === this.bytes.length;
  }

  byte(): number {
    if (this.offset >= this.bytes.length) throw new Error('Transaction ends early');
    return this.bytes[this.offset++]!;
  }

  take(length: number): Uint8Array {
    if (this.offset + length > this.bytes.length) throw new Error('Transaction ends early');
    const out = this.bytes.slice(this.offset, this.offset + length);
    this.offset += length;
    return out;
  }

  // Solana's compact length prefix: 7 bits per byte, at most three bytes.
  length(): number {
    let value = 0;
    for (let shift = 0; shift < 21; shift += 7) {
      const byte = this.byte();
      value |= (byte & 0x7f) << shift;
      if (!(byte & 0x80)) return value;
    }
    throw new Error('Bad length prefix');
  }

  key(): string {
    return base58.encode(this.take(32));
  }
}

export function decodeTransaction(wire: Uint8Array): DecodedTransaction {
  const reader = new Reader(wire);
  const count = reader.length();
  const signatures = Array.from({ length: count }, () => reader.take(64));
  const start = reader.position;
  const message = readMessage(reader);
  if (signatures.length !== message.signers) throw new Error('Signature count does not match the message');
  return { signatures, message, messageBytes: wire.slice(start) };
}

// A message on its own, as signers sign it. Throws unless the bytes are exactly one.
export function decodeMessage(bytes: Uint8Array): DecodedMessage {
  return readMessage(new Reader(bytes));
}

function readMessage(reader: Reader): DecodedMessage {
  const first = reader.byte();
  const versioned = (first & 0x80) !== 0;
  if (versioned && (first & 0x7f) !== 0) throw new Error('Unsupported transaction version');
  const signers = versioned ? reader.byte() : first;
  const readonlySigners = reader.byte();
  const readonlyUnsigned = reader.byte();

  const staticKeys = Array.from({ length: reader.length() }, () => reader.key());
  const blockhash = reader.key();
  const instructions = Array.from({ length: reader.length() }, () => ({
    program: reader.byte(),
    accounts: Array.from(reader.take(reader.length())),
    data: reader.take(reader.length()),
  }));
  const lookups = versioned
    ? Array.from({ length: reader.length() }, () => ({
        table: reader.key(),
        writable: Array.from(reader.take(reader.length())),
        readonly: Array.from(reader.take(reader.length())),
      }))
    : [];
  if (!reader.done) throw new Error('Unexpected bytes after the message');
  if (signers === 0 || signers > staticKeys.length) throw new Error('Bad signer count');

  return { version: versioned ? 0 : 'legacy', signers, readonlySigners, readonlyUnsigned, staticKeys, blockhash, instructions, lookups };
}

// Every account the message uses, in index order: its own keys, then those loaded from lookup
// tables (all writable ones first, then all read-only ones), given each table's addresses.
export function accountKeys(message: DecodedMessage, tables: Map<string, string[]>): string[] {
  const load = (lookup: Lookup, indexes: number[]) =>
    indexes.map((index) => {
      const address = tables.get(lookup.table)?.[index];
      if (!address) throw new Error('Lookup table entry missing');
      return address;
    });
  return [
    ...message.staticKeys,
    ...message.lookups.flatMap((lookup) => load(lookup, lookup.writable)),
    ...message.lookups.flatMap((lookup) => load(lookup, lookup.readonly)),
  ];
}

// A lookup table that isn't one, or lacks an entry the message points to.
export class LookupError extends Error {}

// Lookup tables read from the chain before, by network and address. A table's entries never change
// once added: it only grows, until it's closed for good, and no other table can ever take its
// address. So what was read stays true, and a table is read again only when a message points past
// what was read. (Swaps use the same few tables over and over: this saves a round trip to the node
// each time.)
const tablesRead = new Map<string, string[]>();
const TABLES_KEPT = 256;
// The background is put to sleep when idle, and memory goes with it: the tables used last are kept
// in session storage too (extension pages and the background only), for the next request after a
// pause. Gone on lock, with the rest of the session.
const TABLES_STORED = 32;
let restoring: Promise<void> | undefined;

function restoreTables(): Promise<void> {
  restoring ??= browser.storage.session
    .get('lookupTables')
    .then(({ lookupTables }) => {
      for (const [key, addresses] of Object.entries((lookupTables ?? {}) as Record<string, string[]>)) {
        if (!tablesRead.has(key) && Array.isArray(addresses)) tablesRead.set(key, addresses);
      }
    })
    .catch(() => {});
  return restoring;
}

function storeTables() {
  browser.storage.session.set({ lookupTables: Object.fromEntries([...tablesRead].slice(-TABLES_STORED)) }).catch(() => {});
}

// What lookup tables hold, read from the chain, or as read before: again only for one that has to
// hold more than was read (`length`), or with `fresh`. Throws LookupError for one that isn't a table.
export async function readLookupTables(url: string, network: Network, wanted: { table: string; length?: number }[], fresh = false): Promise<Map<string, string[]>> {
  if (wanted.length) await restoreTables();
  const keyOf = (table: string) => `${network}:${table}`;
  const unread = wanted.filter(({ table, length = 0 }) => {
    const read = tablesRead.get(keyOf(table));
    return fresh || !read || length > read.length;
  });
  const accounts = unread.length ? await getAccounts(url, unread.map(({ table }) => table)) : [];
  unread.forEach(({ table }, i) => {
    const account = accounts[i] ?? null;
    const parsed = parsedOf(account);
    const addresses = parsed?.info?.addresses;
    if (!account || account.owner !== LOOKUP_TABLE_PROGRAM || parsed?.type !== 'lookupTable' || !Array.isArray(addresses)) {
      throw new LookupError("An address table that isn't one");
    }
    tablesRead.delete(keyOf(table));
    tablesRead.set(keyOf(table), addresses as string[]);
    if (tablesRead.size > TABLES_KEPT) tablesRead.delete(tablesRead.keys().next().value!);
  });
  if (unread.length) storeTables();
  return new Map(wanted.map(({ table }) => [table, tablesRead.get(keyOf(table))!]));
}

// Every account the message uses, with its lookup tables read from the chain: never taken from
// whoever built the transaction. Throws LookupError.
export async function resolveAccountKeys(url: string, message: DecodedMessage, network: Network): Promise<string[]> {
  const tables = await readLookupTables(
    url,
    network,
    message.lookups.map((lookup) => ({ table: lookup.table, length: Math.max(-1, ...lookup.writable, ...lookup.readonly) + 1 })),
  );
  try {
    return accountKeys(message, tables);
  } catch {
    throw new LookupError('An address table lacks an entry');
  }
}

// Whether the account at `index` (in accountKeys order) is writable in the message.
export function isWritable(message: DecodedMessage, index: number): boolean {
  const statics = message.staticKeys.length;
  if (index < message.signers) return index < message.signers - message.readonlySigners;
  if (index < statics) return index < statics - message.readonlyUnsigned;
  return index - statics < message.lookups.reduce((sum, lookup) => sum + lookup.writable.length, 0);
}

// The transaction with the signature at `index` (its signer's place among the keys) filled in,
// the others kept as they were.
export function withSignatureAt(transaction: DecodedTransaction, index: number, signature: Uint8Array): Uint8Array {
  const signatures = transaction.signatures.map((existing, i) => (i === index ? signature : existing));
  return concat([Uint8Array.of(signatures.length), ...signatures, transaction.messageBytes]);
}

// The transaction with its first signature, the fee payer's, filled in.
export function withSignature(transaction: DecodedTransaction, signature: Uint8Array): Uint8Array {
  return withSignatureAt(transaction, 0, signature);
}
