// The pieces every screen is built from: buttons, fields, avatars, coin logos and addresses.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'icons.dart';
import 'theme.dart';

// The main action: an ivory pill with black text, full width.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool danger;
  const PrimaryButton(this.label, {super.key, this.onPressed, this.busy = false, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = onPressed != null && !busy;
    final background = danger ? p.danger : p.accent;
    final foreground = danger ? p.onDanger : p.onAccent;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Pressable(
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onPressed!();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: buttonHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: enabled || busy ? background : p.fill, borderRadius: BorderRadius.circular(buttonHeight / 2)),
          child: busy
              ? Spinner(size: 20, color: foreground)
              : Text(
                  label,
                  style: geist(17, weight: FontWeight.w600, color: enabled ? foreground : p.muted),
                ),
        ),
      ),
    );
  }
}

// A quieter action: a tinted pill.
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Glyph? icon;
  final bool danger;
  const SecondaryButton(this.label, {super.key, this.onPressed, this.icon, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = onPressed == null
        ? p.muted
        : danger
        ? p.danger
        : p.fg;
    return Pressable(
      onTap: onPressed,
      child: Container(
        height: buttonHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(buttonHeight / 2)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[ZIcon(icon!, size: 20, color: color), const SizedBox(width: 8)],
            Text(
              label,
              style: geist(16, weight: FontWeight.w500, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// A small tinted chip: Half, Max, Paste.
class Chip2 extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Glyph? icon;
  const Chip2(this.label, {super.key, this.onTap, this.icon});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(16)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[ZIcon(icon!, size: 16, color: p.muted), const SizedBox(width: 6)],
            Text(
              label,
              style: geist(14, weight: FontWeight.w500, color: onTap == null ? p.muted.withValues(alpha: 0.5) : p.muted),
            ),
          ],
        ),
      ),
    );
  }
}

// A round action on the home screen: an icon in a circle, its name below.
class RoundAction extends StatelessWidget {
  final Glyph icon;
  final String label;
  final VoidCallback onTap;
  const RoundAction(this.icon, this.label, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        scale: 0.94,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
                child: Center(child: ZIcon(icon, size: 22, color: p.fg)),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: geist(13, weight: FontWeight.w500, color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// A wallet's or an address's avatar: two letters on a tint.
class Monogram extends StatelessWidget {
  final String? name;
  final String address;
  final double size;
  // Brighter, for the active wallet on a lit row.
  final bool strong;
  const Monogram(this.name, this.address, {super.key, this.size = 40, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: strong ? p.fillStrong : p.fill, shape: BoxShape.circle),
      child: Text(
        monogram(name, address),
        style: geist(size * 0.36, weight: FontWeight.w600, color: p.fg, spacing: 0.3),
      ),
    );
  }
}

// A token's logo, from zandr's logo server; its first letter on a tint while there's none.
class CoinLogo extends StatelessWidget {
  final String? logo;
  final String? label;
  final double size;
  const CoinLogo(this.logo, this.label, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
      child: Text(
        (label ?? '?').isEmpty ? '?' : String.fromCharCode((label ?? '?').runes.first).toUpperCase(),
        style: geist(size * 0.4, weight: FontWeight.w600, color: p.muted),
      ),
    );
    if (logo == null) return fallback;
    // The letter until the logo arrives, then the logo fading in over it.
    return ClipOval(
      child: Image.network(
        logo!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        frameBuilder: (_, child, frame, sync) => sync
            ? child
            : Stack(
                children: [
                  fallback,
                  AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), curve: Curves.easeOut, child: child),
                ],
              ),
      ),
    );
  }
}

class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: GlyphPainter([(ZIcons.rosette, Palette.of(context).verified), (ZIcons.rosetteCheck, const Color(0xFFFFFFFF))])),
  );
}

// An address in full, its groups of four told apart by alternating tone rather than spaces, so it
// reads as the one string it is.
class AddressText extends StatelessWidget {
  final String address;
  final double size;
  final TextAlign align;
  const AddressText(this.address, {super.key, this.size = 15, this.align = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < address.length; i += 4)
            TextSpan(
              text: address.substring(i, (i + 4).clamp(0, address.length)),
              style: TextStyle(color: (i ~/ 4).isEven ? p.fg : p.muted),
            ),
        ],
      ),
      textAlign: align,
      style: geist(size, weight: FontWeight.w500, features: tabular, height: 1.5),
    );
  }
}

// A rounded panel on a faint tint: the extension's cards.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(color: color ?? Palette.of(context).fill, borderRadius: BorderRadius.circular(radius + 6)),
    child: child,
  );
}

