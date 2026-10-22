// JSON-RPC calls to the Solana node the wallet sends through (src/lib/solana/rpc.ts).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

// Why a call failed: the node refused it, limited it, couldn't be reached, or answered with an
// error of its own (`detail` has its message).
enum RpcFailure { forbidden, rateLimited, unreachable, rejected }

class ChainError implements Exception {
  final RpcFailure reason;
  final String? detail;
  const ChainError(this.reason, [this.detail]);

  @override
  String toString() => 'RPC ${reason.name}${detail == null ? '' : ': $detail'}';
}

class Rpc {
  final String url;
  final http.Client _client;
  Rpc(this.url, [http.Client? client]) : _client = client ?? http.Client();

  // A request turned away for going too fast is tried twice more, a moment later each time.
  Future<T> call<T>(String method, List<Object?> params) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _call<T>(method, params);
      } on ChainError catch (error) {
        if (attempt == 2 || error.reason != RpcFailure.rateLimited) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt + 1));
      }
    }
  }

  Future<T> _call<T>(String method, List<Object?> params) async {
    http.Response response;
    try {
      response = await _client
          .post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}))
          .timeout(const Duration(seconds: 15));
    } on Exception {
      throw const ChainError(RpcFailure.unreachable);
    }
    if (serverAbsent(response)) throw const ChainError(RpcFailure.unreachable);
    if (response.statusCode == 401 || response.statusCode == 403) throw const ChainError(RpcFailure.forbidden);
    if (response.statusCode == 429) throw const ChainError(RpcFailure.rateLimited);
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    if (body is Map && body['error'] is Map) {
      final error = body['error'] as Map;
      if (error['code'] == 429 || error['code'] == -32429) throw const ChainError(RpcFailure.rateLimited);
      final message = '${error['message'] ?? 'Unknown error'}';
      throw ChainError(RpcFailure.rejected, message.length > 300 ? message.substring(0, 300) : message);
    }
    if (response.statusCode >= 300 || body is! Map || !body.containsKey('result')) {
      throw ChainError(response.statusCode >= 500 ? RpcFailure.unreachable : RpcFailure.rejected);
    }
    return body['result'] as T;
  }

  // Accounts as the node's jsonParsed encoding gives them; null for one that doesn't exist.
  Future<List<Map<String, dynamic>?>> getAccounts(List<String> addresses, {String commitment = 'confirmed'}) async {
    final result = await call<Map<String, dynamic>>('getMultipleAccounts', [
      addresses,
      {'encoding': 'jsonParsed', 'commitment': commitment},
    ]);
    return (result['value'] as List).map((value) => value == null ? null : (value as Map).cast<String, dynamic>()).toList();
  }
}

// What a jsonParsed account says about itself: {type, info}, or null if it wasn't parsed.
Map<String, dynamic>? parsedOf(Map<String, dynamic>? account) {
  final data = account?['data'];
  if (data is! Map) return null;
  final parsed = data['parsed'];
  return parsed is Map ? parsed.cast<String, dynamic>() : null;
}

// The raw token amount of a parsed token account.
BigInt tokenAmountOf(Map<String, dynamic>? account) {
  final amount = ((parsedOf(account)?['info'] as Map?)?['tokenAmount'] as Map?)?['amount'];
  return amount is String && RegExp(r'^\d+$').hasMatch(amount) ? BigInt.parse(amount) : BigInt.zero;
}

// What a node said of itself: the chain it serves (null for none Zandr knows), its version, and
// how long it took to answer.
class RpcProbe {
  final Network? network;
  final String version;
  final int latencyMs;
  const RpcProbe(this.network, this.version, this.latencyMs);
}

// Asks a node which chain it serves (by its genesis hash) and its version, as the extension does
// (src/lib/network.ts). Throws ChainError when it doesn't answer like a Solana node.
Future<RpcProbe> probeRpc(String url, [http.Client? client]) async {
  final started = DateTime.now();
  final rpc = Rpc(url, client);
  final [hash, version] = await Future.wait([rpc._call<Object?>('getGenesisHash', const []), rpc._call<Object?>('getVersion', const [])]);
  final network = genesisHash.entries.where((entry) => entry.value == hash).firstOrNull?.key;
  return RpcProbe(network, version is Map ? '${version['solana-core'] ?? 'unknown'}' : 'unknown', DateTime.now().difference(started).inMilliseconds);
}
