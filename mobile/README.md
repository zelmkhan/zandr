# Zandr for iPhone

The Zandr wallet as a Flutter app, iOS first. It is the extension's wallet carried over: the same
keys from the same recovery phrase, the same transfer protections and the same swap checks. It has
no password of its own: Face ID or the iPhone's passcode unlocks it. It also talks to the same
server (zandr's API on Railway) for the default Solana node, Jupiter, token logos and the
exchanges' token lists.

## Security

- **The vault** holds every recovery phrase and private key, encrypted with AES-256-GCM under a
  random 256-bit vault key. It is kept in the iOS Keychain:
  - readable only while the iPhone is unlocked;
  - never in backups or iCloud;
  - never moved to another device (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- **The vault key** is a separate Keychain item, released only after Face ID or the iPhone's
  passcode, every time it's read (`userPresence`):
  - unlocking asks for it;
  - showing a recovery phrase or private key, or removing a wallet, asks again, even while unlocked;
  - it needs a passcode on the iPhone, so setting up a wallet asks for one first;
  - turning the passcode off deletes it for good (`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`).
    The wallet then opens only from its recovery phrase.
- **Deleting the app deletes the wallet.** The Keychain outlives an app, so the first launch after
  an install clears what an earlier install left.
- **While unlocked, only the vault key is in memory.** A phrase or key is decrypted for the moment
  a signature or an export needs it, then wiped.
- **Locking:**
  - after the auto-lock time away from the app or idle in it;
  - whenever the app isn't in front, the screen is covered, so the app switcher's snapshot shows
    nothing.
- **The address book** is encrypted under a key derived from the vault key (HKDF), so one changed
  outside the app fails to open.
- **The last balances shown** are kept for the next unlock, to show at once before the network
  answers: encrypted the same way, under a key of their own derived from the vault key.
- **Clipboard:**
  - a phrase or key pasted in is taken off the clipboard;
  - a private key copied out is taken off it again after a minute.

## Layout

- `lib/core/`: the wallet's logic, plain Dart, ported from the extension (`src/lib`, `src/server`):
  - keys and the vault's encryption;
  - Solana transactions, the RPC client and Jupiter;
  - coins, history, exchange checks, send, swap and reclaim;
  - following sent transactions and live balances.
- `lib/app/`: Keychain storage, preferences, the vault and session, the app's state.
- `lib/ui/`: the screens.
- `lib/dev/preview.dart`: every screen with sample data in a browser, for development only
  (`flutter build web -t lib/dev/preview.dart`, then `?screen=home`, `send`, `review`, …).
- `assets/data/`: the exchanges' wallets and token lists, shared with the extension. Run
  `tool/sync_data.sh` after they change; `test/data_test.dart` fails until then.

## Building

It needs Flutter 3.38 or later and Xcode with the iOS SDK:

```sh
flutter pub get
open ios/Runner.xcworkspace   # set the signing team once
flutter run                    # on a connected iPhone or a simulator
```

The bundle id is `app.zandr.wallet`. Face ID needs a real iPhone, or a simulator with
Features → Face ID → Enrolled.

## Tests

```sh
flutter test --exclude-tags live   # offline
flutter test --tags live           # against mainnet; nothing is signed
```

**Offline tests** check that the app agrees with the extension byte for byte:
- the same addresses from a phrase;
- the extension's vault format still opens (`lib/core/vault_crypto.dart`), though the app now seals
  its own vault under a random key;
- identical transactions;
- real mainnet transactions read the same way.

**Live tests**, against mainnet:
- plan transfers to an exchange's wallet, a mint, a program and a lookalike, and see each one stopped;
- quote and assemble swaps with Zandr's fee, check them and test-run them, and refuse one whose fee
  was changed;
- find accounts to reclaim and test-run closing them;
- follow a busy wallet over the socket.
