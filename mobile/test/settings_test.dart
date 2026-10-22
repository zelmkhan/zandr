// Settings: a transfer protection turns off only once Face ID or the passcode confirms it, and
// back on without asking.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/vault.dart';
import 'package:zandr/app/wallet.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/secrets.dart';
import 'package:zandr/core/send.dart' show Protection;
import 'package:zandr/ui/app.dart';
import 'package:zandr/ui/settings.dart';
import 'package:zandr/ui/theme.dart';

void main() {
  testWidgets('turning a protection off asks for Face ID or the passcode', (tester) async {
    final store = MemoryStore();
    final preferences = MemoryPreferences();
    await tester.runAsync(() => Vault(store, preferences).create(const VaultContents(
          [Keyring('k1', PhraseSecret(['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow']))],
          [WalletEntry(id: 'w1', name: 'Main wallet', address: 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX', keyring: 'k1')],
        )));
    final state = AppState(store, preferences, live: false);
    await tester.runAsync(state.start);
    await tester.runAsync(state.vault.unlock);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: themeFor(Palette.dark), home: const SettingsScreen())));
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Program addresses'));
    await tester.pumpAndSettle();
    bool on() => state.preferences.protections.contains(Protection.programAddresses);

    // The prompt dismissed: still on.
    store.keyFails = KeyOutcome.cancelled;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(on(), isTrue);

    // Confirmed: off.
    store.keyFails = null;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(on(), isFalse);

    // Back on, without asking.
    store.keyFails = KeyOutcome.cancelled;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(on(), isTrue);
    state.vault.lock();
  });

  testWidgets('mainnet\'s node: Private, Public or Custom; devnet\'s has no Public', (tester) async {
    final state = AppState(MemoryStore(), MemoryPreferences(), live: false);
    await tester.runAsync(state.start);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: themeFor(Palette.dark), home: const SettingsScreen())));
    expect(find.text('Mainnet · Zandr\'s node'), findsOneWidget);
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Public'));
    await tester.pumpAndSettle();
    expect(state.preferences.publicServices, isTrue);
    expect(state.preferences.rpcUrl(Network.mainnet), publicRpcMainnet);
    expect(find.text('Public services'), findsOneWidget);
    await tester.tap(find.text('Devnet'));
    await tester.pumpAndSettle();
    expect(find.text('Public'), findsNothing);
    // Devnet's choice leaves mainnet's public services on.
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(state.preferences.publicServices, isTrue);
    await tester.tap(find.text('Mainnet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    expect(state.preferences.publicServices, isFalse);
    expect(state.preferences.rpcUrl(Network.mainnet), defaultRpc[Network.mainnet]);
    // The connection checks the screen started finish before the test does.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  });

  testWidgets('a page that fits doesn\'t bounce under the finger', (tester) async {
    final state = AppState(MemoryStore(), MemoryPreferences(), live: false);
    await tester.runAsync(state.start);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: themeFor(Palette.dark), home: const SettingsScreen())));
    final before = tester.getTopLeft(find.text('General'));
    final gesture = await tester.startGesture(tester.getCenter(find.text('Network')));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
    }
    expect(tester.getTopLeft(find.text('General')), before);
    await gesture.up();
    await tester.pumpAndSettle();
    // On iOS, where lists bounce.
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
