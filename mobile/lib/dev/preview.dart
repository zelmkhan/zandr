// The screens with sample data, in a browser, for looking at them while developing:
//   flutter build web -t lib/dev/preview.dart, then open it with ?screen=<name>.
// No network, no Keychain and no keys: the sample wallets are public addresses, and nothing here
// ships in the app.
import 'package:flutter/material.dart';

import '../app/preferences.dart';
import '../app/store.dart';
import '../app/vault.dart';
import '../app/wallet.dart';
import '../core/activity.dart';
import '../core/config.dart';
import '../core/jupiter.dart';
import '../core/models.dart';
import '../core/reclaim.dart';
import '../core/send.dart';
import '../core/solana/addresses.dart';
import '../core/swap.dart';
import '../core/units.dart';
import '../ui/address_book.dart';
import '../ui/app.dart';
import '../ui/home.dart';
import '../ui/onboarding.dart';
import '../ui/outcome.dart';
import '../ui/receive.dart';
import '../ui/reclaim.dart';
import '../ui/send.dart';
import '../ui/settings.dart';
import '../ui/swap.dart';
import '../ui/theme.dart';
import '../ui/unlock.dart';
import '../ui/wallets.dart';

const _trading = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';
const _mom = 'EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK';
const _phrase = ['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow'];

