// Solana addresses: the programs the wallet talks to, and derived addresses (src/lib/solana/addresses.ts).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import '../base58.dart';

const systemProgram = '11111111111111111111111111111111';
const tokenProgram = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const token2022Program = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const associatedTokenProgram = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const computeBudgetProgram = 'ComputeBudget111111111111111111111111111111';
const lookupTableProgram = 'AddressLookupTab1e1111111111111111111111111';
const memoProgram = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
const jupiterProgram = 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4';
// SOL as a token, for swaps and token lists.
const wrappedSol = 'So11111111111111111111111111111111111111112';
const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

Uint8List? decodeAddress(String address) {
  final bytes = base58Decode(address);
  return bytes != null && bytes.length == 32 ? bytes : null;
}

final _p = BigInt.two.pow(255) - BigInt.from(19);
final _d = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final _sqrtMinusOneSquaredCheck = BigInt.from(-1) % _p;

// Whether 32 bytes are an ed25519 public key (a point on the curve), one a private key could sign
// for. Program-derived addresses are deliberately off it: no key exists for them. Decompresses the
// point as RFC 8032 does: y must be below p, and x² = (y² − 1)/(d·y² + 1) must have a root.
bool isOnCurve(Uint8List bytes) {
  if (bytes.length != 32) return false;
  final copy = Uint8List.fromList(bytes);
  final sign = copy[31] >> 7;
  copy[31] &= 0x7f;
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(copy[i]);
  }
  if (y >= _p) return false;
  final y2 = (y * y) % _p;
  final u = (y2 - BigInt.one) % _p;
  final v = (_d * y2 + BigInt.one) % _p;
  final v3 = (v * v % _p) * v % _p;
  final v7 = (v3 * v3 % _p) * v % _p;
  var x = (u * v3 % _p) * (u * v7 % _p).modPow((_p - BigInt.from(5)) >> 3, _p) % _p;
  final vx2 = v * x % _p * x % _p;
  if (vx2 != u) {
    if (vx2 != (_sqrtMinusOneSquaredCheck * u) % _p) return false;
    x = x * BigInt.two.modPow((_p - BigInt.one) >> 2, _p) % _p;
  }
  if (x == BigInt.zero && sign == 1) return false;
  return true;
}

// The program-derived address for these seeds: the first hash, from bump 255 down, that is off the
// curve, as the runtime's find_program_address does.
String findProgramAddress(List<Uint8List> seeds, String program) {
  final programBytes = base58Decode(program)!;
  final marker = utf8.encode('ProgramDerivedAddress');
  for (var bump = 255; bump >= 0; bump--) {
    final hash = Uint8List.fromList(const DartSha256().hashSync([...seeds.expand((seed) => seed), bump, ...programBytes, ...marker]).bytes);
    if (!isOnCurve(hash)) return base58Encode(hash);
  }
  throw StateError('No program address for these seeds');
}

// The token account a wallet holds a token in, by convention: what wallets and exchanges send to.
String associatedTokenAddress(String owner, String mint, String program) =>
    findProgramAddress([base58Decode(owner)!, base58Decode(program)!, base58Decode(mint)!], associatedTokenProgram);
