// An address's history (src/server/activity.ts): its latest transactions, each read for what it
// did to the address. What moved comes from the balances before and after, which the node reports
// for every account, so it holds for any program; instructions only name the other side.
import 'config.dart';
import 'jupiter.dart';
import 'models.dart';
import 'solana/addresses.dart';
import 'solana/rpc.dart';
import 'units.dart';

// send: only coins out, through the system and token programs, signed by the address;
// receive: only coins in, from a transfer to it; swap: out and in, through an app;
// app: anything else; failed: nothing moved but the fee.
enum ActivityKind { send, receive, swap, app, failed }

class ActivityChange {
  final String? mint; // null for SOL
  final String amount; // signed: "-0.1", "+25"
  final String? symbol, logo;
  final bool verified;
  const ActivityChange({this.mint, required this.amount, this.symbol, this.logo, required this.verified});
}

class Activity {
  final String signature;
  final DateTime? time;
  final ActivityKind kind;
  final List<ActivityChange> changes; // arrivals first
  final String? fee; // in SOL, when this address paid it
  final String? counterparty;
  final String? program;
  final String? app;
  const Activity({required this.signature, this.time, required this.kind, required this.changes, this.fee, this.counterparty, this.program, this.app});
}

class ActivityPage {
  final List<Activity> items;
  // Continues further back (pass as `before`); null at the end.
  final String? next;
  const ActivityPage(this.items, this.next);
}

const _basicPrograms = {
  systemProgram, tokenProgram, token2022Program, associatedTokenProgram, computeBudgetProgram, memoProgram,
  'Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo',
};

const _apps = {
  'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4': 'Jupiter',
  'whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc': 'Orca',
  '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8': 'Raydium',
  'CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK': 'Raydium',
  'CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C': 'Raydium',
  'LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo': 'Meteora',
  '6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P': 'Pump.fun',
  'MarBmsSgKXdrN1egZf5sqe1TMai9K1rChYNDJgjq7aD': 'Marinade',
  'Stake11111111111111111111111111111111111111': 'Staking',
  'M2mx93ekt1fmXSVkTrUL9xVFHkmME8HTUi5Cyc5aF7K': 'Magic Eden',
  'TSWAPaqyCSx2KABk68Shruf4rp7CxcNi8hAsbdwmHbN': 'Tensor',
  'dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH': 'Drift',
  'KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD': 'Kamino',
  'PhoeNiXZ8ByJGLkxNfZRnkUfjvmuYqLR89jjFHGqdXY': 'Phoenix',
};

BigInt? _big(Object? value) => value is int ? BigInt.from(value) : value is String && RegExp(r'^\d+$').hasMatch(value) ? BigInt.parse(value) : null;
String? _str(Object? value) => value is String ? value : null;

typedef _Move = ({String? mint, BigInt delta, int decimals});
typedef Reading = ({ActivityKind kind, List<_Move> moves, String? fee, String? counterparty, String? program});

Reading? readTransaction(Map<String, dynamic> transaction, String address) {
  final meta = transaction['meta'] as Map?;
  final message = (transaction['transaction'] as Map?)?['message'] as Map?;
  if (meta == null || message == null || message['accountKeys'] is! List || meta['preBalances'] is! List || meta['postBalances'] is! List) return null;

  final keys = [
    for (final key in message['accountKeys'] as List)
      key is String ? (pubkey: key, signer: false) : key is Map ? (pubkey: _str(key['pubkey']) ?? '', signer: key['signer'] == true) : (pubkey: '', signer: false),
  ];
  final index = keys.indexWhere((key) => key.pubkey == address);
  final signed = index >= 0 && keys[index].signer;
  final fee = _big(meta['fee']) ?? BigInt.zero;
  final payer = index == 0;
  final failed = meta['err'] != null;

  var sol = BigInt.zero;
  if (index >= 0) {
    final before = _big((meta['preBalances'] as List)[index]), after = _big((meta['postBalances'] as List)[index]);
    if (before != null && after != null) sol = after - before + (payer ? fee : BigInt.zero);
  }

  final owners = <String, String>{};
  final tokens = <String, ({BigInt delta, int decimals})>{};
  for (final (balances, sign) in [(meta['preTokenBalances'], BigInt.from(-1)), (meta['postTokenBalances'], BigInt.one)]) {
    if (balances is! List) continue;
    for (final balance in balances) {
      if (balance is! Map || balance['accountIndex'] is! int || balance['mint'] is! String) continue;
      final i = balance['accountIndex'] as int;
      final account = i < keys.length ? keys[i].pubkey : null;
      final owner = _str(balance['owner']);
      if (account != null && owner != null) owners[account] = owner;
      final amount = balance['uiTokenAmount'] as Map?;
      final units = _big(amount?['amount']);
      if (owner != address || units == null || amount?['decimals'] is! int) continue;
      final mint = balance['mint'] as String;
      final entry = tokens[mint] ?? (delta: BigInt.zero, decimals: amount!['decimals'] as int);
      tokens[mint] = (delta: entry.delta + sign * units, decimals: entry.decimals);
    }
  }
  // Wrapped SOL is SOL to the user.
  final wrapped = tokens.remove(wrappedSol);
  if (wrapped != null) sol += wrapped.delta;

  final List<_Move> moves = failed
      ? []
      : [
          for (final MapEntry(key: mint, value: entry) in tokens.entries)
            if (entry.delta != BigInt.zero) (mint: mint, delta: entry.delta, decimals: entry.decimals),
          if (sol != BigInt.zero) (mint: null, delta: sol, decimals: 9),
        ];

  final top = (message['instructions'] as List?) ?? const [];
  final inner = [
    for (final group in (meta['innerInstructions'] as List?) ?? const [])
      if (group is Map && group['instructions'] is List) ...(group['instructions'] as List),
  ];
  final instructions = [
    for (final instruction in [...top, ...inner])
      if (instruction is Map && instruction['programId'] is String)
        // A memo's `parsed` is its text.
        if (instruction['parsed'] case final parsed)
          (
            programId: instruction['programId'] as String,
            type: parsed is Map ? _str(parsed['type']) : null,
            info: parsed is Map && parsed['info'] is Map ? parsed['info'] as Map : const {},
          ),
  ];
  final program = instructions.where((i) => !_basicPrograms.contains(i.programId)).firstOrNull?.programId;

  String? ownerOf(Object? account) => account is String ? (owners[account] ?? account) : null;
  String? to, from;
  for (final (programId: _, :type, :info) in instructions) {
    if (type != 'transfer' && type != 'transferChecked') continue;
    final lamports = info['lamports'] is int;
    final sender = _str(info['authority']) ?? _str(info['multisigAuthority']) ?? (lamports ? _str(info['source']) : ownerOf(info['source']));
    final recipient = lamports ? _str(info['destination']) : ownerOf(info['destination']);
    if (sender == null || recipient == null || sender == recipient) continue;
    if (sender == address && recipient != address) to ??= recipient;
    if (recipient == address && sender != address) from ??= sender;
  }

  final ins = moves.where((move) => move.delta > BigInt.zero).toList();
  final outs = moves.where((move) => move.delta < BigInt.zero).toList();
  final ActivityKind kind;
  if (failed) {
    kind = ActivityKind.failed;
  } else if (program == null && signed && outs.isNotEmpty && ins.isEmpty && to != null) {
    kind = ActivityKind.send;
  } else if (ins.isNotEmpty && outs.isEmpty && from != null && (program == null || !signed)) {
    kind = ActivityKind.receive;
  } else if (program != null && ins.isNotEmpty && outs.isNotEmpty) {
    kind = ActivityKind.swap;
  } else {
    kind = ActivityKind.app;
  }
  return (
    kind: kind,
    moves: [...ins, ...outs],
    fee: payer ? formatUnits(fee, 9) : null,
    counterparty: kind == ActivityKind.send || kind == ActivityKind.failed ? to : kind == ActivityKind.receive ? from : null,
    program: program,
  );
}

