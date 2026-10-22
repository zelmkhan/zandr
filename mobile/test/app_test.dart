// The app starts on the welcome screen with nothing stored, and on the unlock screen once there's
// a vault, which asks for Face ID or the passcode at once.
import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/vault.dart';
import 'package:zandr/app/wallet.dart';
import 'package:zandr/core/secrets.dart';
import 'package:zandr/ui/app.dart';

void main() {
  testWidgets('welcome, with nothing stored', (tester) async {
    final state = AppState(MemoryStore(), MemoryPreferences(), live: false);
    await tester.runAsync(state.start);
    await tester.pumpWidget(ZandrApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('Create a new wallet'), findsOneWidget);
    await tester.tap(find.text('I already have a wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Restore a wallet'), findsOneWidget);
  });

  testWidgets('unlock, once there is a vault', (tester) async {
    final store = MemoryStore();
    final preferences = MemoryPreferences();
    await tester.runAsync(() => Vault(store, preferences).create(
          const VaultContents(
            [Keyring('k1', PhraseSecret(['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow']))],
            [WalletEntry(id: 'w1', name: 'Main wallet', address: 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX', keyring: 'k1')],
          ),
        ));
    final state = AppState(store, preferences, live: false);
    await tester.runAsync(state.start);
    expect(state.phase, Phase.locked);
    // The prompt dismissed: the screen waits, with a button to ask again.
    store.keyFails = KeyOutcome.cancelled;
    await tester.pumpWidget(ZandrApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('Unlock with your iPhone passcode'), findsOneWidget);
    expect(state.phase, Phase.locked);
    store.keyFails = null;
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    expect(state.phase, Phase.unlocked);
    state.lock();
  });
}
