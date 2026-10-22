// The encrypted wallet and the unlocked session (src/lib/wallets.ts, addressBook.ts), kept in the
// Keychain (store.dart): the vault under a random key that only Face ID or the iPhone's passcode
// releases. There's no password of Zandr's own.
//
// While unlocked, the app holds only the vault key in memory, never a phrase: phrases and keys are
// decrypted for the moment a signature or an export needs them, then the bytes are wiped (Dart's
// own copies of text aside: strings can't be wiped). Locking forgets the key.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/base58.dart';
import '../core/secrets.dart';
import '../core/send.dart' show lookalike;
import '../core/vault_crypto.dart';
import 'preferences.dart';
import 'store.dart';

const walletNameMaxLength = 32;
const contactNameMaxLength = 32;
const defaultWalletName = 'Main wallet';

String newId() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = [for (final byte in b) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// A keyring is a recovery phrase or a private key; each wallet is one address from a keyring:
// account N of a phrase, or the key's only address (N = 0).
class Keyring {
  final String id;
  final WalletSecret secret;
  const Keyring(this.id, this.secret);
  Map<String, Object> toJson() => {'id': id, 'secret': secret.toJson()};
}

class WalletEntry {
  final String id, name, address, keyring;
  final int account;
  const WalletEntry({required this.id, required this.name, required this.address, required this.keyring, this.account = 0});
  Map<String, Object> toJson() => {'id': id, 'name': name, 'address': address, 'keyring': keyring, 'account': account};
}

class VaultContents {
  final List<Keyring> keyrings;
  final List<WalletEntry> wallets;
  const VaultContents(this.keyrings, this.wallets);

  Map<String, Object> toJson() => {'keyrings': [for (final k in keyrings) k.toJson()], 'wallets': [for (final w in wallets) w.toJson()]};

  // The first extension vaults held a single wallet: read as a list of one.
  factory VaultContents.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('wallets')) {
      return VaultContents(
        [Keyring('keyring-1', WalletSecret.fromJson((json['secret'] as Map).cast()))],
        [WalletEntry(id: 'wallet-1', name: json['name'] as String? ?? defaultWalletName, address: json['address'] as String, keyring: 'keyring-1')],
      );
    }
    return VaultContents(
      [for (final k in (json['keyrings'] as List).cast<Map>()) Keyring(k['id'] as String, WalletSecret.fromJson((k['secret'] as Map).cast()))],
      [
        for (final w in (json['wallets'] as List).cast<Map>())
          WalletEntry(id: w['id'] as String, name: w['name'] as String, address: w['address'] as String, keyring: w['keyring'] as String, account: (w['account'] as int?) ?? 0),
      ],
    );
  }
}

enum WalletSource { phrase, privateKey }

// A wallet as the app lists it: no secrets, only where it came from.
class WalletSummary {
  final String id, name, address;
  final WalletSource source;
  const WalletSummary(this.id, this.name, this.address, this.source);
}

class Contact {
  final String id, name, address;
  final int addedAt;
  const Contact(this.id, this.name, this.address, this.addedAt);
  Map<String, Object> toJson() => {'id': id, 'name': name, 'address': address, 'addedAt': addedAt};
  factory Contact.fromJson(Map json) => Contact(json['id'] as String, json['name'] as String, json['address'] as String, (json['addedAt'] as num?)?.toInt() ?? 0);
}

class LockedError implements Exception {
  const LockedError();
}

// The stored address book failed verification: changed outside zandr.
class TamperedError implements Exception {
  const TamperedError();
}

sealed class AddResult {
  const AddResult();
}

class Added extends AddResult {
  final WalletSummary wallet;
  const Added(this.wallet);
}

enum AddError { name, secret, duplicate }

class NotAdded extends AddResult {
  final AddError error;
  final String? conflict;
  const NotAdded(this.error, [this.conflict]);
}

enum ContactError { name, invalidAddress, ownAddress, duplicate, lookalike }

class ContactRefused implements Exception {
  final ContactError error;
  final String? conflict;
  const ContactRefused(this.error, [this.conflict]);
}

List<WalletSummary> _summaries(VaultContents contents) => [
      for (final wallet in contents.wallets)
        WalletSummary(
          wallet.id,
          wallet.name,
          wallet.address,
          contents.keyrings.where((k) => k.id == wallet.keyring).firstOrNull?.secret is PhraseSecret ? WalletSource.phrase : WalletSource.privateKey,
        ),
    ];

void _wipe(Uint8List? bytes) => bytes?.fillRange(0, bytes.length, 0);

class Vault {
  final SecureStore store;
  final PreferenceStore preferences;
  Vault(this.store, this.preferences);

  Uint8List? _key;
  List<WalletSummary> _wallets = const [];
  String? _activeId;

