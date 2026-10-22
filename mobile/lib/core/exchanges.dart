// What an address is to an exchange, and what the exchange takes there (src/server/exchanges.ts,
// exchangeTokens.ts). An exchange's own wallets are listed (exchangeWallets.json); a deposit address
// is one that passes on what it receives to one of them, which shows in its own history. Which
// tokens each exchange accepts comes from its lists: the snapshot that ships with zandr, or a
// fresher one from zandr's server. Tokens are matched by mint, never by name.
import 'activity.dart';
import 'solana/rpc.dart';

final _mint = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');
final _decimal = RegExp(r'^\d{1,20}(\.\d{1,20})?$');

// Address → the exchange's name, from exchangeWallets.json.
Map<String, String> hotWalletsFrom(Map<String, dynamic> json) => {
      for (final exchange in (json['exchanges'] as List).cast<Map>())
        for (final wallet in (exchange['wallets'] as List).cast<Map>()) wallet['address'] as String: exchange['name'] as String,
    };

// One token an exchange takes on Solana: its mint (null for SOL), the exchange's name for it, the
// least it credits in whole tokens, and whether deposits were open when the list was fetched.
class ExchangeToken {
  final String? mint;
  final String coin;
  final String? depositMin;
  final bool deposit;
  const ExchangeToken({this.mint, required this.coin, this.depositMin, required this.deposit});

  Map<String, Object?> toJson() => {'mint': mint, 'coin': coin, 'depositMin': depositMin, 'deposit': deposit};
}

class ExchangeTokenList {
  final String exchange;
  final DateTime fetchedAt;
  final String source;
  // mint: the exchange names mints; symbol: zandr matched its symbols to mints; coingecko: the
  // tokens it trades, which tells one it doesn't trade at all but not one it takes elsewhere only.
  final String matchedBy;
  // Whether a token missing from the list means the exchange doesn't take it.
  final bool complete;
  final List<String>? unmatched;
  final List<ExchangeToken> tokens;
  const ExchangeTokenList({required this.exchange, required this.fetchedAt, required this.source, required this.matchedBy, required this.complete, this.unmatched, required this.tokens});

  Map<String, Object?> toJson() => {
        'exchange': exchange, 'fetchedAt': fetchedAt.toUtc().toIso8601String(), 'source': source, 'matchedBy': matchedBy,
        'complete': complete, 'unmatched': ?unmatched, 'tokens': [for (final token in tokens) token.toJson()],
      };
}

// Lists as they came over the network, checked field by field, or null if anything is off.
List<ExchangeTokenList>? validLists(Object? value) {
  if (value is! Map || value['updated'] is! String || value['lists'] is! List) return null;
  final lists = value['lists'] as List;
  if (lists.length > 100) return null;
  final checked = <ExchangeTokenList>[];
  for (final list in lists) {
    if (list is! Map) return null;
    final exchange = list['exchange'], fetchedAt = list['fetchedAt'], source = list['source'];
    final matchedBy = list['matchedBy'], complete = list['complete'], unmatched = list['unmatched'], tokens = list['tokens'];
    if (exchange is! String || exchange.isEmpty || exchange.length > 40) return null;
    final fetched = fetchedAt is String ? DateTime.tryParse(fetchedAt) : null;
    if (fetched == null || source is! String) return null;
    if (!const {'mint', 'symbol', 'coingecko'}.contains(matchedBy) || complete is! bool) return null;
    if (unmatched != null && (unmatched is! List || unmatched.any((symbol) => symbol is! String))) return null;
    if (tokens is! List || tokens.length > 5000) return null;
    final entries = <ExchangeToken>[];
    for (final token in tokens) {
      if (token is! Map) return null;
      final mint = token['mint'], coin = token['coin'], depositMin = token['depositMin'], deposit = token['deposit'];
      if (mint != null && (mint is! String || !_mint.hasMatch(mint))) return null;
      if (coin is! String || coin.length > 40 || deposit is! bool) return null;
      if (depositMin != null && (depositMin is! String || !_decimal.hasMatch(depositMin))) return null;
      entries.add(ExchangeToken(mint: mint as String?, coin: coin, depositMin: depositMin as String?, deposit: deposit));
    }
    // A list with nothing on it says nothing.
    if (entries.isEmpty) continue;
    checked.add(ExchangeTokenList(
      exchange: exchange, fetchedAt: fetched, source: source, matchedBy: matchedBy as String, complete: complete,
      unmatched: unmatched == null ? null : (unmatched as List).cast<String>().take(100).toList(), tokens: entries,
    ));
  }
  return checked;
}

