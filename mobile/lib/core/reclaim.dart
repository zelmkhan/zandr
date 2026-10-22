// Reclaiming SOL from the wallet's token accounts (src/lib/reclaim.ts). Each holds rent, about
// 0.002 SOL, that closing it returns. Empty accounts are simply closed. Accounts holding junk
// (worth under a dollar, or with no price) can be closed too, their tokens burned first, but only
// those the user picked and acknowledged, and only if they're still junk when checked again.
// Collectibles and wrapped SOL are never offered. Every account is read again right before, every
// transaction test-run, and signed only if the test run closes those accounts and returns their
// rent to the wallet.
import 'dart:convert';
import 'dart:typed_data';

import 'base58.dart';
import 'config.dart';
import 'jupiter.dart';
import 'models.dart';
import 'portfolio.dart';
import 'send.dart' show priorityPrice;
import 'sent.dart';
import 'solana/addresses.dart';
import 'solana/rpc.dart';
import 'solana/transaction.dart';
import 'units.dart';

const reclaimJunkMaxUsd = 1.0;
// Accounts per transaction, and about what each transaction costs, in lamports.
const reclaimBatch = (close: 20, burn: 8);
// About what one costs at a usual priority: the base fee and the priority fee for its compute.
const reclaimFeePerTransaction = 15000;
// Compute units per account, generously, for the test run; what's sent asks for what that used.
const _units = (close: 8000, burn: 16000);
// The priority fee per compute unit, in micro-lamports: what recent transactions on these accounts
// paid, but at least enough to land within the minute a blockhash lasts even on a busy network.
// The accounts are long idle, so their own recent fees say little: the floor does the work. Next
// to the rent each account gives back (about 2,000,000 lamports), even the cap costs little.
final _minPrice = BigInt.from(100000);
final _maxPrice = BigInt.from(2000000);
final _baseFee = BigInt.from(5000);

// Token-2022 extensions that don't keep an account from closing or its tokens from burning.
const _harmless = {'immutableOwner', 'memoTransfer', 'cpiGuard', 'nonTransferableAccount', 'transferHookAccount'};

enum ReclaimReason {
  // None of the accounts asked for can be closed any more.
  nothing,
  unacknowledged,
  // Token prices couldn't be checked, so nothing is burned.
  prices,
  network,
  // The test run failed, or didn't return what closing should: `detail`.
  simulation,
}

class ReclaimFailure implements Exception {
  final ReclaimReason reason;
  final String? detail;
  const ReclaimFailure(this.reason, [this.detail]);
}

// An account offered: empty, or holding junk (`balance` and `value`, US dollars, for junk only).
class ReclaimAccount {
  final String address, mint;
  final String? symbol, logo;
  final bool verified;
  final String sol;
  final String? balance;
  final double? value;
  const ReclaimAccount({required this.address, required this.mint, this.symbol, this.logo, required this.verified, required this.sol, this.balance, this.value});
}

class ReclaimPlan {
  final List<ReclaimAccount> empty, junk;
  final bool pricesKnown;
  const ReclaimPlan(this.empty, this.junk, this.pricesKnown);
}

class _Account {
  final String address, mint, program;
  final BigInt lamports, amount;
  final int decimals;
  const _Account(this.address, this.mint, this.program, this.lamports, this.amount, this.decimals);
}

// A token account the wallet alone controls and can close, with what's in it.
_Account? _closable(Map entry, String owner) {
  final account = (entry['account'] as Map?)?.cast<String, dynamic>();
  final parsed = parsedOf(account);
  final info = parsed?['info'] as Map?;
  final tokenAmount = info?['tokenAmount'] as Map?;
  if (parsed?['type'] != 'account' || info == null || info['mint'] is! String || entry['pubkey'] is! String) return null;
  final program = account!['owner'];
  if (program != tokenProgram && program != token2022Program) return null;
  final raw = tokenAmount?['amount'], decimals = tokenAmount?['decimals'];
  if (raw is! String || !RegExp(r'^\d+$').hasMatch(raw) || decimals is! int) return null;
  // The wallet's, usable, not wrapped SOL, and closable by the wallet: no one else holds that right.
  if (info['owner'] != owner || info['state'] != 'initialized' || info['isNative'] == true) return null;
  if (info['closeAuthority'] != null && info['closeAuthority'] != owner) return null;
  final extensions = (info['extensions'] as List?) ?? const [];
  final harmless = extensions.every((extension) =>
      extension is Map &&
      (_harmless.contains(extension['extension']) ||
          (extension['extension'] == 'transferFeeAmount' && '${(extension['state'] as Map?)?['withheldAmount'] ?? 0}' == '0')));
  final lamports = account['lamports'];
  if (!harmless || lamports is! int || lamports <= 0) return null;
  return _Account(entry['pubkey'] as String, info['mint'] as String, program as String, BigInt.from(lamports), BigInt.parse(raw), decimals);
}

