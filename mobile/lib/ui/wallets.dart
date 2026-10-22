// The wallets: switch between them, drag one by its avatar (or hold it) to reorder, add one, and
// for each: rename it, show its recovery phrase (if it came from one) or private key, or remove it.
// Showing a secret or removing a wallet asks for Face ID or the passcode, even while unlocked.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/store.dart';
import '../app/vault.dart';
import '../core/secrets.dart';
import 'app.dart';
import 'format.dart';
import 'home.dart' show push;
import 'icons.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showWallets(BuildContext context) => showSheet(context, (_) => const _WalletsSheet());

class _WalletsSheet extends StatefulWidget {
  const _WalletsSheet();
  @override
  State<_WalletsSheet> createState() => _WalletsSheetState();
}

class _WalletsSheetState extends State<_WalletsSheet> {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final wallets = state.vault.wallets;
    final navigator = Navigator.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    // Half the screen to start with; with many wallets, as tall as they need, up to all of it.
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        height: sheetHeight(box.maxHeight, 36 + wallets.length * 66.0 + 80 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
              child: Text(
                'Wallets',
                style: geist(20, weight: FontWeight.w600, color: p.fg),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                physics: scrollIfNeeded,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                buildDefaultDragHandles: false,
                itemCount: wallets.length,
                proxyDecorator: (child, _, _) => Material(color: p.raised, borderRadius: BorderRadius.circular(14), child: child),
                onReorder: (from, to) async {
                  final ids = [for (final w in wallets) w.id];
                  final moved = ids.removeAt(from);
                  ids.insert(to > from ? to - 1 : to, moved);
                  HapticFeedback.selectionClick();
                  await state.vault.reorderWallets(ids);
                  await state.walletsChanged();
                },
                itemBuilder: (context, i) {
                  final wallet = wallets[i];
                  final active = wallet.id == state.active?.id;
                  // The active wallet's row is lit, its letters brighter, as in the extension.
                  return Padding(
                    key: ValueKey(wallet.id),
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: ReorderableDelayedDragStartListener(
                      index: i,
                      child: Material(
                        color: active ? p.fill : Colors.transparent,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: () async {
                            navigator.pop();
                            if (!active) await state.switchWallet(wallet.id);
                          },
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 10, 0, 10),
                            child: Row(
                              children: [
                                ReorderableDragStartListener(
                                  index: i,
                                  child: Monogram(wallet.name, wallet.address, size: 44, strong: active),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        wallet.name,
                                        style: geist(17, weight: FontWeight.w600, color: p.fg),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(shortAddress(wallet.address), style: geist(14, color: p.muted)),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => showSheet(context, (_) => _WalletMenu(wallet)),
                                  icon: ZIcon(ZIcons.more, size: 20, color: p.muted),
                                  tooltip: 'More for ${wallet.name}',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12 + bottom),
              child: Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      'New wallet',
                      icon: ZIcons.plus,
                      onPressed: () {
                        navigator.pop();
                        push(context, const AddWalletFlow(create: true));
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SecondaryButton(
                      'Import',
                      icon: ZIcons.import,
                      onPressed: () {
                        navigator.pop();
                        push(context, const AddWalletFlow(create: false));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletMenu extends StatefulWidget {
  final WalletSummary wallet;
  const _WalletMenu(this.wallet);
  @override
  State<_WalletMenu> createState() => _WalletMenuState();
}

class _WalletMenuState extends State<_WalletMenu> {
  // Why Face ID or the passcode gave nothing, said at the top of the menu.
  String? _problem;

  Future<T?> _confirmed<T>(Future<T> Function() action) async {
    setState(() => _problem = null);
    final result = await confirmed(action);
    if (mounted) setState(() => _problem = result.problem);
    return result.value;
  }

  @override
  Widget build(BuildContext context) {
    final wallet = widget.wallet;
    final p = Palette.of(context);
    final state = AppScope.read(context);
    final navigator = Navigator.of(context);
    Widget item(Glyph icon, String label, VoidCallback onTap, {bool danger = false}) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: gutter),
      leading: ZIcon(icon, size: 22, color: danger ? p.danger : p.fg),
      title: Text(
        label,
        style: geist(16, weight: FontWeight.w500, color: danger ? p.danger : p.fg),
      ),
      onTap: onTap,
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
            child: Row(
              children: [
                Monogram(wallet.name, wallet.address),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    wallet.name,
                    style: geist(20, weight: FontWeight.w600, color: p.fg),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (_problem != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 8), child: Notice(_problem!)),
          Momentary(builder: (context, copied, run) => item(copied ? ZIcons.check : ZIcons.copy, copied ? 'Copied' : 'Copy address', () => run(() => copyText(wallet.address)))),
          item(ZIcons.rename, 'Rename', () async {
            final name = await showSheet<String>(context, (_) => _RenameSheet(wallet.name));
            if (name == null) return;
            await state.vault.renameWallet(wallet.id, name);
            await state.walletsChanged();
            navigator.pop();
          }),
          if (wallet.source == WalletSource.phrase)
            item(ZIcons.phrase, 'Show recovery phrase', () async {
              final found = await _confirmed(() => state.vault.exportPhrase(wallet.id));
              if (found?.words != null && context.mounted) push(context, _SecretScreen.phrase(found!.words!, found.wallets));
            }),
          item(ZIcons.privateKey, 'Show private key', () async {
            final key = await _confirmed(() => state.vault.exportPrivateKey(wallet.id));
            if (key != null && context.mounted) push(context, _SecretScreen.key(key));
          }),
          if (state.vault.wallets.length > 1)
            item(ZIcons.trash, 'Remove wallet', () async {
              final sure = await showSheet<bool>(context, (_) => _RemoveSheet(wallet.name));
              if (sure != true || !context.mounted) return;
              final removed = await _confirmed(() => state.vault.removeWallet(wallet.id));
              if (removed == true) {
                await state.walletsChanged();
                navigator.pop();
              }
            }, danger: true),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RenameSheet extends StatefulWidget {
  final String name;
  const _RenameSheet(this.name);
  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final _name = TextEditingController(text: widget.name);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final valid = Vault.validName(_name.text) != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Rename wallet',
              style: geist(20, weight: FontWeight.w600, color: p.fg),
            ),
            const SizedBox(height: 16),
            Field(_name, autofocus: true, autocorrect: true, onChanged: (_) => setState(() {})),
            const SizedBox(height: 16),
            PrimaryButton('Save', onPressed: valid ? () => Navigator.pop(context, Vault.validName(_name.text)) : null),
          ],
        ),
      ),
    );
  }
}

// Runs what asks for Face ID or the passcode first: what it gives back, or null and why not (no
// reason when the person cancelled).
Future<({T? value, String? problem})> confirmed<T>(Future<T> Function() action) async {
  try {
    return (value: await action(), problem: null);
  } on KeyFailure catch (failure) {
    return (
      value: null,
      problem: switch (failure.outcome) {
        KeyOutcome.cancelled => null,
        KeyOutcome.gone => 'The key that opens this wallet is gone from this iPhone: its passcode was turned off.',
        KeyOutcome.failed => 'Couldn\'t check it\'s you. Try again.',
      },
    );
  }
}

class _RemoveSheet extends StatelessWidget {
  final String name;
  const _RemoveSheet(this.name);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Remove $name',
              style: geist(20, weight: FontWeight.w600, color: p.fg),
            ),
            const SizedBox(height: 8),
            Text('Only its recovery phrase or private key can bring it back. Make sure you have it written down.', style: geist(15, color: p.muted, height: 1.4)),
            const SizedBox(height: 16),
            PrimaryButton('Remove', danger: true, onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ),
    );
  }
}

// A recovery phrase or a private key, shown once Face ID or the passcode confirmed it: behind a
// veil until tapped, and gone from the screen when the app goes to the background.
class _SecretScreen extends StatefulWidget {
  final List<String>? words;
  final List<String> wallets;
  final String? privateKey;
  const _SecretScreen.phrase(List<String> this.words, this.wallets) : privateKey = null;
  const _SecretScreen.key(String this.privateKey) : words = null, wallets = const [];
  @override
  State<_SecretScreen> createState() => _SecretScreenState();
}

class _SecretScreenState extends State<_SecretScreen> {
  bool _shown = false;
  Timer? _clear;

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final phrase = widget.words != null;
    return SubScreen(
      title: phrase ? 'Recovery phrase' : 'Private key',
      bottom: PrimaryButton('Done', onPressed: () => Navigator.pop(context)),
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        children: [
          Notice(
            'Never share it',
            body: phrase
                ? 'Anyone with these words can take everything in ${widget.wallets.length > 1 ? 'these wallets: ${widget.wallets.join(', ')}' : 'this wallet'}. Zandr will never ask for them.'
                : 'Anyone with this key can take everything in this wallet. Zandr will never ask for it.',
          ),
          const SizedBox(height: 20),
          if (phrase)
            PhraseGrid(words: widget.words!, hidden: !_shown, onReveal: () => setState(() => _shown = true))
          else ...[
            GestureDetector(
              onTap: () => setState(() => _shown = true),
              child: Panel(
                child: _shown
                    ? SelectableText(
                        widget.privateKey!,
                        style: geist(16, weight: FontWeight.w500, color: p.fg, height: 1.5),
                      )
                    : Row(
                        children: [
                          ZIcon(ZIcons.eye, color: p.muted),
                          const SizedBox(width: 10),
                          Text('Tap to show, when no one is looking', style: geist(15, color: p.muted)),
                        ],
                      ),
              ),
            ),
            if (_shown) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Momentary(
                  builder: (context, copied, run) => Chip2(
                    copied ? 'Copied for one minute' : 'Copy for one minute',
                    icon: copied ? ZIcons.check : ZIcons.copy,
                    onTap: () => run(() async {
                      await copyText(widget.privateKey!);
                      // Taken off the clipboard again, unless something else was copied since.
                      _clear?.cancel();
                      _clear = Timer(const Duration(minutes: 1), () => clearClipboardIf(widget.privateKey!));
                    }),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// Adding a wallet: a new one with a phrase of its own (shown once), or one imported by its phrase
// or key; then its name.
class AddWalletFlow extends StatefulWidget {
  final bool create;
  const AddWalletFlow({super.key, required this.create});
  @override
  State<AddWalletFlow> createState() => _AddWalletFlowState();
}

class _AddWalletFlowState extends State<AddWalletFlow> {
  List<String>? _words;
  WalletSecret? _secret;
  int _step = 0;
  String? _problem;

  @override
  void initState() {
    super.initState();
    if (widget.create) {
      generatePhrase().then((words) {
        if (mounted) setState(() => _words = words);
      });
    }
  }

  Future<void> _add(String name) async {
    final state = AppScope.read(context);
    final result = await state.vault.importWallet(_secret ?? PhraseSecret(_words!), name);
    if (!mounted) return;
    switch (result) {
      case Added():
        await state.walletsChanged();
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      case NotAdded(:final error, :final conflict):
        setState(
          () => _problem = switch (error) {
            AddError.duplicate => 'This wallet is already here${conflict == null ? '' : ', as $conflict'}.',
            AddError.name => 'Give it a name of up to $walletNameMaxLength characters.',
            AddError.secret => 'That recovery phrase or key isn\'t valid.',
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    void back() => _step == 0 ? Navigator.pop(context) : setState(() => _step--);
    if (widget.create) {
      final words = _words;
      if (words == null) return const Scaffold();
      return switch (_step) {
        0 => ShowPhraseStep(words: words, onBack: back, onDone: () => setState(() => _step = 1)),
        _ => _NameWithProblem(problem: _problem, onBack: back, onDone: _add),
      };
    }
    return switch (_step) {
      0 => RestoreStep(
        onBack: back,
        onDone: (secret) => setState(() {
          _secret = secret;
          _step = 1;
        }),
      ),
      _ => _NameWithProblem(problem: _problem, onBack: back, onDone: _add),
    };
  }
}

class _NameWithProblem extends StatelessWidget {
  final String? problem;
  final VoidCallback onBack;
  final ValueChanged<String> onDone;
  const _NameWithProblem({required this.problem, required this.onBack, required this.onDone});

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      NameStep(initial: 'Wallet ${AppScope.of(context).vault.wallets.length + 1}', onBack: onBack, onDone: onDone),
      if (problem != null) Positioned(left: gutter, right: gutter, bottom: 100, child: Notice(problem!)),
    ],
  );
}
