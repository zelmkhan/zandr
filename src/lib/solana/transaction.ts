// Solana transactions, legacy and version 0: the instructions zandr sends, and their wire format.
import { base58 } from '@scure/base';
import {
  ASSOCIATED_TOKEN_PROGRAM,
  COMPUTE_BUDGET_PROGRAM,
  SYSTEM_PROGRAM,
  concat,
} from '@/lib/solana/addresses';

export type AccountMeta = { address: string; signer: boolean; writable: boolean };
export type Instruction = { program: string; accounts: AccountMeta[]; data: Uint8Array };

const writable = (address: string, signer = false): AccountMeta => ({ address, signer, writable: true });
const readonly = (address: string, signer = false): AccountMeta => ({ address, signer, writable: false });

function u32(value: number): Uint8Array {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value, true);
  return bytes;
}

function u64(value: bigint): Uint8Array {
  if (value < 0n || value >= 2n ** 64n) throw new RangeError('Amount out of range');
  const bytes = new Uint8Array(8);
  new DataView(bytes.buffer).setBigUint64(0, value, true);
  return bytes;
}

// System program: move lamports between two system accounts.
export function transferSol(from: string, to: string, lamports: bigint): Instruction {
  return { program: SYSTEM_PROGRAM, accounts: [writable(from, true), writable(to)], data: concat([u32(2), u64(lamports)]) };
}

// Token program (either one): TransferChecked, which also states the mint and its decimals, so
// the program refuses the transfer if either isn't what the wallet believed.
export function transferTokens(
  tokenProgram: string,
  source: string,
  mint: string,
  destination: string,
  owner: string,
  amount: bigint,
  decimals: number,
): Instruction {
  return {
    program: tokenProgram,
    accounts: [writable(source), readonly(mint), writable(destination), readonly(owner, true)],
    data: concat([Uint8Array.of(12), u64(amount), Uint8Array.of(decimals)]),
  };
}

// Associated token program: open the recipient's account for the token if it isn't there yet,
// and do nothing if it is (CreateIdempotent), paid for by `payer`.
export function createTokenAccount(payer: string, account: string, owner: string, mint: string, tokenProgram: string): Instruction {
  return {
    program: ASSOCIATED_TOKEN_PROGRAM,
    accounts: [writable(payer, true), writable(account), readonly(owner), readonly(mint), readonly(SYSTEM_PROGRAM), readonly(tokenProgram)],
    data: Uint8Array.of(1),
  };
}

// Token program (either one): BurnChecked, which destroys `amount` of the tokens in `account`,
// stating the mint's decimals so the program refuses it if they aren't what the wallet believed.
export function burnTokens(tokenProgram: string, account: string, mint: string, owner: string, amount: bigint, decimals: number): Instruction {
  return {
    program: tokenProgram,
    accounts: [writable(account), writable(mint), readonly(owner, true)],
    data: concat([Uint8Array.of(15), u64(amount), Uint8Array.of(decimals)]),
  };
}

// Token program (either one): CloseAccount, which closes an empty token account and sends the rent
// it held to `destination`. Only the account's owner (or close authority) may.
export function closeTokenAccount(tokenProgram: string, account: string, destination: string, owner: string): Instruction {
  return { program: tokenProgram, accounts: [writable(account), writable(destination), readonly(owner, true)], data: Uint8Array.of(9) };
}

export function setComputeUnitLimit(units: number): Instruction {
  return { program: COMPUTE_BUDGET_PROGRAM, accounts: [], data: concat([Uint8Array.of(2), u32(units)]) };
}

// The priority fee, in micro-lamports per compute unit.
export function setComputeUnitPrice(microLamports: bigint): Instruction {
  return { program: COMPUTE_BUDGET_PROGRAM, accounts: [], data: concat([Uint8Array.of(3), u64(microLamports)]) };
}

// Solana's compact length prefix (shortvec): 7 bits per byte, the high bit set on all but the last.
function shortVec(length: number): Uint8Array {
  const bytes: number[] = [];
  for (let rest = length; ; ) {
    const low = rest & 0x7f;
    rest >>= 7;
    if (rest === 0) {
      bytes.push(low);
      return Uint8Array.from(bytes);
    }
    bytes.push(low | 0x80);
  }
}

// Every account the instructions use, once each, signer and writable if any use makes it so: the
// fee payer first, the programs run among them.
function accountMetas(feePayer: string, instructions: Instruction[]): Map<string, AccountMeta> {
  const metas = new Map<string, AccountMeta>([[feePayer, writable(feePayer, true)]]);
  const add = (meta: AccountMeta) => {
    const known = metas.get(meta.address);
    metas.set(meta.address, known ? { ...known, signer: known.signer || meta.signer, writable: known.writable || meta.writable } : meta);
  };
  for (const instruction of instructions) {
    instruction.accounts.forEach(add);
    add(readonly(instruction.program));
  }
  return metas;
}