class _PreviewVault extends Vault {
  _PreviewVault(super.store, super.preferences);
  static const _wallets = [WalletSummary('w1', 'Main wallet', 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX', WalletSource.phrase), WalletSummary('w2', 'Trading', _trading, WalletSource.privateKey)];
  @override
  bool get unlocked => true;
  @override
  List<WalletSummary> get wallets => _wallets;
  @override
  WalletSummary? get active => _wallets.first;
  @override
  Future<List<Contact>> readAddressBook() async => const [Contact('c1', 'Mom', _mom, 0), Contact('c2', 'Bybit deposit', 'AC5RDfQFmDS1deWZos921JfqscXdByf8BKHs5ACWjtW2', 0)];
}

Coin _coin(String mint, String symbol, String name, String balance, double price, double change, {bool native = false, int decimals = 6}) => Coin(
      mint: mint, native: native, program: native ? 'system' : 'token', amount: '${parseUnits(balance, native ? 9 : decimals)}', decimals: native ? 9 : decimals,
      balance: balance, name: name, symbol: symbol, logo: '$logoServer/$mint', verified: true, price: price, value: double.parse(balance) * price, change24h: change,
    );

final _coins = [
  _coin(wrappedSol, 'SOL', 'Solana', '12.4862', 178.42, 2.31, native: true),
  _coin(usdcMint, 'USDC', 'USD Coin', '1250.5', 1.0, 0.01),
  _coin('JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', 'JUP', 'Jupiter', '840.12', 0.61, -1.84),
  _coin('DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', 'BONK', 'Bonk', '1520000', 0.0000231, 5.12, decimals: 5),
];

final _activity = [
  Activity(signature: 's1', time: DateTime.now().subtract(const Duration(minutes: 4)), kind: ActivityKind.swap, changes: const [
    ActivityChange(mint: usdcMint, amount: '+178.1', symbol: 'USDC', verified: true),
    ActivityChange(amount: '-1', symbol: 'SOL', verified: true),
  ], program: jupiterProgram, app: 'Jupiter'),
  Activity(signature: 's2', time: DateTime.now().subtract(const Duration(hours: 3)), kind: ActivityKind.receive, changes: const [ActivityChange(amount: '+2.5', symbol: 'SOL', verified: true)], counterparty: _mom),
  Activity(signature: 's3', time: DateTime.now().subtract(const Duration(days: 1)), kind: ActivityKind.send, changes: const [ActivityChange(mint: usdcMint, amount: '-50', symbol: 'USDC', verified: true)], counterparty: 'AC5RDfQFmDS1deWZos921JfqscXdByf8BKHs5ACWjtW2'),
  Activity(signature: 's4', time: DateTime.now().subtract(const Duration(days: 3)), kind: ActivityKind.failed, changes: const [], counterparty: _mom),
];

class _PreviewState extends AppState {
  // ignore: use_super_parameters
  _PreviewState(MemoryStore store, MemoryPreferences preferences) : super(store, preferences, vault: _PreviewVault(store, preferences), live: false);

  // The unlock screen as it waits: as if the Face ID prompt was dismissed.
  @override
  Future<void> unlock() async => throw const KeyFailure(KeyOutcome.cancelled);

  @override
  Future<void> refreshPortfolio({int? minContextSlot}) async {
    portfolio = Portfolio(network: Network.mainnet, address: active!.address, coins: _coins, value: _coins.fold(0.0, (sum, coin) => sum + coin.value!), updatedAt: DateTime.now());
    notifyListeners();
  }

  @override
  Future<void> loadActivity({bool more = false}) async {
    activity = _activity;
    activityLoaded = true;
    notifyListeners();
  }
}

SwapBuild _build() => SwapBuild(
      inputMint: wrappedSol, outputMint: usdcMint, inAmount: '1000000000', outAmount: '178104523', minOutAmount: '177214000', priceImpactPct: 0.0003,
      route: const ['Whirlpool', 'Meteora DLMM'], instructions: const [], computeUnitPrice: BigInt.zero, lookupTables: const [], blockhash: '', lastValidBlockHeight: 0,
    );

Widget _screen(String name) {
  const intent = SendIntent(from: 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX', to: '28nYGHJyUVcVdxZtzKByBXEj127XnrUkrE3VaGuWj1ZU', amount: '25');
  final review = SendReview(
    network: Network.mainnet, from: intent.from, to: intent.to, coin: const SendCoin(mint: 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', symbol: 'JUP', name: 'Jupiter', logo: '$logoServer/JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', decimals: 6),
    amount: '25', fee: '0.000005017', checks: const [ExchangeWalletCheck('Binance')], notes: const [],
  );
  final fine = SendReview(
    network: Network.mainnet, from: intent.from, to: _mom, contact: 'Mom', coin: const SendCoin(symbol: 'SOL', name: 'Solana', logo: '$logoServer/$wrappedSol', decimals: 9),
    amount: '0.5', fee: '0.000005001', rent: null, checks: const [], notes: const [ExchangeUncheckedNote()],
  );
  void nothing([Object? _]) {}
  return switch (name) {
    'welcome' => const Onboarding(),
    'phrase' => ShowPhraseStep(words: _phrase, onBack: nothing, onDone: nothing),
    'restore' => RestoreStep(onBack: nothing, onDone: nothing),
    'passcode' => PasscodeStep(onBack: nothing, onDone: nothing),
    'unlock' => const UnlockScreen(),
    'home' => const HomeScreen(),
    'activity' => const HomeScreen(activityTab: true),
    'receive' => const ReceiveScreen(),
    'send' => const SendScreen(),
    'review' => SendReviewScreen(intent, symbol: 'JUP', preview: review),
    'reviewok' => SendReviewScreen(intent, symbol: 'SOL', preview: fine),
    'swap' => SwapScreen(preview: SwapQuote(id: 'q', at: DateTime.now(), from: intent.from, build: _build(), input: const MintInfo(9, tokenProgram), output: const MintInfo(6, tokenProgram), fee: BigInt.from(8500000))),
    'reclaim' => const ReclaimScreen(
        preview: ReclaimPlan([
          ReclaimAccount(address: 'a1', mint: 'm1', symbol: 'SAMO', verified: true, sol: '0.00203928'),
          ReclaimAccount(address: 'a2', mint: 'm2', symbol: 'ORCA', verified: true, sol: '0.00203928'),
        ], [
          ReclaimAccount(address: 'a3', mint: 'm3', symbol: 'FREE-AIRDROP', verified: false, sol: '0.00203928', balance: '1000000', value: null),
          ReclaimAccount(address: 'a4', mint: 'm4', symbol: 'DUST', verified: false, sol: '0.00207408', balance: '12.5', value: 0.04),
        ], true),
      ),
    'outcome' => OutcomeScreen.sent(doneTitle: 'Sent', summary: '0.5 SOL to Mom', sent: const []),
    'settings' => const SettingsScreen(),
    'addressbook' => const AddressBookScreen(),
    'wallets' => const _OpenWallets(),
    _ => const HomeScreen(),
  };
}

class _OpenWallets extends StatefulWidget {
  const _OpenWallets();
  @override
  State<_OpenWallets> createState() => _OpenWalletsState();
}

class _OpenWalletsState extends State<_OpenWallets> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => showWallets(context));
  }

  @override
  Widget build(BuildContext context) => const HomeScreen();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final screen = Uri.base.queryParameters['screen'] ?? 'home';
  final light = Uri.base.queryParameters['theme'] == 'light';
  final preferences = MemoryPreferences(Preferences(theme: light ? ThemeChoice.light : ThemeChoice.dark));
  final state = _PreviewState(MemoryStore(), preferences);
  await state.start();
  state.faceIdAvailable = true;
  state.phase = Phase.unlocked;
  await state.refreshPortfolio();
  runApp(AppScope(
    state: state,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFor(light ? Palette.light : Palette.dark),
      home: Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _screen(screen))),
    ),
  ));
}
