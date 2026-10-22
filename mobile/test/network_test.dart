// How the app spends its round trips: the same request asked twice at once goes out once, others
// side by side; names and prices of coins held last time are asked for while the balances load;
// and the last balances show at once on unlock, before the network answers.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/vault.dart';
import 'package:zandr/app/wallet.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/portfolio.dart';
import 'package:zandr/core/secrets.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/solana/rpc.dart';

const wallet = 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX';
const bonk = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

// A node and Jupiter in one: each request is logged, and the node's answers wait for `nodeGate`.
class FakeNet {
  final log = <String>[];
  Completer<void> nodeGate = Completer<void>()..complete();
  late final client = MockClient((request) async {
    if (request.url.path.endsWith('/rpc/mainnet')) {
      final body = jsonDecode(request.body) as Map;
      log.add('node ${body['method']}');
      await nodeGate.future;
      final value = switch (body['method']) {
        'getBalance' => 2000000000,
        'getTokenAccountsByOwner' => (body['params'] as List)[1]['programId'] == tokenProgram
            ? [
                {
                  'pubkey': 'acc',
                  'account': {
                    'data': {
                      'parsed': {
                        'info': {'mint': bonk, 'tokenAmount': {'amount': '1500000', 'decimals': 5, 'uiAmountString': '15'}},
                      },
                    },
                  },
                },
              ]
            : [],
        _ => null,
      };
      return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {'context': {'slot': 1}, 'value': value}}), 200);
    }
    if (request.url.path.endsWith('/price/v3')) {
      log.add('prices ${request.url.queryParameters['ids']}');
      return http.Response(jsonEncode({wrappedSol: {'usdPrice': 150.0}, bonk: {'usdPrice': 0.00002}}), 200);
    }
    if (request.url.path.endsWith('/tokens/v2/search')) {
      log.add('names ${request.url.queryParameters['query']}');
      return http.Response(jsonEncode([{'id': bonk, 'name': 'Bonk', 'symbol': 'BONK', 'isVerified': true, 'decimals': 5, 'usdPrice': 0.00002}]), 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the same Jupiter request asked twice at once goes out once; different ones side by side', () async {
    final net = FakeNet();
    final jupiter = Jupiter(net.client);
    final [a, b, names] = await Future.wait<Object>([jupiter.prices([bonk]), jupiter.prices([bonk]), jupiter.tokenInfo([bonk])]);
    expect((a as Map)[bonk], isNotNull);
    expect((b as Map)[bonk], isNotNull);
    expect((names as Map)[bonk], isNotNull);
    expect(net.log.where((line) => line.startsWith('prices')), hasLength(1));
    expect(net.log.where((line) => line.startsWith('names')), hasLength(1));
  });

  test("while zandr's server isn't running, Jupiter is asked directly and the node counts as unreachable", () async {
    final asked = <String>[];
    // What Railway answers in place of a server that isn't running.
    http.Response absent() => http.Response('{"status":"error","code":404,"message":"Application not found"}', 404, headers: {'x-railway-fallback': 'true'});
    final client = MockClient((request) async {
      asked.add(request.url.host);
      if (request.url.toString().startsWith(zandrApi)) return absent();
      return http.Response(jsonEncode({bonk: {'usdPrice': 0.00002}}), 200);
    });
    final prices = await Jupiter(client).prices([bonk]);
    expect(prices[bonk]?.price, 0.00002);
    expect(asked, [Uri.parse(zandrApi).host, Uri.parse(jupiterPublic).host]);
    await expectLater(
      Rpc(defaultRpc[Network.mainnet]!, client).call<Object?>('getHealth', const []),
      throwsA(isA<ChainError>().having((error) => error.reason, 'reason', RpcFailure.unreachable)),
    );
  });

  test('names and prices of the coins held last time are asked for while the balances load', () async {
    final net = FakeNet()..nodeGate = Completer<void>();
    final portfolio = getPortfolio(Rpc(defaultRpc[Network.mainnet]!, net.client), Jupiter(net.client), Network.mainnet, wallet, known: const [bonk]);
    await pumpEventQueue();
    // The node hasn't answered yet, and Jupiter was asked already.
    expect(net.log.any((line) => line.startsWith('prices')), isTrue);
    expect(net.log.any((line) => line.startsWith('names')), isTrue);
    net.nodeGate.complete();
    final coins = (await portfolio).coins;
    expect(coins.map((coin) => coin.symbol), ['SOL', 'BONK']);
    expect(coins.first.value, 300);
    // Nothing asked of Jupiter twice: the early answers served.
    expect(net.log.where((line) => line.startsWith('prices')), hasLength(1));
    expect(net.log.where((line) => line.startsWith('names')), hasLength(1));
  });

  test('the last balances show at once on unlock, before the network answers', () async {
    final net = FakeNet();
    final store = MemoryStore();
    final preferences = MemoryPreferences();
    await Vault(store, preferences).create(const VaultContents(
      [Keyring('k1', PhraseSecret(['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow']))],
      [WalletEntry(id: 'w1', name: 'Main wallet', address: wallet, keyring: 'k1')],
    ));
    final state = AppState(store, preferences, live: false, client: net.client);
    await state.start();
    await state.unlock();
    await state.refreshPortfolio();
    expect(state.portfolio?.coins, hasLength(2));
    // The cache is written in the background, within moments.
    await pumpEventQueue();
    expect(await store.read(SecureKey.cache), isNotNull);
    state.lock();
    expect(state.portfolio, isNull);

    // The network stalls: the balances are there regardless, from the sealed cache.
    net.nodeGate = Completer<void>();
    await state.unlock();
    expect(state.portfolio?.address, wallet);
    expect(state.portfolio?.coins.map((coin) => coin.symbol), ['SOL', 'BONK']);
    // And the cache can't be read without the vault key.
    expect(await store.read(SecureKey.cache), isNot(contains('BONK')));
    net.nodeGate.complete();
    state.lock();
  });
}