// Per exchange, the newer of the shipped list and a fetched one. A fetched list much shorter than
// the one it would replace is taken for a broken fetch and passed over.
List<ExchangeTokenList> newestLists(List<ExchangeTokenList> shipped, List<ExchangeTokenList> fetched) {
  final byExchange = {for (final list in shipped) list.exchange: list};
  for (final list in fetched) {
    final current = byExchange[list.exchange];
    if (current == null || (list.fetchedAt.isAfter(current.fetchedAt) && list.tokens.length >= current.tokens.length * 0.7)) byExchange[list.exchange] = list;
  }
  return byExchange.values.toList();
}

// What a list says about sending a token to one of the exchange's addresses.
// How far the exchange check covers an exchange (src/lib/exchanges.ts). Full: its deposit
// addresses recognized and every token checked against its own list. Traded: no list of its own,
// so checked against the tokens it trades (CoinGecko), which stops a token it doesn't trade at all.
// Partial: a list that can't tell every unsupported token (matched by symbol, some left unmatched)
// or is too old. Addresses: its wallets are known but there's no token list, so only its own
// wallets are stopped.
enum CoverageStatus { full, traded, partial, addresses }

class ExchangeCoverage {
  final String name;
  final CoverageStatus status;
  final int tokens;
  final DateTime? updated;
  const ExchangeCoverage(this.name, this.status, this.tokens, this.updated);
}

// The biggest first, then the rest by name.
const _coverageOrder = ['Binance', 'Coinbase', 'OKX', 'Bybit', 'Kraken', 'Bitget', 'KuCoin', 'Gate', 'MEXC', 'HTX'];

// Every exchange the check knows, from its wallets and its token lists, the best covered first.
List<ExchangeCoverage> exchangeCoverage(Iterable<String> walletExchanges, List<ExchangeTokenList> lists, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final coverage = [
    for (final name in {...walletExchanges, for (final list in lists) list.exchange})
      () {
        final list = lists.where((l) => l.exchange == name).firstOrNull;
        final fresh = list != null && at.difference(list.fetchedAt) <= _trustedFor;
        final status = list == null
            ? CoverageStatus.addresses
            : !list.complete || !fresh
            ? CoverageStatus.partial
            : list.matchedBy == 'coingecko'
            ? CoverageStatus.traded
            : CoverageStatus.full;
        return ExchangeCoverage(name, status, list?.tokens.length ?? 0, list?.fetchedAt);
      }(),
  ];
  int rank(String name) => _coverageOrder.contains(name) ? _coverageOrder.indexOf(name) : _coverageOrder.length;
  return coverage
    ..sort((a, b) {
      final byStatus = a.status.index - b.status.index;
      if (byStatus != 0) return byStatus;
      final byRank = rank(a.name) - rank(b.name);
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });
}

class ExchangeVerdict {
  // False when the list is complete and the token isn't on it.
  final bool accepted;
  final String? coin, depositMin;
  // Deposits of it were paused when a recent list was fetched.
  final bool paused;
  // deposits: the tokens it takes on Solana; trading: (from CoinGecko) the ones it trades.
  final String basis;
  const ExchangeVerdict({required this.accepted, this.coin, this.depositMin, required this.paused, required this.basis});
}

const _day = Duration(days: 1);
// A list this old may miss tokens the exchange has added since.
const _trustedFor = Duration(days: 60);
// A pause is told only from a list this recent: deposits reopen.
const _pauseFresh = Duration(days: 2);
// CoinGecko often files an exchange's markets in these under the fiat they track.
const _stablecoins = {'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB'};

// Null when there's no list for the exchange, or it's too old to go by.
ExchangeVerdict? exchangeVerdict(List<ExchangeTokenList> lists, String exchange, String? mint, {DateTime? now}) {
  final list = lists.where((entry) => entry.exchange == exchange).firstOrNull;
  if (list == null) return null;
  final age = (now ?? DateTime.now()).difference(list.fetchedAt);
  if (age < -_day || age > _trustedFor) return null;
  final token = list.tokens.where((entry) => entry.mint == mint).firstOrNull;
  final basis = list.matchedBy == 'coingecko' ? 'trading' : 'deposits';
  if (token == null && basis == 'trading' && mint != null && _stablecoins.contains(mint)) return null;
  if (token == null) return list.complete ? ExchangeVerdict(accepted: false, paused: false, basis: basis) : null;
  return ExchangeVerdict(accepted: true, coin: token.coin, depositMin: token.depositMin, paused: !token.deposit && age <= _pauseFresh, basis: basis);
}

enum ExchangeKind { hotWallet, deposit }

