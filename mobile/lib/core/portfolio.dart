// An address's coins and their value: balances from the node, names and prices from Jupiter
// (src/server/portfolio.ts). Balances are read at the processed commitment, as soon as a node has
// run the block, and from a node that has reached `minContextSlot` when a change came in it.
import 'config.dart';
import 'jupiter.dart';
import 'models.dart';
import 'solana/addresses.dart';
import 'solana/rpc.dart';
import 'units.dart';

const _tokenPrograms = {'token': tokenProgram, 'token-2022': token2022Program};

Map<String, Object> _readConfig(int? minContextSlot) => {'commitment': 'processed', 'minContextSlot': ?minContextSlot};

Future<BigInt> getBalance(Rpc rpc, String address, {int? minContextSlot}) async {
  final result = await rpc.call<Map<String, dynamic>>('getBalance', [address, _readConfig(minContextSlot)]);
  final lamports = result['value'];
  if (lamports is! int || lamports < 0) throw const ServiceError(ServiceFailure.badResponse, 'rpc');
  return BigInt.from(lamports);
}

typedef _TokenAccount = ({String mint, String amount, int decimals, String balance});

Future<List<_TokenAccount>> _tokenAccounts(Rpc rpc, String address, String program, int? minContextSlot) async {
  final result = await rpc.call<Map<String, dynamic>>('getTokenAccountsByOwner', [
    address,
    {'programId': _tokenPrograms[program]},
    {'encoding': 'jsonParsed', ..._readConfig(minContextSlot)},
  ]);
  final accounts = <_TokenAccount>[];
  for (final entry in result['value'] as List? ?? const []) {
    final info = ((((entry as Map?)?['account'] as Map?)?['data'] as Map?)?['parsed'] as Map?)?['info'] as Map?;
    final tokenAmount = info?['tokenAmount'] as Map?;
    if (info?['mint'] is! String || tokenAmount == null) continue;
    final amount = tokenAmount['amount'], decimals = tokenAmount['decimals'], ui = tokenAmount['uiAmountString'];
    if (amount is! String || !RegExp(r'^\d+$').hasMatch(amount) || decimals is! int) continue;
    final balance = ui is String && RegExp(r'^\d+(\.\d+)?$').hasMatch(ui) ? ui : formatUnits(BigInt.parse(amount), decimals);
    accounts.add((mint: info!['mint'] as String, amount: amount, decimals: decimals, balance: balance));
  }
  return accounts;
}

// `known`: the mints held last time. Their names and prices are asked for alongside the balances,
// so when nothing new arrived a refresh is one round of requests rather than three in a row.
Future<Portfolio> getPortfolio(Rpc rpc, Jupiter jupiter, Network network, String address, {int? minContextSlot, Iterable<String> known = const []}) async {
  final mainnet = network == Network.mainnet;
  final early = mainnet && known.isNotEmpty
      ? Future.wait([jupiter.tokenInfo(known.toList()), jupiter.prices([wrappedSol, ...known])]).then<void>((_) {}, onError: (_) {})
      : Future<void>.value();
  final results = await Future.wait([
    getBalance(rpc, address, minContextSlot: minContextSlot),
    _tokenAccounts(rpc, address, 'token', minContextSlot),
    _tokenAccounts(rpc, address, 'token-2022', minContextSlot),
  ]);
  final lamports = results[0] as BigInt;

  // One holding per mint: several accounts of a token add up. Emptied accounts are left out, and
  // so are collectibles (NFTs), which have no decimals.
  final holdings = <String, ({String program, BigInt amount, int decimals, String balance})>{};
  for (final (program, accounts) in [('token', results[1] as List<_TokenAccount>), ('token-2022', results[2] as List<_TokenAccount>)]) {
    for (final account in accounts) {
      if (account.amount == '0' || account.decimals == 0) continue;
      final held = holdings[account.mint];
      holdings[account.mint] = held == null
          ? (program: program, amount: BigInt.parse(account.amount), decimals: account.decimals, balance: account.balance)
          : (program: held.program, amount: held.amount + BigInt.parse(account.amount), decimals: held.decimals, balance: addDecimals(held.balance, account.balance));
    }
  }

  // Names and prices exist for mainnet only, asked for together (Jupiter has the ones asked for
  // early already); a price counts only for a token that trades at all.
  await early;
  final [infosFound, pricesFound] = mainnet
      ? await Future.wait<Map<String, Object?>>([jupiter.tokenInfo(holdings.keys.toList()), jupiter.prices([wrappedSol, ...holdings.keys])])
      : const [<String, Object?>{}, <String, Object?>{}];
  final infos = infosFound.cast<String, TokenInfo?>();
  final prices = {
    for (final MapEntry(:key, :value) in pricesFound.cast<String, Price?>().entries)
      if (key == wrappedSol || (infos[key]?.traded ?? false)) key: value,
  };

  ({double? price, double? value, double? change24h}) priced(String mint, String balance) {
    final quote = prices[mint];
    return (price: quote?.price, value: quote == null ? null : double.parse(balance) * quote.price, change24h: quote?.change24h);
  }

  final solBalance = formatUnits(lamports, 9);
  final solPrice = priced(wrappedSol, solBalance);
  final sol = Coin(
    mint: wrappedSol, native: true, program: 'system', amount: '$lamports', decimals: 9, balance: solBalance,
    name: 'Solana', symbol: 'SOL', logo: jupiter.logo(wrappedSol), verified: true,
    price: solPrice.price, value: solPrice.value, change24h: solPrice.change24h,
  );

  final tokens = <Coin>[];
  for (final MapEntry(key: mint, value: holding) in holdings.entries) {
    // Wrapped SOL that some swaps leave behind gets its own name, so it isn't taken for SOL itself.
    final info = mint == wrappedSol ? TokenInfo(name: 'Wrapped SOL', symbol: 'wSOL', logo: jupiter.logo(wrappedSol), verified: true, traded: true) : infos[mint];
    final p = priced(mint, holding.balance);
    tokens.add(Coin(
      mint: mint, native: false, program: holding.program, amount: '${holding.amount}', decimals: holding.decimals, balance: holding.balance,
      name: info?.name, symbol: info?.symbol, logo: info?.logo, verified: info?.verified ?? false,
      price: p.price, value: p.value, change24h: p.change24h,
    ));
  }
  // Highest value first; tokens without a price after, by name, unknown ones last.
  tokens.sort((a, b) {
    final byValue = (b.value ?? -1).compareTo(a.value ?? -1);
    return byValue != 0 ? byValue : (a.name ?? '\u{ffff}').compareTo(b.name ?? '\u{ffff}');
  });
  final coins = [sol, ...tokens];
  return Portfolio(network: network, address: address, coins: coins, value: coins.fold(0.0, (sum, coin) => sum + (coin.value ?? 0)), updatedAt: DateTime.now());
}