// The accounts listed in a message, in the order Solana requires: fee payer first, then writable
// signers, read-only signers, writable and read-only accounts. With its header: how many sign, and
// how many of those and of the rest are read-only.
function staticAccounts(metas: AccountMeta[]): { accounts: AccountMeta[]; header: Uint8Array } {
  const rank = (meta: AccountMeta) => (meta.signer ? 0 : 2) + (meta.writable ? 0 : 1);
  const [payer, ...rest] = metas;
  const accounts = [payer!, ...rest.sort((a, b) => rank(a) - rank(b))];
  const signers = accounts.filter((meta) => meta.signer);
  const header = Uint8Array.of(
    signers.length,
    signers.filter((meta) => !meta.writable).length,
    accounts.filter((meta) => !meta.signer && !meta.writable).length,
  );
  return { accounts, header };
}

// The instructions, pointing into the message's list of accounts (`index`).
function compileInstructions(instructions: Instruction[], index: Map<string, number>): Uint8Array[] {
  const at = (address: string) => {
    const i = index.get(address);
    if (i === undefined || i > 255) throw new RangeError('Too many accounts for one transaction');
    return i;
  };
  return [
    shortVec(instructions.length),
    ...instructions.flatMap((instruction) => [
      Uint8Array.of(at(instruction.program)),
      shortVec(instruction.accounts.length),
      Uint8Array.from(instruction.accounts.map((meta) => at(meta.address))),
      shortVec(instruction.data.length),
      instruction.data,
    ]),
  ];
}

// The message the signers sign: the accounts in the order Solana requires, the blockhash, and the
// instructions pointing into that list.
export function compileMessage(feePayer: string, instructions: Instruction[], blockhash: string): Uint8Array {
  const { accounts, header } = staticAccounts([...accountMetas(feePayer, instructions).values()]);
  const index = new Map(accounts.map((meta, i) => [meta.address, i]));
  return concat([
    header,
    shortVec(accounts.length),
    ...accounts.map((meta) => base58.decode(meta.address)),
    base58.decode(blockhash),
    ...compileInstructions(instructions, index),
  ]);
}

// A version 0 message: as compileMessage, but accounts may be loaded from address lookup tables
// (`tables`: each table's addresses, as read from the chain), which keeps the transaction small.
// An account that neither signs nor is a program run comes from the first table holding it; the
// rest are listed in full. Tables none of whose addresses are used are left out.
export function compileV0Message(feePayer: string, instructions: Instruction[], blockhash: string, tables: Map<string, string[]>): Uint8Array {
  const metas = accountMetas(feePayer, instructions);
  const programs = new Set(instructions.map((instruction) => instruction.program));
  const loaded = new Set<string>();
  const lookups: { table: string; writable: { address: string; index: number }[]; readonly: { address: string; index: number }[] }[] = [];
  for (const [table, addresses] of tables) {
    const lookup = { table, writable: [] as { address: string; index: number }[], readonly: [] as { address: string; index: number }[] };
    addresses.forEach((address, index) => {
      const meta = metas.get(address);
      if (!meta || meta.signer || programs.has(address) || loaded.has(address) || index > 255) return;
      loaded.add(address);
      (meta.writable ? lookup.writable : lookup.readonly).push({ address, index });
    });
    if (lookup.writable.length || lookup.readonly.length) lookups.push(lookup);
  }

  // Listed in full first, then loaded: all writable ones (table by table), then all read-only ones.
  const { accounts, header } = staticAccounts([...metas.values()].filter((meta) => !loaded.has(meta.address)));
  const order = [
    ...accounts.map((meta) => meta.address),
    ...lookups.flatMap((lookup) => lookup.writable.map((entry) => entry.address)),
    ...lookups.flatMap((lookup) => lookup.readonly.map((entry) => entry.address)),
  ];
  const index = new Map(order.map((address, i) => [address, i]));
  return concat([
    Uint8Array.of(0x80),
    header,
    shortVec(accounts.length),
    ...accounts.map((meta) => base58.decode(meta.address)),
    base58.decode(blockhash),
    ...compileInstructions(instructions, index),
    shortVec(lookups.length),
    ...lookups.flatMap((lookup) => [
      base58.decode(lookup.table),
      shortVec(lookup.writable.length),
      Uint8Array.from(lookup.writable.map((entry) => entry.index)),
      shortVec(lookup.readonly.length),
      Uint8Array.from(lookup.readonly.map((entry) => entry.index)),
    ]),
  ]);
}

// The transaction on the wire: its signatures, then the message they sign.
export function serializeTransaction(message: Uint8Array, signatures: Uint8Array[]): Uint8Array {
  return concat([shortVec(signatures.length), ...signatures, message]);
}
