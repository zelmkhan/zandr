// Swapping one coin for another through Jupiter (src/lib/swap.ts). Jupiter quotes a swap and gives
// the instructions that carry it out (Swap API v2, /build); the wallet puts them into a transaction
// itself, with its own compute budget and zandr's fee, and trusts none of it. Before anything is
// signed it takes the transaction apart and checks that only this wallet signs, only programs a swap
// needs run, and in only the ways a swap uses them, that none of the wallet's other token accounts
// is even in it, and that a test run takes out no more than quoted and brings in no less than the
// minimum. Then it signs exactly those bytes.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'base58.dart';
import 'jupiter.dart';
import 'models.dart';
import 'sent.dart';
import 'solana/addresses.dart';
import 'solana/message.dart';
import 'solana/rpc.dart';
import 'solana/transaction.dart';
import 'units.dart';
import 'vault_crypto.dart' show randomBytes;

// zandr's fee: 0.85% of the swap, always in SOL, sent to zandr's wallet by a transfer of its own in
// the same transaction (so it's paid only if the swap goes through).
final _feeBps = BigInt.from(85);
const feeWallet = '4GAsMyghyygb4BUxCpcBpPWnMs1YrqBsYvVFDCy3ueme';
// What a swap may cost in SOL beyond what's sold and zandr's fee: the network fee, a priority fee
// (capped at 0.001 SOL) and opening an account for the token bought.
final _solBudget = BigInt.from(10000000);
final _maxPriorityFee = BigInt.from(1000000);
// The most compute a transaction may ask for; a swap asks for what its test run used, and a fifth more.
const _maxUnits = 1400000;
// The largest transaction the network takes, in bytes.
const _maxTransaction = 1232;
// Kept back when swapping all of the wallet's SOL, to pay for the swap itself.
final _solReserve = BigInt.from(5000000);
// How far below the quote a swap may come out before it fails instead: half a percent.
const _slippageBps = 50;
const quoteTtl = Duration(seconds: 60);
// A quote is built with a blockhash good for about a minute; older than this, it's built again.
const _rebuildAfter = Duration(seconds: 30);
// Other token accounts of the wallet a swap may route through (each checked in the test run).
const _maxOtherAccounts = 4;

// Offered before anything is searched for: SOL, the main stablecoins and well-known tokens.
const popularTokens = [
  wrappedSol,
  usdcMint,
  'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB', // USDT
  'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', // JUP
  'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn', // JitoSOL
  'mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So', // mSOL
  'jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL', // JTO
  'HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3', // PYTH
  '4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R', // RAY
  'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', // BONK
  'EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm', // WIF
];

enum SwapReason {
  walletChanged, sameToken, unknownToken, invalidAmount, insufficient, noRoute, expired,
  // SOL needed to pay for the swap: `needed`.
  insufficientSol,
  // The transaction from the swap service failed zandr's checks: nothing was signed. `detail` says why.
  unsafe,
  simulation,
  network,
}

class SwapFailure implements Exception {
  final SwapReason reason;
  final String? needed, detail;
  const SwapFailure(this.reason, {this.needed, this.detail});
  @override
  String toString() => 'SwapFailure(${reason.name}${detail == null ? '' : ': $detail'})';
}

Never _fail(SwapReason reason, {String? needed, String? detail}) => throw SwapFailure(reason, needed: needed, detail: detail);
Never _unsafe(String detail) => _fail(SwapReason.unsafe, detail: detail);

class MintInfo {
  final int decimals;
  final String program;
  const MintInfo(this.decimals, this.program);
}

// A quote as built, kept until it's swapped: in whole coins for the screen, raw for the swap.
class SwapQuote {
  final String id;
  final DateTime at;
  final String from;
  final SwapBuild build;
  final MintInfo input, output;
  // zandr's, in lamports.
  final BigInt fee;
  const SwapQuote({required this.id, required this.at, required this.from, required this.build, required this.input, required this.output, required this.fee});

  String get inAmount => formatUnits(BigInt.parse(build.inAmount), input.decimals);
  String get outAmount => formatUnits(BigInt.parse(build.outAmount), output.decimals);
  String get minOutAmount => formatUnits(BigInt.parse(build.minOutAmount), output.decimals);
  // Jupiter gives it as a fraction.
  double get priceImpactPct => build.priceImpactPct * 100;
  String? get feeText => fee > BigInt.zero ? formatUnits(fee, 9) : null;
}

