// Recovery phrases and private keys, as the extension handles them (src/lib/secrets.ts): the same
// phrase gives the same addresses on the phone as in the browser. Keys are derived when needed and
// their bytes wiped after use (Dart's own copies aside: strings can't be wiped).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base58.dart';
import 'wordlist.dart';

// A wallet's secret: a recovery phrase (the wallet is one of its accounts), or a private key.
sealed class WalletSecret {
  const WalletSecret();

  Map<String, Object> toJson();

  static WalletSecret fromJson(Map<String, Object?> json) => switch (json['kind']) {
        'phrase' => PhraseSecret((json['words'] as List).cast<String>()),
        'privateKey' => KeySecret(json['key'] as String),
        _ => throw const FormatException('Unknown secret'),
      };
}

class PhraseSecret extends WalletSecret {
  final List<String> words;
  const PhraseSecret(this.words);

  @override
  Map<String, Object> toJson() => {'kind': 'phrase', 'words': words};
}

class KeySecret extends WalletSecret {
  // Base58 of the 64-byte secret key.
  final String key;
  const KeySecret(this.key);

  @override
  Map<String, Object> toJson() => {'kind': 'privateKey', 'key': key};
}

// Why a secret can't be used.
enum SecretError { wordCount, unknownWord, checksum, invalidKey }

final _random = Random.secure();
final _sha256 = Sha256();
final _hmacSha512 = Hmac.sha512();
final _ed25519 = Ed25519();

// Account N of a phrase is m/44'/501'/N'/0', as in Phantom, Solflare and the extension.
List<int> _solanaPath(int account) => [44, 501, account, 0];

// 12 words, 128 bits of entropy, as most Solana wallets use.
Future<List<String>> generatePhrase() async {
  final entropy = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
  final words = await _entropyToWords(entropy);
  entropy.fillRange(0, entropy.length, 0);
  return words;
}

Future<List<String>> _entropyToWords(Uint8List entropy) async {
  final hash = (await _sha256.hash(entropy)).bytes;
  final bits = StringBuffer();
  for (final byte in entropy) {
    bits.write(byte.toRadixString(2).padLeft(8, '0'));
  }
  bits.write(hash[0].toRadixString(2).padLeft(8, '0').substring(0, entropy.length * 8 ~/ 32));
  final text = bits.toString();
  return [for (var i = 0; i < text.length; i += 11) wordlist[int.parse(text.substring(i, i + 11), radix: 2)]];
}

List<String> normalizeWords(List<String> words) => [for (final word in words) word.trim().toLowerCase()];

// Null when the secret can be used; otherwise why not, and for an unknown word, which one.
Future<({SecretError error, int? index})?> checkSecret(WalletSecret secret) async {
  switch (secret) {
    case KeySecret(:final key):
      return await parsePrivateKey(key) == null ? (error: SecretError.invalidKey, index: null) : null;
    case PhraseSecret(:final words):
      final normal = normalizeWords(words);
      if (normal.length != 12 && normal.length != 24) return (error: SecretError.wordCount, index: null);
      final unknown = normal.indexWhere((word) => !wordlist.contains(word));
      if (unknown >= 0) return (error: SecretError.unknownWord, index: unknown);
      return await _checksumOk(normal) ? null : (error: SecretError.checksum, index: null);
  }
}

Future<bool> _checksumOk(List<String> words) async {
  final bits = words.map((word) => wordlist.indexOf(word).toRadixString(2).padLeft(11, '0')).join();
  final entropyBits = bits.length * 32 ~/ 33;
  final entropy = Uint8List.fromList([for (var i = 0; i < entropyBits; i += 8) int.parse(bits.substring(i, i + 8), radix: 2)]);
  final expected = await _entropyToWords(entropy);
  entropy.fillRange(0, entropy.length, 0);
  return expected.join(' ') == words.join(' ');
}

// The one form a valid secret is stored in: lowercase words, or the 64-byte key in base58.
Future<WalletSecret> canonicalSecret(WalletSecret secret) async {
  switch (secret) {
    case PhraseSecret(:final words):
      return PhraseSecret(normalizeWords(words));
    case KeySecret(:final key):
      final bytes = await parsePrivateKey(key);
      if (bytes == null) throw const FormatException('Invalid private key');
      final canonical = base58Encode(bytes);
      bytes.fillRange(0, bytes.length, 0);
      return KeySecret(canonical);
  }
}

// BIP-39: the 64-byte seed of a phrase (no passphrase).
Future<Uint8List> _seedOf(List<String> words) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: _hmacSha512, iterations: 2048, bits: 512);
  final key = await pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(words.join(' '))), nonce: utf8.encode('mnemonic'));
  return Uint8List.fromList(await key.extractBytes());
}

