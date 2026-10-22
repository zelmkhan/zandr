// Where the wallet keeps what must stay on this phone and nowhere else: the iOS Keychain.
//
// The vault (every recovery phrase and private key, encrypted with AES-256-GCM under a random
// vault key) is a Keychain item readable only while the phone is unlocked, never backed up, never
// synced to iCloud and never moved to another phone (kSecAttrAccessibleWhenUnlockedThisDeviceOnly).
// The Keychain itself encrypts it again under keys the Secure Enclave holds.
//
// The vault key is a second item, which the Keychain hands over only after Face ID or the
// iPhone's passcode, every time it's read (userPresence). It can exist only while the phone has a
// passcode: turning the passcode off deletes it for good (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly),
// and then only the recovery phrase brings the wallet back.
//
// The Keychain outlives the app: a phone keeps its items when the app is deleted. So the first
// launch after an install clears them, and deleting the app deletes the wallet, as users expect.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SecureKey {
  // The encrypted vault, as JSON.
  vault,
  // The encrypted address book: under a key derived from the vault key.
  addressBook,
  // The vault key, behind Face ID and the passcode.
  vaultKey,
  // What was last shown (the balances), sealed under a key derived from the vault key, to show at
  // once on the next unlock.
  cache,
}

// Why no vault key came: the person cancelled; iOS couldn't ask (the app wasn't in front, say);
// or the key is gone for good (the passcode was turned off), so only the recovery phrase helps.
enum KeyOutcome { cancelled, failed, gone }

class KeyFailure implements Exception {
  final KeyOutcome outcome;
  const KeyFailure(this.outcome);
}

abstract class SecureStore {
  Future<String?> read(SecureKey key);
  Future<void> write(SecureKey key, String value);
  Future<void> delete(SecureKey key);
  Future<void> deleteAll();
  // The vault key: asks for Face ID or the passcode. Throws KeyFailure.
  Future<String> readVaultKey();
  Future<void> writeVaultKey(String value);
}

class KeychainStore implements SecureStore {
  static const _plain = FlutterSecureStorage(
    iOptions: IOSOptions(accountName: 'app.zandr.wallet', accessibility: KeychainAccessibility.unlocked_this_device, synchronizable: false),
  );
  static const _guarded = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'app.zandr.wallet.key',
      accessibility: KeychainAccessibility.passcode,
      synchronizable: false,
      accessControlFlags: [AccessControlFlag.userPresence],
    ),
  );

  // errSecUserCanceled, errSecAuthFailed: the prompt was dismissed, or the face didn't match.
  static const _cancelled = {-128, -25293};

  // Clears what an earlier install left in the Keychain. App preferences (UserDefaults) go with
  // the app, so a missing mark means this is the first launch since installing.
  static Future<KeychainStore> open() async {
    final preferences = SharedPreferencesAsync();
    if (await preferences.getBool('installed') != true) {
      await _plain.deleteAll();
      await _guarded.deleteAll();
      await preferences.setBool('installed', true);
    }
    return KeychainStore();
  }

  @override
  Future<String?> read(SecureKey key) => _plain.read(key: key.name);
  @override
  Future<void> write(SecureKey key, String value) => _plain.write(key: key.name, value: value);
  @override
  Future<void> delete(SecureKey key) => key == SecureKey.vaultKey ? _guarded.delete(key: key.name) : _plain.delete(key: key.name);

  @override
  Future<void> deleteAll() async {
    await _plain.deleteAll();
    await _guarded.deleteAll();
  }

  @override
  Future<String> readVaultKey() async {
    String? value;
    try {
      value = await _guarded.read(key: SecureKey.vaultKey.name);
    } on PlatformException catch (error) {
      throw KeyFailure(_cancelled.contains(error.details) ? KeyOutcome.cancelled : KeyOutcome.failed);
    }
    // Only a key that isn't there is gone: any other error may pass, and says try again.
    if (value == null) throw const KeyFailure(KeyOutcome.gone);
    return value;
  }

  @override
  Future<void> writeVaultKey(String value) async {
    // An item behind Face ID and the passcode can't be overwritten in place without asking.
    await _guarded.delete(key: SecureKey.vaultKey.name);
    await _guarded.write(key: SecureKey.vaultKey.name, value: value);
  }
}

// In memory only: for tests and the browser preview, never for a real wallet.
class MemoryStore implements SecureStore {
  final _items = <SecureKey, String>{};
  // What the next Face ID or passcode prompt does, for tests.
  KeyOutcome? keyFails;

  @override
  Future<String?> read(SecureKey key) async => _items[key];
  @override
  Future<void> write(SecureKey key, String value) async => _items[key] = value;
  @override
  Future<void> delete(SecureKey key) async => _items.remove(key);
  @override
  Future<void> deleteAll() async => _items.clear();

  @override
  Future<String> readVaultKey() async {
    if (keyFails != null) throw KeyFailure(keyFails!);
    final value = _items[SecureKey.vaultKey];
    if (value == null) throw const KeyFailure(KeyOutcome.gone);
    return value;
  }

  @override
  Future<void> writeVaultKey(String value) async => _items[SecureKey.vaultKey] = value;
}