class SwapReview {
  final SwapQuote quote;
  // What the test run says arrives at today's prices; at least the quote's minimum either way.
  final String outAmount;
  final String fee;
  // Paid once to open the account for the token bought, if the wallet has none yet.
  final String? rent;
  const SwapReview({required this.quote, required this.outAmount, required this.fee, this.rent});
}

BigInt _tokenAmount(Map<String, dynamic>? account) => tokenAmountOf(account);

// Decimals and token program of each mint, read once: neither ever changes.
final _mints = <String, MintInfo>{};

String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

typedef _Simulation = ({Object? err, List<String> logs, List<dynamic>? accounts, int? unitsConsumed});

class Swapper {
  final Rpc rpc;
  final Jupiter jupiter;
  // The wallet's coins as last fetched: their prices give the fee on a swap between two tokens.
  final Portfolio? Function() portfolio;
  Swapper(this.rpc, this.jupiter, this.portfolio);

  Future<List<TokenListing>> tokens(String query) async {
    if (query.trim().isNotEmpty) return jupiter.search(query.trim());
    final found = await jupiter.tokenInfo(popularTokens);
    return [for (final mint in popularTokens) if (found[mint] != null) TokenListing(mint, found[mint]!)];
  }

  Future<T> _network<T>(Future<T> Function() call, {bool quoting = false}) async {
    try {
      return await call();
    } on ChainError catch (error) {
      throw SwapFailure(SwapReason.network, detail: error.detail ?? error.reason.name);
    } on ServiceError catch (error) {
      // Jupiter answers a pair or amount it can't route with an error, not an empty quote.
      if (quoting && (error.reason == ServiceFailure.badResponse || error.reason == ServiceFailure.invalidRequest)) _fail(SwapReason.noRoute);
      throw SwapFailure(SwapReason.network, detail: error.detail == null ? error.reason.name : 'the swap service says: ${error.detail}');
    }
  }

  // A coin the wallet holds, as its balances last had it (kept live): native SOL for wrapped SOL's mint.
  Coin? _walletCoin(String from, String mint) {
    final held = portfolio();
    if (held == null || held.address != from) return null;
    return held.coins.where((coin) => mint == wrappedSol ? coin.native : !coin.native && coin.mint == mint).firstOrNull;
  }

  Future<List<MintInfo>> _mintInfo(List<String> addresses, [String? from]) async {
    // Wrapped SOL, and the coins the wallet holds, are known without asking the node.
    for (final address in addresses) {
      if (_mints.containsKey(address)) continue;
      final coin = from == null ? null : _walletCoin(from, address);
      if (address == wrappedSol) {
        _mints[address] = const MintInfo(9, tokenProgram);
      } else if (coin != null) {
        _mints[address] = MintInfo(coin.decimals, coin.program == 'token-2022' ? token2022Program : tokenProgram);
      }
    }
    final missing = addresses.where((address) => !_mints.containsKey(address)).toList();
    final accounts = missing.isEmpty ? const <Map<String, dynamic>?>[] : await rpc.getAccounts(missing);
    for (final (i, account) in accounts.indexed) {
      final parsed = parsedOf(account);
      final decimals = (parsed?['info'] as Map?)?['decimals'];
      final owner = account?['owner'];
      if (account == null || parsed?['type'] != 'mint' || (owner != tokenProgram && owner != token2022Program) || decimals is! int) _fail(SwapReason.unknownToken);
      _mints[missing[i]] = MintInfo(decimals, owner as String);
    }
    return [for (final address in addresses) _mints[address]!];
  }

  // The wallet's SOL, or what it holds of a token in its usual account for it: the one a swap uses.
  Future<BigInt> _holding(String from, String mint, MintInfo token) async {
    if (mint == wrappedSol) {
      final result = await rpc.call<Map<String, dynamic>>('getBalance', [from, {'commitment': 'confirmed'}]);
      return BigInt.from(result['value'] as int);
    }
    final [account] = await rpc.getAccounts([associatedTokenAddress(from, mint, token.program)]);
    return _tokenAmount(account);
  }

