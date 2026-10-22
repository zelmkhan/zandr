// Against mainnet: the socket subscribes, and a busy wallet's changes come in as they happen.
// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/live.dart';

void main() {
  test('changes of a busy wallet arrive over the socket', () async {
    final slots = <int?>[];
    final changed = Completer<void>();
    final watch = LiveWatch('5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9', () => defaultRpc[Network.mainnet]!, (slot) {
      slots.add(slot);
      if (slot != null && !changed.isCompleted) changed.complete();
    });
    await changed.future.timeout(const Duration(seconds: 60));
    watch.stop();
    print('refreshes: $slots');
    expect(slots.first, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
