// What happened to what was just sent. The screen can open before it's sent (`run` does that): a
// small spinner while it waits; once the network took it (its signature is known), a green check
// with a ring drawing round it, slowing toward 80% and crawling on to 95%, until it lands and the
// ring closes.
// Should it fail or expire after all, the mark turns red and says so.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../core/sent.dart';
import 'app.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

typedef SentTransaction = ({String signature, Pending pending});

class OutcomeScreen extends StatefulWidget {
  final String workingTitle, doneTitle;
  final String? summary;
  // Sends it; what it sent, or throws why not (said by `describe`).
  final Future<({List<SentTransaction> sent, String? summary})> Function() run;
  final String Function(Object error) describe;
  const OutcomeScreen({super.key, this.workingTitle = 'Sending…', required this.doneTitle, this.summary, required this.run, required this.describe});

  // For what's already sent.
  factory OutcomeScreen.sent({required String doneTitle, String? summary, required List<SentTransaction> sent}) =>
      OutcomeScreen(doneTitle: doneTitle, summary: summary, run: () async => (sent: sent, summary: summary), describe: (e) => '$e');

  @override
  State<OutcomeScreen> createState() => _OutcomeScreenState();
}

class _OutcomeScreenState extends State<OutcomeScreen> {
  List<SentTransaction>? _sent;
  String? _summary;
  String? _refused;
  Settled? _trouble;
  int _confirmed = 0;
  // Every transaction of it confirmed.
  bool get _landed => _sent != null && _sent!.isNotEmpty && _confirmed == _sent!.length;

  @override
  void initState() {
    super.initState();
    _summary = widget.summary;
    _start();
  }

