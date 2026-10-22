// The outcome screen can be left at any stage from its back button: to the wallet while it's on
// its way or done, back to the form when nothing went. What's sent keeps being followed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/wallet.dart';
import 'package:zandr/core/sent.dart';
import 'package:zandr/ui/app.dart';
import 'package:zandr/ui/outcome.dart';
import 'package:zandr/ui/theme.dart';

class _State extends AppState {
  final followed = <String>[];
  _State() : super(MemoryStore(), MemoryPreferences(), live: false);
  @override
  Future<Settled?> follow(String signature, Pending pending, {Future<void>? cancel}) {
    followed.add(signature);
    return Completer<Settled?>().future;
  }
}

typedef _Run = Future<({List<SentTransaction> sent, String? summary})> Function();

// Home, then a form, then the outcome over it.
Future<_State> _open(WidgetTester tester, _Run run) async {
  final state = _State();
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(
      theme: themeFor(Palette.dark),
      home: Builder(
        builder: (home) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(home).push(MaterialPageRoute<void>(
              builder: (form) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(form).push(MaterialPageRoute<void>(
                    builder: (_) => OutcomeScreen(doneTitle: 'Sent', run: run, describe: (_) => 'The network refused it.'),
                  )),
                  child: const Text('Form'),
                ),
              ),
            )),
            child: const Text('Home'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Home'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Form'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return state;
}

void main() {
  testWidgets('left while sending: back to the wallet, and still followed once sent', (tester) async {
    final sending = Completer<({List<SentTransaction> sent, String? summary})>();
    final state = await _open(tester, () => sending.future);
    expect(find.text('Sending…'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Form'), findsNothing);
    sending.complete((sent: [(signature: 'sig', pending: const Pending('', 0))], summary: null));
    await tester.pump();
    expect(state.followed, ['sig']);
  });

  testWidgets('not sent: back to the form', (tester) async {
    await _open(tester, () async => throw Exception('refused'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Not sent'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Form'), findsOneWidget);
  });
}