// SLIP-0010 for ed25519, hardened steps only. Intermediate keys are wiped as the next comes.
Future<Uint8List> deriveEd25519(Uint8List seed, List<int> path) async {
  var node = Uint8List.fromList((await _hmacSha512.calculateMac(seed, secretKey: SecretKey(utf8.encode('ed25519 seed')))).bytes);
  for (final index in path) {
    final data = Uint8List(37);
    data.setRange(1, 33, node.sublist(0, 32));
    ByteData.view(data.buffer).setUint32(33, (index | 0x80000000) & 0xffffffff);
    final child = Uint8List.fromList((await _hmacSha512.calculateMac(data, secretKey: SecretKey(node.sublist(32)))).bytes);
    node.fillRange(0, node.length, 0);
    data.fillRange(0, data.length, 0);
    node = child;
  }
  final key = Uint8List.fromList(node.sublist(0, 32));
  node.fillRange(0, node.length, 0);
  return key;
}

Future<Uint8List> _publicKeyOf(Uint8List privateKey) async {
  final pair = await _ed25519.newKeyPairFromSeed(privateKey);
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}

// A private key as wallets export it: base58 of 64 bytes, or a JSON byte array (CLI keypair
// files). Its last 32 bytes are the public key and must match the first 32, so a mistyped key is
// refused rather than importing a different wallet.
Future<Uint8List?> parsePrivateKey(String input) async {
  final value = input.trim();
  Uint8List? bytes;
  if (value.startsWith('[')) {
    try {
      final array = jsonDecode(value);
      if (array is! List || !array.every((n) => n is int && n >= 0 && n <= 255)) return null;
      bytes = Uint8List.fromList(array.cast<int>());
    } on FormatException {
      return null;
    }
  } else {
    bytes = base58Decode(value);
  }
  if (bytes == null || bytes.length != 64) return null;
  final publicKey = await _publicKeyOf(Uint8List.fromList(bytes.sublist(0, 32)));
  for (var i = 0; i < 32; i++) {
    if (publicKey[i] != bytes[32 + i]) {
      bytes.fillRange(0, bytes.length, 0);
      return null;
    }
  }
  return bytes;
}

// The 32-byte private key of account N of a phrase, or of a private key.
Future<Uint8List> _privateKeyBytes(WalletSecret secret, int account) async {
  switch (secret) {
    case KeySecret(:final key):
      final bytes = (await parsePrivateKey(key))!;
      final privateKey = Uint8List.fromList(bytes.sublist(0, 32));
      bytes.fillRange(0, bytes.length, 0);
      return privateKey;
    case PhraseSecret(:final words):
      final seed = await _seedOf(words);
      final privateKey = await deriveEd25519(seed, _solanaPath(account));
      seed.fillRange(0, seed.length, 0);
      return privateKey;
  }
}

// The address of account N of a valid, canonical secret.
Future<String> addressOf(WalletSecret secret, [int account = 0]) async {
  final privateKey = await _privateKeyBytes(secret, account);
  try {
    return base58Encode(await _publicKeyOf(privateKey));
  } finally {
    privateKey.fillRange(0, privateKey.length, 0);
  }
}

// The private key as wallets export it: base58 of the 64-byte secret key.
Future<String> privateKeyOf(WalletSecret secret, [int account = 0]) async {
  if (secret is KeySecret) return secret.key;
  final privateKey = await _privateKeyBytes(secret, account);
  final full = Uint8List(64)
    ..setRange(0, 32, privateKey)
    ..setRange(32, 64, await _publicKeyOf(privateKey));
  privateKey.fillRange(0, 32, 0);
  final key = base58Encode(full);
  full.fillRange(0, 64, 0);
  return key;
}

// Signs as the wallet; its address comes back so the caller can check it signed as the one meant.
Future<({Uint8List signature, String address})> signMessage(WalletSecret secret, int account, Uint8List message) async {
  final privateKey = await _privateKeyBytes(secret, account);
  try {
    final pair = await _ed25519.newKeyPairFromSeed(privateKey);
    final signature = await _ed25519.sign(message, keyPair: pair);
    return (signature: Uint8List.fromList(signature.bytes), address: base58Encode((await pair.extractPublicKey()).bytes));
  } finally {
    privateKey.fillRange(0, privateKey.length, 0);
  }
}

// Whether `signature` is the address's over `message`.
Future<bool> verifySignature(String address, Uint8List message, Uint8List signature) async {
  final publicKey = base58Decode(address);
  if (publicKey == null || publicKey.length != 32 || signature.length != 64) return false;
  return _ed25519.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
}
