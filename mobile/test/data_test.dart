// The exchange data ships in both the extension and the app: they must not drift apart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/exchanges.dart';

void main() {
  for (final name in ['exchangeWallets.json', 'exchangeTokens.json']) {
    test('$name matches the extension', () {
      expect(File('assets/data/$name').readAsStringSync(), File('../src/server/$name').readAsStringSync(), reason: 'run tool/sync_data.sh');
    });
  }

  test('the About page tells the version pubspec.yaml builds', () {
    final version = RegExp(r'^version: ([\d.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(appVersion, version);
  });

  test('exchanges: the best covered first, the biggest first within each', () {
    final now = DateTime.utc(2026, 10, 1);
    ExchangeTokenList list(String exchange, {String matchedBy = 'mint', bool complete = true, int daysOld = 1}) => ExchangeTokenList(
          exchange: exchange, fetchedAt: now.subtract(Duration(days: daysOld)), source: 'test', matchedBy: matchedBy, complete: complete,
          tokens: const [ExchangeToken(coin: 'SOL', deposit: true)],
        );
    final coverage = exchangeCoverage(
      ['Rollbit', 'Binance', 'Zeta'],
      [list('Rollbit'), list('Binance'), list('OKX', matchedBy: 'coingecko'), list('Kraken', complete: false), list('Gate', daysOld: 90)],
      now: now,
    );
    expect([for (final c in coverage) '${c.name}:${c.status.name}'], ['Binance:full', 'Rollbit:full', 'OKX:traded', 'Kraken:partial', 'Gate:partial', 'Zeta:addresses']);
  });
}
