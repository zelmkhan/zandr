// How the app looks and behaves, remembered on this phone (src/lib/preferences.ts). Nothing secret,
// so kept in the app's preferences, next to (not inside) the vault.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/send.dart' show Protection;

enum ThemeChoice { dark, light, system }

// Minutes away from the app (or idle in it) before it locks.
const autoLockChoices = [1, 5, 15, 60];
const minCoinValueChoices = [0.0, 0.01, 1.0, 5.0];

class Preferences {
  final ThemeChoice theme;
  final bool hideBalance;
  // Coins worth less than this many US dollars are left out of the home screen's list; 0 shows all.
  final double minCoinValue;
  final Network network;
  // A custom RPC URL per network, or none for the default one.
  final Map<Network, String> rpc;
  // Public services in place of zandr's server: Helius as mainnet's default node, and Jupiter and
  // token logos asked for directly (only the exchanges' token lists still come from zandr's
  // server). A custom node, where set, is still the one used.
  final bool publicServices;
  final int autoLockMinutes;
  final Set<Protection> protections;
  // The wallet shown, by its id in the vault (an opaque id that says nothing about it).
  final String? activeWallet;

  const Preferences({
    this.theme = ThemeChoice.dark,
    this.hideBalance = false,
    this.minCoinValue = 0,
    this.network = Network.mainnet,
    this.rpc = const {},
    this.publicServices = false,
    this.autoLockMinutes = 5,
    this.protections = const {...Protection.values},
    this.activeWallet,
  });

  String rpcUrl(Network network) => rpc[network] ?? (network == Network.mainnet && publicServices ? publicRpcMainnet : defaultRpc[network]!);

  Preferences copyWith({
    ThemeChoice? theme,
    bool? hideBalance,
    double? minCoinValue,
    Network? network,
    Map<Network, String>? rpc,
    bool? publicServices,
    int? autoLockMinutes,
    Set<Protection>? protections,
    String? Function()? activeWallet,
  }) =>
      Preferences(
        theme: theme ?? this.theme,
        hideBalance: hideBalance ?? this.hideBalance,
        minCoinValue: minCoinValue ?? this.minCoinValue,
        network: network ?? this.network,
        rpc: rpc ?? this.rpc,
        publicServices: publicServices ?? this.publicServices,
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        protections: protections ?? this.protections,
        activeWallet: activeWallet == null ? this.activeWallet : activeWallet(),
      );

  Map<String, Object?> toJson() => {
        'theme': theme.name,
        'hideBalance': hideBalance,
        'minCoinValue': minCoinValue,
        'network': network.name,
        'rpc': {for (final MapEntry(:key, :value) in rpc.entries) key.name: value},
        'publicServices': publicServices,
        'autoLockMinutes': autoLockMinutes,
        'protections': {for (final protection in Protection.values) protection.name: protections.contains(protection)},
        'activeWallet': activeWallet,
      };

  // Falls back to the defaults rather than failing: a lost preference must not break the app.
  factory Preferences.fromJson(Object? json) {
    const defaults = Preferences();
    if (json is! Map) return defaults;
    T pick<T>(String key, T fallback) => json[key] is T ? json[key] as T : fallback;
    final protections = json['protections'] is Map ? json['protections'] as Map : const {};
    return Preferences(
      theme: ThemeChoice.values.asNameMap()[json['theme']] ?? defaults.theme,
      hideBalance: pick('hideBalance', false),
      minCoinValue: (json['minCoinValue'] as num?)?.toDouble() ?? 0,
      network: Network.values.asNameMap()[json['network']] ?? Network.mainnet,
      rpc: {
        if (json['rpc'] is Map)
          for (final MapEntry(:key, :value) in (json['rpc'] as Map).entries)
            if (Network.values.asNameMap()[key] != null && value is String) Network.values.asNameMap()[key]!: value,
      },
      publicServices: pick('publicServices', false),
      autoLockMinutes: autoLockChoices.contains(json['autoLockMinutes']) ? json['autoLockMinutes'] as int : defaults.autoLockMinutes,
      // Only the protections that exist now, each on unless turned off.
      protections: {for (final protection in Protection.values) if (protections[protection.name] != false) protection},
      activeWallet: json['activeWallet'] as String?,
    );
  }
}

// Where preferences live: the app's preferences on the phone, or memory in tests.
abstract class PreferenceStore {
  Future<Preferences> load();
  Future<void> save(Preferences preferences);
  Future<String?> readText(String key);
  Future<void> writeText(String key, String? value);
}

class DevicePreferences implements PreferenceStore {
  final _store = SharedPreferencesAsync();

  @override
  Future<Preferences> load() async {
    try {
      final text = await _store.getString('preferences');
      return Preferences.fromJson(text == null ? null : jsonDecode(text));
    } catch (_) {
      return const Preferences();
    }
  }

  @override
  Future<void> save(Preferences preferences) => _store.setString('preferences', jsonEncode(preferences.toJson()));

  @override
  Future<String?> readText(String key) => _store.getString(key);

  @override
  Future<void> writeText(String key, String? value) => value == null ? _store.remove(key) : _store.setString(key, value);
}

class MemoryPreferences implements PreferenceStore {
  Preferences _preferences;
  final _texts = <String, String>{};
  MemoryPreferences([this._preferences = const Preferences()]);

  @override
  Future<Preferences> load() async => _preferences;
  @override
  Future<void> save(Preferences preferences) async => _preferences = preferences;
  @override
  Future<String?> readText(String key) async => _texts[key];
  @override
  Future<void> writeText(String key, String? value) async => value == null ? _texts.remove(key) : _texts[key] = value;
}

// An error message for a URL that can't be an RPC endpoint, or null if it looks fine. Plain http
// only for a node on this phone: anywhere else it could be read or tampered with.
String? checkRpcUrl(String input) {
  final url = Uri.tryParse(input.trim());
  if (url == null || !url.hasScheme || url.host.isEmpty) return 'Enter a full URL, like https://rpc.example.com';
  final local = url.host == 'localhost' || url.host == '127.0.0.1';
  if (url.scheme == 'https' || (url.scheme == 'http' && local)) return null;
  return 'Use an https:// URL. Plain http is only allowed for a node on this phone.';
}
