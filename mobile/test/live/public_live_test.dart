// Against mainnet through public services only: Helius's node (its socket too), Jupiter's public
// API, and logos through wsrv.nl. Nothing signed.
// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zandr/core/activity.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/live.dart';
import 'package:zandr/core/models.dart';
import 'package:zandr/core/portfolio.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/solana/rpc.dart';
import 'package:zandr/core/swap.dart';

const wallet = '43DbAvKxhXh1oSxkJSqGosNw3HpBnmsWiak6tB5wpecN';

void main() {
  final rpc = Rpc(publicRpcMainnet);
  final jupiter = Jupiter.publicApi();

  test('balances, names, prices and logos', () async {
    // A few tries: a VPN in the way can drop new connections to Cloudflare-hosted services.
    Portfolio? portfolio;
    for (var attempt = 1; portfolio == null; attempt++) {
      try {
        portfolio = await getPortfolio(rpc, jupiter, Network.mainnet, wallet);
      } catch (error) {
        print('try $attempt: $error');
        if (attempt == 5) rethrow;
      }
    }
    final logos = [for (final coin in portfolio.coins.take(5)) if (coin.logo != null) coin.logo!];
    print('${portfolio.coins.length} coins, \$${portfolio.value.toStringAsFixed(0)}; ${portfolio.coins.take(5).map((coin) => coin.symbol).join(', ')}');
    expect(portfolio.coins.first.price, greaterThan(0));
    expect(logos, isNotEmpty);
    for (final logo in logos) {
      http.Response? response;
      for (var attempt = 1; response == null; attempt++) {
        try {
          response = await http.get(Uri.parse(logo));
        } on http.ClientException {
          if (attempt == 5) rethrow;
        }
      }
      expect(response.headers['content-type'], 'image/png', reason: logo);
    }
    // The wallet holds well over a thousand tokens, and Jupiter's public API takes a few requests at a time.
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('history', () async {
    final page = await getActivity(rpc, jupiter, Network.mainnet, wallet, limit: 10);
    print('${page.items.length} transactions');
    expect(page.items, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a swap quoted, built and test-run', () async {
    final swapper = Swapper(rpc, jupiter, () => null);
    final quote = await swapper.quote(wallet, wrappedSol, usdcMint, '0.05');
    final (:transaction, :review) = await swapper.assemble(quote, wallet);
    print('${quote.inAmount} SOL → ${review.outAmount} USDC (min ${quote.minOutAmount}), route ${quote.build.route}');
    expect(double.parse(review.outAmount), greaterThanOrEqualTo(double.parse(quote.minOutAmount)));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("changes of a busy wallet arrive over Helius's socket", () async {
    final changed = Completer<void>();
    final watch = LiveWatch('5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9', () => publicRpcMainnet, (slot) {
      if (slot != null && !changed.isCompleted) changed.complete();
    });
    await changed.future.timeout(const Duration(seconds: 60));
    watch.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
