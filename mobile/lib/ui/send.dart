// Sending: a coin, an amount and a recipient; then the review, where Zandr says what the recipient
// really is and stops a transfer its protections catch; then the outcome.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/base58.dart';
import '../core/models.dart';
import '../core/send.dart';
import '../core/solana/rpc.dart';
import '../core/units.dart';
import '../app/vault.dart';
import 'app.dart';
import 'format.dart';
import 'home.dart' show push;
import 'icons.dart';
import 'outcome.dart';
import 'scan.dart';
import 'theme.dart';
import 'widgets.dart';

class SendScreen extends StatefulWidget {
  final String? mint;
  final Scanned? to;
  const SendScreen({super.key, this.mint, this.to});
  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> with SingleTickerProviderStateMixin {
  late String? _mint = widget.to?.mint ?? widget.mint;
  late final _amount = TextEditingController(text: widget.to?.amount ?? '');
  late final _to = TextEditingController(text: widget.to?.address ?? '');
  bool _max = false;
  String? _contact;
  Timer? _inspect;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void dispose() {
    _amount.dispose();
    _to.dispose();
    _inspect?.cancel();
    _shake.dispose();
    super.dispose();
  }

  Coin? _coin(Portfolio? portfolio) => portfolio?.coins.where((c) => _mint == null ? c.native : !c.native && c.mint == _mint).firstOrNull;

  void _recipientChanged(String value) {
    setState(() => _contact = null);
    _inspect?.cancel();
    _inspect = Timer(const Duration(milliseconds: 400), () async {
      if (isAddress(value.trim())) (await AppScope.read(context).sender()).inspectRecipient(value.trim());
    });
  }

  Future<void> _pickCoin(Portfolio portfolio) async {
    final picked = await showSheet<Coin>(context, (context) => _CoinPicker(portfolio.coins));
    if (picked != null) {
      setState(() {
        _mint = picked.native ? null : picked.mint;
        _max = false;
        _amount.clear();
      });
    }
  }

  Future<void> _pickRecipient() async {
    final state = AppScope.read(context);
    final contacts = await state.vault.readAddressBook().catchError((_) => <Contact>[]);
    if (!mounted) return;
    final picked = await showSheet<({String name, String address})>(
      context,
      (context) => _RecipientPicker(
        contacts: contacts,
        wallets: [
          for (final w in state.vault.wallets)
            if (w.id != state.active?.id) (name: w.name, address: w.address),
        ],
      ),
    );
    if (picked != null) {
      setState(() {
        _to.text = picked.address;
        _contact = picked.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final portfolio = state.portfolio;
    final coin = _coin(portfolio);
    final decimals = coin?.decimals ?? 9;
    final amount = parseUnits(_amount.text, decimals);
    final balance = coin == null ? null : BigInt.tryParse(coin.amount);
    final over = amount != null && balance != null && amount > balance;
    final ready = coin != null && isAddress(_to.text.trim()) && (_max || (amount != null && amount > BigInt.zero && !over));

    return SubScreen(
      title: 'Send',
      bottom: PrimaryButton(
        'Review',
        onPressed: ready
            ? () async {
                final picked = await push<String>(
                  context,
                  SendReviewScreen(
                    SendIntent(from: state.active!.address, mint: _mint, to: _to.text.trim(), amount: _max ? 'max' : _amount.text.trim()),
                    symbol: coin.label,
                  ),
                );
                // From the review: send to a token account's owner instead.
                if (picked != null && mounted) setState(() => _to.text = picked);
              }
            : null,
      ),
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Amount',
                      style: geist(15, weight: FontWeight.w500, color: p.muted),
                    ),
                    const Spacer(),
                    Chip2(
                      'Half',
                      onTap: coin == null
                          ? null
                          : () => setState(() {
                              _max = false;
                              _amount.text = formatUnits(BigInt.parse(coin.amount) ~/ BigInt.two, coin.decimals);
                            }),
                    ),
                    const SizedBox(width: 8),
                    Chip2(
                      'Max',
                      onTap: coin == null
                          ? null
                          : () => setState(() {
                              // All of a token; all the SOL the fee leaves, worked out in the review.
                              _max = true;
                              _amount.text = coin.balance;
                            }),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    GestureDetector(
                      onTap: portfolio == null ? null : () => _pickCoin(portfolio),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
                        decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(26)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CoinLogo(coin?.logo, coin?.label, size: 32),
                            const SizedBox(width: 8),
                            Text(
                              coin?.label ?? (portfolio == null ? '…' : 'Select'),
                              style: geist(17, weight: FontWeight.w600, color: p.fg),
                            ),
                            if (coin?.verified ?? false) ...[const SizedBox(width: 4), const VerifiedBadge(size: 15)],
                            const SizedBox(width: 4),
                            ZIcon(ZIcons.chevronDown, size: 18, color: p.muted),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _amount,
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')), _commaToDot],
                        onChanged: (text) {
                          setState(() => _max = false);
                          final typed = parseUnits(text, decimals);
                          if (typed != null && balance != null && typed > balance) {
                            HapticFeedback.mediumImpact();
                            _shake.forward(from: 0);
                          }
                        },
                        style: geist(32, weight: FontWeight.w600, color: over ? p.danger : p.fg, features: tabular),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: '0',
                          hintStyle: geist(32, weight: FontWeight.w600, color: p.muted),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ShakeX(
                  controller: _shake,
                  child: Text(coin == null ? ' ' : 'Balance ${formatAmount(coin.balance)} ${coin.label}', style: geist(14, color: over ? p.danger : p.muted)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Recipient',
                      style: geist(15, weight: FontWeight.w500, color: p.muted),
                    ),
                    if (_contact != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _contact!,
                        style: geist(15, weight: FontWeight.w600, color: p.fg),
                      ),
                    ],
                  ],
                ),
                TextField(
                  controller: _to,
                  maxLines: 2,
                  minLines: 1,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: _recipientChanged,
                  style: geist(17, weight: FontWeight.w500, color: p.fg, height: 1.4),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Solana address',
                    hintStyle: geist(17, color: p.muted),
                  ),
                ),
                if (_to.text.trim().isNotEmpty && !isAddress(_to.text.trim())) Text('This isn\'t a valid Solana address.', style: geist(14, color: p.danger)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip2(
                      'Paste',
                      icon: ZIcons.paste,
                      onTap: () async {
                        final clip = await Clipboard.getData(Clipboard.kTextPlain);
                        final text = clip?.text?.trim();
                        if (text != null && text.isNotEmpty) {
                          _to.text = text;
                          _recipientChanged(text);
                        }
                      },
                    ),
                    Chip2(
                      'Scan',
                      icon: ZIcons.scan,
                      onTap: () async {
                        final scanned = await scan(context);
                        if (scanned == null) return;
                        setState(() {
                          _to.text = scanned.address;
                          if (scanned.mint != null || scanned.amount != null) _mint = scanned.mint;
                          if (scanned.amount != null) _amount.text = scanned.amount!;
                        });
                        _recipientChanged(scanned.address);
                      },
                    ),
                    Chip2('Saved', icon: ZIcons.addressBook, onTap: _pickRecipient),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final _commaToDot = TextInputFormatter.withFunction((old, value) => value.copyWith(text: value.text.replaceAll(',', '.')));

// Shakes its child sideways once each time the controller runs: a nudge, not a message.
class ShakeX extends StatelessWidget {
  final AnimationController controller;
  final Widget child;
  const ShakeX({super.key, required this.controller, required this.child});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => Transform.translate(offset: Offset(sin(controller.value * pi * 6) * 7 * (1 - controller.value), 0), child: child),
    child: child,
  );
}

class _CoinPicker extends StatelessWidget {
  final List<Coin> coins;
  const _CoinPicker(this.coins);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
              child: Text(
                'Select coin',
                style: geist(20, weight: FontWeight.w600, color: p.fg),
              ),
            ),
            Flexible(
              child: ListView(
                physics: scrollIfNeeded,
                shrinkWrap: true,
                children: [
                  for (final coin in coins)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: gutter),
                      leading: CoinLogo(coin.logo, coin.label),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              coin.label,
                              style: geist(16, weight: FontWeight.w600, color: p.fg),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (coin.verified) ...[const SizedBox(width: 4), const VerifiedBadge(size: 15)],
                        ],
                      ),
                      subtitle: Text(formatAmount(coin.balance), style: geist(14, color: p.muted)),
                      trailing: Text(
                        coin.value == null ? '' : formatUsd(coin.value!),
                        style: geist(15, weight: FontWeight.w500, color: p.fg),
                      ),
                      onTap: () => Navigator.pop(context, coin),
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

class _RecipientPicker extends StatelessWidget {
  final List<Contact> contacts;
  final List<({String name, String address})> wallets;
  const _RecipientPicker({required this.contacts, required this.wallets});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget row(String name, String address) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: gutter),
      leading: Monogram(name, address),
      title: Text(
        name,
        style: geist(16, weight: FontWeight.w600, color: p.fg),
      ),
      subtitle: Text(shortAddress(address), style: geist(14, color: p.muted)),
      onTap: () => Navigator.pop(context, (name: name, address: address)),
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 4),
      child: Text(
        text,
        style: geist(14, weight: FontWeight.w600, color: p.muted),
      ),
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(
          physics: scrollIfNeeded,
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 0),
              child: Text(
                'Saved addresses',
                style: geist(20, weight: FontWeight.w600, color: p.fg),
              ),
            ),
            if (contacts.isEmpty && wallets.isEmpty)
              Padding(
                padding: const EdgeInsets.all(gutter),
                child: Text('Nothing saved yet. Add addresses in Settings → Address book.', style: geist(15, color: p.muted)),
              ),
            if (contacts.isNotEmpty) heading('Address book'),
            for (final c in contacts) row(c.name, c.address),
            if (wallets.isNotEmpty) heading('Your wallets'),
            for (final w in wallets) row(w.name, w.address),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

String sendFailureText(SendFailure failure, String symbol) => switch (failure.reason) {
  SendReason.walletChanged => 'The active wallet changed. Start this transfer again.',
  SendReason.invalidAddress => 'This isn\'t a valid Solana address.',
  SendReason.ownAddress => 'That\'s this wallet\'s own address.',
  SendReason.noCoin => 'This wallet doesn\'t hold this coin anymore.',
  SendReason.invalidAmount => 'Enter a valid amount.',
  SendReason.insufficient => 'You don\'t have that much $symbol.',
  SendReason.splitBalance => 'Your $symbol is spread across several accounts. Send a smaller amount.',
  SendReason.nonTransferable => 'This token can\'t be transferred: its creator made it non-transferable.',
  SendReason.transferHook => 'Zandr can\'t send this token yet: it runs a program of its own on every transfer.',
  SendReason.blocked => 'Zandr stopped this transfer: see why above.',
  SendReason.insufficientSol => 'Not enough SOL to cover the costs. You need ${failure.needed} SOL.',
  SendReason.belowMinimum =>
    !failure.leftover
        ? 'A new address needs at least ${failure.minimum} SOL.'
        : symbol == 'SOL'
        ? 'Leave at least ${failure.minimum} SOL in the wallet, or send all of it.'
        : 'This would leave less than ${failure.minimum} SOL in the wallet, which the network doesn\'t allow. Add some SOL first.',
  SendReason.simulation => 'This transfer would fail: ${failure.detail}',
  SendReason.network => switch (failure.rpc) {
    RpcFailure.forbidden => 'The RPC endpoint refused. Set one up in Settings → Network.',
    RpcFailure.rateLimited => 'The RPC endpoint is busy. Try again in a moment.',
    RpcFailure.unreachable => 'Couldn\'t reach the network. Check your connection.',
    _ => 'The network refused: ${failure.detail ?? 'no reason given'}',
  },
};

({String title, String text}) checkText(SendCheck check, String symbol) => switch (check) {
  ProgramCheck(kind: ProgramKind.program) => (title: 'This is a program, not a wallet', text: 'Programs have no owner who could send coins back. Whatever you send here is most likely lost for good.'),
  ProgramCheck(kind: ProgramKind.owned) => (title: 'This address belongs to a program', text: 'It\'s an account a program controls, not a wallet. Only that program can move what you send here.'),
  ProgramCheck() => (title: 'No wallet controls this address', text: 'It\'s derived from a program and has no private key. Only that program can move what you send here, if it ever does.'),
  MintCheck(:final token) => (title: 'This is a token\'s mint address', text: 'It identifies ${token ?? 'a token'} itself and isn\'t a wallet. Whatever you send here is lost.'),
  TokenAccountCheck(:final owner) => (title: 'This is a token account, not a wallet', text: 'It belongs to the wallet ${shortAddress(owner)}. Send to that wallet instead.'),
  LookalikeCheck(:final name) => (title: 'Looks like $name, but isn\'t', text: 'It starts and ends like $name\'s address, but the middle differs: a common trick to make you send to a scammer.'),
  ExchangeWalletCheck(:final exchange) => (
    title: 'This is $exchange\'s own wallet',
    text: 'It isn\'t a deposit address, so $exchange won\'t credit what you send here to any account. Copy your deposit address from $exchange instead.',
  ),
  ExchangeTokenCheck(:final exchange, basis: 'trading') => (
    title: '$exchange doesn\'t trade $symbol',
    text: 'This is a $exchange deposit address, and $exchange doesn\'t list this token. It would most likely never reach your account.',
  ),
  ExchangeTokenCheck(:final exchange) => (
    title: '$exchange doesn\'t accept $symbol on Solana',
    text: 'This is a $exchange deposit address, and this token isn\'t on $exchange\'s list. It would most likely never reach your account.',
  ),
  ExchangePausedCheck(:final exchange, :final coin) => (
    title: '$exchange isn\'t taking ${coin ?? symbol} deposits now',
    text: '$exchange has deposits of this token on Solana turned off. What you send now may never reach your account, or only once they\'re back on.',
  ),
  ExchangeMinimumCheck(:final exchange, :final minimum, :final coin) => (
    title: 'Below $exchange\'s minimum deposit',
    text: '$exchange credits ${coin ?? symbol} deposits of at least $minimum. A smaller one isn\'t credited to your account.',
  ),
};

class SendReviewScreen extends StatefulWidget {
  final SendIntent intent;
  final String symbol;
  // Shown as is, without asking the network: for the screens' preview.
  final SendReview? preview;
  const SendReviewScreen(this.intent, {super.key, required this.symbol, this.preview});
  @override
  State<SendReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<SendReviewScreen> {
  late SendReview? _review = widget.preview;
  SendFailure? _failure;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_review == null) _prepare();
  }

  Future<void> _prepare() async {
    try {
      final review = await (await AppScope.read(context).sender()).prepare(widget.intent);
      if (mounted) setState(() => _review = review);
    } on SendFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    }
  }

  Future<void> _send() async {
    final review = _review!;
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      // Exactly what was reviewed: its coin and recipient, the amount as worked out, not "max".
      final intent = SendIntent(from: review.from, mint: review.coin.mint, to: review.to, amount: review.amount);
      final sent = await (await state.sender()).submit(intent, review.fee, state.sign);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => OutcomeScreen.sent(
            doneTitle: 'Sent',
            summary: '${formatAmount(review.amount)} ${review.coin.label} to ${review.contact ?? shortAddress(review.to)}',
            sent: [(signature: sent.signature, pending: sent.pending)],
          ),
        ),
      );
    } on BlockedSend catch (blocked) {
      // Something about the recipient changed since the review: show it again.
      if (mounted) setState(() => _review = blocked.review);
    } on SendFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final review = _review;
    final symbol = review?.coin.label ?? widget.symbol;
    return SubScreen(
      title: 'Review',
      bottom: review == null ? null : PrimaryButton('Send', busy: _busy, onPressed: review.checks.isEmpty ? _send : null),
      child: review == null
          ? (_failure == null ? const Center(child: Spinner(size: 26)) : Padding(padding: const EdgeInsets.all(gutter), child: Notice(sendFailureText(_failure!, symbol))))
          : ListView(
              physics: scrollIfNeeded,
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              children: [
                const SizedBox(height: 8),
                Center(child: CoinLogo(review.coin.logo, symbol, size: 56)),
                const SizedBox(height: 12),
                Text(
                  '${formatAmount(review.amount)} $symbol',
                  textAlign: TextAlign.center,
                  style: geist(32, weight: FontWeight.w600, color: p.fg, features: tabular),
                ),
                const SizedBox(height: 24),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('To', style: geist(15, color: p.muted)),
                      const SizedBox(height: 6),
                      if (review.contact != null)
                        Text(
                          review.contact!,
                          style: geist(17, weight: FontWeight.w600, color: p.fg),
                        ),
                      AddressText(review.to, size: 16),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(children: [DetailRow('Network fee', Text('${review.fee} SOL')), if (review.rent != null) DetailRow('Recipient\'s new token account', Text('${review.rent} SOL'))]),
                ),
                for (final note in review.notes) ...[
                  const SizedBox(height: 12),
                  switch (note) {
                    ExchangeNoListNote(:final exchange) => Notice(
                      'Zandr can\'t check $exchange\'s tokens',
                      body: 'This is a $exchange deposit address, but $exchange publishes no list of the tokens it takes. Make sure it takes $symbol on Solana before you send.',
                      danger: false,
                    ),
                    ExchangeUncheckedNote() => Notice(
                      'Exchange check didn\'t finish',
                      body: 'Zandr couldn\'t tell in time whether this address belongs to an exchange. If it\'s an exchange deposit address, make sure the exchange takes $symbol on Solana.',
                      danger: false,
                    ),
                  },
                ],
                for (final check in review.checks) ...[
                  const SizedBox(height: 12),
                  Notice(checkText(check, symbol).title, body: checkText(check, symbol).text),
                  if (check case TokenAccountCheck(:final owner) when owner.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Chip2('Send to ${shortAddress(owner)} instead', onTap: () => Navigator.pop(context, owner)),
                      ),
                    ),
                ],
                if (_failure != null && _failure!.reason != SendReason.blocked) ...[const SizedBox(height: 12), Notice(sendFailureText(_failure!, symbol))],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
