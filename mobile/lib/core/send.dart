// Sending SOL and tokens (src/lib/send.ts). A transfer is planned from the chain as it is now and
// checked (amount, fees, what the recipient really is) and test-run by the node before anything is
// signed. Submitting plans it all over again, so what gets signed is never staler than what the
// user confirmed.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'base58.dart';
import 'config.dart';
import 'exchanges.dart';
import 'jupiter.dart';
import 'models.dart';
import 'sent.dart';
import 'solana/addresses.dart';
import 'solana/rpc.dart';
import 'solana/transaction.dart';
import 'units.dart';

// Lamports per signature.
final _baseFee = BigInt.from(5000);
// A SOL transfer needs about 450 compute units, its compute budget instructions included.
const _solUnits = 600;
// The limit for the test run that measures a token transfer.
const _simulationUnits = 400000;
// The size of a token account, about: Token-2022 ones run a few bytes over.
const _tokenAccountSize = 170;
// The priority fee offered, in micro-lamports per compute unit, stays within these.
final _minPrice = BigInt.from(1000);
final _maxPrice = BigInt.from(5000000);
// How long a transfer waits to learn whether the recipient is an exchange's: without an answer by
// then it goes on unchecked for that.
const _exchangeWait = Duration(seconds: 12);

// The checks before a transfer, each switchable in Security settings.
enum Protection { exchangeSupport, programAddresses, mintAddresses, tokenAccounts, lookalikeAddresses }

// Same first and last four characters, the part shortened displays show, but a different address:
// the shape of address poisoning.
bool lookalike(String a, String b) => a != b && a.length > 8 && b.length > 8 && a.substring(0, 4) == b.substring(0, 4) && a.substring(a.length - 4) == b.substring(b.length - 4);

class SendIntent {
  final String from;
  final String? mint; // null for SOL
  final String to;
  final String amount; // whole coins, or 'max'
  const SendIntent({required this.from, this.mint, required this.to, required this.amount});
}

enum ProgramKind { program, owned, derived }

// Reasons, found on the recipient, not to send. Each comes from a protection and stops the
// transfer: sending anyway takes turning that protection off.
sealed class SendCheck {
  const SendCheck();
  Protection get protection;
}

// A program; an account a program controls; or an address derived from a program, with no key.
class ProgramCheck extends SendCheck {
  final ProgramKind kind;
  const ProgramCheck(this.kind);
  @override
  Protection get protection => Protection.programAddresses;
}

class MintCheck extends SendCheck {
  final String? token;
  const MintCheck(this.token);
  @override
  Protection get protection => Protection.mintAddresses;
}

class TokenAccountCheck extends SendCheck {
  final String owner;
  const TokenAccountCheck(this.owner);
  @override
  Protection get protection => Protection.tokenAccounts;
}

// Starts and ends like a saved address or one of the wallets, but isn't it.
class LookalikeCheck extends SendCheck {
  final String name, address;
  const LookalikeCheck(this.name, this.address);
  @override
  Protection get protection => Protection.lookalikeAddresses;
}

// An exchange's own wallet, not a deposit address: nothing sent there is credited to anyone.
class ExchangeWalletCheck extends SendCheck {
  final String exchange;
  const ExchangeWalletCheck(this.exchange);
  @override
  Protection get protection => Protection.exchangeSupport;
}

// A deposit address of an exchange that doesn't take this token on Solana (basis "deposits") or
// doesn't trade it at all ("trading").
class ExchangeTokenCheck extends SendCheck {
  final String exchange, basis;
  const ExchangeTokenCheck(this.exchange, this.basis);
  @override
  Protection get protection => Protection.exchangeSupport;
}

class ExchangePausedCheck extends SendCheck {
  final String exchange;
  final String? coin;
  const ExchangePausedCheck(this.exchange, this.coin);
  @override
  Protection get protection => Protection.exchangeSupport;
}

// Less than the exchange credits: its minimum deposit in whole tokens.
class ExchangeMinimumCheck extends SendCheck {
  final String exchange, minimum;
  final String? coin;
  const ExchangeMinimumCheck(this.exchange, this.minimum, this.coin);
  @override
  Protection get protection => Protection.exchangeSupport;
}

// What zandr couldn't check, shown without stopping the transfer: whether the address is an
// exchange's (no answer in time), or the token, at an exchange with no list.
sealed class SendNote {
  const SendNote();
}

