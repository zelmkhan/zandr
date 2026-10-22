// Token names, logos and prices, token search and swaps, from Jupiter (src/server/jupiter.ts).
// Requests go through zandr's server, under its key and rate limit; while that server can't
// answer, straight to Jupiter's public API for ten minutes. With public services, always straight
// to Jupiter's public API. Jupiter says with each answer how much of its rate-limit window is
// left: once it's used up, nothing more goes out until it resets.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'base58.dart';
import 'config.dart';
import 'models.dart';
import 'solana/addresses.dart';

final _mint = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');
final _amount = RegExp(r'^\d{1,30}$');
final _base64 = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

// Names and symbols are whatever a token's creator chose: control and invisible formatting
// characters go (right-to-left overrides can make a name display as another), and length is capped.
String? cleanText(Object? text, int max) {
  if (text is! String) return null;
  final cleaned = text.replaceAll(RegExp(r'[\p{Cc}\p{Cf}]', unicode: true), '').trim();
  final runes = cleaned.runes.take(max).toList();
  return runes.isEmpty ? null : String.fromCharCodes(runes);
}

// The names scam tokens borrow most: an unverified token using one shows no logo, so a fake "USDC"
// doesn't look like the real one.
final _borrowed = 'SOL WSOL USDC USDT USDS USDE USDG PYUSD EURC JUP JTO PYTH BONK WIF RAY ORCA MSOL JITOSOL BSOL JUPSOL INF ETH WETH BTC WBTC CBBTC TRUMP POPCAT SOLANA USDCOIN TETHER BITCOIN ETHEREUM JUPITER WRAPPEDSOL'.split(' ').toSet();
String _plain(String? text) => unorm.nfkc(text ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

// The logos public services can't look up by mint: the ones the app shows before Jupiter answers.
const _knownIcons = {
  wrappedSol: 'https://raw.githubusercontent.com/solana-labs/token-list/main/assets/mainnet/So11111111111111111111111111111111111111112/logo.png',
  usdcMint: 'https://raw.githubusercontent.com/solana-labs/token-list/main/assets/mainnet/EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v/logo.png',
};

// Where a token's logo is, as its creator put it: https, or IPFS and Arweave by their gateways.
String? iconSource(Object? icon) {
  if (icon is! String) return null;
  final url = Uri.tryParse(icon.trim());
  if (url == null || url.host.isEmpty) return null;
  return switch (url.scheme) {
    'ipfs' => 'https://ipfs.io/ipfs/${url.host}${url.path}',
    'ar' => 'https://arweave.net/${url.host}${url.path}',
    'https' => url.toString(),
    _ => null,
  };
}

// The file an IPFS address names, whichever gateway it's on: /ipfs/<cid>/… on the gateway's own
// host, or <cid>.ipfs.<gateway>.
String? _ipfsFile(String source) {
  final url = Uri.parse(source);
  final path = RegExp(r'^/ipfs/([A-Za-z0-9]+)(/.*)?$').firstMatch(url.path);
  if (path != null) return '${path[1]}${path[2] ?? ''}';
  final subdomain = RegExp(r'^([a-z0-9]+)\.ipfs\.').firstMatch(url.host);
  return subdomain == null ? null : '${subdomain[1]}${url.path == '/' ? '' : url.path}';
}

// IPFS gateways that let wsrv.nl fetch from them: ipfs.io, which most tokens name, turns it away.
const _ipfsGateways = ['https://ipfs.filebase.io/ipfs/', 'https://4everland.io/ipfs/'];

// A token's logo: from zandr's logo server by mint, or, with public services, the image its
// creator named (`icon`, as Jupiter gives it) through wsrv.nl, an IPFS one from one gateway and
// then the other. Either way the creator's host never sees who looks.
String? tokenLogo(String mint, {Object? icon, bool public = false}) {
  if (!public) return '$logoServer/$mint';
  final source = iconSource(icon ?? _knownIcons[mint]);
  if (source == null) return null;
  final file = _ipfsFile(source);
  return file == null ? proxiedLogo(source) : proxiedLogo('${_ipfsGateways[0]}$file', fallback: proxiedLogo('${_ipfsGateways[1]}$file'));
}

String? logoFor(String mint, {required bool verified, String? symbol, String? name, Object? icon, bool public = false}) {
  if (!verified && (_borrowed.contains(_plain(symbol)) || _borrowed.contains(_plain(name)))) return null;
  return tokenLogo(mint, icon: icon, public: public);
}

TokenInfo parseToken(Map<String, dynamic> token, {bool public = false}) {
  final verified = token['isVerified'] == true;
  final name = cleanText(token['name'], 48);
  final symbol = cleanText(token['symbol'], 16);
  final decimals = token['decimals'];
  final price = token['usdPrice'];
  return TokenInfo(
    name: name,
    symbol: symbol,
    logo: logoFor(token['id'] as String, verified: verified, symbol: symbol, name: name, icon: token['icon'], public: public),
    verified: verified,
    decimals: decimals is int && decimals >= 0 && decimals <= 255 ? decimals : null,
    traded: price is num && price > 0,
  );
}

class _Cached<T> {
  final T value;
  final DateTime expires;
  _Cached(this.value, Duration ttl) : expires = DateTime.now().add(ttl);
  bool get fresh => DateTime.now().isBefore(expires);
}

// A swap built by Jupiter for one wallet: its price, and the instructions carrying it out, which
// the wallet puts into a transaction itself and checks before signing.
class SwapBuild {
  final String inputMint, outputMint, inAmount, outAmount, minOutAmount;
  final double priceImpactPct;
  final List<String> route;
  // In order: opening accounts and wrapping SOL, the swap, unwrapping, anything after.
  final List<({String program, List<({String address, bool signer, bool writable})> accounts, String data})> instructions;
  // Micro-lamports per compute unit, as Jupiter suggests it: the wallet caps it.
  final BigInt computeUnitPrice;
  // Only the tables' addresses: what's in them is read from the chain.
  final List<String> lookupTables;
  final String blockhash;
  final int lastValidBlockHeight;
  const SwapBuild({
    required this.inputMint,
    required this.outputMint,
    required this.inAmount,
    required this.outAmount,
    required this.minOutAmount,
    required this.priceImpactPct,
    required this.route,
    required this.instructions,
    required this.computeUnitPrice,
    required this.lookupTables,
    required this.blockhash,
    required this.lastValidBlockHeight,
  });
}

class Jupiter {
  final http.Client _client;
  // Public services: Jupiter's public API only, and logos to match.
  final bool public;
  Jupiter([http.Client? client]) : _client = client ?? http.Client(), public = false;
  Jupiter.publicApi([http.Client? client]) : _client = client ?? http.Client(), public = true;

  // Public services, or zandr's server not answering for now: logos from where they are, through
  // the image proxy, as zandr's logo server is on that server too.
  bool get _direct => public || DateTime.now().isBefore(_fallbackUntil);

  // A known token's logo (SOL's, USDC's), shown before Jupiter has answered.
  String? logo(String mint) => tokenLogo(mint, public: _direct);

  final _infos = <String, _Cached<TokenInfo?>>{};
  final _prices = <String, _Cached<Price?>>{};
  final _searches = <String, _Cached<List<TokenListing>>>{};
  DateTime _fallbackUntil = DateTime(0);
  DateTime _heldUntil = DateTime(0);
  // Requests on their way, by path: the same one asked again meanwhile waits for that answer.
  final _inflight = <String, Future<Object?>>{};

  String get _base => public || DateTime.now().isBefore(_fallbackUntil) ? jupiterPublic : jupiterViaZandr;

  void _heed(http.Response response) {
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    if (reset == null) return;
    if (response.statusCode == 429 || response.headers['x-ratelimit-remaining'] == '0') {
      final until = DateTime.fromMillisecondsSinceEpoch(reset * 1000 + 100);
      final cap = DateTime.now().add(const Duration(seconds: 10));
      _heldUntil = until.isAfter(cap) ? cap : until;
    }
  }

  // Requests go out side by side (a swap's price never waits behind a refresh of prices); a used-up
  // rate window, as zandr's server or Jupiter tells it, is waited out first.
  Future<Object?> _request(String path, {Map<String, dynamic>? body}) {
    if (body != null) return _send(path, body: body);
    // A block, not an arrow: whenComplete waits for whatever its callback returns, and remove()
    // returns this very future.
    return _inflight[path] ??= _send(path).whenComplete(() {
      _inflight.remove(path);
    });
  }

  Future<Object?> _send(String path, {Map<String, dynamic>? body}) async {
    var dropped = 0;
    for (var attempt = 0;; attempt++) {
      final wait = _heldUntil.difference(DateTime.now());
      if (!wait.isNegative) await Future<void>.delayed(wait);
      final base = _base;
      http.Response response;
      try {
        final uri = Uri.parse('$base$path');
        response = await (body == null
                ? _client.get(uri)
                : _client.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 15));
      } on Exception catch (error) {
        if (base == jupiterViaZandr) {
          _fallbackUntil = DateTime.now().add(const Duration(minutes: 10));
          continue;
        }
        // With public services there's nowhere else to go: a dropped connection is tried twice more.
        if (public && error is! TimeoutException && dropped++ < 2) {
          await Future<void>.delayed(Duration(milliseconds: 500 * dropped));
          continue;
        }
        throw const ServiceError(ServiceFailure.unreachable, 'tokens');
      }
      _heed(response);
      // zandr's server without a Jupiter key, failing, or not running at all (Railway answers in
      // its place then, marking the answer): Jupiter directly for a while.
      if (base == jupiterViaZandr && (response.statusCode >= 500 || serverAbsent(response))) {
        _fallbackUntil = DateTime.now().add(const Duration(minutes: 10));
        continue;
      }
      if (response.statusCode == 429) {
        if (attempt >= 2) throw const ServiceError(ServiceFailure.rateLimited, 'tokens');
        if (!_heldUntil.isAfter(DateTime.now())) await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 1500 : 4000));
        continue;
      }
      if (response.statusCode == 401 || response.statusCode == 403) throw const ServiceError(ServiceFailure.forbidden, 'tokens');
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw const ServiceError(ServiceFailure.badResponse, 'tokens');
      }
      if (response.statusCode >= 300) {
        final said = decoded is Map && decoded['error'] is String ? cleanText(decoded['error'], 160) : null;
        throw ServiceError(ServiceFailure.badResponse, 'tokens', said);
      }
      return decoded;
    }
  }

  // Names, logos and whether verified, 80 mints a request (keeping the query under the 4 KB zandr's
  // server takes); unknown ones are null. Cached an hour.
  Future<Map<String, TokenInfo?>> tokenInfo(List<String> mints) async {
    final found = <String, TokenInfo?>{};
    final missing = <String>[];
    for (final mint in mints.toSet()) {
      final hit = _infos[mint];
      if (hit != null && hit.fresh) {
        found[mint] = hit.value;
      } else if (_mint.hasMatch(mint)) {
        missing.add(mint);
      }
    }
    for (var i = 0; i < missing.length; i += 80) {
      final batch = missing.sublist(i, i + 80 > missing.length ? missing.length : i + 80);
      final body = await _request('/tokens/v2/search?query=${batch.join(',')}');
      if (body is! List) throw const ServiceError(ServiceFailure.badResponse, 'tokens');
      final result = <String, TokenInfo>{};
      for (final token in body) {
        if (token is Map && token['id'] is String && batch.contains(token['id'])) result[token['id'] as String] = parseToken(token.cast(), public: _direct);
      }
      for (final mint in batch) {
        _infos[mint] = _Cached(result[mint], const Duration(hours: 1));
        found[mint] = result[mint];
      }
    }
    return found;
  }

  // US dollar prices and their 24-hour change; Jupiter leaves out tokens it can't price. Cached 30 s.
  Future<Map<String, Price?>> prices(List<String> mints) async {
    final found = <String, Price?>{};
    final missing = <String>[];
    for (final mint in mints.toSet()) {
      final hit = _prices[mint];
      if (hit != null && hit.fresh) {
        found[mint] = hit.value;
      } else if (_mint.hasMatch(mint)) {
        missing.add(mint);
      }
    }
    for (var i = 0; i < missing.length; i += 50) {
      final batch = missing.sublist(i, i + 50 > missing.length ? missing.length : i + 50);
      final body = await _request('/price/v3?ids=${batch.join(',')}');
      if (body is! Map) throw const ServiceError(ServiceFailure.badResponse, 'tokens');
      for (final mint in batch) {
        final entry = body[mint];
        final price = entry is Map ? entry['usdPrice'] : null;
        final change = entry is Map ? entry['priceChange24h'] : null;
        final value = price is num && price >= 0 && price.isFinite ? Price(price.toDouble(), change is num ? change.toDouble() : null) : null;
        _prices[mint] = _Cached(value, const Duration(seconds: 30));
        found[mint] = value;
      }
    }
    return found;
  }

  // Tokens matching a name, symbol or mint, verified ones first; cached a couple of minutes.
  Future<List<TokenListing>> search(String query) async {
    final key = query.trim().toLowerCase();
    final cached = _searches[key];
    if (cached != null && cached.fresh) return cached.value;
    final body = await _request('/tokens/v2/search?query=${Uri.encodeComponent(query.trim())}');
    if (body is! List) throw const ServiceError(ServiceFailure.badResponse, 'tokens');
    final found = <TokenListing>[];
    for (final token in body) {
      if (token is! Map || token['id'] is! String || !_mint.hasMatch(token['id'] as String)) continue;
      final info = parseToken(token.cast(), public: _direct);
      _infos[token['id'] as String] = _Cached(info, const Duration(hours: 1));
      found.add(TokenListing(token['id'] as String, info));
    }
    found.sort((a, b) => (b.info.verified ? 1 : 0) - (a.info.verified ? 1 : 0));
    final top = found.take(30).toList();
    _searches[key] = _Cached(top, const Duration(minutes: 2));
    return top;
  }

  // A swap of `amount` (smallest units) built for `taker` (Swap API v2's /build). The route is
  // kept to 48 accounts, leaving room in the transaction for the wallet's own instructions.
  Future<SwapBuild> build(String inputMint, String outputMint, String amount, int slippageBps, String taker) async {
    final query = Uri(queryParameters: {
      'inputMint': inputMint, 'outputMint': outputMint, 'amount': amount, 'taker': taker,
      'slippageBps': '$slippageBps', 'maxAccounts': '48',
    }).query;
    final body = await _request('/swap/v2/build?$query');
    ({String program, List<({String address, bool signer, bool writable})> accounts, String data}) instruction(Object? value) {
      if (value is! Map || value['programId'] is! String || !_mint.hasMatch(value['programId'] as String) || value['accounts'] is! List ||
          value['data'] is! String || !_base64.hasMatch(value['data'] as String)) {
        throw const ServiceError(ServiceFailure.badResponse, 'tokens');
      }
      return (
        program: value['programId'] as String,
        accounts: [
          for (final account in value['accounts'] as List)
            if (account is Map && account['pubkey'] is String && _mint.hasMatch(account['pubkey'] as String) && account['isSigner'] is bool && account['isWritable'] is bool)
              (address: account['pubkey'] as String, signer: account['isSigner'] as bool, writable: account['isWritable'] as bool)
            else
              throw const ServiceError(ServiceFailure.badResponse, 'tokens'),
        ],
        data: value['data'] as String,
      );
    }

    List<({String program, List<({String address, bool signer, bool writable})> accounts, String data})> list(Object? value) =>
        value is List ? [for (final entry in value) instruction(entry)] : [];
    if (body is! Map || body['inputMint'] != inputMint || body['outputMint'] != outputMint || body['swapMode'] != 'ExactIn' ||
        ![body['inAmount'], body['outAmount'], body['otherAmountThreshold']].every((v) => v is String && _amount.hasMatch(v)) || body['swapInstruction'] is! Map) {
      throw const ServiceError(ServiceFailure.badResponse, 'tokens');
    }
    final meta = body['blockhashWithMetadata'];
    final hash = meta is Map ? meta['blockhash'] : null;
    if (hash is! List || hash.length != 32 || !hash.every((b) => b is int && b >= 0 && b <= 255) || meta['lastValidBlockHeight'] is! int) {
      throw const ServiceError(ServiceFailure.badResponse, 'tokens');
    }
    var price = BigInt.zero;
    for (final entry in list(body['computeBudgetInstructions'])) {
      if (entry.program != computeBudgetProgram) continue;
      final data = base64Decode(entry.data);
      if (data.length == 9 && data[0] == 3) {
        for (var i = 8; i >= 1; i--) {
          price = (price << 8) | BigInt.from(data[i]);
        }
      }
    }
    final impact = double.tryParse('${body['priceImpactPct']}') ?? 0;
    final tables = body['addressesByLookupTableAddress'];
    return SwapBuild(
      inputMint: inputMint,
      outputMint: outputMint,
      inAmount: body['inAmount'] as String,
      outAmount: body['outAmount'] as String,
      minOutAmount: body['otherAmountThreshold'] as String,
      priceImpactPct: impact.isFinite ? impact : 0,
      route: [
        if (body['routePlan'] is List)
          for (final step in body['routePlan'] as List)
            if (step is Map && step['swapInfo'] is Map) cleanText((step['swapInfo'] as Map)['label'], 32) ?? '?',
      ],
      instructions: [
        ...list(body['setupInstructions']),
        instruction(body['swapInstruction']),
        if (body['cleanupInstruction'] != null) instruction(body['cleanupInstruction']),
        ...list(body['otherInstructions']),
      ],
      computeUnitPrice: price,
      lookupTables: tables is Map ? [for (final key in tables.keys) if (key is String && _mint.hasMatch(key)) key] : const [],
      blockhash: base58Encode(hash.cast<int>()),
      lastValidBlockHeight: meta['lastValidBlockHeight'] as int,
    );
  }
}

