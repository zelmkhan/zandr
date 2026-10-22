// Base58 (Bitcoin's alphabet), how Solana writes addresses, signatures and keys.
import 'dart:typed_data';

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

String base58Encode(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  final out = StringBuffer();
  final base = BigInt.from(58);
  final digits = <String>[];
  while (value > BigInt.zero) {
    digits.add(_alphabet[(value % base).toInt()]);
    value = value ~/ base;
  }
  for (final byte in bytes) {
    if (byte != 0) break;
    out.write('1');
  }
  out.writeAll(digits.reversed);
  return out.toString();
}

// Null for text that isn't base58.
Uint8List? base58Decode(String text) {
  var value = BigInt.zero;
  final base = BigInt.from(58);
  for (final char in text.split('')) {
    final digit = _alphabet.indexOf(char);
    if (digit < 0) return null;
    value = value * base + BigInt.from(digit);
  }
  final bytes = <int>[];
  while (value > BigInt.zero) {
    bytes.add((value & BigInt.from(0xff)).toInt());
    value = value >> 8;
  }
  final zeros = text.split('').takeWhile((char) => char == '1').length;
  return Uint8List.fromList([...List.filled(zeros, 0), ...bytes.reversed]);
}

// A Solana address: 32 bytes in base58.
bool isAddress(String text) {
  if (text.length < 32 || text.length > 44) return false;
  return base58Decode(text)?.length == 32;
}