class ExchangeUncheckedNote extends SendNote {
  const ExchangeUncheckedNote();
}

class ExchangeNoListNote extends SendNote {
  final String exchange;
  const ExchangeNoListNote(this.exchange);
}

class SendCoin {
  final String? mint;
  final String? symbol, name, logo;
  final int decimals;
  const SendCoin({this.mint, this.symbol, this.name, this.logo, required this.decimals});
  String get label => symbol ?? name ?? 'Unknown token';
}

// What a transfer will do, for the user to confirm. Amounts are decimal strings; fees in SOL.
class SendReview {
  final Network network;
  final String from, to;
  // The recipient's name in the address book, or the wallet's own name for one of the user's wallets.
  final String? contact;
  final SendCoin coin;
  final String amount, fee;
  // Paid once to open the recipient's account for the token, when they don't have one yet.
  final String? rent;
  final List<SendCheck> checks;
  final List<SendNote> notes;
  const SendReview({required this.network, required this.from, required this.to, this.contact, required this.coin, required this.amount, required this.fee, this.rent, required this.checks, required this.notes});
}

enum SendReason {
  walletChanged, invalidAddress, ownAddress, noCoin, invalidAmount, insufficient, splitBalance, nonTransferable, transferHook,
  // A protection stopped it: the review says which.
  blocked,
  // SOL needed for the fee (and the recipient's new account), in total: `needed`.
  insufficientSol,
  // A new address must get at least `minimum` SOL; a wallet must keep that much, or nothing (`leftover`).
  belowMinimum,
  network,
  // The network ran the transfer as a test and it failed: `detail`.
  simulation,
}

class SendFailure implements Exception {
  final SendReason reason;
  final String? needed, minimum, detail;
  final bool leftover;
  final RpcFailure? rpc;
  const SendFailure(this.reason, {this.needed, this.minimum, this.detail, this.leftover = false, this.rpc});
}

Never _fail(SendReason reason, {String? needed, String? minimum, String? detail, bool leftover = false}) =>
    throw SendFailure(reason, needed: needed, minimum: minimum, detail: detail, leftover: leftover);

String _sol(BigInt lamports) => formatUnits(lamports, 9);

BigInt _feeFor(int units, BigInt price) => _baseFee + (price * BigInt.from(units) + BigInt.from(999999)) ~/ BigInt.from(1000000);

// What recent transactions touching these accounts paid per compute unit, the median of those that
// paid anything, within bounds: enough to land soon without overpaying.
BigInt _priorityPrice(List<dynamic> fees) => priorityPrice(fees, _minPrice, _maxPrice);

BigInt priorityPrice(List<dynamic> fees, BigInt min, BigInt max) {
  final paid = [
    for (final fee in fees)
      if (fee is Map && fee['prioritizationFee'] is int && (fee['prioritizationFee'] as int) > 0) BigInt.from(fee['prioritizationFee'] as int),
  ]..sort();
  final median = paid.isEmpty ? BigInt.zero : paid[paid.length ~/ 2];
  return median < min ? min : median > max ? max : median;
}

typedef Simulation = ({Object? err, List<String> logs, int? unitsConsumed, List<dynamic>? accounts});

// A test run of the transaction by the node, unsigned, against the latest state. `accounts` come
// back as they'd be afterwards.
Future<Simulation> simulate(Rpc rpc, String from, List<Instruction> instructions, [List<String> accounts = const []]) async {
  final message = compileMessage(from, instructions, base58Encode(Uint8List(32)));
  final wire = base64.encode(serializeTransaction(message, [Uint8List(64)]));
  final result = await rpc.call<Map<String, dynamic>>('simulateTransaction', [
    wire,
    {
      'encoding': 'base64', 'sigVerify': false, 'replaceRecentBlockhash': true, 'commitment': 'confirmed',
      if (accounts.isNotEmpty) 'accounts': {'addresses': accounts, 'encoding': 'base64'},
    },
  ]);
  final value = result['value'] as Map;
  return (
    err: value['err'],
    logs: [for (final line in (value['logs'] as List?) ?? const []) '$line'],
    unitsConsumed: value['unitsConsumed'] as int?,
    accounts: value['accounts'] as List?,
  );
}

bool _lacksSol(Simulation simulation) =>
    RegExp('InsufficientFundsForFee|InsufficientFundsForRent|AccountNotFound').hasMatch(jsonEncode(simulation.err)) ||
    simulation.logs.any((line) => RegExp('insufficient lamports', caseSensitive: false).hasMatch(line));

