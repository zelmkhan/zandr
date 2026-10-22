// Swap: the switch between the two cards swaps the coins whenever both are picked, as in the
// extension, held or not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/vault.dart';
import 'package:zandr/app/wallet.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/models.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/units.dart';
import 'package:zandr/ui/app.dart';
import 'package:zandr/ui/swap.dart';
import 'package:zandr/ui/theme.dart';

class _Vault extends Vault {
  _Vault(super.store, super.preferences);
  static const _wallet = WalletSummary('w1', 'Main wallet', 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX', WalletSource.phrase);
  @override
  bool get unlocked => true;
  @override
  WalletSummary? get active => _wallet;
}

// Holds SOL only, unless told to hold USDC too.
class _State extends AppState {
  _State({required bool usdc}) : super(MemoryStore(), MemoryPreferences(), vault: _Vault(MemoryStore(), MemoryPreferences()), live: false) {
    Coin coin(String mint, String symbol, String balance, int decimals, {bool native = false}) => Coin(
          mint: mint, native: native, program: native ? 'system' : 'token', amount: '${parseUnits(balance, decimals)}', decimals: decimals,
          balance: balance, name: symbol, symbol: symbol, logo: null, verified: true, price: 1, value: 1, change24h: 0,
        );
    portfolio = Portfolio(
      network: Network.mainnet,
      address: _Vault._wallet.address,
      coins: [coin(wrappedSol, 'SOL', '2', 9, native: true), if (usdc) coin(usdcMint, 'USDC', '10', 6)],
      value: 2,
      updatedAt: DateTime.now(),
    );
  }
}

Future<void> open(WidgetTester tester, {required bool usdc}) async {
  await tester.pumpWidget(AppScope(state: _State(usdc: usdc), child: MaterialApp(theme: themeFor(Palette.dark), home: const SwapScreen())));
  await tester.pump();
}

void main() {
  for (final usdc in [true, false]) {
    testWidgets('switches the coins, USDC ${usdc ? 'held' : 'not held'}', (tester) async {
      await open(tester, usdc: usdc);
      expect(find.text('Balance 2 SOL'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Switch coins'));
      await tester.pump(const Duration(milliseconds: 400));
      // USDC is now what's paid with; SOL what comes.
      expect(find.text(usdc ? 'Balance 10 USDC' : 'You don\'t hold this coin'), findsOneWidget);
      expect(find.text('Balance 2 SOL'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Switch coins'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Balance 2 SOL'), findsOneWidget);
      expect(find.text('You don\'t hold this coin'), findsNothing);
    });
  }
}
