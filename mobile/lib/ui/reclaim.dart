// Getting back the SOL that the wallet's token accounts hold as rent: every empty account, and any
// junk the user picks (worth under a dollar, or with no price), its tokens burned first.
import 'package:flutter/material.dart';

import '../core/reclaim.dart';
import '../core/units.dart';
import 'app.dart';
import 'format.dart';
import 'outcome.dart';
import 'theme.dart';
import 'widgets.dart';

String reclaimFailureText(Object error) {
  if (error is! ReclaimFailure) return 'Something went wrong: $error';
  return switch (error.reason) {
    ReclaimReason.nothing => 'Those accounts changed meanwhile and none can be closed now.',
    ReclaimReason.unacknowledged => 'Confirm that the picked tokens will be destroyed.',
    ReclaimReason.prices => 'Token prices couldn\'t be checked, so nothing was burned. Try again in a moment.',
    ReclaimReason.simulation => 'The network\'s test run didn\'t go as it should, so nothing was signed: ${error.detail}',
    ReclaimReason.network => 'Couldn\'t reach the network. Check your connection and try again.',
  };
}

class ReclaimScreen extends StatefulWidget {
  // Shown as is, without asking the network: for the screens' preview.
  final ReclaimPlan? preview;
  const ReclaimScreen({super.key, this.preview});
  @override
  State<ReclaimScreen> createState() => _ReclaimScreenState();
}

class _ReclaimScreenState extends State<ReclaimScreen> {
  ReclaimPlan? _plan;
  Object? _failure;
  final _closing = <String>{};
  final _burning = <String>{};
  bool _acknowledged = false;