// Why a test run failed, in the words of the program that refused it if it said, else the error.
String whyFailed(Simulation simulation) {
  final said = simulation.logs.lastWhere((line) => RegExp(r'^Program log: (Error: )?').hasMatch(line) && !line.startsWith('Program log: Instruction:'), orElse: () => '');
  final text = said.isNotEmpty ? said.replaceFirst(RegExp(r'^Program log: (Error: )?'), '') : jsonEncode(simulation.err);
  return text.length > 200 ? text.substring(0, 200) : text;
}

class _Plan {
  final SendReview review;
  final List<Instruction> instructions;
  final int units;
  final BigInt price;
  final String blockhash;
  final int lastValidBlockHeight;
  _Plan(this.review, this.instructions, this.units, this.price, this.blockhash, this.lastValidBlockHeight);
}

// The least a system account may hold, and about what opening a token account costs, per node:
// they change rarely, so asked once an hour.
final _minimums = <String, ({DateTime at, BigInt system, BigInt tokenAccount})>{};

Future<({BigInt system, BigInt tokenAccount})> _rentMinimums(Rpc rpc) async {
  final known = _minimums[rpc.url];
  if (known != null && DateTime.now().difference(known.at) < const Duration(hours: 1)) return (system: known.system, tokenAccount: known.tokenAccount);
  final [system, tokenAccount] = await Future.wait([
    rpc.call<int>('getMinimumBalanceForRentExemption', [0]),
    rpc.call<int>('getMinimumBalanceForRentExemption', [_tokenAccountSize]),
  ]);
  _minimums[rpc.url] = (at: DateTime.now(), system: BigInt.from(system), tokenAccount: BigInt.from(tokenAccount));
  return (system: BigInt.from(system), tokenAccount: BigInt.from(tokenAccount));
}

class Sender {
  final Rpc rpc;
  final Network network;
  final Jupiter jupiter;
  // Null off mainnet, or with the exchange check off.
  final Exchanges? exchanges;
  // Fetches the exchanges' lists fresh, for an exchange this install has none for; true if new ones came.
  final Future<bool> Function()? refreshLists;
  final Set<Protection> enabled;
  // The address book and the user's wallets: who a recipient is, and what it may imitate.
  final List<({String name, String address})> known;

  Sender({required this.rpc, required this.network, required this.jupiter, this.exchanges, this.refreshLists, required this.enabled, required this.known});

  // As the recipient is typed in: whether it's an exchange's is worked out now (and remembered),
  // so the review has the answer at once.
  void inspectRecipient(String to) {
    if (exchanges != null && decodeAddress(to.trim()) != null) exchanges!.addressInfo(to.trim()).ignore();
  }

  Future<SendReview> prepare(SendIntent intent) async => (await _plan(intent, null)).review;

  // Checks again, then signs and sends; only the exact amount the user saw (no 'max'), at no more
  // than the fee they saw. A check that finds anything stops it. `sign` signs the message with
  // the sending wallet's key. Returns the signature, the review, and what's needed to follow it.
  Future<({String signature, SendReview review, Pending pending})> submit(SendIntent intent, String maxFeeText, Future<Uint8List> Function(Uint8List message) sign) async {
    final maxFee = parseUnits(maxFeeText, 9);
    if (intent.amount == 'max' || maxFee == null) _fail(SendReason.invalidAmount);
    final plan = await _plan(intent, maxFee);
    if (plan.review.checks.isNotEmpty) throw BlockedSend(plan.review);

    final message = compileMessage(plan.review.from, [setComputeUnitLimit(plan.units), setComputeUnitPrice(plan.price), ...plan.instructions], plan.blockhash);
    final signature = await sign(message);
    final wire = base64.encode(serializeTransaction(message, [signature]));
    // The node runs it once more before taking it; it refuses anything that would fail.
    await _network(() => rpc.call<String>('sendTransaction', [
          wire,
          {'encoding': 'base64', 'preflightCommitment': 'confirmed', 'maxRetries': 0},
        ]));
    return (signature: base58Encode(signature), review: plan.review, pending: Pending(wire, plan.lastValidBlockHeight));
  }