// The latest transactions, `limit` a page (back from `before`, or down to `until` to catch up),
// read three at a time. A node that stops answering partway, or takes longer than 7 s once the
// first came, gives a shorter page, which the next continues.
Future<ActivityPage> getActivity(Rpc rpc, Jupiter jupiter, Network network, String address, {String? before, String? until, int limit = 20}) async {
  final listed = await rpc.call<List<dynamic>>('getSignaturesForAddress', [
    address,
    {'limit': limit, 'commitment': 'confirmed', 'before': ?before, 'until': ?until},
  ]);
  final entries = [
    for (final entry in listed)
      if (entry is Map && entry['signature'] is String)
        (signature: entry['signature'] as String, time: entry['blockTime'] is int ? DateTime.fromMillisecondsSinceEpoch((entry['blockTime'] as int) * 1000) : null),
  ];

  final transactions = <Map<String, dynamic>?>[];
  Object? failure;
  DateTime? deadline;
  for (var i = 0; i < entries.length && failure == null && (deadline == null || DateTime.now().isBefore(deadline)); i += 3) {
    try {
      transactions.addAll(await Future.wait(entries.skip(i).take(3).map((entry) => rpc.call<Map<String, dynamic>?>('getTransaction', [
            entry.signature,
            {'encoding': 'jsonParsed', 'commitment': 'confirmed', 'maxSupportedTransactionVersion': 1},
          ]))));
      deadline ??= DateTime.now().add(const Duration(seconds: 7));
    } catch (error) {
      failure = error;
    }
  }
  if (failure != null && transactions.isEmpty) throw failure;

  final readings = [
    for (final (i, transaction) in transactions.indexed) (entry: entries[i], reading: transaction == null ? null : readTransaction(transaction, address)),
  ];
  final mints = {for (final r in readings) ...?r.reading?.moves.map((move) => move.mint).whereType<String>()}.toList();
  final infos = network == Network.mainnet && mints.isNotEmpty ? await jupiter.tokenInfo(mints) : <String, TokenInfo?>{};

  final items = [
    for (final (:entry, :reading) in readings)
      if (reading != null)
        Activity(
          signature: entry.signature,
          time: entry.time,
          kind: reading.kind,
          changes: [
            for (final move in reading.moves)
              () {
                final amount = '${move.delta.isNegative ? '-' : '+'}${formatUnits(move.delta.abs(), move.decimals)}';
                if (move.mint == null) return ActivityChange(amount: amount, symbol: 'SOL', logo: jupiter.logo(wrappedSol), verified: true);
                final info = infos[move.mint];
                return ActivityChange(mint: move.mint, amount: amount, symbol: info?.symbol, logo: info?.logo, verified: info?.verified ?? false);
              }(),
          ],
          fee: reading.fee,
          counterparty: reading.counterparty,
          program: reading.program,
          app: reading.program == null ? null : _apps[reading.program],
        ),
  ];
  final more = transactions.length < entries.length || entries.length == limit;
  return ActivityPage(items, more && transactions.isNotEmpty ? entries[transactions.length - 1].signature : null);
}
