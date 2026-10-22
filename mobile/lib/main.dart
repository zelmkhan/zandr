// Zandr for iPhone: the extension's wallet and its protections, with the vault in the Keychain and
// its key behind Face ID and the iPhone's passcode.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/preferences.dart';
import 'app/store.dart';
import 'app/wallet.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // In a browser (for looking at the screens while developing) nothing is kept: there's no Keychain.
  final SecureStore store = kIsWeb ? MemoryStore() : await KeychainStore.open();
  final PreferenceStore preferences = kIsWeb ? MemoryPreferences() : DevicePreferences();
  final state = AppState(store, preferences);
  await state.start();
  // The mark decoded before the first frame, so it's there from that frame on, where the launch
  // screen had it: no blank moment in between.
  final mark = Completer<void>();
  const AssetImage('assets/images/mark.png').resolve(ImageConfiguration.empty).addListener(ImageStreamListener((_, _) {
    if (!mark.isCompleted) mark.complete();
  }, onError: (_, _) {
    if (!mark.isCompleted) mark.complete();
  }));
  await mark.future;
  runApp(ZandrApp(state: state));
}
