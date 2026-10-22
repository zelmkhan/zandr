// Against mainnet: a wallet's closable token accounts found, priced and test-run, nothing signed
// (signing throws, which is reached only once every test run passed).
// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/reclaim.dart';
import 'package:zandr/core/solana/rpc.dart';

const wallet = '86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY';

class _Stop implements Exception {}

void main() {
  test('finds, prices and test-runs closing', () async {
    final reclaimer = Reclaimer(Rpc(defaultRpc[Network.mainnet]!), Jupiter(), Network.mainnet);
    final plan = await reclaimer.plan(wallet);
    print('${plan.empty.length} empty, ${plan.junk.length} junk, prices known: ${plan.pricesKnown}; '
        'junk e.g. ${plan.junk.take(3).map((a) => '${a.symbol} ${a.balance} \$${a.value?.toStringAsFixed(4)}').toList()}');
    expect(plan.pricesKnown, isTrue);
    final close = plan.empty.take(3).map((a) => a.address).toList();
    final burn = plan.junk.take(2).map((a) => a.address).toList();
    if (close.isEmpty && burn.isEmpty) return;
    var signed = 0;
    await expectLater(
      reclaimer.execute(wallet, close, burn, true, (messages) async {
        signed = messages.length;
        throw _Stop();
      }),
      throwsA(isA<_Stop>()),
    );
    print('test runs passed; $signed transaction(s) would be signed');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
