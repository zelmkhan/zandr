// The wallet: its name and address, what it's worth, the main actions, and its coins and history,
// kept live.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/preferences.dart';
import '../core/activity.dart';
import '../core/config.dart';
import '../core/models.dart';
import 'address_book.dart';
import 'app.dart';
import 'format.dart';
import 'icons.dart';
import 'receive.dart';
import 'reclaim.dart';
import 'send.dart';
import 'settings.dart';
import 'swap.dart';
import 'theme.dart';
import 'wallets.dart';
import 'widgets.dart';

// The unlocked wallet's own navigator: locking replaces it whole, so nothing opened before stays.
class HomeNavigator extends StatelessWidget {
  const HomeNavigator({super.key});
  @override
  Widget build(BuildContext context) => Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const HomeScreen()));
}

Future<T?> push<T>(BuildContext context, Widget screen) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

class HomeScreen extends StatefulWidget {
  final bool activityTab;
  const HomeScreen({super.key, this.activityTab = false});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late bool _activityTab = widget.activityTab;

  @override
  void initState() {
    super.initState();
    if (_activityTab) WidgetsBinding.instance.addPostFrameCallback((_) => AppScope.read(context).loadActivity());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final wallet = state.active;
    if (wallet == null) return const SizedBox();
    final portfolio = state.portfolio;
    final hide = state.preferences.hideBalance;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // The wallet: tap the avatar for the others, the address to copy it.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  GestureDetector(onTap: () => showWallets(context), child: Monogram(wallet.name, wallet.address, size: 44)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => showWallets(context),
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            wallet.name,
                            style: geist(17, weight: FontWeight.w600, color: p.fg),
                            overflow: TextOverflow.ellipsis,
                          ),
                          // The copy icon turns into a check once copied, as in the extension.
                          Momentary(
                            builder: (context, copied, run) => GestureDetector(
                              onTap: () => run(() => copyText(wallet.address)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(copied ? 'Copied' : shortAddress(wallet.address), style: geist(14, color: p.muted)),
                                  const SizedBox(width: 6),
                                  ZIcon(copied ? ZIcons.check : ZIcons.copy, size: 14, color: p.muted),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (state.network == Network.devnet)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: p.caution.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        'Devnet',
                        style: geist(13, weight: FontWeight.w600, color: p.caution),
                      ),
                    ),
                  Builder(
                    builder: (button) => IconButton(
                      onPressed: () => _menu(button),
                      icon: ZIcon(ZIcons.more, size: 20, color: p.muted),
                      tooltip: 'Menu',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: p.fg,
                backgroundColor: p.raised,
                onRefresh: () async {
                  HapticFeedback.lightImpact();
                  await Future.wait([state.refreshPortfolio(), if (_activityTab) state.loadActivity()]);
                },
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          const SizedBox(height: 32),
                          GestureDetector(
                            onTap: () => state.setPreferences(state.preferences.copyWith(hideBalance: !hide)),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // A new balance, or hiding it, fades in over the old.
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  switchInCurve: Curves.easeOut,
                                  switchOutCurve: Curves.easeIn,
                                  child: !hide && portfolio == null && state.portfolioError == null
                                      // Exactly a balance's height, so nothing below moves when it arrives.
                                      ? Stack(
                                          key: const ValueKey('loading'),
                                          alignment: Alignment.center,
                                          children: [
                                            Opacity(
                                              opacity: 0,
                                              child: Text(
                                                r'$0,000.00',
                                                style: geist(40, weight: FontWeight.w600, spacing: -0.04 * 40, features: tabular),
                                              ),
                                            ),
                                            const SkeletonBlock(176, 42),
                                          ],
                                        )
                                      : Text(
                                          hide
                                              ? '•••••'
                                              : portfolio == null
                                              ? '—'
                                              : formatUsd(portfolio.value),
                                          key: ValueKey(hide ? 'hidden' : portfolio?.value),
                                          // As the extension's balance: tight digits, but dots spread apart.
                                          style: geist(40, weight: FontWeight.w600, color: p.fg, spacing: hide ? 4 : -0.04 * 40, features: tabular),
                                        ),
                                ),
                                const SizedBox(width: 12),
                                ZIcon(hide ? ZIcons.eye : ZIcons.eyeOff, size: 22, color: p.muted),
                              ],
                            ),
                          ),
                          const SizedBox(height: 28),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              // As in the extension, Explore is here before it leads anywhere.
                              Momentary(builder: (context, soon, run) => RoundAction(ZIcons.explore, soon ? 'Soon' : 'Explore', () => run(() async {}))),
                              RoundAction(ZIcons.receive, 'Receive', () => push(context, const ReceiveScreen())),
                              RoundAction(ZIcons.send, 'Send', () => push(context, const SendScreen())),
                              RoundAction(ZIcons.swap, 'Swap', () => push(context, const SwapScreen())),
                            ],
                          ),
                          const SizedBox(height: 28),
                          // One height for both tabs, so switching moves nothing; the buttons' icons end
                          // where the coins' values do.
                          Padding(
                            padding: const EdgeInsets.only(left: gutter, right: gutter - 8),
                            child: SizedBox(
                              height: 40,
                              child: Row(
                                children: [
                                  _Tab('Coins', !_activityTab, () => setState(() => _activityTab = false)),
                                  const SizedBox(width: 20),
                                  _Tab('Activity', _activityTab, () {
                                    setState(() => _activityTab = true);
                                    if (!state.activityLoaded) state.loadActivity();
                                  }),
                                  const Spacer(),
                                  if (!_activityTab) ...[
                                    _BarButton(ZIcons.reclaim, 'Reclaim SOL', (_) => push(context, const ReclaimScreen())),
                                    const SizedBox(width: 4),
                                    _BarButton(ZIcons.filter, 'Hide small coins', _filter, lit: state.preferences.minCoinValue > 0),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_activityTab) ..._activity(context) else ..._coins(context),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The wallet's menu, dropping from the dots as in the extension: settings, the address book,
  // locking.
  void _menu(BuildContext button) {
    final state = AppScope.read(button);
    void then(BuildContext menu, VoidCallback action) {
      Navigator.pop(menu);
      action();
    }

    showDropdown<void>(
      button,
      (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownItem(ZIcons.settings, 'Settings', () => then(menu, () => push(button, const SettingsScreen()))),
          DropdownItem(ZIcons.addressBook, 'Address book', () => then(menu, () => push(button, const AddressBookScreen()))),
          DropdownItem(ZIcons.lock, 'Lock wallet', () => then(menu, state.lock)),
        ],
      ),
    );
  }

  // Coins worth less than a minimum left out, picked in a row as in the extension.
  void _filter(BuildContext button) {
    final state = AppScope.read(button);
    showDropdown<void>(button, (menu) {
      final p = Palette.of(menu);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
            child: Text(
              'Minimum value',
              style: geist(13, weight: FontWeight.w500, color: p.muted),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, value) in minCoinValueChoices.indexed) ...[
                if (i > 0) const SizedBox(width: 4),
                _Choice(value == 0 ? 'None' : '>${formatUsd(value)}', state.preferences.minCoinValue == value, () {
                  state.setPreferences(state.preferences.copyWith(minCoinValue: value));
                  Navigator.pop(menu);
                }),
              ],
            ],
          ),
        ],
      );
    });
  }

  List<Widget> _coins(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final portfolio = state.portfolio;
    if (portfolio == null) {
      return [
        SliverToBoxAdapter(
          child: state.portfolioError != null
              ? EmptyState(
                  ZIcons.offline,
                  'Couldn\'t load your coins',
                  text: 'The network didn\'t answer.',
                  action: Chip2('Try again', onTap: state.refreshPortfolio),
                )
              : const SkeletonRows(),
        ),
      ];
    }
    final minimum = state.preferences.minCoinValue;
    final shown = [
      for (final coin in portfolio.coins)
        if (coin.native || minimum == 0 || (coin.value ?? 0) >= minimum) coin,
    ];
    final hidden = portfolio.coins.length - shown.length;
    return [
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) => _CoinRow(shown[i], hide: state.preferences.hideBalance),
      ),
      if (hidden > 0)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '$hidden coin${hidden == 1 ? '' : 's'} worth under ${formatUsd(minimum)} hidden',
              textAlign: TextAlign.center,
              style: geist(14, color: p.muted),
            ),
          ),
        ),
    ];
  }

  List<Widget> _activity(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.activityLoaded) {
      return [
        SliverToBoxAdapter(
          child: state.activityError != null
              ? EmptyState(
                  ZIcons.offline,
                  'Couldn\'t load the activity',
                  text: 'The network didn\'t answer.',
                  action: Chip2('Try again', onTap: () => state.loadActivity()),
                )
              : const SkeletonRows(),
        ),
      ];
    }
    if (state.activity.isEmpty) {
      return [SliverToBoxAdapter(child: EmptyState(ZIcons.clock, 'No activity yet', text: 'Transfers and swaps show up here.'))];
    }
    return [
      SliverList.builder(
        itemCount: state.activity.length,
        itemBuilder: (context, i) => _ActivityRow(state.activity[i], network: state.network),
      ),
      if (state.activityNext != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: state.activityLoading ? const Spinner() : Chip2('Show more', onTap: () => state.loadActivity(more: true))),
          ),
        ),
    ];
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Tab(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: geist(18, weight: FontWeight.w600, color: selected ? p.fg : p.muted),
      ),
    );
  }
}