  // zandr's fee, in lamports: a share of what's sold or bought, whichever is SOL; else of what's
  // sold, at its price in SOL from the wallet's own coins. None without a price.
  BigInt _feeOf(String from, SwapBuild build, MintInfo input) {
    if (build.inputMint == wrappedSol) return BigInt.parse(build.inAmount) * _feeBps ~/ BigInt.from(10000);
    if (build.outputMint == wrappedSol) return BigInt.parse(build.outAmount) * _feeBps ~/ BigInt.from(10000);
    final held = portfolio();
    final coins = held != null && held.address == from ? held.coins : const <Coin>[];
    final sol = coins.where((coin) => coin.native).firstOrNull?.price;
    final token = coins.where((coin) => !coin.native && coin.mint == build.inputMint).firstOrNull?.price;
    if (sol == null || token == null || sol <= 0) return BigInt.zero;
    final inSol = (int.parse(build.inAmount) / pow(10, input.decimals)) * (token / sol);
    return BigInt.from((inSol * 1e9 * _feeBps.toInt() / 10000).floor());
  }

  Future<SwapBuild> _build(String from, String inputMint, String outputMint, BigInt amount) =>
      jupiter.build(inputMint, outputMint, '$amount', _slippageBps, from);

  Future<SwapQuote> quote(String from, String inputMint, String outputMint, String amountText) => _network(() async {
        if (decodeAddress(inputMint) == null || decodeAddress(outputMint) == null) _fail(SwapReason.unknownToken);
        if (inputMint == outputMint) _fail(SwapReason.sameToken);
        // What's sold is in the wallet, its decimals and balance known from the balances already;
        // what's bought is looked up alongside the price, not before it. Anything the balances got
        // wrong, the test run before signing finds.
        final [input] = await _mintInfo([inputMint], from);
        final known = _walletCoin(from, inputMint);
        final held = known != null ? BigInt.parse(known.amount) : await _holding(from, inputMint, input);
        final amount = amountText == 'max' ? (inputMint == wrappedSol ? held - _solReserve : held) : parseUnits(amountText, input.decimals);
        if (amount == null) _fail(SwapReason.invalidAmount);
        if (amount <= BigInt.zero) _fail(amountText == 'max' ? SwapReason.insufficient : SwapReason.invalidAmount);
        if (amount > held) _fail(SwapReason.insufficient);
        final found = await Future.wait<Object>([_build(from, inputMint, outputMint, amount), _mintInfo([outputMint], from)], eagerError: true);
        final build = found[0] as SwapBuild;
        final output = (found[1] as List<MintInfo>).single;
        return SwapQuote(id: _hex(randomBytes(16)), at: DateTime.now(), from: from, build: build, input: input, output: output, fee: _feeOf(from, build, input));
      }, quoting: true);

  Never _failedRun(_Simulation simulation) {
    final failed = jsonEncode(simulation.err);
    if (RegExp('InsufficientFundsForFee|InsufficientFundsForRent|AccountNotFound').hasMatch(failed) ||
        simulation.logs.any((line) => RegExp('insufficient lamports', caseSensitive: false).hasMatch(line))) {
      _fail(SwapReason.insufficientSol, needed: formatUnits(_solBudget, 9));
    }
    final said = simulation.logs.lastWhere((line) => RegExp(r'^Program log: (Error|error)').hasMatch(line), orElse: () => '');
    final text = said.isNotEmpty ? said.replaceFirst('Program log: ', '') : failed;
    _fail(SwapReason.simulation, detail: text.length > 200 ? text.substring(0, 200) : text);
  }

  Future<_Simulation> _simulate(Uint8List wire, [List<String>? accounts]) async {
    final result = await rpc.call<Map<String, dynamic>>('simulateTransaction', [
      base64.encode(wire),
      {
        'encoding': 'base64', 'sigVerify': false, 'replaceRecentBlockhash': true, 'commitment': 'confirmed',
        if (accounts != null) 'accounts': {'addresses': accounts, 'encoding': 'jsonParsed'},
      },
    ]);
    final value = result['value'] as Map;
    return (
      err: value['err'],
      logs: [for (final line in (value['logs'] as List?) ?? const []) '$line'],
      accounts: value['accounts'] as List?,
      unitsConsumed: value['unitsConsumed'] as int?,
    );
  }

