// Getting a wallet: a new one with its own recovery phrase (shown once), or one restored from a
// phrase or a private key; then its name. Its key goes behind Face ID and the iPhone's passcode,
// so the iPhone needs a passcode first.
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/vault.dart';
import '../core/secrets.dart';
import 'app.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Step { welcome, phrase, restore, name, passcode }

class Onboarding extends StatefulWidget {
  const Onboarding({super.key});
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final _steps = <_Step>[_Step.welcome];
  List<String>? _words;
  WalletSecret? _secret;
  String _name = defaultWalletName;
  bool _creating = false;
  // Why the last try to create the wallet didn't, said on the step itself.
  String? _problem;

  _Step get _step => _steps.last;
  void _go(_Step step) => setState(() {
    _problem = null;
    _steps.add(step);
  });
  void _back() => setState(() {
    _problem = null;
    _steps.removeLast();
  });

  Future<void> _create() async {
    _words = await generatePhrase();
    _secret = PhraseSecret(_words!);
    _go(_Step.phrase);
  }

  // The vault, once the iPhone has a passcode to keep its key behind.
  Future<void> _finish() async {
    if (_creating) return;
    final state = AppScope.read(context);
    setState(() {
      _creating = true;
      _problem = null;
    });
    try {
      await state.checkPasscode();
      if (!state.passcodeSet) {
        if (_step == _Step.passcode) {
          if (mounted) setState(() => _problem = 'This iPhone still has no passcode.');
        } else {
          _go(_Step.passcode);
        }
        return;
      }
      final secret = await canonicalSecret(_secret!);
      final keyring = Keyring(newId(), secret);
      final wallet = WalletEntry(id: newId(), name: _name, address: await addressOf(secret), keyring: keyring.id);
      await state.createVault(VaultContents([keyring], [wallet]));
    } catch (_) {
      if (mounted) setState(() => _problem = 'Zandr couldn\'t keep the wallet\'s key on this iPhone. Try again.');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = switch (_step) {
      _Step.welcome => _Welcome(onCreate: _create, onRestore: () => _go(_Step.restore)),
      _Step.phrase => ShowPhraseStep(words: _words!, onBack: _back, onDone: () => _go(_Step.name)),
      _Step.restore => RestoreStep(
        onBack: _back,
        onDone: (secret) {
          _secret = secret;
          _go(_Step.name);
        },
      ),
      _Step.name => NameStep(
        initial: _name,
        busy: _creating,
        problem: _problem,
        onBack: _back,
        onDone: (name) {
          _name = name;
          _finish();
        },
      ),
      _Step.passcode => PasscodeStep(busy: _creating, problem: _problem, onBack: _back, onDone: _finish),
    };
    return PopScope(
      canPop: _steps.length == 1,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_creating) _back();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(_steps.length), child: page),
      ),
    );
  }
}

class StepFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? bottom;
  final VoidCallback? onBack;
  const StepFrame({super.key, required this.title, this.subtitle, required this.child, this.bottom, this.onBack});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: onBack == null
                    ? null
                    : IconButton(
                        onPressed: onBack,
                        icon: ZIcon(ZIcons.back, color: p.muted),
                        tooltip: 'Back',
                      ),
              ),
            ),
            Expanded(
              child: ListView(
                physics: scrollIfNeeded,
                padding: const EdgeInsets.symmetric(horizontal: gutter),
                children: [
                  Text(
                    title,
                    style: geist(28, weight: FontWeight.w600, color: p.fg, height: 1.2),
                  ),
                  if (subtitle != null) ...[const SizedBox(height: 10), Text(subtitle!, style: geist(16, color: p.muted, height: 1.45))],
                  const SizedBox(height: 28),
                  child,
                ],
              ),
            ),
            if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 12), child: bottom),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onCreate, onRestore;
  const _Welcome({required this.onCreate, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              Text(
                'Zandr',
                style: geist(48, weight: FontWeight.w600, color: p.fg, spacing: -1),
              ),
              const SizedBox(height: 12),
              Text('A Solana wallet that stops mistakes before they cost you.', style: geist(19, color: p.muted, height: 1.4)),
              const Spacer(flex: 2),
              PrimaryButton('Create a new wallet', onPressed: onCreate),
              const SizedBox(height: 12),
              SecondaryButton('I already have a wallet', onPressed: onRestore),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class ShowPhraseStep extends StatefulWidget {
  final List<String> words;
  final VoidCallback onBack, onDone;
  const ShowPhraseStep({super.key, required this.words, required this.onBack, required this.onDone});
  @override
  State<ShowPhraseStep> createState() => ShowPhraseStepState();
}

class ShowPhraseStepState extends State<ShowPhraseStep> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return StepFrame(
      title: 'Your recovery phrase',
      subtitle:
          'These 12 words are the wallet. Write them down on paper, in order, and keep them where only you can find them. Anyone with them can take everything in it; without them, a lost phone means a lost wallet.',
      onBack: widget.onBack,
      bottom: PrimaryButton('I wrote it down', onPressed: _shown ? widget.onDone : null),
      child: Column(
        children: [
          PhraseGrid(words: widget.words, hidden: !_shown, onReveal: () => setState(() => _shown = true)),
          const SizedBox(height: 16),
          Text(
            'Zandr will never ask for it. No one from Zandr will either.',
            style: geist(14, color: p.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// Twelve or twenty-four words in two columns, numbered; behind a veil until tapped.
class PhraseGrid extends StatelessWidget {
  final List<String> words;
  final bool hidden;
  final VoidCallback? onReveal;
  const PhraseGrid({super.key, required this.words, this.hidden = false, this.onReveal});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final half = (words.length / 2).ceil();
    Widget column(int from) => Expanded(
      child: Column(
        children: [
          for (var i = from; i < min(from + half, words.length); i++)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${i + 1}',
                      style: geist(14, color: p.muted, features: tabular),
                    ),
                  ),
                  Text(
                    words[i],
                    style: geist(17, weight: FontWeight.w500, color: p.fg),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    final grid = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [column(0), column(half)]);
    if (!hidden) return grid;
    return GestureDetector(
      onTap: onReveal,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
            child: ExcludeSemantics(child: grid),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(24)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ZIcon(ZIcons.eye, size: 20, color: p.fg),
                const SizedBox(width: 8),
                Text(
                  'Tap to show, when no one is looking',
                  style: geist(15, weight: FontWeight.w500, color: p.fg),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// What the person typed as a secret: a phrase (words), or a private key, told apart by shape.
WalletSecret secretFrom(String text) {
  final value = text.trim();
  final words = value.toLowerCase().split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).toList();
  if (words.length == 1 && (value.length > 60 || value.startsWith('['))) return KeySecret(value);
  return PhraseSecret(words);
}

String secretProblem(({SecretError error, int? index}) check, WalletSecret secret) => switch (check.error) {
  SecretError.wordCount => 'A recovery phrase has 12 or 24 words; this has ${(secret as PhraseSecret).words.length}.',
  SecretError.unknownWord => 'Word #${check.index! + 1}, "${(secret as PhraseSecret).words[check.index!]}", isn\'t a recovery phrase word. Check its spelling.',
  SecretError.checksum => 'These words aren\'t a valid recovery phrase. Check each one and their order.',
  SecretError.invalidKey => 'That isn\'t a Solana private key. Paste the whole key, as your wallet exported it.',
};

// After a secret was pasted in, it shouldn't stay on the clipboard for other apps to read.
Future<void> clearClipboardIf(String secretText) async {
  final clip = await Clipboard.getData(Clipboard.kTextPlain);
  if (clip?.text != null && clip!.text!.trim() == secretText.trim()) await Clipboard.setData(const ClipboardData(text: ''));
}

class RestoreStep extends StatefulWidget {
  final VoidCallback onBack;
  final ValueChanged<WalletSecret> onDone;
  const RestoreStep({super.key, required this.onBack, required this.onDone});
  @override
  State<RestoreStep> createState() => RestoreStepState();
}

class RestoreStepState extends State<RestoreStep> {
  final _text = TextEditingController();
  String? _problem;
  bool _checking = false;

  Future<void> _continue() async {
    final secret = secretFrom(_text.text);
    setState(() => _checking = true);
    final check = await checkSecret(secret);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _problem = check == null ? null : secretProblem(check, secret);
    });
    if (check != null) return;
    await clearClipboardIf(_text.text);
    _text.clear();
    widget.onDone(secret);
  }

  @override
  void dispose() {
    _text.clear();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StepFrame(
      title: 'Restore a wallet',
      subtitle: 'Enter its recovery phrase, words separated by spaces, or its private key. It stays on this phone, encrypted.',
      onBack: widget.onBack,
      bottom: PrimaryButton('Continue', busy: _checking, onPressed: _text.text.trim().isEmpty ? null : _continue),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Field(_text, hint: 'Recovery phrase or private key', maxLines: 5, autofocus: true, keyboard: TextInputType.visiblePassword, onChanged: (_) => setState(() => _problem = null)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Chip2(
              'Paste',
              icon: ZIcons.paste,
              onTap: () async {
                final clip = await Clipboard.getData(Clipboard.kTextPlain);
                if (clip?.text != null) setState(() => _text.text = clip!.text!.trim());
              },
            ),
          ),
          if (_problem != null) ...[const SizedBox(height: 16), Notice(_problem!)],
        ],
      ),
    );
  }
}

class NameStep extends StatefulWidget {
  final String initial;
  final bool busy;
  final String? problem;
  final VoidCallback onBack;
  final ValueChanged<String> onDone;
  const NameStep({super.key, required this.initial, this.busy = false, this.problem, required this.onBack, required this.onDone});
  @override
  State<NameStep> createState() => NameStepState();
}

class NameStepState extends State<NameStep> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  Widget build(BuildContext context) {
    final valid = Vault.validName(_name.text) != null;
    return StepFrame(
      title: 'Name your wallet',
      subtitle: 'Only you see it. You can change it later.',
      onBack: widget.busy ? null : widget.onBack,
      bottom: PrimaryButton('Continue', busy: widget.busy, onPressed: valid ? () => widget.onDone(Vault.validName(_name.text)!) : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Field(
            _name,
            hint: defaultWalletName,
            autofocus: true,
            autocorrect: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (valid && !widget.busy) widget.onDone(Vault.validName(_name.text)!);
            },
          ),
          if (widget.problem != null) ...[const SizedBox(height: 16), Notice(widget.problem!)],
        ],
      ),
    );
  }
}

// Shown only when the iPhone has no passcode: the wallet's key can't be kept without one.
class PasscodeStep extends StatelessWidget {
  final bool busy;
  final String? problem;
  final VoidCallback onBack, onDone;
  const PasscodeStep({super.key, this.busy = false, this.problem, required this.onBack, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return StepFrame(
      title: 'Set a passcode first',
      subtitle:
          'Zandr keeps the key that opens your wallet in the iPhone\'s Keychain, where only Face ID or the passcode can release it. Set a passcode in Settings, under Face ID & Passcode, then come back.',
      onBack: busy ? null : onBack,
      bottom: PrimaryButton('I set a passcode', busy: busy, onPressed: onDone),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Center(child: ZIcon(ZIcons.lock, size: 96, color: p.muted)),
          ),
          if (problem != null) ...[const SizedBox(height: 24), Notice(problem!)],
        ],
      ),
    );
  }
}