double? _valueOf(_Account account, Coin? coin) => coin?.price == null ? null : double.parse(formatUnits(account.amount, account.decimals)) * coin!.price!;
bool _isJunk(double? value) => value == null || value < reclaimJunkMaxUsd;
int _byRent(_Account a, _Account b) => b.lamports.compareTo(a.lamports);
BigInt _feeFor(int units, BigInt price) => _baseFee + (price * BigInt.from(units) + BigInt.from(999999)) ~/ BigInt.from(1000000);

class Reclaimer {
  final Rpc rpc;
  final Jupiter jupiter;
  final Network network;
  Reclaimer(this.rpc, this.jupiter, this.network);

  Future<T> _network<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ChainError catch (error) {
      throw ReclaimFailure(ReclaimReason.network, error.detail ?? error.reason.name);
    }
  }

  // The wallet's token accounts that could be closed, as the chain has them now: empty ones, and
  // ones holding tokens that aren't collectibles (those have no decimals).
  Future<({List<_Account> empty, List<_Account> held})> _find(String owner) async {
    final lists = await Future.wait([
      for (final programId in [tokenProgram, token2022Program])
        rpc.call<Map<String, dynamic>>('getTokenAccountsByOwner', [
          owner,
          {'programId': programId},
          {'encoding': 'jsonParsed', 'commitment': 'confirmed'},
        ]),
    ]);
    final accounts = [
      for (final list in lists)
        for (final entry in (list['value'] as List).whereType<Map>()) ?_closable(entry, owner),
    ];
    return (
      empty: accounts.where((account) => account.amount == BigInt.zero).toList(),
      held: accounts.where((account) => account.amount > BigInt.zero && account.decimals > 0).toList(),
    );
  }

  Future<Map<String, Coin>> _coins(String address) async {
    final portfolio = await getPortfolio(rpc, jupiter, network, address);
    return {for (final coin in portfolio.coins) coin.mint: coin};
  }

  ReclaimAccount _view(_Account account, ({String? symbol, String? logo, bool verified})? names, bool held, double? value) => ReclaimAccount(
        address: account.address, mint: account.mint, symbol: names?.symbol, logo: names?.logo, verified: names?.verified ?? false,
        sol: formatUnits(account.lamports, 9), balance: held ? formatUnits(account.amount, account.decimals) : null, value: held ? value : null,
      );

  Future<ReclaimPlan> plan(String from) => _network(() async {
        final (:empty, :held) = await _find(from);
        // Junk, by value: without prices it can't be told apart, and none is offered.
        Map<String, Coin>? coins;
        if (held.isNotEmpty) coins = await _coins(from).then<Map<String, Coin>?>((value) => value).catchError((_) => null);
        final junk = coins == null ? <_Account>[] : held.where((account) => _isJunk(_valueOf(account, coins![account.mint]))).toList();

        // Names and logos for the empty ones; the tokens are all but forgotten, so lacking them is fine.
        final mints = {for (final account in empty) account.mint}.toList();
        final infos = network == Network.mainnet && mints.isNotEmpty ? await jupiter.tokenInfo(mints).catchError((_) => <String, TokenInfo?>{}) : <String, TokenInfo?>{};

        empty.sort(_byRent);
        final valued = [for (final account in junk) (account: account, coin: coins![account.mint], value: _valueOf(account, coins[account.mint]))]
          // Those with no price first, then the least worth.
          ..sort((a, b) => (a.value ?? -1).compareTo(b.value ?? -1));
        return ReclaimPlan(
          [
            for (final account in empty)
              _view(account, infos[account.mint] == null ? null : (symbol: infos[account.mint]!.symbol, logo: infos[account.mint]!.logo, verified: infos[account.mint]!.verified), false, null),
          ],
          [for (final (:account, :coin, :value) in valued) _view(account, coin == null ? null : (symbol: coin.symbol, logo: coin.logo, verified: coin.verified), true, value)],
          held.isEmpty || coins != null,
        );
      });

  // What one transaction does: each account burned first if it holds anything, then closed, the
  // rent going to the wallet. `units` is the compute it asks for: by default, generously.
  ({List<Instruction> instructions, BigInt fee, int units}) _transactionFor(List<_Account> accounts, String owner, BigInt price, [int? units]) {
    final asked = units ?? accounts.fold<int>(0, (sum, account) => sum + (account.amount > BigInt.zero ? _units.burn : _units.close));
    return (
      instructions: [
        setComputeUnitLimit(asked),
        setComputeUnitPrice(price),
        for (final account in accounts) ...[
          if (account.amount > BigInt.zero) burnTokens(account.program, account.address, account.mint, owner, account.amount, account.decimals),
          closeTokenAccount(account.program, account.address, owner, owner),
        ],
      ],
      fee: _feeFor(asked, price),
      units: asked,
    );
  }

  // The test run: the accounts closed, and the wallet at least their rent better off, the fee aside.
  // What's sent then asks for the compute the test run used, and a margin: a transaction asking for
  // far more than it needs ranks lower with the validators for the same price.
  Future<({Uint8List? message, String? detail})> _testRun(String owner, List<_Account> accounts, String blockhash, BigInt price) async {
    final (:instructions, :fee, :units) = _transactionFor(accounts, owner, price);
    final message = compileMessage(owner, instructions, blockhash);
    final watched = [owner, for (final account in accounts) account.address];
    final [before, result] = await Future.wait<Object?>([
      rpc.getAccounts([owner]),
      rpc.call<Map<String, dynamic>>('simulateTransaction', [
        base64.encode(serializeTransaction(message, [Uint8List(64)])),
        {'encoding': 'base64', 'sigVerify': false, 'replaceRecentBlockhash': true, 'commitment': 'confirmed', 'accounts': {'addresses': watched, 'encoding': 'base64'}},
      ]),
    ]);
    final simulation = (result as Map)['value'] as Map;
    if (simulation['err'] != null) {
      final logs = [for (final line in (simulation['logs'] as List?) ?? const []) '$line'];
      final said = logs.lastWhere((line) => line.startsWith('Program log: Error'), orElse: () => '');
      final text = said.isNotEmpty ? said.replaceFirst(RegExp(r'^Program log: (Error: )?'), '') : jsonEncode(simulation['err']);
      return (message: null, detail: text.length > 200 ? text.substring(0, 200) : text);
    }
    final after = (simulation['accounts'] as List?) ?? const [];
    int lamportsOf(Object? account) => account is Map && account['lamports'] is int ? account['lamports'] as int : 0;
    final closed = after.skip(1).every((account) => lamportsOf(account) == 0);
    final gained = BigInt.from(lamportsOf(after.firstOrNull)) - BigInt.from(lamportsOf((before as List).firstOrNull));
    final rent = accounts.fold(BigInt.zero, (sum, account) => sum + account.lamports);
    final used = simulation['unitsConsumed'];
    final tight = used is int && used > 0 ? (used * 1.15).ceil() + 300 : units;
    final sent = _transactionFor(accounts, owner, price, tight < units ? tight : units);
    // Checked against the fee of what was test-run (its generous compute), which the test run charged.
    if (!closed || gained < rent - fee) return (message: null, detail: "The test run didn't close the accounts or return their SOL.");
    return (message: compileMessage(owner, sent.instructions, blockhash), detail: null);
  }

  // Closes `close` (empty) and burns then closes `burn` (junk, acknowledged), as they are now.
  // `sign` signs every message with the wallet's key; each transaction is sent and returned to follow.
  Future<({List<({String signature, Pending pending})> sent, String reclaimed, int burned, int skipped})> execute(
    String from,
    List<String> close,
    List<String> burn,
    bool acknowledged,
    Future<List<Uint8List>> Function(List<Uint8List> messages) sign,
  ) =>
      _network(() async {
        final requested = [...close, ...burn];
        if (requested.isEmpty || requested.length > 500 || requested.any((address) => decodeAddress(address) == null)) throw const ReclaimFailure(ReclaimReason.nothing);
        if (burn.isNotEmpty && !acknowledged) throw const ReclaimFailure(ReclaimReason.unacknowledged);

        // Only what was asked for and can still be closed, as the chain has it now.
        final (:empty, :held) = await _find(from);
        final closing = empty.where((account) => close.contains(account.address)).toList();
        var burning = held.where((account) => burn.contains(account.address)).toList();
        var skipped = requested.length - closing.length - burning.length;

        // Burned only if still junk: what it's worth now, not when the list was shown.
        if (burning.isNotEmpty) {
          final Map<String, Coin> coins;
          try {
            coins = await _coins(from);
          } on Exception {
            throw const ReclaimFailure(ReclaimReason.prices);
          }
          final junk = burning.where((account) => _isJunk(_valueOf(account, coins[account.mint]))).toList();
          skipped += burning.length - junk.length;
          burning = junk;
        }
        if (closing.isEmpty && burning.isEmpty) throw const ReclaimFailure(ReclaimReason.nothing);

        final [latestResult, fees] = await Future.wait<Object?>([
          rpc.call<Map<String, dynamic>>('getLatestBlockhash', [
            {'commitment': 'confirmed'},
          ]),
          // The node takes up to 128 accounts: the wallet's own and the first of those closing.
          rpc.call<List<dynamic>>('getRecentPrioritizationFees', [
            [from, for (final account in [...closing, ...burning].take(127)) account.address],
          ]).then<List<dynamic>>((found) => found, onError: (_) => const []),
        ]);
        final latest = (latestResult! as Map)['value'] as Map;
        final blockhash = latest['blockhash'] as String;
        final price = priorityPrice(fees! as List<dynamic>, _minPrice, _maxPrice);

        List<List<_Account>> batchesOf(List<_Account> items, int size) => [for (var i = 0; i < items.length; i += size) items.sublist(i, (i + size).clamp(0, items.length))];
        // Each transaction test-run. One that fails over a token that can't be burned is tried
        // account by account, and the ones that still fail are left out.
        final batches = [...batchesOf(closing, reclaimBatch.close), ...batchesOf(burning, reclaimBatch.burn)];
        final runs = await Future.wait([for (final batch in batches) _testRun(from, batch, blockhash, price)]);
        final messages = <Uint8List>[];
        // The accounts each message closes, in step with `messages`.
        final closes = <List<_Account>>[];
        String? failed;
        for (final (i, run) in runs.indexed) {
          if (run.message != null) {
            messages.add(run.message!);
            closes.add(batches[i]);
            continue;
          }
          failed = run.detail;
          final alone = await Future.wait([for (final account in batches[i]) _testRun(from, [account], blockhash, price)]);
          final good = [for (final (j, account) in batches[i].indexed) if (alone[j].message != null) account];
          skipped += batches[i].length - good.length;
          if (good.isEmpty) continue;
          final retried = await _testRun(from, good, blockhash, price);
          if (retried.message == null) {
            skipped += good.length;
            continue;
          }
          messages.add(retried.message!);
          closes.add(good);
        }
        if (messages.isEmpty) throw failed != null ? ReclaimFailure(ReclaimReason.simulation, failed) : const ReclaimFailure(ReclaimReason.nothing);

        // Signed together, sent one by one. Should the node turn one away once others went, what went
        // is still followed and told, and the rest left as they were.
        final signatures = await sign(messages);
        final sent = <({String signature, Pending pending})>[];
        final done = <_Account>[];
        for (final (i, message) in messages.indexed) {
          final wire = base64.encode(serializeTransaction(message, [signatures[i]]));
          try {
            await rpc.call<String>('sendTransaction', [
              wire,
              {'encoding': 'base64', 'preflightCommitment': 'confirmed', 'maxRetries': 0},
            ]);
          } catch (_) {
            if (sent.isEmpty) rethrow;
            skipped += [for (final rest in closes.skip(i)) ...rest].length;
            break;
          }
          sent.add((signature: base58Encode(signatures[i]), pending: Pending(wire, latest['lastValidBlockHeight'] as int)));
          done.addAll(closes[i]);
        }
        return (
          sent: sent,
          reclaimed: formatUnits(done.fold(BigInt.zero, (sum, account) => sum + account.lamports), 9),
          burned: done.where((account) => account.amount > BigInt.zero).length,
          skipped: skipped,
        );
      });
}
