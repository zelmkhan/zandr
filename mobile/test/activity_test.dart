// Real mainnet transactions, each read by the extension (src/server/activity.ts) and here: the
// readings must match.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/activity.dart';

void main() {
  final cases = jsonDecode(utf8.decode(gzip.decode(File('test/fixtures/activity.json.gz').readAsBytesSync()))) as List;

  test('reads transactions as the extension does', () {
    expect(cases.length, greaterThan(10));
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final reading = readTransaction((c['transaction'] as Map).cast(), c['address'] as String);
      final expected = c['reading'] as Map?;
      final got = reading == null
          ? null
          : {
              'kind': reading.kind.name,
              'moves': [for (final m in reading.moves) {'mint': m.mint, 'delta': '${m.delta}', 'decimals': m.decimals}],
              'fee': reading.fee,
              'counterparty': reading.counterparty,
              'program': reading.program,
            };
      expect(got, expected, reason: c['signature'] as String);
    }
  });
}
