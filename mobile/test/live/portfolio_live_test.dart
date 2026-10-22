// Against mainnet, through zandr's server: a real wallet's coins, names and prices.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/portfolio.dart';
import 'package:zandr/core/solana/rpc.dart';

void main() {
  test('a wallet with SOL and tokens', () async {
    final portfolio = await getPortfolio(Rpc(defaultRpc[Network.mainnet]!), Jupiter(), Network.mainnet, '43DbAvKxhXh1oSxkJSqGosNw3HpBnmsWiak6tB5wpecN');
    final sol = portfolio.coins.first;
    // ignore: avoid_print
    print('SOL ${sol.balance} (\$${sol.value?.toStringAsFixed(2)}), ${portfolio.coins.length - 1} tokens, total \$${portfolio.value.toStringAsFixed(2)}; top: ${portfolio.coins.skip(1).take(3).map((c) => '${c.symbol} ${c.balance}').join(', ')}');
    expect(sol.native, isTrue);
    expect(sol.price, isNotNull);
    expect(portfolio.coins.length, greaterThan(1));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
