// The app's state: locked or not, the active wallet, its coins and history kept live, and the
// services that read the chain. Locks after the auto-lock time away from the app or idle in it,
// and covers the screen whenever the app isn't in front (the app switcher's snapshot shows nothing).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';

import '../core/activity.dart';
import '../core/config.dart';
import '../core/exchanges.dart';
import '../core/jupiter.dart';
import '../core/live.dart';
import '../core/models.dart';
import '../core/portfolio.dart';
import '../core/reclaim.dart';
import '../core/send.dart';
import '../core/sent.dart';
import '../core/solana/rpc.dart';
import '../core/swap.dart';
import 'exchange_lists.dart';
import 'net.dart';
import 'preferences.dart';
import 'store.dart';
import 'vault.dart';

enum Phase { loading, onboarding, locked, unlocked }

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final SecureStore store;
  final PreferenceStore preferenceStore;
  late final Vault vault = _vault ?? Vault(store, preferenceStore);
  final Vault? _vault;
  // Coins kept live over the node's socket; off for the screens' preview, which has no network.
  final bool live;
  // One connection pool for every request: see net.dart.
  final http.Client client;
  late final ExchangeLists exchangeLists = ExchangeLists(preferenceStore, client);
  late final _jupiterViaZandr = Jupiter(client);
  late final _jupiterPublic = Jupiter.publicApi(client);
  Jupiter get jupiter => preferences.publicServices ? _jupiterPublic : _jupiterViaZandr;

  AppState(this.store, this.preferenceStore, {Vault? vault, this.live = true, http.Client? client}) : _vault = vault, client = client ?? appHttpClient();

  Phase phase = Phase.loading;
  Preferences preferences = const Preferences();
  // The app isn't in front: the screen is covered.
  bool obscured = false;
  bool faceIdAvailable = false;
  // The iPhone has a passcode: without one, the vault key can't be kept.
  bool passcodeSet = false;

  Portfolio? portfolio;
  Object? portfolioError;
  bool refreshing = false;
  List<Activity> activity = const [];
  String? activityNext;
  bool activityLoading = false, activityLoaded = false;
  Object? activityError;

  LiveWatch? _live;
  Timer? _idle;
  DateTime _lastActive = DateTime.now();
  DateTime? _awaySince;

  WalletSummary? get active => vault.active;
  Network get network => preferences.network;

  final _rpcs = <String, Rpc>{};
  Rpc get rpc => _rpcs.putIfAbsent(preferences.rpcUrl(network), () => Rpc(preferences.rpcUrl(network), client));
  Exchanges? _exchanges;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    preferences = await preferenceStore.load();
    phase = await vault.hasVault() ? Phase.locked : Phase.onboarding;
    notifyListeners();
    _warm();
    await checkPasscode();
    exchangeLists.refresh().ignore();
  }

  // Opens the connection to the node ahead of need (while Face ID runs, or as the app comes back),
  // so the first real request doesn't also wait for a TLS handshake. Asks nothing about the wallet.
  void _warm() {
    if (!live) return;
    rpc.call<Object?>('getHealth', const []).ignore();
  }

  // Whether the iPhone has a passcode, and Face ID: asked again after the person may have set one.
  Future<void> checkPasscode() async {
    if (kIsWeb) return;
    try {
      final auth = LocalAuthentication();
      passcodeSet = await auth.isDeviceSupported();
      faceIdAvailable = passcodeSet && (await auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      passcodeSet = faceIdAvailable = false;
    }
    notifyListeners();
  }

  // Activity, for auto-lock: a touch anywhere in the app counts.
  void touch() => _lastActive = DateTime.now();

  Duration get _autoLock => Duration(minutes: preferences.autoLockMinutes);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final front = state == AppLifecycleState.resumed;
    if (obscured != !front) {
      obscured = !front;
      notifyListeners();
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _awaySince ??= DateTime.now();
      _live?.stop();
      _live = null;
    } else if (front) {
      final away = _awaySince;
      _awaySince = null;
      if (away != null) {
        _warm();
        // The exchanges' lists, if 12 hours have passed: the app may stay open for days.
        exchangeLists.refresh().ignore();
      }
      if (phase == Phase.unlocked && away != null && DateTime.now().difference(away) >= _autoLock) {
        lock();
      } else if (phase == Phase.unlocked) {
        touch();
        _watch();
        refreshPortfolio();
      }
    }
  }

  Future<void> _unlocked() async {
    preferences = await preferenceStore.load();
    phase = Phase.unlocked;
    touch();
    _idle?.cancel();
    _idle = Timer.periodic(const Duration(seconds: 15), (_) {
      if (phase == Phase.unlocked && _awaySince == null && DateTime.now().difference(_lastActive) >= _autoLock) lock();
    });
    try {
      _cache = await vault.readCache();
    } catch (_) {
      _cache = {};
    }
    _walletChanged();
  }

  // The last balances of each wallet on each network (the few most recent), from the sealed cache:
  // shown at once on unlock or switching, then refreshed. Kept apart for public services, whose
  // logos come from elsewhere.
  Map<String, Object?> _cache = {};
  static const _cacheLimit = 8;
  String _cacheKey(String address, Network network, Jupiter jupiter) => '${network.name}${jupiter.public ? '-public' : ''}:$address';

  void _remember(Portfolio fresh, Jupiter jupiter) {
    final key = _cacheKey(fresh.address, fresh.network, jupiter);
    _cache
      ..remove(key)
      ..[key] = fresh.toJson();
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    vault.writeCache(Map.of(_cache)).ignore();
  }

  // Asks for Face ID or the passcode. Throws KeyFailure.
  Future<void> unlock() async {
    await vault.unlock();
    await _unlocked();
  }

  void lock() {
    vault.lock();
    _cache = {};
    _idle?.cancel();
    _live?.stop();
    _live = null;
    portfolio = null;
    activity = const [];
    activityNext = null;
    activityLoaded = false;
    phase = Phase.locked;
    notifyListeners();
  }

  Future<void> createVault(VaultContents contents) async {
    await vault.create(contents);
    await _unlocked();
  }

  // For a vault whose key is gone: it can't be opened, so it goes, and the welcome screen follows,
  // for restoring the wallet from its recovery phrase.
  Future<void> startOver() async {
    await vault.eraseEverything();
    preferences = const Preferences();
    phase = Phase.onboarding;
    notifyListeners();
  }

  Future<void> setPreferences(Preferences next) async {
    final networkChanged = next.network != preferences.network ||
        next.rpcUrl(next.network) != preferences.rpcUrl(preferences.network) ||
        next.publicServices != preferences.publicServices;
    await preferenceStore.save(next);
    preferences = next;
    if (networkChanged && phase == Phase.unlocked) {
      _walletChanged();
    } else {
      notifyListeners();
    }
  }

  Future<void> switchWallet(String id) async {
    await vault.switchWallet(id);
    preferences = await preferenceStore.load();
    _walletChanged();
  }

  // After the vault changed (a wallet added, removed or renamed): the active one may be another.
  Future<void> walletsChanged() async {
    preferences = await preferenceStore.load();
    // A removed wallet's balances go from the cache too.
    final addresses = {for (final wallet in vault.wallets) wallet.address};
    final before = _cache.length;
    _cache.removeWhere((key, _) => !addresses.contains(key.split(':').last));
    if (_cache.length != before) vault.writeCache(Map.of(_cache)).ignore();
    if (portfolio?.address != active?.address) {
      _walletChanged();
    } else {
      notifyListeners();
    }
  }

  void _walletChanged() {
    final wallet = active;
    final cached = wallet == null ? null : _cache[_cacheKey(wallet.address, network, jupiter)];
    portfolio = null;
    if (cached is Map) {
      try {
        portfolio = Portfolio.fromJson(cached.cast());
      } catch (_) {
        // Written by an older version: fetched afresh.
      }
    }
    portfolioError = null;
    activity = const [];
    activityNext = null;
    activityLoaded = false;
    activityError = null;
    notifyListeners();
    _watch();
    refreshPortfolio();
  }

  void _watch() {
    _live?.stop();
    final wallet = active;
    if (wallet == null || !live) return;
    _live = LiveWatch(wallet.address, () => rpc.endpoint, (slot) {
      refreshPortfolio(minContextSlot: slot);
      if (slot != null && activityLoaded) refreshActivity();
    });
  }

  // The tokens this wallet held last time on this network, to price ahead of the balances.
  List<String> _knownMints(String address, Network network) {
    final last = portfolio;
    return last == null || last.address != address || last.network != network ? const [] : [for (final coin in last.coins) if (!coin.native) coin.mint];
  }

  Future<void>? _refreshing;
  bool _again = false;

  // One refresh at a time; a change meanwhile asks for one more after it.
  Future<void> refreshPortfolio({int? minContextSlot}) {
    if (_refreshing != null) {
      _again = true;
      return _refreshing!;
    }
    return _refreshing = () async {
      final wallet = active;
      if (wallet == null) return;
      refreshing = true;
      notifyListeners();
      final network = this.network;
      final jupiter = this.jupiter;
      try {
        Portfolio fresh;
        try {
          fresh = await getPortfolio(rpc, jupiter, network, wallet.address, minContextSlot: minContextSlot, known: _knownMints(wallet.address, network));
        } on ChainError catch (error) {
          // A node that hasn't reached the change yet: a moment, then from wherever it is.
          if (minContextSlot == null || !(error.detail ?? '').contains('context slot')) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          fresh = await getPortfolio(rpc, jupiter, network, wallet.address, known: _knownMints(wallet.address, network));
        }
        if (active?.address == wallet.address && this.network == network && this.jupiter == jupiter) {
          portfolio = fresh;
          portfolioError = null;
          _remember(fresh, jupiter);
        }
      } catch (error) {
        if (active?.address == wallet.address) portfolioError = error;
      } finally {
        refreshing = false;
        _refreshing = null;
        notifyListeners();
        if (_again) {
          _again = false;
          refreshPortfolio();
        }
      }
    }();
  }

  Future<void> loadActivity({bool more = false}) async {
    final wallet = active;
    if (wallet == null || activityLoading || (more && activityNext == null)) return;
    activityLoading = true;
    activityError = null;
    notifyListeners();
    try {
      final page = await getActivity(rpc, jupiter, network, wallet.address, before: more ? activityNext : null);
      if (active?.address != wallet.address) return;
      activity = more ? [...activity, ...page.items] : page.items;
      activityNext = page.next;
      activityLoaded = true;
    } catch (error) {
      activityError = error;
    } finally {
      activityLoading = false;
      notifyListeners();
    }
  }

  // What's newer than the newest shown.
  Future<void> refreshActivity() async {
    final wallet = active;
    if (wallet == null || activity.isEmpty) return loadActivity();
    try {
      final page = await getActivity(rpc, jupiter, network, wallet.address, until: activity.first.signature);
      if (active?.address != wallet.address || page.items.isEmpty) return;
      final known = {for (final item in activity) item.signature};
      activity = [...page.items.where((item) => !known.contains(item.signature)), ...activity];
      notifyListeners();
    } catch (_) {
      // The next change or pull tries again.
    }
  }

  Future<Exchanges?> _exchangesNow() async {
    if (network != Network.mainnet || !preferences.protections.contains(Protection.exchangeSupport)) return null;
    if (_exchanges?.rpc != rpc) _exchanges = Exchanges(rpc, await exchangeLists.hotWallets(), exchangeLists.lists);
    return _exchanges;
  }

  // Everyone the user knows: saved addresses and their own wallets.
  Future<List<({String name, String address})>> known() async {
    final contacts = await vault.readAddressBook().catchError((_) => <Contact>[]);
    return [
      for (final contact in contacts) (name: contact.name, address: contact.address),
      for (final wallet in vault.wallets) (name: wallet.name, address: wallet.address),
    ];
  }

  Future<Sender> sender() async => Sender(
        rpc: rpc,
        network: network,
        jupiter: jupiter,
        exchanges: await _exchangesNow(),
        // At a transfer to an exchange with no list, fresh ones are asked for (at most every 10
        // minutes); with public services, only every 12 hours, as always.
        refreshLists: preferences.publicServices ? null : () => exchangeLists.refresh(const Duration(minutes: 10)),
        enabled: preferences.protections,
        known: await known(),
      );

  // One per node, so what it learns of tokens (their decimals and programs) is kept between quotes.
  Swapper? _swapper;
  Swapper swapper() => _swapper?.rpc == rpc && _swapper?.jupiter == jupiter ? _swapper! : _swapper = Swapper(rpc, jupiter, () => portfolio);
  Reclaimer reclaimer() => Reclaimer(rpc, jupiter, network);

  Future<Uint8List> sign(Uint8List message) async {
    touch();
    final wallet = active;
    if (wallet == null) throw const LockedError();
    return (await vault.sign(wallet.address, [message])).single;
  }

  Future<List<Uint8List>> signAll(List<Uint8List> messages) async {
    touch();
    final wallet = active;
    if (wallet == null) throw const LockedError();
    return vault.sign(wallet.address, messages);
  }

  // Follows a transaction this app sent until it lands; the coins follow it.
  Future<Settled?> follow(String signature, Pending pending, {Future<void>? cancel}) async {
    final settled = await followSent(rpc, signature, pending, cancel: cancel);
    if (settled?.status == SettledStatus.confirmed || settled?.status == SettledStatus.failed) {
      refreshPortfolio();
      if (activityLoaded) refreshActivity();
    }
    return settled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idle?.cancel();
    _live?.stop();
    super.dispose();
  }
}