  Future<T> _network<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ChainError catch (error) {
      throw SendFailure(SendReason.network, rpc: error.reason, detail: error.detail);
    }
  }

  Future<_Plan> _plan(SendIntent intent, BigInt? maxFee) => _network(() => _planned(intent, maxFee));

  Future<_Plan> _planned(SendIntent intent, BigInt? maxFee) async {
    final from = intent.from;
    final to = intent.to.trim();
    final toBytes = decodeAddress(to);
    if (toBytes == null) _fail(SendReason.invalidAddress);
    if (to == from) _fail(SendReason.ownAddress);
    final mint = intent.mint;
    if (mint != null && decodeAddress(mint) == null) _fail(SendReason.noCoin);

    // Whether the recipient is an exchange's, and what its list says of the token, looked up while
    // the chain is read below. "unknown": no answer in time.
    final atExchange = () async {
      final exchanges = this.exchanges;
      if (exchanges == null) return null;
      try {
        final found = await exchanges.transferCheck(to, mint).timeout(_exchangeWait);
        if (found.exchange != null && found.kind == ExchangeKind.deposit && found.listed == null && await (refreshLists?.call() ?? Future.value(false))) {
          return await exchanges.transferCheck(to, mint).catchError((_) => found);
        }
        return found;
      } catch (_) {
        return 'unknown';
      }
    }();

    // The recipient's usual account for the token, under either token program.
    final recipientUsual = mint == null ? <String>[] : [associatedTokenAddress(to, mint, tokenProgram), associatedTokenAddress(to, mint, token2022Program)];

    final results = await Future.wait<Object?>([
      rpc.getAccounts(mint == null ? [to, from] : [to, from, mint, ...recipientUsual]),
      rpc.call<Map<String, dynamic>>('getLatestBlockhash', [
        {'commitment': 'confirmed'},
      ]),
      _rentMinimums(rpc),
      mint == null
          ? Future.value(const [])
          : rpc.call<Map<String, dynamic>>('getTokenAccountsByOwner', [
              from,
              {'mint': mint},
              {'encoding': 'jsonParsed', 'commitment': 'confirmed'},
            ]).then((result) => result['value'] as List),
      rpc.call<List<dynamic>>('getRecentPrioritizationFees', [
        [from, to],
      ]),
    ]);
    final accounts = results[0] as List<Map<String, dynamic>?>;
    final recipient = accounts[0], sender = accounts[1];
    final mintAccount = mint == null ? null : accounts[2];
    final recipientUsualAccounts = mint == null ? const <Map<String, dynamic>?>[] : accounts.sublist(3);
    final latest = (results[1] as Map)['value'] as Map;
    final (:system, tokenAccount: accountRent) = results[2] as ({BigInt system, BigInt tokenAccount});
    final minimum = system;
    final held = results[3] as List;
    final fees = results[4] as List;
    final balance = BigInt.from((sender?['lamports'] as int?) ?? 0);

    // What the recipient really is.
    final checks = <SendCheck>[];
    final parsed = parsedOf(recipient);
    final owner = recipient?['owner'];
    final tokenOwned = owner == tokenProgram || owner == token2022Program;
    // A token account for the very token being sent: the transfer goes straight into it, as meant.
    final intoTokenAccount = mint != null && tokenOwned && parsed?['type'] == 'account' && (parsed?['info'] as Map?)?['mint'] == mint;
    if (recipient?['executable'] == true) {
      checks.add(const ProgramCheck(ProgramKind.program));
    } else if (tokenOwned && parsed?['type'] == 'mint') {
      checks.add(const MintCheck(null));
    } else if (tokenOwned && parsed?['type'] == 'account') {
      if (!intoTokenAccount) checks.add(TokenAccountCheck('${(parsed?['info'] as Map?)?['owner'] ?? ''}'));
    } else if (recipient != null && owner != systemProgram) {
      checks.add(const ProgramCheck(ProgramKind.owned));
    } else if (!isOnCurve(toBytes)) {
      checks.add(const ProgramCheck(ProgramKind.derived));
    }

    // Who the recipient is to the user: a saved address, one of their wallets, or a lookalike of one.
    final contact = known.where((entry) => entry.address == to).firstOrNull?.name;
    final similar = contact == null ? known.where((entry) => lookalike(entry.address, to)).firstOrNull : null;
    if (similar != null) checks.add(LookalikeCheck(similar.name, similar.address));

    // The priority fee to offer, no more than leaves the total within `maxFee`.
    BigInt priceFor(int units) {
      final price = _priorityPrice(fees);
      if (maxFee == null) return price;
      final cap = maxFee > _baseFee ? ((maxFee - _baseFee) * BigInt.from(1000000)) ~/ BigInt.from(units) : BigInt.zero;
      return price < cap ? price : cap;
    }

    SendCoin coin;
    BigInt amount;
    List<Instruction> instructions;
    int units;
    BigInt price;
    BigInt? rent;

    if (mint == null) {
      coin = const SendCoin(symbol: 'SOL', name: 'Solana', logo: '$logoServer/$wrappedSol', decimals: 9);
      units = _solUnits;
      price = priceFor(units);
      final fee = _feeFor(units, price);
      final requested = intent.amount == 'max' ? balance - fee : parseUnits(intent.amount, 9);
      if (requested == null || (requested <= BigInt.zero && intent.amount != 'max')) _fail(SendReason.invalidAmount);
      amount = requested;
      if (amount <= BigInt.zero || (amount <= balance && amount + fee > balance)) _fail(SendReason.insufficientSol, needed: _sol(fee));
      if (amount > balance) _fail(SendReason.insufficient);
      final leftover = balance - amount - fee;
      if (leftover > BigInt.zero && leftover < minimum) _fail(SendReason.belowMinimum, minimum: _sol(minimum), leftover: true);
      if (recipient == null && amount < minimum) _fail(SendReason.belowMinimum, minimum: _sol(minimum));

      instructions = [transferSol(from, to, amount)];
      // The very transaction to be sent, priority fee included: with "max", one lamport off in the
      // fee would leave dust the network refuses.
      final simulation = await simulate(rpc, from, [setComputeUnitLimit(units), setComputeUnitPrice(price), ...instructions]);
      if (simulation.err != null) _fail(SendReason.simulation, detail: whyFailed(simulation));
    } else {
      final mintParsed = parsedOf(mintAccount);
      final mintInfo = mintParsed?['info'] as Map?;
      final program = mintAccount?['owner'];
      if (mintInfo == null || mintParsed?['type'] != 'mint' || (program != tokenProgram && program != token2022Program)) _fail(SendReason.noCoin);
      final tokenProgramId = program as String;
      final decimals = mintInfo['decimals'];
      if (decimals is! int || decimals < 0 || decimals > 255) _fail(SendReason.noCoin);

      // Token-2022 tokens can carry rules of their own.
      final extensions = (mintInfo['extensions'] as List?)?.whereType<Map>().toList() ?? const [];
      if (extensions.any((extension) => extension['extension'] == 'nonTransferable')) _fail(SendReason.nonTransferable);
      if (extensions.any((extension) => extension['extension'] == 'transferHook' && (extension['state'] as Map?)?['programId'] != null)) _fail(SendReason.transferHook);

      // The wallet's accounts holding the token, largest first, its usual one ahead of a tie.
      final own = associatedTokenAddress(from, mint, tokenProgramId);
      ({String address, BigInt amount})? sourceOf(Object? entry) {
        if (entry is! Map || entry['pubkey'] is! String) return null;
        final info = parsedOf((entry['account'] as Map?)?.cast<String, dynamic>())?['info'] as Map?;
        final raw = (info?['tokenAmount'] as Map?)?['amount'];
        if (info?['state'] != 'initialized' || raw is! String || !RegExp(r'^\d+$').hasMatch(raw)) return null;
        final amount = BigInt.parse(raw);
        return amount > BigInt.zero ? (address: entry['pubkey'] as String, amount: amount) : null;
      }

      final sources = [for (final entry in held) ?sourceOf(entry)]..sort((a, b) => a.amount == b.amount ? (b.address == own ? 1 : 0) - (a.address == own ? 1 : 0) : b.amount.compareTo(a.amount));
      if (sources.isEmpty) _fail(SendReason.noCoin);

      final requested = intent.amount == 'max' ? sources.first.amount : parseUnits(intent.amount, decimals);
      if (requested == null || requested <= BigInt.zero) _fail(SendReason.invalidAmount);
      amount = requested;
      final source = sources.where((entry) => entry.address == own && entry.amount >= requested).firstOrNull ?? sources.where((entry) => entry.amount >= requested).firstOrNull;
      if (source == null) _fail(sources.fold(BigInt.zero, (sum, entry) => sum + entry.amount) >= amount ? SendReason.splitBalance : SendReason.insufficient);

      // Into the recipient's usual account for the token, opened on the way if they have none yet.
      final destination = intoTokenAccount ? to : associatedTokenAddress(to, mint, tokenProgramId);
      final destinationAccount = intoTokenAccount ? recipient : recipientUsualAccounts[tokenProgramId == tokenProgram ? 0 : 1];
      final opening = destinationAccount == null;
      instructions = [
        if (opening) createTokenAccount(from, destination, to, mint, tokenProgramId),
        transferTokens(tokenProgramId, source.address, mint, destination, from, amount, decimals),
      ];

      // The test run measures the compute units and, for a new account, what opening it costs.
      final simulation = await simulate(rpc, from, [setComputeUnitLimit(_simulationUnits), ...instructions], opening ? [destination] : []);
      if (simulation.err != null) {
        if (_lacksSol(simulation)) _fail(SendReason.insufficientSol, needed: _sol(_feeFor(_solUnits, _minPrice) + (opening ? accountRent : BigInt.zero)));
        _fail(SendReason.simulation, detail: whyFailed(simulation));
      }
      units = ((simulation.unitsConsumed ?? _simulationUnits) * 1.15).ceil() + 1000;
      price = priceFor(units);
      if (opening) {
        final lamports = (simulation.accounts?.firstOrNull as Map?)?['lamports'];
        rent = lamports is int ? BigInt.from(lamports) : accountRent;
      }
      final needed = _feeFor(units, price) + (rent ?? BigInt.zero);
      if (balance < needed) _fail(SendReason.insufficientSol, needed: _sol(needed));
      final leftover = balance - needed;
      if (leftover > BigInt.zero && leftover < minimum) _fail(SendReason.belowMinimum, minimum: _sol(minimum), leftover: true);
      coin = SendCoin(mint: mint, decimals: decimals);
    }

    // At an exchange: its own wallet, a token it doesn't take or isn't taking now, or less than
    // it credits. What couldn't be checked is said too, without stopping the transfer.
    final exchange = await atExchange;
    final notes = <SendNote>[];
    if (exchange == 'unknown') {
      notes.add(const ExchangeUncheckedNote());
    } else if (exchange is TransferCheck && exchange.exchange != null) {
      final name = exchange.exchange!, listed = exchange.listed;
      if (exchange.kind == ExchangeKind.deposit && listed == null) notes.add(ExchangeNoListNote(name));
      if (exchange.kind == ExchangeKind.hotWallet) {
        checks.add(ExchangeWalletCheck(name));
      } else if (exchange.kind == ExchangeKind.deposit && listed != null && !listed.accepted) {
        checks.add(ExchangeTokenCheck(name, listed.basis));
      } else if (exchange.kind == ExchangeKind.deposit && listed != null && listed.paused) {
        checks.add(ExchangePausedCheck(name, listed.coin));
      } else if (exchange.kind == ExchangeKind.deposit && listed?.depositMin != null) {
        final least = parseUnits(listed!.depositMin!, coin.decimals);
        if (least != null && amount < least) checks.add(ExchangeMinimumCheck(name, listed.depositMin!, listed.coin));
      }
    }
    final found = checks.where((check) => enabled.contains(check.protection)).toList();

    // Names for the token being sent and for a mint the recipient turned out to be. Optional: the
    // transfer doesn't depend on them.
    final named = [?mint, if (found.any((check) => check is MintCheck)) to];
    final infos = named.isNotEmpty && network == Network.mainnet ? await jupiter.tokenInfo(named).catchError((_) => <String, TokenInfo?>{}) : <String, TokenInfo?>{};
    if (mint != null) coin = SendCoin(mint: mint, symbol: infos[mint]?.symbol, name: infos[mint]?.name, logo: infos[mint]?.logo, decimals: coin.decimals);
    final reviewed = [for (final check in found) check is MintCheck ? MintCheck(infos[to]?.symbol ?? infos[to]?.name) : check];

    return _Plan(
      SendReview(
        network: network, from: from, to: to, contact: contact, coin: coin, amount: formatUnits(amount, coin.decimals),
        fee: _sol(_feeFor(units, price)), rent: rent == null ? null : _sol(rent), checks: reviewed, notes: notes,
      ),
      instructions,
      units,
      price,
      latest['blockhash'] as String,
      latest['lastValidBlockHeight'] as int,
    );
  }
}

// A protection found something at submit time: the review says what.
class BlockedSend extends SendFailure {
  final SendReview review;
  const BlockedSend(this.review) : super(SendReason.blocked);
}
