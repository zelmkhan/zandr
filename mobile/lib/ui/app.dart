// The app's frame: the state shared with every screen, which screen shows (welcome, unlock or the
// wallet), the theme, and the cover over everything whenever the app isn't in front.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/preferences.dart';
import '../app/wallet.dart';
import 'home.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'unlock.dart';
import 'widgets.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  // Without listening: for actions, not for what's shown.
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class ZandrApp extends StatelessWidget {
  final AppState state;
  const ZandrApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final choice = state.preferences.theme;
          return MaterialApp(
            title: 'Zandr',
            debugShowCheckedModeBanner: false,
            theme: themeFor(choice == ThemeChoice.dark ? Palette.dark : Palette.light),
            darkTheme: themeFor(choice == ThemeChoice.light ? Palette.light : Palette.dark),
            themeMode: ThemeMode.system,
            builder: (context, child) {
              // The status bar light over dark screens (the lock screen is dark whatever the theme)
              // and dark over light ones, so the time and battery never vanish into the background.
              final dark = Palette.of(context).brightness == Brightness.dark || state.phase == Phase.loading || state.phase == Phase.locked;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
                // Larger text as the iPhone sets it, up to where the screens still hold together.
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: _Cover(state: state, child: child!),
                ),
              );
            },
            home: const _Gate(),
          );
        },
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (state.phase) {
        Phase.loading => const _Splash(key: ValueKey('loading')),
        Phase.onboarding => const Onboarding(key: ValueKey('onboarding')),
        // Dark whatever the theme, as the launch screen before it.
        Phase.locked => Theme(key: const ValueKey('locked'), data: themeFor(Palette.dark), child: const UnlockScreen()),
        // A fresh navigator per unlock: nothing from before locking stays on the stack.
        Phase.unlocked => const HomeNavigator(key: ValueKey('unlocked')),
      },
    );
  }
}

// As the launch screen: black, the mark in the middle.
class _Splash extends StatelessWidget {
  const _Splash({super.key});
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Palette.dark.bg,
    child: Center(child: BrandMark(color: Palette.dark.fg)),
  );
}

// Touches count as activity for auto-lock; a tap on nothing in particular puts the keyboard away;
// and while the app isn't in front, nothing of the wallet shows: the app switcher's snapshot is of
// this cover.
class _Cover extends StatelessWidget {
  final AppState state;
  final Widget child;
  const _Cover({required this.state, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => state.touch(),
      // Buttons and fields under the tap win it; this gets only taps that land on none of them.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Stack(
          children: [
            child,
            if (state.obscured)
              Positioned.fill(
                child: ColoredBox(
                  color: Palette.dark.bg,
                  child: Center(child: BrandMark(color: Palette.dark.fg)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
