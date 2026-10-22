// Solana transactions, legacy and version 0: the instructions the wallet sends, and their wire
// format (src/lib/solana/transaction.ts).
import 'dart:typed_data';

import '../base58.dart';
import 'addresses.dart';

class AccountMeta {
  final String address;
  final bool signer;
  final bool writable;
  const AccountMeta(this.address, {this.signer = false, this.writable = false});
}

class Instruction {
  final String program;
  final List<AccountMeta> accounts;
  final Uint8List data;
  const Instruction(this.program, this.accounts, this.data);
}

AccountMeta _writable(String address, [bool signer = false]) => AccountMeta(address, signer: signer, writable: true);
AccountMeta _readonly(String address, [bool signer = false]) => AccountMeta(address, signer: signer);

Uint8List u32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List u64(BigInt value) {
  if (value < BigInt.zero || value >= BigInt.two.pow(64)) throw RangeError('Amount out of range');
  final bytes = Uint8List(8);
  var rest = value;
  for (var i = 0; i < 8; i++) {
    bytes[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return bytes;
}

Uint8List concat(List<List<int>> parts) => Uint8List.fromList([for (final part in parts) ...part]);

// System program: move lamports between two system accounts.
Instruction transferSol(String from, String to, BigInt lamports) =>
    Instruction(systemProgram, [_writable(from, true), _writable(to)], concat([u32(2), u64(lamports)]));

// Either token program: TransferChecked, stating the mint and its decimals so the program refuses
// the transfer if either isn't what the wallet believed.
Instruction transferTokens(String program, String source, String mint, String destination, String owner, BigInt amount, int decimals) =>
    Instruction(program, [_writable(source), _readonly(mint), _writable(destination), _readonly(owner, true)], concat([[12], u64(amount), [decimals]]));

// Associated token program: open the recipient's account for the token, or do nothing if it's
// there (CreateIdempotent), paid for by `payer`.
Instruction createTokenAccount(String payer, String account, String owner, String mint, String program) => Instruction(
      associatedTokenProgram,
      [_writable(payer, true), _writable(account), _readonly(owner), _readonly(mint), _readonly(systemProgram), _readonly(program)],
      Uint8List.fromList([1]),
    );

// Either token program: BurnChecked.
Instruction burnTokens(String program, String account, String mint, String owner, BigInt amount, int decimals) =>
    Instruction(program, [_writable(account), _writable(mint), _readonly(owner, true)], concat([[15], u64(amount), [decimals]]));

// Either token program: CloseAccount, sending the rent it held to `destination`.
Instruction closeTokenAccount(String program, String account, String destination, String owner) =>
    Instruction(program, [_writable(account), _writable(destination), _readonly(owner, true)], Uint8List.fromList([9]));

Instruction setComputeUnitLimit(int units) => Instruction(computeBudgetProgram, const [], concat([[2], u32(units)]));

// The priority fee, in micro-lamports per compute unit.
Instruction setComputeUnitPrice(BigInt microLamports) => Instruction(computeBudgetProgram, const [], concat([[3], u64(microLamports)]));

// Solana's compact length prefix: 7 bits per byte, the high bit set on all but the last.
Uint8List shortVec(int length) {
  final bytes = <int>[];
  var rest = length;
  while (true) {
    final low = rest & 0x7f;
    rest >>= 7;
    if (rest == 0) {
      bytes.add(low);
      return Uint8List.fromList(bytes);
    }
    bytes.add(low | 0x80);
  }
}

// Every account the instructions use, once each, signer and writable if any use makes it so: the
// fee payer first.
Map<String, AccountMeta> _accountMetas(String feePayer, List<Instruction> instructions) {
  final metas = <String, AccountMeta>{feePayer: _writable(feePayer, true)};
  void add(AccountMeta meta) {
    final known = metas[meta.address];
    metas[meta.address] = known == null
        ? meta
        : AccountMeta(meta.address, signer: known.signer || meta.signer, writable: known.writable || meta.writable);
  }

  for (final instruction in instructions) {
    instruction.accounts.forEach(add);
    add(_readonly(instruction.program));
  }
  return metas;
}

// The accounts in the order Solana requires (fee payer, writable signers, read-only signers,
// writable, read-only), and the header counting them.
({List<AccountMeta> accounts, Uint8List header}) _staticAccounts(List<AccountMeta> metas) {
  int rank(AccountMeta meta) => (meta.signer ? 0 : 2) + (meta.writable ? 0 : 1);
  final rest = metas.sublist(1)..sort((a, b) => rank(a) - rank(b));
  final accounts = [metas.first, ...rest];
  final signers = accounts.where((meta) => meta.signer).toList();
  final header = Uint8List.fromList([
    signers.length,
    signers.where((meta) => !meta.writable).length,
    accounts.where((meta) => !meta.signer && !meta.writable).length,
  ]);
  return (accounts: accounts, header: header);
}

List<List<int>> _compileInstructions(List<Instruction> instructions, Map<String, int> index) {
  int at(String address) {
    final i = index[address];
    if (i == null || i > 255) throw RangeError('Too many accounts for one transaction');
    return i;
  }

  return [
    shortVec(instructions.length),
    for (final instruction in instructions) ...[
      [at(instruction.program)],
      shortVec(instruction.accounts.length),
      [for (final meta in instruction.accounts) at(meta.address)],
      shortVec(instruction.data.length),
      instruction.data,
    ],
  ];
}

// A legacy message: what the signers sign.
Uint8List compileMessage(String feePayer, List<Instruction> instructions, String blockhash) {
  final (:accounts, :header) = _staticAccounts(_accountMetas(feePayer, instructions).values.toList());
  final index = {for (final (i, meta) in accounts.indexed) meta.address: i};
  return concat([
    header,
    shortVec(accounts.length),
    for (final meta in accounts) base58Decode(meta.address)!,
    base58Decode(blockhash)!,
    ..._compileInstructions(instructions, index),
  ]);
}

// A version 0 message: accounts may come from lookup tables (`tables`: each one's addresses, as
// read from the chain). An account that neither signs nor is a program run comes from the first
// table holding it; tables none of whose addresses are used are left out.
Uint8List compileV0Message(String feePayer, List<Instruction> instructions, String blockhash, Map<String, List<String>> tables) {
  final metas = _accountMetas(feePayer, instructions);
  final programs = instructions.map((instruction) => instruction.program).toSet();
  final loaded = <String>{};
  final lookups = <({String table, List<({String address, int index})> writable, List<({String address, int index})> readonly})>[];
  for (final MapEntry(key: table, value: addresses) in tables.entries) {
    final writable = <({String address, int index})>[];
    final readonly = <({String address, int index})>[];
    for (final (index, address) in addresses.indexed) {
      final meta = metas[address];
      if (meta == null || meta.signer || programs.contains(address) || loaded.contains(address) || index > 255) continue;
      loaded.add(address);
      (meta.writable ? writable : readonly).add((address: address, index: index));
    }
    if (writable.isNotEmpty || readonly.isNotEmpty) lookups.add((table: table, writable: writable, readonly: readonly));
  }

  final (:accounts, :header) = _staticAccounts(metas.values.where((meta) => !loaded.contains(meta.address)).toList());
  final order = [
    ...accounts.map((meta) => meta.address),
    for (final lookup in lookups) ...lookup.writable.map((entry) => entry.address),
    for (final lookup in lookups) ...lookup.readonly.map((entry) => entry.address),
  ];
  final index = {for (final (i, address) in order.indexed) address: i};
  return concat([
    [0x80],
    header,
    shortVec(accounts.length),
    for (final meta in accounts) base58Decode(meta.address)!,
    base58Decode(blockhash)!,
    ..._compileInstructions(instructions, index),
    shortVec(lookups.length),
    for (final lookup in lookups) ...[
      base58Decode(lookup.table)!,
      shortVec(lookup.writable.length),
      [for (final entry in lookup.writable) entry.index],
      shortVec(lookup.readonly.length),
      [for (final entry in lookup.readonly) entry.index],
    ],
  ]);
}

// The transaction on the wire: its signatures, then the message they sign.
Uint8List serializeTransaction(Uint8List message, List<Uint8List> signatures) =>
    concat([shortVec(signatures.length), ...signatures, message]);