  // Takes the swap apart and test-runs it. Returns what arrives, the network fee and any rent, or
  // fails with why it isn't safe to sign.
  Future<({BigInt received, BigInt fee, BigInt? rent})> inspect(DecodedTransaction transaction, SwapQuote checked) async {
    final SwapQuote(:from, build: quote, :input, :output, fee: zandrFee) = checked;
    final message = transaction.message;
    if (message.signers != 1 || message.readonlySigners != 0 || message.staticKeys.first != from) {
      _unsafe('It needs a signature from another account, or someone else pays for it.');
    }

    // The wallet's own token accounts a swap touches: the one sold from, the one bought into, and
    // the wrapped SOL account a SOL swap goes through. Any other of the wallet's it names is
    // checked in the test run.
    final wrapped = associatedTokenAddress(from, wrappedSol, tokenProgram);
    final source = quote.inputMint == wrappedSol ? wrapped : associatedTokenAddress(from, quote.inputMint, input.program);
    final target = quote.outputMint == wrappedSol ? wrapped : associatedTokenAddress(from, quote.outputMint, output.program);
    final allowed = {source, target, wrapped};
    var feePaid = false;
    final watched = {from, source, target}.toList();

    // Everything the checks need from the node, asked at once: the lookup tables (read from the
    // chain rather than taken from the swap service), the wallet's token accounts, and the test
    // run with the state before it. The test run is only looked at once the checks pass.
    final results = await Future.wait<Object?>([
      resolveAccountKeys(rpc, message).catchError((Object error) {
        if (error is LookupError) _unsafe("It refers to an address table that isn't one, or to addresses its tables lack.");
        throw error;
      }),
      Future.wait([
        for (final programId in [tokenProgram, token2022Program])
          rpc.call<Map<String, dynamic>>('getTokenAccountsByOwner', [
            from,
            {'programId': programId},
            {'encoding': 'base64', 'dataSlice': {'offset': 0, 'length': 0}},
          ]),
      ]),
      rpc.getAccounts(watched),
      _simulate(transaction.withSignatureAt(0, Uint8List(64)), watched),
    ]);
    final keys = results[0] as List<String>;
    final own = {
      for (final result in results[1] as List<Map<String, dynamic>>)
        for (final entry in result['value'] as List) (entry as Map)['pubkey'] as String,
    };
    final before = results[2] as List<Map<String, dynamic>?>;
    final simulation = results[3] as _Simulation;
    final others = {for (final key in keys) if (own.contains(key) && !allowed.contains(key)) key}.toList();
    if (others.length > _maxOtherAccounts) _unsafe('It names too many other token accounts of this wallet.');

    // Instruction by instruction: only what a swap needs, used only the way a swap uses it.
    var units = BigInt.from(200000);
    var price = BigInt.zero;
    for (final instruction in message.instructions) {
      if (instruction.program >= message.staticKeys.length) _unsafe('It runs a program from an address table.');
      final program = message.staticKeys[instruction.program];
      String? account(int index) => index < instruction.accounts.length && instruction.accounts[index] < keys.length ? keys[instruction.accounts[index]] : null;
      final data = instruction.data;
      final view = ByteData.sublistView(data);
      BigInt u64At(int offset) => BigInt.from(view.getUint32(offset, Endian.little)) | (BigInt.from(view.getUint32(offset + 4, Endian.little)) << 32);

      switch (program) {
        case computeBudgetProgram:
          if (data.isNotEmpty && data[0] == 2 && data.length == 5) {
            units = BigInt.from(view.getUint32(1, Endian.little));
          } else if (data.isNotEmpty && data[0] == 3 && data.length == 9) {
            price = u64At(1);
          } else if (data.isEmpty || (data[0] != 1 && data[0] != 4)) {
            _unsafe('It sets the compute budget in an unexpected way.');
          }
        case systemProgram:
          // Wrapping SOL: a transfer from the wallet into its own wrapped SOL account. And zandr's
          // fee, once, of exactly what was shown.
          if (data.length != 12 || view.getUint32(0, Endian.little) != 2 || account(0) != from) _unsafe("It moves SOL somewhere other than the wallet's own wrapped SOL account.");
          final isFee = account(1) == feeWallet && !feePaid && u64At(4) == zandrFee && zandrFee > BigInt.zero;
          if (isFee) {
            feePaid = true;
          } else if (account(1) == feeWallet) {
            _unsafe("It pays zandr's fee other than as shown.");
          } else if (account(1) != wrapped) {
            _unsafe("It moves SOL somewhere other than the wallet's own wrapped SOL account.");
          }
        case tokenProgram || token2022Program:
          // Syncing and closing the wrapped SOL account, the SOL going back to the wallet.
          if (data.isNotEmpty && data[0] == 17 && account(0) == wrapped) break;
          if (data.isNotEmpty && data[0] == 9 && account(0) == wrapped && account(1) == from && account(2) == from) break;
          _unsafe("It runs a token instruction a swap doesn't need, like handing over control of an account.");
        case associatedTokenProgram:
          // Opening the wallet's own accounts, paid by the wallet.
          if ((data.isEmpty || data[0] == 0 || data[0] == 1) && account(0) == from && account(2) == from) break;
          _unsafe('It opens a token account for someone else.');
        case jupiterProgram:
          break;
        default:
          _unsafe("It runs a program a swap doesn't need (${program.substring(0, 4)}…${program.substring(program.length - 4)}).");
      }
    }

    // The test run: what leaves the wallet and what arrives, against the latest state.
    if (simulation.err != null) _failedRun(simulation);

    // A route through a token the wallet also holds may go through the wallet's own account for
    // it: allowed only if the test run leaves each such account as it was or better.
    if (others.isNotEmpty) {
      final [was, run] = await Future.wait<Object?>([rpc.getAccounts(others), _simulate(transaction.withSignatureAt(0, Uint8List(64)), others)]);
      final previous = was as List<Map<String, dynamic>?>;
      final ran = run as _Simulation;
      if (ran.err != null) _fail(SwapReason.simulation, detail: jsonEncode(ran.err));
      for (var i = 0; i < others.length; i++) {
        final then = (parsedOf(previous[i])?['info'] as Map?) ?? const {};
        final nowAccount = (ran.accounts?[i] as Map?)?.cast<String, dynamic>();
        final now = parsedOf(nowAccount)?['info'] as Map?;
        bool same(String field) => now?[field]?.toString() == then[field]?.toString();
        if (now == null || now['owner'] != from || !same('delegate') || !same('closeAuthority') || !same('state') || _tokenAmount(nowAccount) < _tokenAmount(previous[i])) {
          _unsafe("It would take from, or hand over, another of this wallet's token accounts.");
        }
      }
    }

    final after = simulation.accounts ?? const [];
    Map<String, dynamic>? afterOf(String address) => (after.elementAtOrNull(watched.indexOf(address)) as Map?)?.cast<String, dynamic>();
    Map<String, dynamic>? beforeOf(String address) => before[watched.indexOf(address)];
    BigInt lamports(Map<String, dynamic>? account) => BigInt.from((account?['lamports'] as int?) ?? 0);
    final solChange = lamports(afterOf(from)) - lamports(beforeOf(from));

    final inAmount = BigInt.parse(quote.inAmount);
    final minOut = BigInt.parse(quote.minOutAmount);
    final fee = BigInt.from(5000) + (price * units + BigInt.from(999999)) ~/ BigInt.from(1000000);
    if (quote.inputMint == wrappedSol) {
      if (-solChange > inAmount + zandrFee + _solBudget) _unsafe('It takes more SOL than quoted.');
    } else {
      if (_tokenAmount(beforeOf(source)) - _tokenAmount(afterOf(source)) > inAmount) _unsafe('It takes more of the token than quoted.');
      if (quote.outputMint != wrappedSol && -solChange > zandrFee + _solBudget) _unsafe('It takes more SOL than a swap costs.');
    }

    BigInt received;
    if (quote.outputMint == wrappedSol) {
      received = solChange + fee + zandrFee;
      if (solChange < minOut - zandrFee - _solBudget) _unsafe('It brings in less SOL than the minimum.');
    } else {
      received = _tokenAmount(afterOf(target)) - _tokenAmount(beforeOf(target));
      if (received < minOut) _unsafe('It brings in less than the minimum.');
    }
    final opened = quote.outputMint != wrappedSol && beforeOf(target) == null && afterOf(target) != null;
    return (received: received.isNegative ? BigInt.zero : received, fee: fee, rent: opened ? lamports(afterOf(target)) : null);
  }

