// How the app spends its round trips: the same request asked twice at once goes out once, others
// side by side; names and prices of coins held last time are asked for while the balances load;
// and the last balances show at once on unlock, before the network answers.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zandr/app/exchange_lists.dart';
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

  test("while zandr's server isn't running, Jupiter, logos and the node are public ones", () async {
    final asked = <String>[];
    // What Railway answers in place of a server that isn't running.
    http.Response absent() => http.Response('{"status":"error","code":404,"message":"Application not found"}', 404, headers: {'x-railway-fallback': 'true'});
    final client = MockClient((request) async {
      asked.add(request.url.host);
      if (request.url.toString().startsWith(zandrApi)) return absent();
      if (request.url.host == Uri.parse(publicRpcMainnet).host) return http.Response('{"jsonrpc":"2.0","id":1,"result":"ok"}', 200);
      if (request.url.path.endsWith('/tokens/v2/search')) {
        return http.Response(jsonEncode([{'id': bonk, 'name': 'Bonk', 'symbol': 'BONK', 'icon': 'https://arweave.net/bonk', 'isVerified': true, 'decimals': 5}]), 200);
      }
      return http.Response(jsonEncode({bonk: {'usdPrice': 0.00002}}), 200);
    });
    final jupiter = Jupiter(client);
    final prices = await jupiter.prices([bonk]);
    expect(prices[bonk]?.price, 0.00002);
    expect(asked, [Uri.parse(zandrApi).host, Uri.parse(jupiterPublic).host]);
    // zandr's logo server is down with it: logos through the image proxy meanwhile.
    expect(Uri.parse((await jupiter.tokenInfo([bonk]))[bonk]!.logo!).host, 'wsrv.nl');
    expect(Uri.parse(jupiter.logo(wrappedSol)!).host, 'wsrv.nl');

    // The node: zandr's tried once, then Helius's public one stands in, without asking zandr's again.
    asked.clear();
    final rpc = Rpc(defaultRpc[Network.mainnet]!, client);
    expect(await rpc.call<Object?>('getHealth', const []), 'ok');
    expect(await rpc.call<Object?>('getHealth', const []), 'ok');
    expect(asked, [Uri.parse(zandrApi).host, Uri.parse(publicRpcMainnet).host, Uri.parse(publicRpcMainnet).host]);
    expect(rpc.endpoint, publicRpcMainnet);
    // A node of the user's own has nothing standing in for it.
    await expectLater(
      Rpc('https://rpc.example.com', MockClient((_) async => absent())).call<Object?>('getHealth', const []),
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

  test('with public services only the exchanges\' lists come from zandr\'s server: Helius, Jupiter and logos directly', () async {
    final asked = <Uri>[];
    final client = MockClient((request) async {
      asked.add(request.url);
      if (request.url.host == Uri.parse(publicRpcMainnet).host) {
        final body = jsonDecode(request.body) as Map;
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
      if (request.url.path.endsWith('/price/v3')) return http.Response(jsonEncode({wrappedSol: {'usdPrice': 150.0}, bonk: {'usdPrice': 0.00002}}), 200);
      if (request.url.path.endsWith('/tokens/v2/search')) {
        return http.Response(jsonEncode([{'id': bonk, 'name': 'Bonk', 'symbol': 'BONK', 'icon': 'ipfs://bafkbonk', 'isVerified': true, 'decimals': 5, 'usdPrice': 0.00002}]), 200);
      }
      return http.Response('{}', 404);
    });
    final store = MemoryStore();
    final preferences = MemoryPreferences(const Preferences(publicServices: true));
    await Vault(store, preferences).create(const VaultContents(
      [Keyring('k1', PhraseSecret(['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow']))],
      [WalletEntry(id: 'w1', name: 'Main wallet', address: wallet, keyring: 'k1')],
    ));
    final state = AppState(store, preferences, live: false, client: client);
    await state.start();
    await state.unlock();
    await state.refreshPortfolio();
    final coins = state.portfolio!.coins;
    expect(coins.map((coin) => coin.symbol), ['SOL', 'BONK']);
    expect(coins.first.value, 300);
    expect(asked.map((url) => url.host).toSet(), {Uri.parse(publicRpcMainnet).host, Uri.parse(jupiterPublic).host, Uri.parse(zandrApi).host});
    expect(asked.where((url) => url.host == Uri.parse(zandrApi).host).map((url) => url.path).toSet(), {'/v1/exchange-tokens'});
    // Logos through the image proxy: SOL's from the token list, BONK's from its IPFS address on a
    // gateway that lets the proxy in, and another should that one fail.
    expect(coins.map((coin) => Uri.parse(coin.logo!).host).toSet(), {'wsrv.nl'});
    final bonkLogo = Uri.parse(coins.last.logo!).queryParameters;
    expect(bonkLogo['url'], 'https://ipfs.filebase.io/ipfs/bafkbonk');
    expect(Uri.parse(bonkLogo['default']!).queryParameters['url'], 'https://4everland.io/ipfs/bafkbonk');
    state.lock();
  });

  test('public services: Helius for mainnet unless a custom node is set; devnet as it was', () {
    const public = Preferences(publicServices: true);
    expect(public.rpcUrl(Network.mainnet), publicRpcMainnet);
    expect(public.rpcUrl(Network.devnet), defaultRpc[Network.devnet]);
    expect(public.copyWith(rpc: {Network.mainnet: 'https://rpc.example.com'}).rpcUrl(Network.mainnet), 'https://rpc.example.com');
    expect(Preferences.fromJson(public.toJson()).publicServices, isTrue);
    expect(Preferences.fromJson(const {}).publicServices, isFalse);
  });

  test("the exchanges' lists: three tries while zandr's server can't answer, then none for 12 hours", () async {
    var asked = 0;
    var down = true;
    final client = MockClient((request) async {
      asked++;
      if (down) return http.Response('{"status":"error","code":404,"message":"Application not found"}', 404, headers: {'x-railway-fallback': 'true'});
      return http.Response('{}', 200);
    });
    final store = MemoryPreferences();
    final lists = ExchangeLists(store, client, Duration.zero);
    expect(await lists.refresh(), isFalse);
    expect(asked, 3);
    // Back up, but tried within 12 hours: not asked again yet.
    down = false;
    expect(await lists.refresh(), isFalse);
    expect(asked, 3);
    // 12 hours later (as the stored time says): asked once, and an answer that isn't lists stands.
    await store.writeText('exchangeTokensTriedAt', '${DateTime.now().subtract(const Duration(hours: 13)).millisecondsSinceEpoch}');
    expect(await lists.refresh(), isFalse);
    expect(asked, 4);
  });
}