// A text field on a tint, as the extension's: no border, a label above.
class Field extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboard;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int? maxLines;
  final Widget? suffix;
  final FocusNode? focus;
  final TextInputAction? action;
  final bool autocorrect;
  const Field(
    this.controller, {
    super.key,
    this.hint,
    this.obscure = false,
    this.autofocus = false,
    this.keyboard,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.suffix,
    this.focus,
    this.action,
    this.autocorrect = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(radius)),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              autofocus: autofocus,
              obscureText: obscure,
              // The dots as big as the unlock screen's, as in the extension.
              obscuringCharacter: '•',
              keyboardType: keyboard,
              textInputAction: action,
              maxLines: obscure ? 1 : maxLines,
              minLines: 1,
              autocorrect: autocorrect,
              enableSuggestions: autocorrect,
              enableIMEPersonalizedLearning: false,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              style: obscure && controller.text.isNotEmpty ? geist(28, color: p.fg, spacing: 1, height: 1.2) : geist(17, color: p.fg, height: 1.3),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: geist(17, color: p.muted),
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
                isDense: true,
              ),
            ),
          ),
          ?suffix,
        ],
      ),
    );
  }
}

// A screen inside the wallet: a back arrow and a title, then the content.
class SubScreen extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget> actions;
  final Widget? bottom;
  final VoidCallback? onBack;
  const SubScreen({super.key, required this.title, required this.child, this.actions = const [], this.bottom, this.onBack});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  IconButton(
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                    icon: ZIcon(ZIcons.back, color: p.muted),
                    tooltip: 'Back',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      style: geist(20, weight: FontWeight.w600, color: p.fg),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...actions,
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(child: child),
            if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 12), child: bottom),
          ],
        ),
      ),
    );
  }
}

// A line of a review: a label on the left, its value on the right.
class DetailRow extends StatelessWidget {
  final String label;
  final Widget value;
  const DetailRow(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: geist(15, color: p.muted)),
          const SizedBox(width: 16),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: DefaultTextStyle(
                style: geist(15, weight: FontWeight.w500, color: p.fg),
                textAlign: TextAlign.right,
                child: value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// A warning on a review or form: what's wrong and what to do about it.
class Notice extends StatelessWidget {
  final String title;
  final String? body;
  final bool danger;
  final Glyph? icon;
  const Notice(this.title, {super.key, this.body, this.danger = true, this.icon});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = danger ? p.danger : p.caution;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(radius)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZIcon(icon ?? (danger ? ZIcons.warning : ZIcons.info), size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: geist(15, weight: FontWeight.w600, color: color),
                ),
                if (body != null) ...[const SizedBox(height: 4), Text(body!, style: geist(14, color: p.fg.withValues(alpha: 0.8), height: 1.4))],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// The wallet's mark, as on its icon and the iPhone's launch screen (the same size there, 96
// points, so starting up and unlocking show it standing still).
class BrandMark extends StatelessWidget {
  final double size;
  final Color? color;
  const BrandMark({super.key, this.size = 96, this.color});

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/mark.png',
    width: size,
    height: size,
    color: color ?? Palette.of(context).fg,
    colorBlendMode: BlendMode.srcIn,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
  );
}

// Anything tappable that isn't a row: it gives a little under the finger (smaller, dimmer) and
// springs back, so a tap is felt to land.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.97});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 90 : 220),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: AnimatedOpacity(opacity: _down ? 0.82 : 1, duration: const Duration(milliseconds: 120), child: widget.child),
      ),
    );
  }
}

// One of a few, side by side, the chosen one lit (the extension's .segmented).
class Segmented<T> extends StatelessWidget {
  final List<T> options;
  final T value;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const Segmented({super.key, required this.options, required this.value, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.hairline),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (option == value) return;
                  HapticFeedback.selectionClick();
                  onChanged(option);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: option == value ? p.fillStrong : Colors.transparent, borderRadius: BorderRadius.circular(9)),
                  child: Text(
                    label(option),
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: geist(14, weight: FontWeight.w500, color: option == value ? p.fg : p.muted),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// A panel that drops from a button, its right edge under the button's, as the extension's menus
// do: a fade and a few points' slide, gone on a tap anywhere else.
Future<T?> showDropdown<T>(BuildContext anchor, Widget Function(BuildContext context) builder) {
  final box = anchor.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  HapticFeedback.selectionClick();
  return Navigator.of(anchor).push<T>(_DropdownRoute<T>(rect, builder, MaterialLocalizations.of(anchor).modalBarrierDismissLabel));
}

class _DropdownRoute<T> extends PopupRoute<T> {
  final Rect anchor;
  final Widget Function(BuildContext) builder;
  @override
  final String barrierLabel;
  _DropdownRoute(this.anchor, this.builder, this.barrierLabel);

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final p = Palette.of(context);
    final screen = MediaQuery.sizeOf(context);
    return Stack(
      children: [
        Positioned(
          top: anchor.bottom + 8,
          right: (screen.width - anchor.right).clamp(12, screen.width),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: p.menu,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.hairline),
              boxShadow: [BoxShadow(color: p.shadow, blurRadius: 40, offset: const Offset(0, 16))],
            ),
            // As wide as its widest line, every line as wide as that.
            child: Material(
              type: MaterialType.transparency,
              child: IntrinsicWidth(child: builder(context)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeIn);
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) => Transform.translate(offset: Offset(0, -4 * (1 - curved.value)), child: child),
        child: child,
      ),
    );
  }
}

