// The exchanges' token lists the wallet goes by (src/lib/exchangeTokens.ts): the snapshot that ships
// with the app, or, where fresher, the lists zandr's server keeps up to date. Those are fetched whole
// every 12 hours, so the server learns nothing about anyone's transfers, checked field by field, and
// kept with the preferences (public data).
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/exchanges.dart';
import 'preferences.dart';

const _every = Duration(hours: 12);

class ExchangeLists {
  final PreferenceStore store;
  final http.Client _client;
  ExchangeLists(this.store, [http.Client? client]) : _client = client ?? http.Client();

  List<ExchangeTokenList>? _shipped;
  Map<String, String>? _hotWallets;

  Future<Map<String, String>> hotWallets() async =>
      _hotWallets ??= hotWalletsFrom(jsonDecode(await rootBundle.loadString('assets/data/exchangeWallets.json')) as Map<String, dynamic>);

  Future<({DateTime checkedAt, List<ExchangeTokenList> lists})> _stored() async {
    try {
      final text = await store.readText('exchangeTokens');
      final entry = text == null ? null : jsonDecode(text) as Map;
      return (
        checkedAt: DateTime.fromMillisecondsSinceEpoch((entry?['checkedAt'] as int?) ?? 0),
        lists: validLists(entry?['data']) ?? const <ExchangeTokenList>[],
      );
    } catch (_) {
      return (checkedAt: DateTime(0), lists: const <ExchangeTokenList>[]);
    }
  }

  // The lists to go by now.
  Future<List<ExchangeTokenList>> lists() async {
    _shipped ??= validLists(jsonDecode(await rootBundle.loadString('assets/data/exchangeTokens.json'))) ?? const [];
    return newestLists(_shipped!, (await _stored()).lists);
  }

  // The exchanges the check knows, and how far, for the protection's page.
  Future<List<ExchangeCoverage>> coverage() async {
    final wallets = jsonDecode(await rootBundle.loadString('assets/data/exchangeWallets.json')) as Map<String, dynamic>;
    return exchangeCoverage([for (final exchange in (wallets['exchanges'] as List).cast<Map>()) exchange['name'] as String], await lists());
  }

  // Fetches fresh lists unless they were fetched within `maxAge`; true if new ones came. A failed
  // fetch keeps what's there.
  Future<bool> refresh([Duration maxAge = _every]) async {
    final (:checkedAt, lists: _) = await _stored();
    if (DateTime.now().difference(checkedAt) < maxAge) return false;
    try {
      final response = await _client.get(Uri.parse('$zandrApi/v1/exchange-tokens')).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      final checked = validLists(data);
      if (checked == null) return false;
      await store.writeText('exchangeTokens', jsonEncode({
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
        'data': {'updated': (data as Map)['updated'], 'lists': [for (final list in checked) list.toJson()]},
      }));
      return true;
    } catch (_) {
      // Offline, or the server is down.
      return false;
    }
  }
}
