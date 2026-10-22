// The extension's look (src/assets/theme.css): warm ivory on black, or near-black ink on white, in
// Geist. Every tint is the ink at some strength.
import 'package:flutter/material.dart';

class Palette {
  final Brightness brightness;
  final Color ink, bg, fg, muted, fill, fillStrong, divider, danger, onDanger, accent, onAccent, up, down, caution, verified, raised, input, panel;
  // A dropdown's panel, its edge and its shadow (--menu, --hairline, --shadow).
  final Color menu, hairline, shadow;
  const Palette({
    required this.brightness,
    required this.ink,
    required this.bg,
    required this.fg,
    required this.muted,
    required this.fill,
    required this.fillStrong,
    required this.divider,
    required this.danger,
    required this.onDanger,
    required this.accent,
    required this.onAccent,
    required this.up,
    required this.down,
    required this.caution,
    required this.verified,
    required this.raised,
    required this.input,
    required this.panel,
    required this.menu,
    required this.hairline,
    required this.shadow,
  });

  static const dark = Palette(
    brightness: Brightness.dark,
    ink: Color(0xfff3f2ea),
    bg: Color(0xff000000),
    fg: Color(0xfff3f2ea),
    muted: Color(0xff7e7d76),
    fill: Color(0x14f3f2ea),
    fillStrong: Color(0x21f3f2ea),
    divider: Color(0x0df3f2ea),
    danger: Color(0xfff08c7e),
    onDanger: Color(0xff000000),
    accent: Color(0xfff3f2ea),
    onAccent: Color(0xff000000),
    up: Color(0xff26d0a8),
    down: Color(0xfff0575d),
    caution: Color(0xfff0b35a),
    verified: Color(0xff4c9bff),
    raised: Color(0xff1d1d1b),
    input: Color(0xff0b0b0b),
    panel: Color(0xff070707),
    menu: Color(0xff0b0b0b),
    hairline: Color(0x17f3f2ea),
    shadow: Color(0x99000000),
  );

  static const light = Palette(
    brightness: Brightness.light,
    ink: Color(0xff141413),
    bg: Color(0xffffffff),
    fg: Color(0xff141413),
    muted: Color(0xff74736d),
    fill: Color(0x0e141413),
    fillStrong: Color(0x17141413),
    divider: Color(0x12141413),
    danger: Color(0xffd0453a),
    onDanger: Color(0xffffffff),
    accent: Color(0xff141413),
    onAccent: Color(0xffffffff),
    up: Color(0xff0b9a78),
    down: Color(0xffe0464c),
    caution: Color(0xffb5741a),
    verified: Color(0xff2f7cf6),
    raised: Color(0xffebebe9),
    input: Color(0xffffffff),
    panel: Color(0xfff7f7f5),
    menu: Color(0xffffffff),
    hairline: Color(0x1a141413),
    shadow: Color(0x24000000),
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

// Geist, as the extension sets it. A variable font: its weight is an axis, set along with the
// weight itself. Unless given, the letter spacing is the extension's (src/assets/ui.css,
// popup/App.svelte): bold text drawn tighter, the larger the tighter; body text as the font has it.
TextStyle geist(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height, double? spacing, List<FontFeature>? features}) => TextStyle(
  fontFamily: 'Geist',
  fontSize: size,
  fontWeight: weight,
  fontVariations: [FontVariation('wght', weight.value.toDouble())],
  color: color,
  height: height,
  letterSpacing: spacing ?? _tracking(size, weight) * size,
  fontFeatures: features,
);

// In em.
double _tracking(double size, FontWeight weight) {
  if (weight.value >= 600) {
    return size >= 30
        ? -0.03
        : size >= 18
        ? -0.02
        : -0.01;
  }
  if (weight.value >= 500 && size >= 20) return -0.015;
  return 0;
}

const tabular = [FontFeature.tabularFigures()];
// Lists bounce only when there's more than fits: a page that doesn't scroll stays put under the
// finger. (iOS otherwise lets every main list bounce; home keeps that, for pulling to refresh.)
const scrollIfNeeded = BouncingScrollPhysics();

const radius = 14.0;
// Every full-width button, the main one and the quieter one alike, so side by side they line up.
const buttonHeight = 52.0;
const gutter = 20.0;

ThemeData themeFor(Palette p) {
  final base = ThemeData(brightness: p.brightness, useMaterial3: true, fontFamily: 'Geist');
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: p.brightness,
    ).copyWith(primary: p.accent, onPrimary: p.onAccent, surface: p.bg, onSurface: p.fg, error: p.danger, onError: p.onDanger),
    textTheme: base.textTheme.apply(fontFamily: 'Geist', bodyColor: p.fg, displayColor: p.fg),
    // A row held down tints, as the extension's do under the pointer; no Material ripple.
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.fill,
    dividerColor: p.divider,
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.fg, selectionColor: p.fillStrong, selectionHandleColor: p.fg),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.panel, modalBackgroundColor: p.panel, showDragHandle: true, dragHandleColor: p.fillStrong),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? p.onAccent : p.muted),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? p.accent : p.fill),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raised,
      contentTextStyle: geist(14, color: p.fg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.iOS: CupertinoPageTransitionsBuilder(), TargetPlatform.android: CupertinoPageTransitionsBuilder(), TargetPlatform.macOS: CupertinoPageTransitionsBuilder()},
    ),
  );
}
