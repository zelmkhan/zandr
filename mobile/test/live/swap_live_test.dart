// Against mainnet: swaps quoted by Jupiter, built, checked and test-run as they'd be signed, with
// zandr's fee; nothing signed. The wallet is a well-funded public one. A swap with the fee changed
// must be refused.
// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/portfolio.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/solana/rpc.dart';
import 'package:zandr/core/swap.dart';

const from = '43DbAvKxhXh1oSxkJSqGosNw3HpBnmsWiak6tB5wpecN';
const jup = 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN';

void main() {
  final rpc = Rpc(defaultRpc[Network.mainnet]!);
  final jupiter = Jupiter();
  final swapper = Swapper(rpc, jupiter, () => null);

  for (final (input, output, amount) in [(wrappedSol, usdcMint, '0.05'), (usdcMint, wrappedSol, '5'), (wrappedSol, jup, '0.02')]) {
    test('$input → $output', () async {
      final quote = await swapper.quote(from, input, output, amount);
      final (:transaction, :review) = await swapper.assemble(quote, from);
      print('${quote.inAmount} → ${review.outAmount} (min ${quote.minOutAmount}), zandr fee ${quote.feeText}, network fee ${review.fee}, '
          '${transaction.messageBytes.length} bytes, route ${quote.build.route}');
      expect(double.parse(review.outAmount), greaterThanOrEqualTo(double.parse(quote.minOutAmount)));
      expect(quote.fee, greaterThan(BigInt.zero));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test("a token-to-token swap's fee, from the wallet's prices", () async {
    final portfolio = await getPortfolio(rpc, jupiter, Network.mainnet, from);
    final priced = Swapper(rpc, jupiter, () => portfolio);
    final quote = await priced.quote(from, usdcMint, jup, '5');
    print('5 USDC → ${quote.outAmount} JUP, zandr fee ${quote.feeText} SOL');
    expect(quote.fee, greaterThan(BigInt.zero));
    await priced.assemble(quote, from);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a fee other than the one shown is refused', () async {
    final quote = await swapper.quote(from, wrappedSol, usdcMint, '0.05');
    final (:transaction, review: _) = await swapper.assemble(quote, from);
    final shown = SwapQuote(id: quote.id, at: quote.at, from: from, build: quote.build, input: quote.input, output: quote.output, fee: quote.fee - BigInt.one);
    await expectLater(swapper.inspect(transaction, shown), throwsA(isA<SwapFailure>().having((f) => f.reason, 'reason', SwapReason.unsafe)));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('another wallet is refused', () async {
    final quote = await swapper.quote(from, wrappedSol, usdcMint, '0.05');
    await expectLater(swapper.assemble(quote, usdcMint), throwsA(isA<SwapFailure>().having((f) => f.reason, 'reason', SwapReason.walletChanged)));
  });
}