class _CoinRow extends StatelessWidget {
  final Coin coin;
  final bool hide;
  const _CoinRow(this.coin, {required this.hide});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final change = coin.change24h;
    return InkWell(
      onTap: () => push(context, SendScreen(mint: coin.native ? null : coin.mint)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 10),
        child: Row(
          children: [
            CoinLogo(coin.logo, coin.symbol ?? coin.name, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          coin.label,
                          style: geist(17, weight: FontWeight.w600, color: p.fg),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (coin.verified) ...[const SizedBox(width: 5), const VerifiedBadge()],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hide ? '•••' : formatAmount(coin.balance),
                    style: geist(15, color: p.muted, features: tabular),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  hide
                      ? '•••'
                      : coin.value == null
                      ? '—'
                      : formatUsd(coin.value!),
                  style: geist(17, weight: FontWeight.w600, color: p.fg, features: tabular),
                ),
                if (change != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    formatChange(change),
                    style: geist(14, color: change >= 0 ? p.up : p.down, features: tabular),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Activity item;
  final Network network;
  const _ActivityRow(this.item, {required this.network});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (icon, title) = switch (item.kind) {
      ActivityKind.send => (ZIcons.send, 'Sent'),
      ActivityKind.receive => (ZIcons.receive, 'Received'),
      ActivityKind.swap => (ZIcons.swap, 'Swapped'),
      ActivityKind.app => (ZIcons.app, item.app ?? 'App'),
      ActivityKind.failed => (ZIcons.close, 'Failed'),
    };
    final who = item.counterparty != null
        ? '${item.kind == ActivityKind.receive ? 'From' : 'To'} ${shortAddress(item.counterparty!)}'
        : item.app ?? (item.program != null ? shortAddress(item.program!) : null);
    final subtitle = [?who, if (item.time != null) timeAgo(item.time!)].join(' · ');
    return InkWell(
      onTap: () => launchUrl(Uri.parse(explorerTransaction(item.signature, network)), mode: LaunchMode.externalApplication),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: item.kind == ActivityKind.failed ? p.danger.withValues(alpha: 0.12) : p.fill, shape: BoxShape.circle),
              child: Center(child: ZIcon(icon, size: 20, color: item.kind == ActivityKind.failed ? p.danger : p.fg)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: geist(17, weight: FontWeight.w600, color: p.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: geist(14, color: p.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final change in item.changes.take(2))
                  Text(
                    '${change.amount.startsWith('-') ? '−' : '+'}${formatAmount(change.amount.substring(1))} ${change.symbol ?? shortAddress(change.mint ?? '')}',
                    style: geist(15, weight: FontWeight.w600, color: change.amount.startsWith('-') ? p.fg : p.up, features: tabular),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// One of the minimum values: lit when it's the one set.
class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Choice(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Pressable(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        height: 36,
        constraints: const BoxConstraints(minWidth: 70),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? p.fillStrong : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        child: Text(
          label,
          style: geist(14, weight: FontWeight.w500, color: selected ? p.fg : p.muted, features: tabular),
        ),
      ),
    );
  }
}

// A small round button beside the tabs, as the extension's: its icon grey, or lit while it has
// something set (a minimum value hiding coins).
class _BarButton extends StatelessWidget {
  final Glyph icon;
  final String label;
  final void Function(BuildContext button) onTap;
  final bool lit;
  const _BarButton(this.icon, this.label, this.onTap, {this.lit = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        scale: 0.9,
        onTap: () => onTap(context),
        child: SizedBox.square(
          dimension: 36,
          child: Center(child: ZIcon(icon, size: 20, color: lit ? p.fg : p.muted)),
        ),
      ),
    );
  }
}
