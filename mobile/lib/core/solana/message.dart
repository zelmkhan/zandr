// Reading transactions built elsewhere (a swap's route from Jupiter): legacy or v0 messages, with
// address lookup tables, decoded byte by byte so they can be checked before anything is signed
// (src/lib/solana/message.ts).
import 'dart:typed_data';

import '../base58.dart';
import 'addresses.dart' show lookupTableProgram;
import 'rpc.dart';
import 'transaction.dart' show concat;

class DecodedInstruction {
  final int program;
  final List<int> accounts;
  final Uint8List data;
  const DecodedInstruction(this.program, this.accounts, this.data);
}

class Lookup {
  final String table;
  final List<int> writable, readonly;
  const Lookup(this.table, this.writable, this.readonly);
}

class DecodedMessage {
  final bool versioned;
  final int signers, readonlySigners, readonlyUnsigned;
  final List<String> staticKeys;
  final String blockhash;
  final List<DecodedInstruction> instructions;
  final List<Lookup> lookups;
  const DecodedMessage({
    required this.versioned,
    required this.signers,
    required this.readonlySigners,
    required this.readonlyUnsigned,
    required this.staticKeys,
    required this.blockhash,
    required this.instructions,
    required this.lookups,
  });

  // Whether the account at `index` (in accountKeys order) is writable.
  bool isWritable(int index) {
    final statics = staticKeys.length;
    if (index < signers) return index < signers - readonlySigners;
    if (index < statics) return index < statics - readonlyUnsigned;
    return index - statics < lookups.fold(0, (sum, lookup) => sum + lookup.writable.length);
  }
}

class DecodedTransaction {
  final List<Uint8List> signatures;
  final DecodedMessage message;
  final Uint8List messageBytes;
  const DecodedTransaction(this.signatures, this.message, this.messageBytes);

  // With the signature at `index` (its signer's place among the keys) filled in.
  Uint8List withSignatureAt(int index, Uint8List signature) =>
      concat([[signatures.length], for (final (i, existing) in signatures.indexed) i == index ? signature : existing, messageBytes]);
}

class _Reader {
  final Uint8List bytes;
  int offset = 0;
  _Reader(this.bytes);

  bool get done => offset == bytes.length;

  int byte() {
    if (offset >= bytes.length) throw const FormatException('Transaction ends early');
    return bytes[offset++];
  }

  Uint8List take(int length) {
    if (offset + length > bytes.length) throw const FormatException('Transaction ends early');
    final out = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return Uint8List.fromList(out);
  }

  int length() {
    var value = 0;
    for (var shift = 0; shift < 21; shift += 7) {
      final b = byte();
      value |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return value;
    }
    throw const FormatException('Bad length prefix');
  }

  String key() => base58Encode(take(32));
}

DecodedTransaction decodeTransaction(Uint8List wire) {
  final reader = _Reader(wire);
  final count = reader.length();
  final signatures = List.generate(count, (_) => reader.take(64));
  final start = reader.offset;
  final message = _readMessage(reader);
  if (signatures.length != message.signers) throw const FormatException('Signature count does not match the message');
  return DecodedTransaction(signatures, message, Uint8List.fromList(wire.sublist(start)));
}

// A message on its own, as signers sign it. Throws unless the bytes are exactly one.
DecodedMessage decodeMessage(Uint8List bytes) => _readMessage(_Reader(bytes));

