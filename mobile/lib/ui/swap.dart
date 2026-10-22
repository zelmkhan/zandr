// Swapping: what to pay with (a coin the wallet holds) and what to receive (any token, searched),
// a live quote, and the swap, built, checked and test-run before it's signed.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config.dart';
import '../core/models.dart';
import '../core/solana/addresses.dart';
import '../core/swap.dart';
import '../core/units.dart';
import 'app.dart';
import 'format.dart';
import 'icons.dart';
import 'outcome.dart';
import 'send.dart' show ShakeX;
import 'theme.dart';
import 'widgets.dart';

// A coin to swap from or into: what's shown of it.
class _Side {
  final String mint;
  final String? symbol, name, logo;
  final bool verified;
  const _Side(this.mint, {this.symbol, this.name, this.logo, this.verified = false});
  String get label => symbol ?? name ?? shortAddress(mint);
  factory _Side.ofCoin(Coin coin) => _Side(coin.mint, symbol: coin.symbol, name: coin.name, logo: coin.logo, verified: coin.verified);
  factory _Side.ofListing(TokenListing token) => _Side(token.mint, symbol: token.info.symbol, name: token.info.name, logo: token.info.logo, verified: token.info.verified);
}

String swapFailureText(Object error, String pay) {
  if (error is! SwapFailure) return 'Something went wrong: $error';
  return switch (error.reason) {
    SwapReason.walletChanged => 'The active wallet changed. Start this swap again.',
    SwapReason.sameToken => 'Pick two different coins.',
    SwapReason.unknownToken => 'Zandr couldn\'t read one of these tokens.',
    SwapReason.invalidAmount => 'Enter a valid amount.',
    SwapReason.insufficient => 'You don\'t have that much $pay.',
    SwapReason.noRoute => 'No route for this swap. Try another amount or coin.',
    SwapReason.expired => 'That price expired. Go back for a fresh one.',
    SwapReason.insufficientSol => 'Not enough SOL to pay for the swap. Keep up to ${error.needed} SOL for fees.',
    SwapReason.unsafe => 'Zandr stopped this swap and signed nothing: ${error.detail}',
    SwapReason.simulation => 'This swap would fail: ${error.detail}',
    SwapReason.network => 'The network couldn\'t be reached or refused: ${error.detail ?? 'no reason given'}',
  };
}

class SwapScreen extends StatefulWidget {
  // A quote shown as is, without asking the network: for the screens' preview.
  final SwapQuote? preview;
  const SwapScreen({super.key, this.preview});
  @override
  State<SwapScreen> createState() => _SwapScreenState();
}

class _SwapScreenState extends State<SwapScreen> with SingleTickerProviderStateMixin {
  _Side? _pay;
  _Side? _receive;
  final _amount = TextEditingController();
  bool _max = false;
  SwapQuote? _quote;
  Object? _failure;
  bool _quoting = false;
  Timer? _debounce;
  int _asked = 0;
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    final sol = state.portfolio?.coins.firstOrNull;
    _pay = sol == null ? _Side(wrappedSol, symbol: 'SOL', name: 'Solana', verified: true, logo: state.jupiter.logo(wrappedSol)) : _Side.ofCoin(sol);
    _receive = _Side(usdcMint, symbol: 'USDC', name: 'USD Coin', verified: true, logo: state.jupiter.logo(usdcMint));
    // Ready by the time a price comes back for an amount.
    _priceOf(_receive);
    if (widget.preview case final quote?) {
      _quote = quote;
      _amount.text = quote.inAmount;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _debounce?.cancel();
    _shake.dispose();
    super.dispose();
  }

  // Prices of coins the wallet doesn't hold, from Jupiter, for what they're worth in dollars.
  final _prices = <String, double?>{};

  // Asks Jupiter once for the price of a coin the wallet doesn't hold.
  void _priceOf(_Side? side) {
    if (side == null || _held(side.mint) != null || _prices.containsKey(side.mint)) return;
    _prices[side.mint] = null;
    AppScope.read(context).jupiter.prices([side.mint]).then((found) {
      if (mounted && found[side.mint] != null) setState(() => _prices[side.mint] = found[side.mint]!.price);
    }, onError: (_) => _prices.remove(side.mint));
  }

  // In US dollars, at the price of the coin as the wallet holds it, or else Jupiter's; null with no
  // price, or for an amount that isn't one.
  double? _worth(String? mint, String amount) {
    final price = mint == null ? null : _held(mint)?.price ?? _prices[mint];
    final value = double.tryParse(amount);
    return price == null || value == null || value <= 0 ? null : value * price;
  }

