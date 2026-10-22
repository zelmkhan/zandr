// The app's vault and session (lib/app/vault.dart), in memory: what the Keychain would hold.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/app/preferences.dart';
import 'package:zandr/app/store.dart';
import 'package:zandr/app/vault.dart';
import 'package:zandr/core/secrets.dart';

const phrase = ['legal', 'winner', 'thank', 'year', 'wave', 'sausage', 'worth', 'useful', 'legal', 'winner', 'thank', 'yellow'];
const address = 'BLeUXTx9thHGT7VJUtF9vHEmfMDgW1nnKZ9UVer2CoLX';

void main() {
  late MemoryStore store;
  late MemoryPreferences preferences;
  late Vault vault;

  setUp(() {
    store = MemoryStore();
    preferences = MemoryPreferences();
    vault = Vault(store, preferences);
  });

  Future<void> create() => vault.create(
        const VaultContents([Keyring('k1', PhraseSecret(phrase))], [WalletEntry(id: 'w1', name: 'Main wallet', address: address, keyring: 'k1')]),
      );

  Matcher fails(KeyOutcome outcome) => throwsA(isA<KeyFailure>().having((f) => f.outcome, 'outcome', outcome));

  test('the vault is sealed under a random key kept apart from it', () async {
    await create();
    final sealed = (await store.read(SecureKey.vault))!;
    expect(sealed, isNot(contains('legal')));
    expect(sealed, isNot(contains(address)));
    expect(base64.decode(await store.readVaultKey()), hasLength(32));
  });

  test('unlocks with the key Face ID or the passcode releases; cancelled stays locked', () async {
    await create();
    vault.lock();
    await vault.unlock();
    expect(vault.active!.address, address);
    vault.lock();
    store.keyFails = KeyOutcome.cancelled;
    await expectLater(vault.unlock(), fails(KeyOutcome.cancelled));
    expect(vault.unlocked, isFalse);
    store.keyFails = KeyOutcome.failed;
    await expectLater(vault.unlock(), fails(KeyOutcome.failed));
    expect(await vault.hasVault(), isTrue);
  });

  test('a key gone, or one that doesn\'t open the vault, is gone; starting over clears everything', () async {
    await create();
    await vault.addContact('Mom', 'EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK');
    vault.lock();
    await store.writeVaultKey(base64.encode(List.filled(32, 7)));
    await expectLater(vault.unlock(), fails(KeyOutcome.gone));
    await store.delete(SecureKey.vaultKey);
    await expectLater(vault.unlock(), fails(KeyOutcome.gone));
    await vault.eraseEverything();
    expect(await vault.hasVault(), isFalse);
    expect(await store.read(SecureKey.addressBook), isNull);
  });

  test('wallets: import, duplicate, phrase and key export, remove, reorder', () async {
    await create();
    final key = await privateKeyOf(const PhraseSecret(phrase), 0);
    expect(await vault.importWallet(KeySecret(key), 'Same'), isA<NotAdded>().having((n) => n.conflict, 'conflict', 'Main wallet'));
    final added = await vault.importWallet(const PhraseSecret(['abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about']), 'Second');
    expect(added, isA<Added>());
    expect(vault.active!.name, 'Second');
    final exported = await vault.exportPhrase('w1');
    expect(exported.words, phrase);
    expect(await vault.exportPrivateKey('w1'), key);
    // Showing a secret or removing a wallet asks again, even while unlocked.
    store.keyFails = KeyOutcome.cancelled;
    await expectLater(vault.exportPhrase('w1'), fails(KeyOutcome.cancelled));
    await expectLater(vault.removeWallet('w1'), fails(KeyOutcome.cancelled));
    expect(vault.wallets, hasLength(2));
    store.keyFails = null;
    await vault.reorderWallets([vault.wallets[1].id, 'w1']);
    expect(vault.wallets.first.name, 'Second');
    expect(await vault.removeWallet('w1'), isTrue);
    expect(await vault.removeWallet(vault.wallets.single.id), isFalse);
  });

  test('signs only as the active wallet', () async {
    await create();
    final message = utf8.encode('hello');
    final [signature] = await vault.sign(address, [message]);
    expect(await verifySignature(address, message, signature), isTrue);
    await expectLater(vault.sign('EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK', [message]), throwsStateError);
    vault.lock();
    await expectLater(vault.sign(address, [message]), throwsA(isA<LockedError>()));
  });

  test('the address book refuses lookalikes, and a changed one fails verification', () async {
    await create();
    await vault.addContact('Mom', 'EdjcxP8MmXP4yRHguEVoH75kbXVfZNFXPgNfL9NqcXXK');
    await expectLater(vault.addContact('Fake', 'Edjc1111111111111111111111111111111111qcXXK'), throwsA(isA<ContactRefused>()));
    final blob = jsonDecode((await store.read(SecureKey.addressBook))!) as Map;
    final bytes = base64.decode(blob['ciphertext'] as String)..[3] ^= 1;
    await store.write(SecureKey.addressBook, jsonEncode({...blob, 'ciphertext': base64.encode(bytes)}));
    await expectLater(vault.readAddressBook(), throwsA(isA<TamperedError>()));
  });
}