DecodedMessage _readMessage(_Reader reader) {
  final first = reader.byte();
  final versioned = first & 0x80 != 0;
  if (versioned && first & 0x7f != 0) throw const FormatException('Unsupported transaction version');
  final signers = versioned ? reader.byte() : first;
  final readonlySigners = reader.byte();
  final readonlyUnsigned = reader.byte();
  final staticKeys = List.generate(reader.length(), (_) => reader.key());
  final blockhash = reader.key();
  final instructions = List.generate(reader.length(), (_) {
    final program = reader.byte();
    final accounts = reader.take(reader.length()).toList();
    final data = reader.take(reader.length());
    return DecodedInstruction(program, accounts, data);
  });
  final lookups = versioned
      ? List.generate(reader.length(), (_) {
          final table = reader.key();
          final writable = reader.take(reader.length()).toList();
          final readonly = reader.take(reader.length()).toList();
          return Lookup(table, writable, readonly);
        })
      : <Lookup>[];
  if (!reader.done) throw const FormatException('Unexpected bytes after the message');
  if (signers == 0 || signers > staticKeys.length) throw const FormatException('Bad signer count');
  return DecodedMessage(
    versioned: versioned,
    signers: signers,
    readonlySigners: readonlySigners,
    readonlyUnsigned: readonlyUnsigned,
    staticKeys: staticKeys,
    blockhash: blockhash,
    instructions: instructions,
    lookups: lookups,
  );
}

// Every account the message uses, in index order: its own keys, then those from lookup tables
// (all writable ones first, then all read-only ones), given each table's addresses.
List<String> accountKeys(DecodedMessage message, Map<String, List<String>> tables) {
  List<String> load(Lookup lookup, List<int> indexes) => [
        for (final index in indexes)
          (tables[lookup.table] != null && index < tables[lookup.table]!.length)
              ? tables[lookup.table]![index]
              : throw const FormatException('Lookup table entry missing'),
      ];
  return [
    ...message.staticKeys,
    for (final lookup in message.lookups) ...load(lookup, lookup.writable),
    for (final lookup in message.lookups) ...load(lookup, lookup.readonly),
  ];
}

class LookupError implements Exception {
  final String message;
  const LookupError(this.message);
}

// Lookup tables read from the chain before, by node and address. A table's entries never change
// once added: it only grows, until it's closed for good. So what was read stays true, and a table
// is read again only when a message points past what was read.
final _tablesRead = <String, List<String>>{};
const _tablesKept = 256;

// What lookup tables hold, read from the chain, or as read before: again only for one that has to
// hold more than was read (`length`). Throws LookupError for one that isn't a table.
Future<Map<String, List<String>>> readLookupTables(Rpc rpc, List<({String table, int length})> wanted) async {
  String keyOf(String table) => '${rpc.url} $table';
  final unread = wanted.where((entry) => (_tablesRead[keyOf(entry.table)]?.length ?? -1) < entry.length || !_tablesRead.containsKey(keyOf(entry.table))).toList();
  final accounts = unread.isEmpty ? const <Map<String, dynamic>?>[] : await rpc.getAccounts([for (final entry in unread) entry.table]);
  for (final (i, entry) in unread.indexed) {
    final account = accounts[i];
    final parsed = parsedOf(account);
    final addresses = (parsed?['info'] as Map?)?['addresses'];
    if (account == null || account['owner'] != lookupTableProgram || parsed?['type'] != 'lookupTable' || addresses is! List || addresses.any((a) => a is! String)) {
      throw const LookupError("An address table that isn't one");
    }
    _tablesRead.remove(keyOf(entry.table));
    _tablesRead[keyOf(entry.table)] = addresses.cast<String>();
    if (_tablesRead.length > _tablesKept) _tablesRead.remove(_tablesRead.keys.first);
  }
  return {for (final entry in wanted) entry.table: _tablesRead[keyOf(entry.table)]!};
}

// Every account the message uses, with its lookup tables read from the chain: never taken from
// whoever built the transaction. Throws LookupError.
Future<List<String>> resolveAccountKeys(Rpc rpc, DecodedMessage message) async {
  final tables = await readLookupTables(rpc, [
    for (final lookup in message.lookups) (table: lookup.table, length: [-1, ...lookup.writable, ...lookup.readonly].reduce((a, b) => a > b ? a : b) + 1),
  ]);
  try {
    return accountKeys(message, tables);
  } on FormatException {
    throw const LookupError('An address table lacks an entry');
  }
}
