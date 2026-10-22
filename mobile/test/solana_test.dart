// The same bytes as the extension's Solana code (src/lib/solana/*.ts): derived addresses, legacy
// and v0 messages, and decoding them back.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/core/base58.dart';
import 'package:zandr/core/solana/addresses.dart';
import 'package:zandr/core/solana/message.dart';
import 'package:zandr/core/solana/transaction.dart';

const owner = 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX';
const to = 'EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK';
const blockhash = 'AFG4eoTGSCdNemYFQhhJBqT7tJwo3WdC4Raeq9SkXx7p';
const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

void main() {
  test('token account addresses and the curve', () {
    expect(associatedTokenAddress(owner, usdc, tokenProgram), 'HpjzXPf8y9CNLxRPZDKFXH7kvKtkfX4BKpxnmsG23vuE');
    expect(associatedTokenAddress(owner, usdc, token2022Program), '4kEQtAam96NSSrSn92wZnDDQEhjgrToEqUm3WCTdVLH8');
    expect(associatedTokenAddress(to, usdc, tokenProgram), '2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR');
    expect(isOnCurve(base58Decode(owner)!), true);
    expect(isOnCurve(base58Decode('HpjzXPf8y9CNLxRPZDKFXH7kvKtkfX4BKpxnmsG23vuE')!), false);
  });

  test('legacy messages, byte for byte', () {
    final legacy = compileMessage(owner, [setComputeUnitLimit(450), setComputeUnitPrice(BigInt.from(1000)), transferSol(owner, to, BigInt.from(1234567))], blockhash);
    expect(base64.encode(legacy), 'AQACBJmdRvs9Elb3BJyO0JMU1yaGEuipG4AOkZNEY4SDBcmMypEHl5LrU/m9TjEI100lDLwV2o3Poghq9f8Fqtk4qy4DBkZv5SEXMv/srbpyw5vnvIzlu8X3EmssQ5s6QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiWBYbLIAEdmU9gUJGKlqviS6V+3dODaGZi2RWkl45EcDAgAFAsIBAAACAAkD6AMAAAAAAAADAgABDAIAAACH1hIAAAAAAA==');
    final token = compileMessage(owner, [
      createTokenAccount(owner, '2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR', to, usdc, tokenProgram),
      transferTokens(tokenProgram, 'HpjzXPf8y9CNLxRPZDKFXH7kvKtkfX4BKpxnmsG23vuE', usdc, '2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR', owner, BigInt.from(5000000), 6),
    ], blockhash);
    expect(base64.encode(token), 'AQAFCJmdRvs9Elb3BJyO0JMU1yaGEuipG4AOkZNEY4SDBcmMGfXRVonClk05UKJ2qkp+o01bAH6rcX/WiSqmMT+GY7L59eZaz0sPeb83Eq6avICOQIlqSqEYPwU+KmuCzsG/icqRB5eS61P5vU4xCNdNJQy8FdqNz6IIavX/BarZOKsuxvp6877brTo9ZfNqq8l0MbG75MLS9uDkfKYCA0UvXWEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAbd9uHXZaGT2cvhRs7reawctIXtX1s3kTqM9YV+/wCpjJclj04kifG7PRApFI4NgwtaE5na/xCEBI572Nvp+FmJYFhssgAR2ZT2BQkYqWq+JLpX7d04NoZmLZFaSXjkRwIHBgABAwQFBgEBBgQCBAEACgxAS0wAAAAAAAY=');
  });

  test('a v0 message with a lookup table, byte for byte, and decoded back', () {
    final tables = {'7MqQi3jKDdDkE9WQ7cTQ1LRzAhKjrWqHQgGMgZ7XrWtz': ["EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR","TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA","HpjzXPf8y9CNLxRPZDKFXH7kvKtkfX4BKpxnmsG23vuE","11111111111111111111111111111111"]};
    final v0 = compileV0Message(owner, [
      createTokenAccount(owner, '2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR', to, usdc, tokenProgram),
      transferTokens(tokenProgram, 'HpjzXPf8y9CNLxRPZDKFXH7kvKtkfX4BKpxnmsG23vuE', usdc, '2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR', owner, BigInt.from(5000000), 6),
      transferSol(owner, to, BigInt.one),
    ], blockhash, tables);
    expect(base64.encode(v0), 'gAEAAwWZnUb7PRJW9wScjtCTFNcmhhLoqRuADpGTRGOEgwXJjMqRB5eS61P5vU4xCNdNJQy8FdqNz6IIavX/BarZOKsuAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAG3fbh12Whk9nL4UbO63msHLSF7V9bN5E6jPWFfv8AqYyXJY9OJInxuz0QKRSODYMLWhOZ2v8QhASOe9jb6fhZiWBYbLIAEdmU9gUJGKlqviS6V+3dODaGZi2RWkl45EcDBAYABQEHAgMBAQMEBgcFAAoMQEtMAAAAAAAGAgIAAQwCAAAAAQAAAAAAAAABXnx5Q92QjvyH1HRlwb0B5e4uXngICYQmYL4Wq4usw6MCAQMBAA==');
    final decoded = decodeTransaction(serializeTransaction(v0, [Uint8List(64)]));
    expect(decoded.message.versioned, isTrue);
    expect(decoded.message.staticKeys.first, owner);
    final keys = accountKeys(decoded.message, tables);
    expect(keys[decoded.message.instructions.last.program], systemProgram);
    expect(keys.contains('2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR'), isTrue);
    expect(decoded.message.isWritable(keys.indexOf('2kLbWCj63Phx5wpgN561j4zbbuYGRd9C1xZbgdLm5xUR')), isTrue);
    expect(decoded.message.isWritable(keys.indexOf(usdc)), isFalse);
  });
}
