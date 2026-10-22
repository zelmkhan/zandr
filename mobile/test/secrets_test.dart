// Expected values computed by the extension's own key code (src/lib/secrets.ts), so the phone and
// the browser agree on every address and signature.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/base58.dart';
import 'package:zandr/core/secrets.dart';

const words = ["legal","winner","thank","year","wave","sausage","worth","useful","legal","winner","thank","yellow"];

void main() {
  test('the same addresses as the extension, accounts 0 to 2', () async {
    for (final (index, expected) in ["BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX","EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK","AFG4eoTGSCdNemYFQhhJBqT7tJwo3WdC4Raeq9SkXx7p"].indexed) {
      expect(await addressOf(const PhraseSecret(words), index), expected);
    }
  });

  test('the same private key and signature', () async {
    expect(await privateKeyOf(const PhraseSecret(words), 0), '37NfN7eam3KCwdC6jAc7nFeuDNYCV1K2AgNWmT4Xo6ogQPMnJ1ZoWA7AKN6jzEoQi3FNTEkkXiwu7VjqXdu8FGUs');
    final signed = await signMessage(const PhraseSecret(words), 0, Uint8List.fromList(utf8.encode('zandr test message')));
    expect(base58Encode(signed.signature), '32nfZX6FMwrT2gM9WzxbS45HT1KiDtxH97aA6MrfVY8siF2bxWtJpAdGYWhxgK34DQLCQA77DgpRRVVLbpAkuLvd');
    expect(signed.address, 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX');
    expect(await verifySignature(signed.address, Uint8List.fromList(utf8.encode('zandr test message')), signed.signature), isTrue);
  });

  test('a private key imports as its own address', () async {
    expect(await addressOf(const KeySecret('4xCo9XupVA5jscDH1CLcHrdoUCYJSi5EaVS24L9oJfwvgNSY7hkeZHFFaPFu4kD4oPr6q3pFj85ZtT3vgqk8mDDP')), 'EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK');
    expect(await parsePrivateKey('4xCo9XupVA5jscDH1CLcHrdoUCYJSi5EaVS24L9oJfwvgNSY7hkeZHFFaPFu4kD4oPr6q3pFj85ZtT3vgqk8mDD1'), isNull);
  });

  test('phrases are checked as the extension checks them', () async {
    expect(await checkSecret(const PhraseSecret(words)), isNull);
    expect((await checkSecret(PhraseSecret('legal winner thank year wave sausage worth useful legal winner thank thank'.split(' '))))?.error, SecretError.checksum);
    expect(await checkSecret(PhraseSecret('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art'.split(' '))), isNull);
    expect((await checkSecret(PhraseSecret('legal winner thank'.split(' '))))?.error, SecretError.wordCount);
    expect((await checkSecret(PhraseSecret('legal winner thank year wave sausage worth useful legal winner thank zzz'.split(' '))))?.index, 11);
  });

  test('a new phrase is 12 valid words', () async {
    final phrase = await generatePhrase();
    expect(phrase.length, 12);
    expect(await checkSecret(PhraseSecret(phrase)), isNull);
  });

  test('base58 round trip', () {
    final bytes = Uint8List.fromList([0, 0, 1, 2, 3, 255]);
    expect(base58Decode(base58Encode(bytes)), bytes);
    expect(isAddress('BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX'), isTrue);
    expect(isAddress('not an address'), isFalse);
  });
}