  // Whenever both coins are picked, as in the extension.
  bool get _canFlip => _pay != null && _receive != null;
  // Half a turn per switch, for the button's arrows.
  double _flipTurns = 0;

  Coin? _held(String mint) => AppScope.read(context).portfolio?.coins.where((c) => c.mint == mint && (c.native || mint != wrappedSol)).firstOrNull;

  void _requote() {
    _debounce?.cancel();
    final asked = ++_asked;
    setState(() {
      _quote = null;
      _failure = null;
      // A request still on its way is no longer this one: nothing is being quoted until asked.
      _quoting = false;
    });
    final pay = _pay, receive = _receive;
    _priceOf(pay);
    _priceOf(receive);
    final coin = pay == null ? null : _held(pay.mint);
    final amount = coin == null ? null : parseUnits(_amount.text, coin.decimals);
    if (pay == null || receive == null || coin == null || (!_max && (amount == null || amount <= BigInt.zero))) return;
    if (!_max && amount! > BigInt.parse(coin.amount)) {
      HapticFeedback.mediumImpact();
      _shake.forward(from: 0);
      return;
    }
    setState(() => _quoting = true);
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final state = AppScope.read(context);
      try {
        final quote = await state.swapper().quote(state.active!.address, pay.mint, receive.mint, _max ? 'max' : _amount.text.trim());
        if (mounted && asked == _asked) {
          setState(() => _quote = quote);
          // Built and checked while the price is on screen, so Swap only signs and sends.
          state.swapper().prepare(quote, state.active!.address);
        }
      } catch (error) {
        if (mounted && asked == _asked) setState(() => _failure = error);
      } finally {
        if (mounted && asked == _asked) setState(() => _quoting = false);
      }
    });
  }

  Future<void> _pickPay() async {
    final coins = AppScope.read(context).portfolio?.coins ?? const [];
    final picked = await showSheet<_Side>(context, (context) => _TokenPicker(held: coins, searchable: false));
    if (picked == null) return;
    setState(() {
      if (picked.mint == _receive?.mint) _receive = _pay;
      _pay = picked;
      _max = false;
      _amount.clear();
    });
    _requote();
  }

  Future<void> _pickReceive() async {
    final picked = await showSheet<_Side>(context, (context) => _TokenPicker(held: const [], searchable: true));
    if (picked == null) return;
    setState(() {
      if (picked.mint == _pay?.mint) _pay = _receive;
      _receive = picked;
    });
    _requote();
  }

  // The two coins swap places, as in the extension: what was to come is now what's paid, as much as
  // the price said would come. A coin the wallet doesn't hold can't be paid, which the card says.
  void _flip() {
    final pay = _pay, receive = _receive;
    if (pay == null || receive == null) return;
    HapticFeedback.selectionClick();
    final out = _quote?.outAmount;
    setState(() {
      _receive = pay;
      _pay = receive;
      _max = false;
      _amount.text = out ?? '';
      _flipTurns += 0.5;
    });
    _requote();
  }

  void _swap() {
    final quote = _quote!;
    final state = AppScope.read(context);
    final pay = _pay!.label, receive = _receive!.label;
    // Straight to the waiting screen: the swap is built, checked, signed and sent there. Back from
    // one that didn't go, a fresh quote.
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => OutcomeScreen(
              workingTitle: 'Swapping…',
              doneTitle: 'Swapped',
              run: () async {
                final result = await state.swapper().execute(quote, state.active!.address, state.sign);
                return (sent: [(signature: result.signature, pending: result.pending)], summary: '${formatAmount(quote.inAmount)} $pay for about ${formatAmount(result.review.outAmount)} $receive');
              },
              describe: (error) => swapFailureText(error, pay),
            ),
          ),
        )
        .then((_) {
          if (mounted) _requote();
        });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    if (state.network != Network.mainnet) {
      return const SubScreen(
        title: 'Swap',
        child: Padding(
          padding: EdgeInsets.all(gutter),
          child: Notice('Swaps work on Mainnet only', danger: false, body: 'Switch the network in Settings to swap.'),
        ),
      );
    }
    final coin = _pay == null ? null : _held(_pay!.mint);
    final amount = coin == null ? null : parseUnits(_amount.text, coin.decimals);
    final over = amount != null && coin != null && amount > BigInt.parse(coin.amount);
    final quote = _quote;

    return SubScreen(
      title: 'Swap',
      bottom: PrimaryButton('Swap', busy: _quoting, onPressed: quote == null ? null : _swap),
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        children: [
          // The two cards, the same height, with the switch button over the seam between them, as
          // in the extension.
          Stack(
            alignment: Alignment.center,
            children: [
              Column(
                children: [
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 32,
                          child: Row(
                            children: [
                              Text(
                                'You pay',
                                style: geist(15, weight: FontWeight.w500, color: p.muted),
                              ),
                              const Spacer(),
                              Chip2(
                                'Half',
                                onTap: coin == null
                                    ? null
                                    : () {
                                        setState(() {
                                          _max = false;
                                          _amount.text = formatUnits(BigInt.parse(coin.amount) ~/ BigInt.two, coin.decimals);
                                        });
                                        _requote();
                                      },
                              ),
                              const SizedBox(width: 8),
                              Chip2(
                                'Max',
                                onTap: coin == null
                                    ? null
                                    : () {
                                        setState(() {
                                          // All of a token; all the SOL but what the swap itself costs.
                                          _max = true;
                                          _amount.text = coin.balance;
                                        });
                                        _requote();
                                      },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 44,
                          child: Row(
                            children: [
                              _TokenButton(_pay, onTap: _pickPay),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: _amount,
                                  textAlign: TextAlign.right,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                                    TextInputFormatter.withFunction((o, v) => v.copyWith(text: v.text.replaceAll(',', '.'))),
                                  ],
                                  onChanged: (_) {
                                    _max = false;
                                    _requote();
                                  },
                                  style: geist(30, weight: FontWeight.w600, color: over ? p.danger : p.fg, features: tabular),
                                  decoration: InputDecoration(
                                    border: InputBorder.none,
                                    hintText: '0',
                                    hintStyle: geist(30, weight: FontWeight.w600, color: p.muted),
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 20,
                          child: Row(
                            children: [
                              Expanded(
                                child: ShakeX(
                                  controller: _shake,
                                  child: Text(
                                    coin == null ? 'You don\'t hold this coin' : 'Balance ${formatAmount(coin.balance)} ${_pay!.label}',
                                    style: geist(14, color: over ? p.danger : p.muted),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (_worth(_pay?.mint, _amount.text) case final worth?)
                                Text(
                                  '≈ ${formatUsd(worth)}',
                                  style: geist(14, color: p.muted, features: tabular),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 32,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'You receive',
                              style: geist(15, weight: FontWeight.w500, color: p.muted),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 44,
                          child: Row(
                            children: [
                              _TokenButton(_receive, onTap: _pickReceive),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  quote == null ? (_quoting ? '…' : '0') : formatAmount(quote.outAmount),
                                  textAlign: TextAlign.right,
                                  overflow: TextOverflow.ellipsis,
                                  style: geist(30, weight: FontWeight.w600, color: quote == null ? p.muted : p.fg, features: tabular),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 20,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _receive != null && _held(_receive!.mint) != null ? 'Balance ${formatAmount(_held(_receive!.mint)!.balance)} ${_receive!.label}' : '',
                                  style: geist(14, color: p.muted),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (quote != null)
                                if (_worth(_receive?.mint, quote.outAmount) case final worth?)
                                  Text(
                                    '≈ ${formatUsd(worth)}',
                                    style: geist(14, color: p.muted, features: tabular),
                                  ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Semantics(
                button: true,
                label: 'Switch coins',
                child: Pressable(
                  scale: 0.9,
                  onTap: _canFlip ? _flip : null,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: p.raised,
                      shape: BoxShape.circle,
                      border: Border.all(color: p.bg, width: 4),
                    ),
                    child: Center(
                      child: AnimatedRotation(
                        turns: _flipTurns,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        child: ZIcon(ZIcons.flip, size: 18, color: _canFlip ? p.fg : p.muted),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_failure != null) Notice(swapFailureText(_failure!, _pay?.label ?? 'it')),
          if (quote != null)
            Panel(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  DetailRow('At least', Text('${formatAmount(quote.minOutAmount)} ${_receive!.label}')),
                  DetailRow(
                    'Rate',
                    Text(() {
                      final ratio = double.parse(quote.outAmount) / max(double.parse(quote.inAmount), 1e-18);
                      return '1 ${_pay!.label} ≈ ${formatAmount('$ratio')} ${_receive!.label}';
                    }()),
                  ),
                  DetailRow(
                    'Price impact',
                    Text(
                      '${quote.priceImpactPct < 0.01 ? '<0.01' : quote.priceImpactPct.toStringAsFixed(2)}%',
                      style: geist(
                        15,
                        weight: FontWeight.w500,
                        color: quote.priceImpactPct > 3
                            ? p.danger
                            : quote.priceImpactPct > 1
                            ? p.caution
                            : p.fg,
                      ),
                    ),
                  ),
                  if (quote.build.route.isNotEmpty) DetailRow('Route', Text(quote.build.route.toSet().join(' → '))),
                  if (quote.feeText != null) DetailRow('Zandr fee (0.85%)', Text('${formatAmount(quote.feeText!)} SOL')),
                ],
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TokenButton extends StatelessWidget {
  final _Side? side;
  final VoidCallback onTap;
  const _TokenButton(this.side, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(26)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CoinLogo(side?.logo, side?.label, size: 32),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                side?.label ?? 'Select',
                style: geist(17, weight: FontWeight.w600, color: p.fg),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (side?.verified ?? false) ...[const SizedBox(width: 4), const VerifiedBadge(size: 15)],
            const SizedBox(width: 4),
            ZIcon(ZIcons.chevronDown, size: 18, color: p.muted),
          ],
        ),
      ),
    );
  }
}

// Coins the wallet holds (to pay with), or any token: popular ones first, then what's searched.
class _TokenPicker extends StatefulWidget {
  final List<Coin> held;
  final bool searchable;
  const _TokenPicker({required this.held, required this.searchable});
  @override
  State<_TokenPicker> createState() => _TokenPickerState();
}

class _TokenPickerState extends State<_TokenPicker> {
  final _query = TextEditingController();
  List<TokenListing>? _found;
  bool _searching = false;
  Timer? _debounce;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    if (widget.searchable) _search('');
  }

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String query) {
    _debounce?.cancel();
    final asked = ++_asked;
    setState(() => _searching = true);
    _debounce = Timer(Duration(milliseconds: query.isEmpty ? 0 : 300), () async {
      try {
        final found = await AppScope.read(context).swapper().tokens(query);
        if (mounted && asked == _asked) setState(() => _found = found);
      } catch (_) {
        if (mounted && asked == _asked) setState(() => _found = const []);
      } finally {
        if (mounted && asked == _asked) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget row(_Side side, String? trailing, String? subtitle) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: gutter),
      leading: CoinLogo(side.logo, side.label),
      title: Row(
        children: [
          Flexible(
            child: Text(
              side.label,
              style: geist(16, weight: FontWeight.w600, color: p.fg),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (side.verified) ...[const SizedBox(width: 4), const VerifiedBadge(size: 15)],
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: geist(14, color: p.muted),
              overflow: TextOverflow.ellipsis,
            ),
      trailing: trailing == null
          ? null
          : Text(
              trailing,
              style: geist(15, weight: FontWeight.w500, color: p.fg),
            ),
      onTap: () => Navigator.pop(context, side),
    );
    final bottom = MediaQuery.paddingOf(context).bottom;
    // Searching takes the whole screen; picking from what's held, half of it, or more for many.
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        height: widget.searchable ? box.maxHeight : sheetHeight(box.maxHeight, 44 + widget.held.length * 72.0 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
              child: Text(
                widget.searchable ? 'Receive' : 'Pay with',
                style: geist(20, weight: FontWeight.w600, color: p.fg),
              ),
            ),
            if (widget.searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
                child: Field(_query, hint: 'Name, symbol or mint address', autofocus: false, onChanged: (value) => _search(value.trim()), suffix: _searching ? const Spinner(size: 16) : null),
              ),
            // Down to the screen's edge, the last rows scrolling clear of the home indicator.
            Expanded(
              child: ListView(
                physics: scrollIfNeeded,
                padding: EdgeInsets.only(bottom: bottom + 8),
                children: [
                  if (!widget.searchable)
                    for (final coin in widget.held) row(_Side.ofCoin(coin), coin.value == null ? null : formatUsd(coin.value!), formatAmount(coin.balance)),
                  if (widget.searchable)
                    for (final token in _found ?? const <TokenListing>[])
                      row(_Side.ofListing(token), null, token.info.verified ? token.info.name : '${token.info.name ?? ''} · ${shortAddress(token.mint)}'),
                  if (widget.searchable && _found != null && _found!.isEmpty && !_searching)
                    Padding(
                      padding: const EdgeInsets.all(gutter),
                      child: Text('Nothing found', style: geist(15, color: p.muted)),
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
