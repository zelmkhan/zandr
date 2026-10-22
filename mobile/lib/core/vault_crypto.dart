// The vault's encryption, in the extension's format (src/lib/vault.ts): AES-256-GCM under a key
// derived from the password with scrypt (N = 2^17, r = 8, p = 1: 128 MiB of memory per guess). Salt
// and IV are random; the KDF parameters are stored with the vault so they can be raised later.
// The ciphertext is WebCrypto's layout: the encrypted bytes, then the 16-byte tag.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pointycastle/export.dart' show Scrypt, ScryptParameters;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _scrypt = (n: 1 << 17, r: 8, p: 1);
final _random = Random.secure();
final _aes = AesGcm.with256bits();

Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

class Kdf {
  final int n, r, p;
  final String salt;
  const Kdf({required this.n, required this.r, required this.p, required this.salt});

  Map<String, Object> toJson() => {'name': 'scrypt', 'N': n, 'r': r, 'p': p, 'salt': salt};
  factory Kdf.fromJson(Map<String, Object?> json) {
    if (json['name'] != 'scrypt') throw const FormatException('Unknown KDF');
    return Kdf(n: json['N'] as int, r: json['r'] as int, p: json['p'] as int, salt: json['salt'] as String);
  }
}

// The vault as stored: everything in it is ciphertext but the KDF's parameters.
class SealedVault {
  final Kdf kdf;
  final String iv;
  final String ciphertext;
  const SealedVault({required this.kdf, required this.iv, required this.ciphertext});

  Map<String, Object> toJson() => {'version': 1, 'kdf': kdf.toJson(), 'iv': iv, 'ciphertext': ciphertext};
  factory SealedVault.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) throw const FormatException('Unknown vault version');
    return SealedVault(kdf: Kdf.fromJson((json['kdf'] as Map).cast()), iv: json['iv'] as String, ciphertext: json['ciphertext'] as String);
  }
}

// scrypt, off the UI thread: it takes a second or two.
Future<Uint8List> deriveVaultKey(String password, Kdf kdf) {
  // The same characters typed on another keyboard, which may compose accents differently, still open it.
  final input = Uint8List.fromList(utf8.encode(unorm.nfkc(password)));
  final salt = base64.decode(kdf.salt);
  Uint8List run() => (Scrypt()..init(ScryptParameters(kdf.n, kdf.r, kdf.p, 32, salt))).process(input);
  return kIsWeb ? Future(run) : Isolate.run(run);
}

Future<String> _encrypt(Uint8List plaintext, List<int> key, Uint8List iv) async {
  final box = await _aes.encrypt(plaintext, secretKey: SecretKey(key), nonce: iv);
  return base64.encode([...box.cipherText, ...box.mac.bytes]);
}

// Null when it doesn't decrypt: a wrong key, or a changed ciphertext.
Future<Uint8List?> _decrypt(String ciphertext, List<int> key, String iv) async {
  final bytes = base64.decode(ciphertext);
  if (bytes.length < 16) return null;
  try {
    final plain = await _aes.decrypt(
      SecretBox(bytes.sublist(0, bytes.length - 16), nonce: base64.decode(iv), mac: Mac(bytes.sublist(bytes.length - 16))),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

// Encrypts under a password with a fresh salt and IV and today's parameters. The derived key comes
// back too, for the session (and Face ID); the caller wipes it.
Future<({SealedVault vault, Uint8List key})> sealWithPassword(Uint8List plaintext, String password) async {
  final kdf = Kdf(n: _scrypt.n, r: _scrypt.r, p: _scrypt.p, salt: base64.encode(randomBytes(32)));
  final key = await deriveVaultKey(password, kdf);
  final iv = randomBytes(12);
  return (vault: SealedVault(kdf: kdf, iv: base64.encode(iv), ciphertext: await _encrypt(plaintext, key, iv)), key: key);
}

// Re-encrypts under the same key (and so the same password), with a fresh IV.
Future<SealedVault> resealWithKey(SealedVault vault, Uint8List key, Uint8List plaintext) async {
  final iv = randomBytes(12);
  return SealedVault(kdf: vault.kdf, iv: base64.encode(iv), ciphertext: await _encrypt(plaintext, key, iv));
}

Future<Uint8List?> openWithKey(SealedVault vault, Uint8List key) => _decrypt(vault.ciphertext, key, vault.iv);

// The plaintext and the derived key, or null if the password is wrong.
Future<({Uint8List plaintext, Uint8List key})?> openWithPassword(SealedVault vault, String password) async {
  final key = await deriveVaultKey(password, vault.kdf);
  final plaintext = await openWithKey(vault, key);
  if (plaintext == null) {
    key.fillRange(0, key.length, 0);
    return null;
  }
  return (plaintext: plaintext, key: key);
}

// A key for something kept beside the vault (the address book, the cache), derived from the vault
// key with HKDF-SHA256 as the extension does, so no two things share a key.
Future<List<int>> subKey(Uint8List vaultKey, String info) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(secretKey: SecretKey(vaultKey), nonce: Uint8List(32), info: utf8.encode(info));
  return key.extractBytes();
}

// Something small sealed under a sub-key: {version, iv, ciphertext}.
Future<Map<String, Object>> sealBlob(Uint8List plaintext, List<int> key) async {
  final iv = randomBytes(12);
  return {'version': 1, 'iv': base64.encode(iv), 'ciphertext': await _encrypt(plaintext, key, iv)};
}

Future<Uint8List?> openBlob(Map<String, Object?> blob, List<int> key) => _decrypt(blob['ciphertext'] as String, key, blob['iv'] as String);