  Future<void> _start() async {
    final state = AppScope.read(context);
    try {
      final result = await widget.run();
      // Followed even once the screen is left: landing refreshes the wallet's coins.
      for (final (:signature, :pending) in result.sent) {
        state.follow(signature, pending).then((settled) {
          if (!mounted || settled == null) return;
          setState(() => settled.status == SettledStatus.confirmed ? _confirmed++ : _trouble ??= settled);
        });
      }
      if (!mounted) return;
      setState(() {
        _sent = result.sent;
        _summary = result.summary ?? _summary;
      });
    } catch (error) {
      if (mounted) setState(() => _refused = widget.describe(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final network = AppScope.of(context).network;
    final working = _sent == null && _refused == null;
    final failed = _refused != null || _trouble != null;
    final title = working
        ? widget.workingTitle
        : _refused != null
        ? 'Not sent'
        : _trouble == null
        ? widget.doneTitle
        : _trouble!.status == SettledStatus.expired
        ? 'Didn\'t go through'
        : 'Failed';
    final text = working
        ? null
        : _refused ??
              (_trouble == null
                  ? _summary
                  : _trouble!.status == SettledStatus.expired
                  ? 'The network didn\'t take it in time. Nothing moved and no fee was paid.'
                  : 'It ran into an error on the network, and the network fee was paid. ${_trouble!.detail ?? ''}');
    // Leaving is always possible, whatever stage it's at: back to the form if nothing went, to the
    // wallet otherwise (a form still filled in would only invite sending it twice). What's on its
    // way keeps going.
    void leave() => _refused != null ? Navigator.of(context).pop() : Navigator.of(context).popUntil((route) => route.isFirst);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) leave();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: gutter),
                // The mark stays put from spinner to check to cross; text below it only adds on.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                    Center(
                      child: _StatusMark(
                        working
                            ? _Phase.working
                            : failed
                            ? _Phase.failed
                            : _landed
                            ? _Phase.landed
                            : _Phase.sent,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: geist(28, weight: FontWeight.w600, color: p.fg),
                    ),
                    if (text != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        text,
                        textAlign: TextAlign.center,
                        style: geist(16, color: p.muted, height: 1.45),
                      ),
                    ],
                    // No words for confirming: the ring round the check says it, and closes once it lands.
                    const Spacer(),
                    if (_sent?.isNotEmpty ?? false) ...[
                      SecondaryButton(
                        'View on Solscan',
                        icon: ZIcons.openOutside,
                        onPressed: () {
                          launchUrl(Uri.parse(explorerTransaction(_sent!.last.signature, network)), mode: LaunchMode.externalApplication);
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_refused != null) PrimaryButton('Back', onPressed: leave) else PrimaryButton('Done', onPressed: working ? null : leave),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              // Top left, as on every other screen, and at any stage.
              Positioned(
                top: 0,
                left: 0,
                child: SizedBox(
                  height: 56,
                  child: IconButton(
                    onPressed: leave,
                    icon: ZIcon(ZIcons.back, color: p.muted),
                    tooltip: 'Back',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Phase { working, sent, landed, failed }

// The mark at the top: a small spinner while waiting; then a tinted circle with a check (or a cross)
// that pops in, and for a sent transaction a ring drawing round it toward 95%, closing once it lands.
class _StatusMark extends StatefulWidget {
  final _Phase phase;
  const _StatusMark(this.phase);
  @override
  State<_StatusMark> createState() => _StatusMarkState();
}

class _StatusMarkState extends State<_StatusMark> with TickerProviderStateMixin {
  // How far round the ring is, 0 to 1. Made up front, not lazily: a screen closed while still
  // waiting must not make them in dispose().
  late final AnimationController _ring, _pop;
  late final Animation<double> _scale, _fade;

  static const _size = 88.0;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(vsync: this);
    _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
    _scale = Tween(begin: 0.55, end: 1.0).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOutBack));
    _fade = CurvedAnimation(
      parent: _pop,
      curve: const Interval(0, 0.5, curve: Curves.easeOut),
    );
    _enter(null);
  }

  @override
  void didUpdateWidget(_StatusMark old) {
    super.didUpdateWidget(old);
    if (old.phase != widget.phase) _enter(old.phase);
  }

  void _enter(_Phase? from) {
    switch (widget.phase) {
      case _Phase.working:
        break;
      case _Phase.sent:
        _pop.forward(from: 0);
        // Most land within seconds: quick at first, slowing toward four fifths; then on at a crawl,
        // ever slower, and still at 95% if it hasn't landed by then. Landing cuts in at any point
        // (animateTo(1) cancels these, and a cancelled step doesn't go on to the next).
        _ring.value = 0;
        _ring.animateTo(0.8, duration: const Duration(seconds: 6), curve: Curves.easeOutCubic).then((_) {
          if (mounted && widget.phase == _Phase.sent) _ring.animateTo(0.95, duration: const Duration(seconds: 25), curve: Curves.easeOutQuad);
        });
      case _Phase.landed:
        if (from == null || from == _Phase.working) _pop.forward(from: 0);
        _ring.animateTo(1, duration: const Duration(milliseconds: 520), curve: Curves.easeOutCubic).whenComplete(() {
          if (mounted) HapticFeedback.mediumImpact();
        });
      case _Phase.failed:
        _ring.stop();
        _pop.forward(from: 0);
        HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final phase = widget.phase;
    final failed = phase == _Phase.failed;
    final color = failed ? p.danger : p.up;
    return Semantics(
      label: switch (phase) {
        _Phase.working => 'Sending',
        _Phase.sent => 'Sent, confirming',
        _Phase.landed => 'Confirmed',
        _Phase.failed => 'Failed',
      },
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedOpacity(opacity: phase == _Phase.working ? 1 : 0, duration: const Duration(milliseconds: 150), child: const Spinner(size: 28)),
            if (phase != _Phase.working) ...[
              // The ring: a faint track, the drawn part over it; gone if it failed.
              AnimatedOpacity(
                opacity: failed ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: CustomPaint(size: const Size.square(_size), painter: _RingPainter(_ring, color, color.withValues(alpha: 0.14))),
              ),
              FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                    child: Center(child: ZIcon(failed ? ZIcons.close : ZIcons.check, size: 34, color: color)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Animation<double> progress;
  final Color color, track;
  _RingPainter(this.progress, this.color, this.track) : super(repaint: progress);

  static const _stroke = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = rect.deflate(_stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawOval(ring, paint..color = track);
    if (progress.value > 0) canvas.drawArc(ring, -1.5707963267948966, 6.283185307179586 * progress.value, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.track != track || old.progress != progress;
}
