// A vault and an address book sealed by the extension's algorithm (src/lib/vault.ts) open here,
// and what the app seals opens again.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/vault_crypto.dart';

const vector = r'{"password":"Пароль ü correct horse","vault":{"version":1,"kdf":{"name":"scrypt","N":131072,"r":8,"p":1,"salt":"YeHEk1RvnCGix+vYWQSKGKOuRbT4fkgoaKPHqWfmaTY="},"iv":"AkOZoE3U2xSLkSCd","ciphertext":"5U07irdnZqfKFb2ueDNZZiXZj7vSb9zPZ85Kzam+8uC60Wbtng6iKutEAD/mLipl8/yeguzYSmG8FME2zaIV0Rs6D6DEA4eYlnR7x7hu9UbMgmUImGzuFG7KTpkDMWbWUXFtMG4bDJN0EajcfJYXb25G10zpwn2gNodKttN8OGKsYVE/n0Jhm+W7ktkfPeewcLMokOxm1gDN9YmgEu6NUN9K55+ExzeWQZDHmFRkkX/imHT+vPurbRgcBZkjf2PFOHLmZ700O4WM8YyEf8O0ifD48/Cwftvl/gOcViupyMcu/0bI+5A/TIv3wuEcuNegVKyP73haPLXu/y2VawRuWL6DGFiGKubD2i9ECPowIVtds9dCQb9Gjdzg1npcWXSH27F3WjlaQOfn4VR5JtuvV38vB+g="},"contents":{"keyrings":[{"id":"k1","secret":{"kind":"phrase","words":["legal","winner","thank","year","wave","sausage","worth","useful","legal","winner","thank","yellow"]}}],"wallets":[{"id":"w1","name":"Main wallet","address":"BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX","keyring":"k1","account":0}]},"bookBlob":{"version":1,"iv":"bCD10vbnb90h+Mj6","ciphertext":"UjC04RrSKQs/X25wg7wD4Gnm7yb75Ce2egHT1p44FBP2CeuKU9CRYxmgbJRtL+ab4J/3MH8V/AGjVGMIetbR79aYtskWmE7VBBULn6Gl7nqmz+xvqaEbO/wXtyd/fYPEFNyngm0aDKF1CEiq2Q=="},"book":[{"id":"c1","name":"Bybit deposit","address":"EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK"}]}';

void main() {
  final data = jsonDecode(vector) as Map<String, dynamic>;
  final vault = SealedVault.fromJson((data['vault'] as Map).cast());

  test('opens a vault sealed by the extension', () async {
    final opened = await openWithPassword(vault, data['password'] as String);
    expect(opened, isNotNull);
    expect(jsonDecode(utf8.decode(opened!.plaintext)), data['contents']);
    expect(await openWithPassword(vault, 'wrong password'), isNull);
  });

  test('opens its address book with the HKDF sub-key', () async {
    final opened = await openWithPassword(vault, data['password'] as String);
    final key = await subKey(opened!.key, 'zandr address book v1');
    final plain = await openBlob((data['bookBlob'] as Map).cast(), key);
    expect(jsonDecode(utf8.decode(plain!)), data['book']);
  });

  test('seals and reopens, by password and by key; a changed byte fails', () async {
    final plaintext = Uint8List.fromList(utf8.encode('{"keyrings":[],"wallets":[]}'));
    final sealed = await sealWithPassword(plaintext, 'another password');
    expect((await openWithPassword(sealed.vault, 'another password'))!.plaintext, plaintext);
    final again = await resealWithKey(sealed.vault, sealed.key, plaintext);
    expect(again.iv, isNot(sealed.vault.iv));
    expect(await openWithKey(again, sealed.key), plaintext);
    final tampered = base64.decode(again.ciphertext)..[0] ^= 1;
    expect(await openWithKey(SealedVault(kdf: again.kdf, iv: again.iv, ciphertext: base64.encode(tampered)), sealed.key), isNull);
  });
}