  // The swap from the quote the user saw, put into a transaction with the compute it needs, then
  // checked and test-run: the transaction to sign, and what it does. `from` is the wallet active now.
  Future<({DecodedTransaction transaction, SwapReview review})> assemble(SwapQuote stored, String from) => _network(() async {
        if (DateTime.now().difference(stored.at) > quoteTtl) _fail(SwapReason.expired);
        if (stored.from != from) _fail(SwapReason.walletChanged);

        // Built when quoted. A while ago, it's built again for a blockhash with time left, and taken
        // only if it still gives at least the minimum the user saw.
        var build = stored.build;
        var fee = stored.fee;
        if (DateTime.now().difference(stored.at) > _rebuildAfter) {
          build = await _build(from, build.inputMint, build.outputMint, BigInt.parse(build.inAmount));
          if (BigInt.parse(build.minOutAmount) < BigInt.parse(stored.build.minOutAmount)) _fail(SwapReason.expired);
          fee = _feeOf(from, build, stored.input);
        }
        final checked = SwapQuote(id: stored.id, at: stored.at, from: from, build: build, input: stored.input, output: stored.output, fee: fee);

        // The lookup tables, read from the chain (what Jupiter says is in them isn't used).
        final Map<String, List<String>> tables;
        try {
          tables = await readLookupTables(rpc, [for (final table in build.lookupTables) (table: table, length: 0)]);
        } on LookupError {
          _unsafe("It refers to an address table that isn't one.");
        }
        final body = [
          for (final instruction in build.instructions)
            Instruction(instruction.program, [for (final a in instruction.accounts) AccountMeta(a.address, signer: a.signer, writable: a.writable)], base64.decode(instruction.data)),
          if (fee > BigInt.zero) transferSol(from, feeWallet, fee),
        ];
        Uint8List compile(int units, BigInt price) {
          final message = compileV0Message(from, [setComputeUnitLimit(units), setComputeUnitPrice(price), ...body], build.blockhash, tables);
          final wire = serializeTransaction(message, [Uint8List(64)]);
          if (wire.length > _maxTransaction) _fail(SwapReason.noRoute);
          return wire;
        }

        // How much compute it needs: a test run with the most a transaction may have. It asks for
        // that and a fifth more, at Jupiter's priority fee capped at 0.001 SOL in all.
        final probe = await _simulate(compile(_maxUnits, BigInt.zero));
        if (probe.err != null) _failedRun(probe);
        final units = min(((probe.unitsConsumed ?? _maxUnits) * 1.2).ceil(), _maxUnits);
        final cap = _maxPriorityFee * BigInt.from(1000000) ~/ BigInt.from(units);
        final price = build.computeUnitPrice < cap ? build.computeUnitPrice : cap;

        // The transaction as it will be signed: taken apart, checked and test-run.
        final transaction = decodeTransaction(compile(units, price));
        final (:received, fee: networkFee, :rent) = await inspect(transaction, checked);
        return (
          transaction: transaction,
          review: SwapReview(
            quote: checked,
            outAmount: formatUnits(received, stored.output.decimals),
            fee: formatUnits(networkFee, 9),
            rent: rent == null ? null : formatUnits(rent, 9),
          ),
        );
      });