class AddressInfo {
  final String address;
  final String? exchange;
  final ExchangeKind? kind;
  final int sweeps, looked;
  const AddressInfo({required this.address, this.exchange, this.kind, this.sweeps = 0, this.looked = 0});
}

// What sending a token to an address means at an exchange.
class TransferCheck {
  final String? exchange;
  final ExchangeKind? kind;
  final ExchangeVerdict? listed;
  const TransferCheck({this.exchange, this.kind, this.listed});
}

// Transactions looked at: enough to see sweeps, few enough to answer in a second or two.
const _lookAt = 12;
// A deposit address stays one; an address with no sweeps yet may make one soon.
const _knownFor = Duration(hours: 12);
const _unknownFor = Duration(minutes: 30);
const _cacheLimit = 5000;

class Exchanges {
  final Rpc rpc;
  final Map<String, String> hotWallets;
  // The lists to go by now: the shipped ones and any fresher.
  final Future<List<ExchangeTokenList>> Function() lists;
  final _known = <String, ({AddressInfo info, DateTime until})>{};

  Exchanges(this.rpc, this.hotWallets, this.lists);

  // A busy node gets three more tries: public nodes allow only a few transactions read a second.
  Future<T> _patiently<T>(Future<T> Function() attempt) async {
    for (final wait in const [1500, 4000, 8000]) {
      try {
        return await attempt();
      } on ChainError catch (error) {
        if (error.reason != RpcFailure.rateLimited) rethrow;
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
    return attempt();
  }

  // Mainnet addresses only: exchanges aren't on devnet.
  Future<AddressInfo> addressInfo(String address) async {
    final hot = hotWallets[address];
    if (hot != null) return AddressInfo(address: address, exchange: hot, kind: ExchangeKind.hotWallet);
    final cached = _known[address];
    if (cached != null && cached.until.isAfter(DateTime.now())) return cached.info;

    // Its latest transactions, read for what it sent where: sweeps are the ones it sent to a hot wallet.
    final listed = await _patiently(() => rpc.call<List<dynamic>>('getSignaturesForAddress', [
          address,
          {'limit': _lookAt, 'commitment': 'confirmed'},
        ]));
    final signatures = [for (final entry in listed) if (entry is Map && entry['signature'] is String) entry['signature'] as String];
    var unread = 0;
    final readings = <Reading?>[];
    for (var i = 0; i < signatures.length; i += 2) {
      readings.addAll(await Future.wait(signatures.skip(i).take(2).map((signature) async {
        // One transaction the node won't return doesn't sink the rest.
        try {
          final transaction = await _patiently(() => rpc.call<Map<String, dynamic>?>('getTransaction', [
                signature,
                {'encoding': 'jsonParsed', 'commitment': 'confirmed', 'maxSupportedTransactionVersion': 1},
              ]));
          return transaction == null ? null : readTransaction(transaction, address);
        } on ChainError {
          unread++;
          return null;
        }
      })));
    }
    // Most of them unread: no answer, rather than one remembered as "not an exchange's".
    if (unread * 2 > signatures.length) throw const ChainError(RpcFailure.unreachable);

    final sweeps = <String, int>{};
    var elsewhere = 0;
    for (final reading in readings) {
      if (reading?.kind != ActivityKind.send || reading!.counterparty == null) continue;
      final exchange = hotWallets[reading.counterparty];
      if (exchange != null) {
        sweeps[exchange] = (sweeps[exchange] ?? 0) + 1;
      } else {
        elsewhere++;
      }
    }
    // One exchange's, and mostly sweeps: a deposit address passes on what it gets, to its exchange
    // only. Sweeps to several exchanges, or sends mostly elsewhere, say nothing for sure.
    final top = (sweeps.entries.toList()..sort((a, b) => b.value - a.value)).firstOrNull;
    final deposit = top != null && sweeps.length == 1 && top.value >= elsewhere;
    final info = AddressInfo(
      address: address,
      exchange: deposit ? top.key : null,
      kind: deposit ? ExchangeKind.deposit : null,
      sweeps: top?.value ?? 0,
      looked: signatures.length,
    );
    _known.remove(address);
    _known[address] = (info: info, until: DateTime.now().add(info.exchange != null ? _knownFor : _unknownFor));
    if (_known.length > _cacheLimit) _known.remove(_known.keys.first);
    return info;
  }

  // Before a transfer of `mint` (null: SOL) to `to`. Mainnet only.
  Future<TransferCheck> transferCheck(String to, String? mint) async {
    final info = await addressInfo(to);
    if (info.exchange == null) return TransferCheck(kind: info.kind);
    return TransferCheck(exchange: info.exchange, kind: info.kind, listed: exchangeVerdict(await lists(), info.exchange!, mint));
  }
}