  @override
  void initState() {
    super.initState();
    final preview = widget.preview;
    if (preview == null) {
      _load();
    } else {
      _plan = preview;
      _closing.addAll(preview.empty.map((a) => a.address));
    }
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      final plan = await state.reclaimer().plan(state.active!.address);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _closing
          ..clear()
          ..addAll(plan.empty.map((a) => a.address));
      });
    } catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  BigInt _lamports(Iterable<ReclaimAccount> accounts) => accounts.fold(BigInt.zero, (sum, a) => sum + (parseUnits(a.sol, 9) ?? BigInt.zero));

  void _reclaim() {
    final state = AppScope.read(context);
    final close = _closing.toList(), burn = _burning.toList();
    final acknowledged = _acknowledged;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => OutcomeScreen(
          workingTitle: 'Reclaiming…',
          doneTitle: 'SOL reclaimed',
          run: () async {
            final result = await state.reclaimer().execute(state.active!.address, close, burn, acknowledged, state.signAll);
            final burned = result.burned == 0 ? '' : ', ${result.burned} ${result.burned == 1 ? 'token' : 'tokens'} burned';
            final skipped = result.skipped == 0
                ? ''
                : ' ${result.skipped} ${result.skipped == 1 ? 'account was' : 'accounts were'} left as they were: they can\'t be closed now, or turned out to be worth more.';
            return (sent: result.sent, summary: '${formatAmount(result.reclaimed)} SOL is back in your wallet$burned.$skipped');
          },
          describe: reclaimFailureText,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final plan = _plan;
    if (plan == null) {
      return SubScreen(
        title: 'Reclaim SOL',
        child: Center(
          child: _failure != null
              ? Padding(padding: const EdgeInsets.all(gutter), child: Notice(reclaimFailureText(_failure!)))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Spinner(size: 26),
                    const SizedBox(height: 16),
                    Text('Looking through your token accounts…', style: geist(15, color: p.muted)),
                  ],
                ),
        ),
      );
    }
    final closing = plan.empty.where((a) => _closing.contains(a.address));
    final burning = plan.junk.where((a) => _burning.contains(a.address));
    final total = formatUnits(_lamports(closing) + _lamports(burning), 9);
    final count = closing.length + burning.length;
    final transactions = (closing.length / reclaimBatch.close).ceil() + (burning.length / reclaimBatch.burn).ceil();
    final fee = formatUnits(BigInt.from(transactions * reclaimFeePerTransaction), 9);
    final ready = count > 0 && (burning.isEmpty || _acknowledged);

    Widget row(ReclaimAccount account, Set<String> picked, {required bool junk}) {
      final label = account.symbol ?? shortAddress(account.mint);
      return CheckboxListTile(
        value: picked.contains(account.address),
        onChanged: (on) => setState(() {
          on == true ? picked.add(account.address) : picked.remove(account.address);
          if (_burning.isEmpty) _acknowledged = false;
        }),
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: p.accent,
        checkColor: p.onAccent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Row(
          children: [
            CoinLogo(account.logo, label, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: geist(15, weight: FontWeight.w600, color: p.fg),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (account.verified) ...[const SizedBox(width: 4), const VerifiedBadge(size: 14)],
                    ],
                  ),
                  if (junk) Text('${formatAmount(account.balance ?? '0')} · ${account.value == null ? 'No price' : formatUsd(account.value!)}', style: geist(13, color: p.muted)),
                ],
              ),
            ),
            Text(
              '+${formatAmount(account.sol)} SOL',
              style: geist(14, weight: FontWeight.w500, color: p.up),
            ),
          ],
        ),
      );
    }

    return SubScreen(
      title: 'Reclaim SOL',
      bottom: count == 0 && plan.empty.isEmpty && plan.junk.isEmpty
          ? null
          : PrimaryButton(
              burning.isNotEmpty ? 'Burn ${burning.length} and reclaim ${formatAmount(total)} SOL' : 'Reclaim ${formatAmount(total)} SOL',
              danger: burning.isNotEmpty,
              onPressed: ready ? _reclaim : null,
            ),
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Text('Every token account holds about 0.002 SOL. Closing one returns it to you; a token you get again later just opens a new one.', style: geist(15, color: p.muted, height: 1.45)),
          ),
          if (plan.empty.isEmpty && plan.junk.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Notice('Nothing to reclaim', body: 'This wallet has no empty token accounts or junk tokens.', danger: false),
            ),
          if (plan.empty.isNotEmpty) ...[
            _Heading(
              'Empty accounts',
              plan.empty.length,
              action: _closing.length == plan.empty.length ? 'Clear' : 'Select all',
              onAction: () => setState(() {
                _closing.length == plan.empty.length ? _closing.clear() : _closing.addAll(plan.empty.map((a) => a.address));
              }),
            ),
            for (final account in plan.empty) row(account, _closing, junk: false),
          ],
          if (plan.junk.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Heading(
              'Junk tokens',
              plan.junk.length,
              action: _burning.length == plan.junk.length ? 'Clear' : 'Select all',
              onAction: () => setState(() {
                _burning.length == plan.junk.length ? _burning.clear() : _burning.addAll(plan.junk.map((a) => a.address));
                if (_burning.isEmpty) _acknowledged = false;
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text('Worth under ${formatUsd(reclaimJunkMaxUsd)}, or with no price. Burning destroys them for good.', style: geist(14, color: p.muted)),
            ),
            for (final account in plan.junk) row(account, _burning, junk: true),
          ] else if (!plan.pricesKnown)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Token prices couldn\'t be checked, so no tokens are offered for burning now.', style: geist(14, color: p.muted)),
            ),
          if (count > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: DetailRow('Network fee', Text('≈ $fee SOL'))),
          if (burning.isNotEmpty)
            CheckboxListTile(
              value: _acknowledged,
              onChanged: (on) => setState(() => _acknowledged = on ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: p.danger,
              checkColor: p.onDanger,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(
                'I understand the ${burning.length} ${burning.length == 1 ? 'token' : 'tokens'} I picked will be destroyed and can\'t be recovered.',
                style: geist(14, color: p.fg, height: 1.4),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final int count;
  final String action;
  final VoidCallback onAction;
  const _Heading(this.title, this.count, {required this.action, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
      child: Row(
        children: [
          Text(
            title,
            style: geist(16, weight: FontWeight.w600, color: p.fg),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: geist(16, weight: FontWeight.w500, color: p.muted),
          ),
          const Spacer(),
          TextButton(
            onPressed: onAction,
            child: Text(
              action,
              style: geist(14, weight: FontWeight.w500, color: p.muted),
            ),
          ),
        ],
      ),
    );
  }
}