  // The swap for the quote on screen, assembled and checked ahead, while the person looks at the
  // price: confirming then only signs and sends. One at a time; a new quote replaces it.
  ({String id, String from, Future<({DecodedTransaction transaction, SwapReview review})> assembled})? _prepared;

  void prepare(SwapQuote quote, String from) {
    final assembled = assemble(quote, from);
    // Its failure, if any, is met when confirming (by assembling again), not as an uncaught error.
    assembled.then((_) {}, onError: (_) {});
    _prepared = (id: quote.id, from: from, assembled: assembled);
  }

  // The swap in one go: assembled and checked (ahead, if `prepare` did it for this very quote while
  // its build is still fresh), then, only if all of that holds, exactly those bytes signed (`sign`,
  // with the active wallet's key) and sent.
  Future<({String signature, SwapReview review, Pending pending})> execute(SwapQuote stored, String from, Future<Uint8List> Function(Uint8List message) sign) async {
    final prepared = _prepared;
    _prepared = null;
    final ahead = prepared != null && prepared.id == stored.id && prepared.from == from && DateTime.now().difference(stored.at) <= _rebuildAfter ? prepared.assembled : null;
    ({DecodedTransaction transaction, SwapReview review}) ready;
    try {
      ready = await (ahead ?? assemble(stored, from));
    } catch (_) {
      if (ahead == null) rethrow;
      // What failed ahead may hold now (a balance that arrived meanwhile): assembled again.
      ready = await assemble(stored, from);
    }
    final (:transaction, :review) = ready;
    final signature = await sign(transaction.messageBytes);
    final wire = base64.encode(transaction.withSignatureAt(0, signature));
    await _network(() => rpc.call<String>('sendTransaction', [
          wire,
          {'encoding': 'base64', 'preflightCommitment': 'confirmed', 'maxRetries': 0},
        ]));
    return (signature: base58Encode(signature), review: review, pending: Pending(wire, review.quote.build.lastValidBlockHeight));
  }
}