  bool get unlocked => _key != null;
  List<WalletSummary> get wallets => _key == null ? const [] : _wallets;
  WalletSummary? get active => _key == null ? null : _wallets.where((w) => w.id == _activeId).firstOrNull;

  // Writes run one at a time, so two quick requests can't both pass a check and the second
  // overwrite the first.
  Future<void> _writes = Future.value();
  Future<T> _serialized<T>(Future<T> Function() write) {
    final task = _writes.then((_) => write());
    _writes = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<Map<String, Object?>?> _readVault() async {
    final text = await store.read(SecureKey.vault);
    return text == null ? null : (jsonDecode(text) as Map).cast();
  }

  Future<bool> hasVault() async => await store.read(SecureKey.vault) != null;

  Future<void> _writeVault(Uint8List plaintext, Uint8List key) async => store.write(SecureKey.vault, jsonEncode(await sealBlob(plaintext, key)));

  // The contents under `key`, or null if the vault doesn't open with it.
  Future<VaultContents?> _openWith(Uint8List key) async {
    final vault = await _readVault();
    if (vault == null) throw StateError('There is no wallet');
    final plaintext = await openBlob(vault, key);
    if (plaintext == null) return null;
    try {
      return VaultContents.fromJson((jsonDecode(utf8.decode(plaintext)) as Map).cast());
    } finally {
      _wipe(plaintext);
    }
  }

  Future<void> _startSession(Uint8List key, VaultContents contents) async {
    _wipe(_key);
    _key = Uint8List.fromList(key);
    _wallets = _summaries(contents);
    final remembered = (await preferences.load()).activeWallet;
    _activeId = _wallets.where((w) => w.id == remembered).firstOrNull?.id ?? _wallets.first.id;
  }

  void lock() {
    _wipe(_key);
    _key = null;
    _wallets = const [];
    _activeId = null;
  }

  // Every wallet, key and saved address on this phone, gone; the preferences reset.
  Future<void> eraseEverything() async {
    lock();
    await store.deleteAll();
    await preferences.save(const Preferences());
  }

  // Encrypts and stores a new vault under a new random key, kept behind Face ID and the passcode,
  // then unlocks it. Never overwrites an existing one.
  Future<void> create(VaultContents contents) => _serialized(() async {
        if (await hasVault()) throw StateError('A wallet already exists');
        final key = randomBytes(32);
        final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(contents.toJson())));
        try {
          // The key first: a vault stored without it could never be opened.
          await store.writeVaultKey(base64.encode(key));
          await _writeVault(plaintext, key);
          // An address book left from no wallet at all can't belong to this one.
          await store.delete(SecureKey.addressBook);
          await preferences.save((await preferences.load()).copyWith(activeWallet: () => contents.wallets.first.id));
          await _startSession(key, contents);
        } finally {
          _wipe(plaintext);
          _wipe(key);
        }
      });

  // The vault key and what it opens, once Face ID or the passcode says it's the owner. Throws
  // KeyFailure: gone, too, for a key that doesn't open the vault. The caller wipes the key.
  Future<({Uint8List key, VaultContents contents})> _owner() async {
    final key = Uint8List.fromList(base64.decode(await store.readVaultKey()));
    final contents = await _openWith(key);
    if (contents == null) {
      _wipe(key);
      throw const KeyFailure(KeyOutcome.gone);
    }
    return (key: key, contents: contents);
  }

  // Unlocks with the key Face ID or the passcode releases. Throws KeyFailure.
  Future<void> unlock() async {
    if (!await hasVault()) throw StateError('There is no wallet to unlock');
    final owner = await _owner();
    try {
      await _startSession(owner.key, owner.contents);
    } finally {
      _wipe(owner.key);
    }
  }

  // Asks for Face ID or the passcode again, even while unlocked, for what shows a secret or can't
  // be undone, and hands over the decrypted contents. Throws KeyFailure.
  Future<T> confirmed<T>(Future<T> Function(VaultContents contents) use) async {
    final owner = await _owner();
    try {
      return await use(owner.contents);
    } finally {
      _wipe(owner.key);
    }
  }

  Future<VaultContents> _contents(Uint8List key) async {
    final contents = await _openWith(key);
    if (contents == null) throw StateError('The vault no longer opens with this session');
    return contents;
  }

  // Signs messages as the active wallet, checking it signs as `address`: decrypted for the moment.
  Future<List<Uint8List>> sign(String address, List<Uint8List> messages) async {
    final key = _key;
    if (key == null) throw const LockedError();
    final contents = await _contents(key);
    final wallet = contents.wallets.where((w) => w.id == _activeId).firstOrNull;
    final keyring = contents.keyrings.where((k) => k.id == wallet?.keyring).firstOrNull;
    if (wallet == null || keyring == null) throw StateError('The active wallet is missing from the vault');
    return [
      for (final message in messages)
        await signMessage(keyring.secret, wallet.account, message).then((signed) {
          if (signed.address != address) throw StateError('The key does not belong to the sending wallet');
          return signed.signature;
        }),
    ];
  }

  // Decrypts, changes and re-encrypts the vault under the session's key, as one queued write; the
  // session's list follows. If `change` returns what it was given, nothing is written.
  Future<VaultContents> update(VaultContents Function(VaultContents contents) change) => _serialized(() async {
        final key = _key;
        if (key == null) throw const LockedError();
        final contents = await _contents(key);
        final changed = change(contents);
        if (identical(changed, contents)) return contents;
        final next = Uint8List.fromList(utf8.encode(jsonEncode(changed.toJson())));
        try {
          await _writeVault(next, key);
        } finally {
          _wipe(next);
        }
        _wallets = _summaries(changed);
        if (!_wallets.any((w) => w.id == _activeId)) await switchWallet(_wallets.first.id);
        return changed;
      });

  Future<void> switchWallet(String id) async {
    if (_key == null) throw const LockedError();
    if (!_wallets.any((w) => w.id == id)) throw StateError('No such wallet');
    _activeId = id;
    await preferences.save((await preferences.load()).copyWith(activeWallet: () => id));
  }

  static String? validName(String input) {
    final name = input.trim();
    return name.isNotEmpty && name.length <= walletNameMaxLength ? name : null;
  }

  // A wallet by its recovery phrase (its first account) or private key, made the active one. A
  // phrase already in the vault is reused rather than stored twice.
  Future<AddResult> importWallet(WalletSecret secret, String nameInput) async {
    final name = validName(nameInput);
    if (name == null) return const NotAdded(AddError.name);
    if (await checkSecret(secret) != null) return const NotAdded(AddError.secret);
    final canonical = await canonicalSecret(secret);
    final address = await addressOf(canonical);
    bool same(WalletSecret other) => switch ((other, canonical)) {
          (PhraseSecret(words: final a), PhraseSecret(words: final b)) => a.join(' ') == b.join(' '),
          (KeySecret(key: final a), KeySecret(key: final b)) => a == b,
          _ => false,
        };
    AddResult result = const NotAdded(AddError.duplicate);
    await update((contents) {
      final existing = contents.wallets.where((w) => w.address == address).firstOrNull;
      if (existing != null) {
        result = NotAdded(AddError.duplicate, existing.name);
        return contents;
      }
      final known = contents.keyrings.where((k) => same(k.secret)).firstOrNull;
      final keyring = known ?? Keyring(newId(), canonical);
      final entry = WalletEntry(id: newId(), name: name, address: address, keyring: keyring.id);
      result = Added(WalletSummary(entry.id, name, address, canonical is PhraseSecret ? WalletSource.phrase : WalletSource.privateKey));
      return VaultContents(known == null ? [...contents.keyrings, keyring] : contents.keyrings, [...contents.wallets, entry]);
    });
    if (result case Added(:final wallet)) await switchWallet(wallet.id);
    return result;
  }

  // These three ask for Face ID or the passcode first. They throw KeyFailure.
  Future<String> exportPrivateKey(String id) => confirmed((contents) async {
        final wallet = contents.wallets.firstWhere((w) => w.id == id);
        return privateKeyOf(contents.keyrings.firstWhere((k) => k.id == wallet.keyring).secret, wallet.account);
      });

  // The phrase a wallet comes from, and the names of every wallet made from it. A wallet imported
  // by its private key alone has none: `words` null.
  Future<({List<String>? words, List<String> wallets})> exportPhrase(String id) => confirmed((contents) async {
        final wallet = contents.wallets.firstWhere((w) => w.id == id);
        final keyring = contents.keyrings.firstWhere((k) => k.id == wallet.keyring);
        final secret = keyring.secret;
        if (secret is! PhraseSecret) return (words: null, wallets: const <String>[]);
        return (words: [...secret.words], wallets: [for (final w in contents.wallets) if (w.keyring == keyring.id) w.name]);
      });

  // Removes a wallet, and its phrase or key if no other wallet uses it. The only wallet can't be
  // removed: false then.
  Future<bool> removeWallet(String id) async {
    await confirmed((_) async {});
    var removed = false;
    await update((contents) {
      if (contents.wallets.length == 1) return contents;
      final wallets = contents.wallets.where((w) => w.id != id).toList();
      removed = wallets.length < contents.wallets.length;
      return VaultContents([for (final k in contents.keyrings) if (wallets.any((w) => w.keyring == k.id)) k], wallets);
    });
    return removed;
  }

  Future<void> renameWallet(String id, String nameInput) async {
    final name = validName(nameInput);
    if (name == null) throw const ContactRefused(ContactError.name);
    await update((contents) => VaultContents(contents.keyrings, [
          for (final w in contents.wallets) w.id == id ? WalletEntry(id: w.id, name: name, address: w.address, keyring: w.keyring, account: w.account) : w,
        ]));
  }

  // Puts the wallets in the order given. No Face ID: the order gives nothing away.
  Future<void> reorderWallets(List<String> ids) => update((contents) {
        final byId = {for (final w in contents.wallets) w.id: w};
        if (ids.length != byId.length || ids.toSet().length != ids.length || !ids.every(byId.containsKey)) throw StateError('Not the same wallets');
        return VaultContents(contents.keyrings, [for (final id in ids) byId[id]!]);
      });

  // The address book: encrypted apart from the vault, under a key derived from the vault key, so
  // reading it never decrypts a phrase, and AES-GCM fails on anything changed outside zandr.
  static const _addressBookInfo = 'zandr address book v1';

  Future<List<Contact>> _readContacts(Uint8List vaultKey) async {
    final text = await store.read(SecureKey.addressBook);
    if (text == null) return [];
    final plaintext = await openBlob((jsonDecode(text) as Map).cast(), await subKey(vaultKey, _addressBookInfo));
    if (plaintext == null) throw const TamperedError();
    return [for (final c in jsonDecode(utf8.decode(plaintext)) as List) Contact.fromJson(c as Map)];
  }

  Future<void> _writeContacts(List<Contact> contacts, Uint8List vaultKey) async {
    final blob = await sealBlob(Uint8List.fromList(utf8.encode(jsonEncode([for (final c in contacts) c.toJson()]))), await subKey(vaultKey, _addressBookInfo));
    await store.write(SecureKey.addressBook, jsonEncode(blob));
  }

  // Throws LockedError, or TamperedError if the stored address book was changed outside zandr.
  Future<List<Contact>> readAddressBook() async {
    final key = _key;
    if (key == null) throw const LockedError();
    return _readContacts(key);
  }

  Future<Contact> addContact(String nameInput, String addressInput) => _serialized(() async {
        final key = _key;
        if (key == null) throw const LockedError();
        final name = nameInput.trim();
        final address = addressInput.trim();
        if (name.isEmpty || name.length > contactNameMaxLength) throw const ContactRefused(ContactError.name);
        if (base58Decode(address)?.length != 32) throw const ContactRefused(ContactError.invalidAddress);
        final own = active!;
        if (address == own.address) throw const ContactRefused(ContactError.ownAddress);
        if (lookalike(address, own.address)) throw ContactRefused(ContactError.lookalike, own.name);
        final contacts = await _readContacts(key);
        final same = contacts.where((c) => c.address == address).firstOrNull;
        if (same != null) throw ContactRefused(ContactError.duplicate, same.name);
        final similar = contacts.where((c) => lookalike(c.address, address)).firstOrNull;
        if (similar != null) throw ContactRefused(ContactError.lookalike, similar.name);
        final contact = Contact(newId(), name, address, DateTime.now().millisecondsSinceEpoch);
        await _writeContacts([...contacts, contact], key);
        return contact;
      });

  Future<void> removeContact(String id) => _serialized(() async {
        final key = _key;
        if (key == null) throw const LockedError();
        await _writeContacts([for (final c in await _readContacts(key)) if (c.id != id) c], key);
      });

  // The last balances shown, kept between launches so the next unlock shows them at once while
  // fresh ones load. Sealed like the address book; anything unreadable is simply no cache.
  static const _cacheInfo = 'zandr cache v1';

  Future<Map<String, Object?>> readCache() async {
    final key = _key;
    if (key == null) throw const LockedError();
    final text = await store.read(SecureKey.cache);
    if (text == null) return {};
    try {
      final plaintext = await openBlob((jsonDecode(text) as Map).cast(), await subKey(key, _cacheInfo));
      return plaintext == null ? {} : (jsonDecode(utf8.decode(plaintext)) as Map).cast();
    } catch (_) {
      return {};
    }
  }

  // Sealed at once, with a copy of the key: locking right after (which wipes the key) can't leave
  // it unwritten. Only the write itself waits its turn.
  Future<void> writeCache(Map<String, Object?> cache) async {
    final key = _key;
    if (key == null) throw const LockedError();
    final copy = Uint8List.fromList(key);
    final Map<String, Object> blob;
    try {
      blob = await sealBlob(Uint8List.fromList(utf8.encode(jsonEncode(cache))), await subKey(copy, _cacheInfo));
    } finally {
      _wipe(copy);
    }
    await _serialized(() => store.write(SecureKey.cache, jsonEncode(blob)));
  }

  // For an address book that failed verification: unreadable, so it can only be thrown away.
  Future<void> clearAddressBook() => _serialized(() async {
        if (_key == null) throw const LockedError();
        await store.delete(SecureKey.addressBook);
      });
}
