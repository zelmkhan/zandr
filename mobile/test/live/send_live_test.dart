// Against mainnet: transfers planned and test-run by the node, nothing signed. The sender is a
// well-funded public wallet; the recipients are ones each check must catch, and fresh addresses.
// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/activity.dart';
import 'package:zandr/core/base58.dart';
import 'package:zandr/core/config.dart';
import 'package:zandr/core/exchanges.dart';
import 'package:zandr/core/jupiter.dart';
import 'package:zandr/core/send.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/solana/rpc.dart';

const from = '43DbAvKxhXh1oSxkJSqGosNw3HpBnmsWiak6tB5wpecN';
const binanceHot = '28nYGHJyUVcVdxZtzKByBXEj127XnrUkrE3VaGuWj1ZU';

void main() {
  final rpc = Rpc(defaultRpc[Network.mainnet]!);
  final jupiter = Jupiter();
  final hot = hotWalletsFrom(jsonDecode(File('assets/data/exchangeWallets.json').readAsStringSync()) as Map<String, dynamic>);
  final shipped = validLists(jsonDecode(File('assets/data/exchangeTokens.json').readAsStringSync()))!;
  final exchanges = Exchanges(rpc, hot, () async => shipped);
  late String fresh;

  Sender sender(List<({String name, String address})> known) =>
      Sender(rpc: rpc, network: Network.mainnet, jupiter: jupiter, exchanges: exchanges, enabled: Protection.values.toSet(), known: known);

  setUpAll(() async {
    final pair = await Ed25519().newKeyPair();
    fresh = base58Encode((await pair.extractPublicKey()).bytes);
  });

  String describe(SendReview review) =>
      '${review.amount} ${review.coin.label} → ${review.to.substring(0, 6)}: fee ${review.fee}${review.rent == null ? '' : ', rent ${review.rent}'}, checks ${review.checks.map((c) => c.runtimeType).toList()}, notes ${review.notes.map((n) => n.runtimeType).toList()}';

  test('SOL to a fresh address: no checks', () async {
    final review = await sender([]).prepare(SendIntent(from: from, to: fresh, amount: '0.01'));
    print(describe(review));
    expect(review.checks, isEmpty);
    expect(review.notes, isEmpty);
  });

  test("SOL to an exchange's own wallet", () async {
    final review = await sender([]).prepare(const SendIntent(from: from, to: binanceHot, amount: '0.01'));
    print(describe(review));
    expect(review.checks.single, isA<ExchangeWalletCheck>().having((c) => c.exchange, 'exchange', 'Binance'));
  });

  test("SOL to USDC's mint", () async {
    final review = await sender([]).prepare(const SendIntent(from: from, to: usdcMint, amount: '0.01'));
    print(describe(review));
    expect(review.checks.single, isA<MintCheck>().having((c) => c.token, 'token', 'USDC'));
  });

  test('SOL to a program', () async {
    final review = await sender([]).prepare(const SendIntent(from: from, to: jupiterProgram, amount: '0.01'));
    print(describe(review));
    expect(review.checks.first, isA<ProgramCheck>().having((c) => c.kind, 'kind', ProgramKind.program));
  });

  test('a lookalike of a saved address', () async {
    final saved = '${fresh.substring(0, 4)}${'1' * (fresh.length - 8)}${fresh.substring(fresh.length - 4)}';
    final review = await sender([(name: 'Mom', address: saved)]).prepare(SendIntent(from: from, to: fresh, amount: '0.01'));
    print(describe(review));
    expect(review.checks.single, isA<LookalikeCheck>().having((c) => c.name, 'name', 'Mom'));
  });

  test('USDC to a fresh address opens its account', () async {
    final review = await sender([]).prepare(SendIntent(from: from, to: fresh, mint: usdcMint, amount: '1'));
    print(describe(review));
    expect(review.coin.symbol, 'USDC');
    expect(review.rent, isNotNull);
    expect(review.checks, isEmpty);
  });

  test('more than the wallet has', () async {
    await expectLater(sender([]).prepare(SendIntent(from: from, to: fresh, amount: '100000000')), throwsA(isA<SendFailure>().having((f) => f.reason, 'reason', SendReason.insufficient)));
  });

  test('a deposit address, found by its sweeps', () async {
    final page = await getActivity(rpc, jupiter, Network.mainnet, binanceHot, limit: 25);
    final senders = {for (final item in page.items) if (item.kind == ActivityKind.receive && item.counterparty != null) item.counterparty!};
    for (final address in senders.take(4)) {
      final info = await exchanges.addressInfo(address);
      print('$address: ${info.exchange} ${info.kind?.name} (${info.sweeps} sweeps of ${info.looked})');
    }
  });
}