// A line in a dropdown: an icon and what it does; tinted while held.
class DropdownItem extends StatefulWidget {
  final Glyph icon;
  final String label;
  final VoidCallback onTap;
  const DropdownItem(this.icon, this.label, this.onTap, {super.key});
  @override
  State<DropdownItem> createState() => _DropdownItemState();
}

class _DropdownItemState extends State<DropdownItem> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = _down ? p.fg : p.muted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        constraints: const BoxConstraints(minWidth: 190),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(color: _down ? p.fill : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZIcon(widget.icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              widget.label,
              style: geist(15, weight: FontWeight.w500, color: color, spacing: 0),
            ),
          ],
        ),
      ),
    );
  }
}

// Where a list has nothing to show, or couldn't load: an icon, a line, a word more, and what to do.
class EmptyState extends StatelessWidget {
  final Glyph icon;
  final String title;
  final String? text;
  final Widget? action;
  const EmptyState(this.icon, this.title, {super.key, this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
            child: ZIcon(icon, size: 24, color: p.muted),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: geist(16, weight: FontWeight.w600, color: p.fg),
          ),
          if (text != null) ...[
            const SizedBox(height: 4),
            Text(
              text!,
              textAlign: TextAlign.center,
              style: geist(14, color: p.muted, height: 1.45),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

// A block standing in for something loading, breathing as the rows below do.
class SkeletonBlock extends StatefulWidget {
  final double width, height;
  const SkeletonBlock(this.width, this.height, {super.key});
  @override
  State<SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<SkeletonBlock> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut)),
    child: Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(color: Palette.of(context).fill, borderRadius: BorderRadius.circular(widget.height / 3)),
    ),
  );
}

// Rows standing in for a list while it loads: the shape of what's coming, breathing.
class SkeletonRows extends StatefulWidget {
  final int count;
  const SkeletonRows({super.key, this.count = 4});
  @override
  State<SkeletonRows> createState() => _SkeletonRowsState();
}

class _SkeletonRowsState extends State<SkeletonRows> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(height / 2)),
    );
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut)),
      child: Column(
        children: [
          for (var i = 0; i < widget.count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(88.0 + 24 * (i % 2), 14), const SizedBox(height: 8), bar(56, 11)]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [bar(64, 14), const SizedBox(height: 8), bar(40, 11)]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> copyText(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.lightImpact();
}

// Says on the button itself that what it does was done ("Copied", a check), for a moment, rather
// than in a message elsewhere: `builder` gets whether that moment is now, and `run` to start it
// with the action.
class Momentary extends StatefulWidget {
  final Widget Function(BuildContext context, bool active, void Function(Future<void> Function() action) run) builder;
  const Momentary({super.key, required this.builder});
  @override
  State<Momentary> createState() => _MomentaryState();
}

class _MomentaryState extends State<Momentary> {
  bool _active = false;
  Timer? _reset;

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    setState(() => _active = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _active = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _active, _run);
}

// Something is on its way: a small ring turning, sized to sit beside text rather than fill the
// screen.
class Spinner extends StatelessWidget {
  final double size;
  final Color? color;
  const Spinner({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CircularProgressIndicator(strokeWidth: size < 20 ? 1.8 : 2.2, strokeCap: StrokeCap.round, color: color ?? Palette.of(context).muted),
  );
}

// A sheet's height for a list of rows: half the screen at least, all of it at most (`room`, what
// the sheet may take), and in between what the rows need.
double sheetHeight(double room, double content) => content.clamp(room / 2, room).toDouble();

// A sheet from the bottom, sized to its content.
Future<T?> showSheet<T>(BuildContext context, Widget Function(BuildContext) builder) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: builder(context),
  ),
);
