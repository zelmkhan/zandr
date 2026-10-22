// Settings, laid out as the extension's (src/entrypoints/options): General, Network, Security and
// About, each a page of its own. In Security each transfer protection opens to a page of its own
// too: what it stops, how, the exchanges it knows, and what it can't catch.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app/preferences.dart';
import '../core/config.dart';
import '../core/exchanges.dart';
import '../core/send.dart' show Protection;
import '../core/solana/rpc.dart';
import 'app.dart';
import 'home.dart' show push;
import 'icons.dart';
import 'theme.dart';
import 'wallets.dart' show confirmed;
import 'widgets.dart';

typedef ProtectionInfo = ({String title, String summary, String lead, List<(String, String)> steps, List<String> limits});

// What each protection is: one line for its row, then its page (src/entrypoints/options/sections/protections.ts).
const protectionInfo = <Protection, ProtectionInfo>{
  Protection.exchangeSupport: (
    title: 'Unsupported tokens on exchanges',
    summary: 'Stop a transfer when the address belongs to an exchange that doesn\'t accept the token.',
    lead: 'Exchanges accept only some tokens on each network. Send one they don\'t support and it usually never reaches your account, and getting it back, if the exchange can at all, takes weeks.',
    steps: [
      ('Recognizes exchange addresses', 'Zandr checks whether the address you\'re sending to is a deposit address of an exchange it knows, or the exchange\'s own wallet, which credits no one.'),
      (
        'Checks the token',
        'It looks up whether that exchange accepts this exact token on Solana, matched by its mint address rather than its name, so look-alike tokens don\'t slip through, and whether the amount reaches the exchange\'s minimum deposit.',
      ),
      ('Stops the transfer', 'If the exchange doesn\'t accept it, Zandr stops the transfer and tells you why, before anything leaves your wallet.'),
    ],
    limits: [
      'A brand-new deposit address that hasn\'t received anything yet: it can\'t be told apart from a regular wallet.',
      'A deposit address that sends its deposits on to an exchange wallet Zandr doesn\'t know.',
      'Tokens of exchanges marked Addresses only or Partial above: their token lists aren\'t public or not complete.',
      'On exchanges marked Traded tokens: a token the exchange trades but takes only on another network.',
      'Changes an exchange makes to its tokens since Zandr\'s last update of its list (every few hours).',
      'A transfer when Zandr can\'t tell within a few seconds whether the address is an exchange\'s: it isn\'t held up for it.',
    ],
  ),
  Protection.programAddresses: (
    title: 'Program addresses',
    summary: 'Stop transfers to programs and to addresses only a program controls, where tokens can get stuck for good.',
    lead: 'Programs, and the addresses they control, have no private key. Tokens sent there can only be moved by the program itself, which usually never happens.',
    steps: [
      ('Looks up the recipient', 'Before sending, Zandr checks on-chain whether the address is a program, or an address derived from one, rather than a regular wallet.'),
      ('Stops the transfer', 'If it is, Zandr stops the transfer and explains what the address is.'),
    ],
    limits: [
      'Transfers that apps you connect to make as part of their own transactions, like a swap or a deposit into a protocol.',
      'Wallets that are themselves controlled by a program, such as multisig vaults: they are stopped too, and you can send anyway once you have checked.',
    ],
  ),
  Protection.mintAddresses: (
    title: 'Token mint addresses',
    summary: 'Stop transfers to a token\'s own mint address, a common copy-paste mistake.',
    lead: 'A mint address identifies a token itself, much like a contract address. It\'s easy to copy it from an explorer or a token page by mistake, and tokens sent there are lost.',
    steps: [
      ('Looks up the recipient', 'Zandr checks on-chain whether the address is a token mint.'),
      ('Stops the transfer', 'If it is, Zandr stops the transfer and names the token the address belongs to.'),
    ],
    limits: [],
  ),
  Protection.tokenAccounts: (
    title: 'Token account addresses',
    summary: 'Stop transfers to a token account instead of the wallet that owns it.',
    lead: 'On Solana each token sits in a separate token account that belongs to a wallet. Sending to a token account as if it were a wallet locks the tokens in an account nobody can use.',
    steps: [
      ('Looks up the recipient', 'Zandr checks on-chain whether the address is a token account rather than a wallet.'),
      ('Points you to the owner', 'If it is, Zandr stops the transfer and shows the wallet that owns it, so you can send there instead.'),
    ],
    limits: ['Sending a token into a token account for that same token: a valid transfer, so it goes through.'],
  ),
  Protection.lookalikeAddresses: (
    title: 'Lookalike addresses',
    summary: 'Stop transfers to an address that starts and ends like one you know, but isn\'t it.',
    lead:
        'Scammers send tiny amounts from addresses that share the first and last characters with ones you use, hoping you\'ll copy theirs from your history next time. Wallets show addresses shortened, so the two look the same.',
    steps: [
      ('Compares the recipient', 'Zandr checks it against your wallets and the addresses in your address book: the same first and last four characters, but a different address in between.'),
      ('Stops the transfer', 'If it looks like one of them without being it, Zandr stops the transfer and names the address it imitates.'),
    ],
    limits: ['An address that imitates one you haven\'t saved and that isn\'t one of your wallets.', 'A lookalike that differs within the first or last four characters.'],
  ),
};

String _networkName(Network network) => network == Network.mainnet ? 'Mainnet' : 'Devnet';

// The node a network is reached through: the default one (zandr's on mainnet, Solana's on devnet),
// public services (mainnet only), or one the user set.
enum _Node { standard, public, custom }

_Node _nodeOf(Preferences prefs, Network network) => prefs.rpc[network] != null
    ? _Node.custom
    : network == Network.mainnet && prefs.publicServices
        ? _Node.public
        : _Node.standard;

String _nodeName(_Node node, Network network) => switch (node) {
  _Node.standard => network == Network.mainnet ? 'Zandr\'s node' : 'Solana\'s node',
  _Node.public => 'Public services',
  _Node.custom => 'Your node',
};

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final prefs = state.preferences;
    final on = prefs.protections.length;
    return SubScreen(
      title: 'Settings',
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 32),
        children: [
          _Card([
            _NavRow(ZIcons.settings, 'General', switch (prefs.theme) {
              ThemeChoice.dark => 'Dark theme',
              ThemeChoice.light => 'Light theme',
              ThemeChoice.system => 'Theme as the iPhone\'s',
            }, () => push(context, const _GeneralPage())),
            _NavRow(ZIcons.network, 'Network', '${_networkName(prefs.network)} · ${_nodeName(_nodeOf(prefs, prefs.network), prefs.network)}', () => push(context, const _NetworkPage())),
            _NavRow(ZIcons.lock, 'Security', on == Protection.values.length ? 'All protections on' : '$on of ${Protection.values.length} protections on', () => push(context, const _SecurityPage())),
            _NavRow(ZIcons.info, 'About', 'Version $appVersion', () => push(context, const _AboutPage())),
          ]),
        ],
      ),
    );
  }
}

// ---- The pages ----

class _GeneralPage extends StatelessWidget {
  const _GeneralPage();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final prefs = state.preferences;
    return _Page(
      title: 'General',
      lead: 'How Zandr looks and what it shows.',
      children: [
        _Card([
          _ChoiceRow<ThemeChoice>(
            'Theme',
            'Dark, light, or the same as your iPhone.',
            options: ThemeChoice.values,
            value: prefs.theme,
            label: (theme) => switch (theme) {
              ThemeChoice.dark => 'Dark',
              ThemeChoice.light => 'Light',
              ThemeChoice.system => 'System',
            },
            onChanged: (theme) => state.setPreferences(prefs.copyWith(theme: theme)),
          ),
          _SwitchRow('Hide balance', 'Show dots instead of amounts, for when others can see your screen.', prefs.hideBalance, (on) => state.setPreferences(prefs.copyWith(hideBalance: on))),
        ]),
      ],
    );
  }
}

class _NetworkPage extends StatefulWidget {
  const _NetworkPage();
  @override
  State<_NetworkPage> createState() => _NetworkPageState();
}

enum _Check { checking, ok, failed }

class _NetworkPageState extends State<_NetworkPage> {
  // Editing a custom node: opened by choosing Custom, closed by saving or cancelling.
  bool _editing = false;
  final _draft = TextEditingController();
  String? _error;
  bool _saving = false;

  // The last check of the node in use, for the endpoint it was made of.
  String? _checkedUrl;
  _Check? _check;
  RpcProbe? _probe;
  String? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkConnection());
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  String _failureText(Object error, {required bool forStatus}) => switch (error) {
    ChainError(reason: RpcFailure.forbidden) => forStatus ? 'Refuses the request: it may need an API key in the URL' : 'This node refuses requests. It may need an API key in the URL.',
    ChainError(reason: RpcFailure.unreachable) => forStatus ? 'Not responding' : 'Couldn\'t reach this URL.',
    _ => forStatus ? 'Doesn\'t answer like a Solana node' : 'This URL doesn\'t answer like a Solana node.',
  };

  Future<void> _checkConnection() async {
    final url = AppScope.read(context).preferences.rpcUrl(AppScope.read(context).network);
    setState(() {
      _checkedUrl = url;
      _check = _Check.checking;
    });
    try {
      final probe = await probeRpc(url, AppScope.read(context).client);
      if (mounted && _checkedUrl == url) {
        setState(() {
          _check = _Check.ok;
          _probe = probe;
        });
      }
    } catch (error) {
      if (mounted && _checkedUrl == url) {
        // Zandr's node: Helius's public one stands in while it can't answer.
        final standIn = url == defaultRpc[Network.mainnet];
        setState(() {
          _check = _Check.failed;
          _failure = '${_failureText(error, forStatus: true)}${standIn ? ' · Helius\'s public node stands in' : ''}';
        });
      }
    }
  }

  Future<void> _set(Preferences next) async {
    await AppScope.read(context).setPreferences(next);
    if (mounted) _checkConnection();
  }

  // A custom node is saved only once it answers, and from the network it's meant for: one on
  // another network would quietly show the wrong balances and send to the wrong chain.
  Future<void> _saveCustom() async {
    final state = AppScope.read(context);
    final network = state.network;
    final url = _draft.text.trim();
    final invalid = checkRpcUrl(url);
    if (invalid != null) return setState(() => _error = invalid);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final probe = await probeRpc(url, AppScope.read(context).client);
      if (!mounted) return;
      if (probe.network != network) {
        setState(() => _error = probe.network == null ? 'This node isn\'t on Solana ${_networkName(network)}.' : 'This node is on ${_networkName(probe.network!)}, not ${_networkName(network)}.');
        return;
      }
      // Your own node in place of public services, so Jupiter goes through zandr's server again.
      await state.setPreferences(state.preferences.copyWith(rpc: {...state.preferences.rpc, network: url}, publicServices: network == Network.mainnet ? false : null));
      HapticFeedback.lightImpact();
      setState(() {
        _editing = false;
        _checkedUrl = url;
        _check = _Check.ok;
        _probe = probe;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _failureText(error, forStatus: false));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final prefs = state.preferences;
    final network = state.network;
    final custom = prefs.rpc[network];
    final node = _editing ? _Node.custom : _nodeOf(prefs, network);
    final endpoint = prefs.rpcUrl(network);
    final shown = _checkedUrl == endpoint ? _check : null;
    return _Page(
      title: 'Network',
      lead: 'Which Solana network Zandr uses, and the node it talks to it through.',
      children: [
        _Card([
          _ChoiceRow<Network>(
            'Network',
            network == Network.devnet ? 'A network for testing: its tokens have no real value.' : 'The main Solana network, where tokens have real value.',
            options: Network.values,
            value: network,
            label: _networkName,
            onChanged: (next) {
              setState(() {
                _editing = false;
                _error = null;
              });
              _set(prefs.copyWith(network: next));
            },
          ),
        ]),
        _GroupTitle('Node for ${_networkName(network)}'),
        _Card([
          _ChoiceRow<_Node>(
            _nodeName(node, network),
            switch (node) {
              _Node.standard => network == Network.mainnet ? 'Run by Zandr, which keeps no record of who asks what.' : endpoint,
              _Node.public => 'Helius\'s node, with Jupiter for prices and swaps, asked directly. Nothing goes through Zandr\'s server.',
              _Node.custom => custom ?? 'Any Solana ${_networkName(network)} node, by its URL.',
            },
            options: network == Network.mainnet ? _Node.values : const [_Node.standard, _Node.custom],
            value: node,
            label: (node) => switch (node) {
              // Zandr's node keeps no record of who asks what; devnet's default is Solana's public one.
              _Node.standard => network == Network.mainnet ? 'Private' : 'Default',
              _Node.public => 'Public',
              _Node.custom => 'Custom',
            },
            onChanged: (next) {
              if (next == _Node.custom) {
                setState(() {
                  _editing = true;
                  _draft.text = custom ?? '';
                  _error = null;
                });
              } else {
                setState(() {
                  _editing = false;
                  _error = null;
                });
                // Public services are mainnet's: devnet's choice leaves them as they are.
                _set(prefs.copyWith(rpc: {...prefs.rpc}..remove(network), publicServices: network == Network.mainnet ? next == _Node.public : null));
              }
            },
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Field(_draft, hint: 'https://', keyboard: TextInputType.url, autofocus: true, onChanged: (_) => setState(() => _error = null), onSubmitted: (_) => _saveCustom()),
                  if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: geist(14, color: p.danger, height: 1.4))],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: SecondaryButton('Cancel', onPressed: _saving ? null : () => setState(() => _editing = false))),
                      const SizedBox(width: 10),
                      Expanded(
                        child: PrimaryButton('Check and save', busy: _saving, onPressed: _draft.text.trim().isEmpty ? null : _saveCustom),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          _InfoRow(
            'Connection',
            switch (shown) {
              null || _Check.checking => 'Checking…',
              _Check.failed => _failure ?? 'Not responding',
              _Check.ok => 'Connected · ${_probe!.network == null ? 'unknown network' : _networkName(_probe!.network!)} · v${_probe!.version} · ${_probe!.latencyMs} ms',
            },
            color: switch (shown) {
              _Check.ok => p.up,
              _Check.failed => p.danger,
              _ => p.muted,
            },
            trailing: Chip2('Check', onTap: shown == _Check.checking ? null : _checkConnection),
          ),
        ]),
      ],
    );
  }
}

class _SecurityPage extends StatelessWidget {
  const _SecurityPage();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final prefs = state.preferences;
    return _Page(
      title: 'Security',
      lead: 'Keeping Zandr locked while you\'re away, and stopping risky transfers before they happen.',
      children: [
        _Card([
          _ChoiceRow<int>(
            'Auto-lock',
            'Lock Zandr after this long away or idle. ${state.faceIdAvailable ? 'Face ID or your iPhone\'s passcode' : 'Your iPhone\'s passcode'} unlocks it, and is asked again before a recovery phrase or key shows.',
            options: autoLockChoices,
            value: prefs.autoLockMinutes,
            label: (minutes) => minutes < 60 ? '$minutes min' : '1 hour',
            onChanged: (minutes) => state.setPreferences(prefs.copyWith(autoLockMinutes: minutes)),
          ),
        ]),
        const _GroupTitle('Transfer protection', lead: 'Checks Zandr runs before a transfer leaves your wallet. We recommend keeping them all on.'),
        _Card([
          for (final protection in Protection.values)
            _Row(
              title: protectionInfo[protection]!.title,
              subtitle: protectionInfo[protection]!.summary,
              trailing: _OnOff(prefs.protections.contains(protection)),
              onTap: () => push(context, _ProtectionPage(protection)),
            ),
        ]),
      ],
    );
  }
}

class _ProtectionPage extends StatefulWidget {
  final Protection protection;
  const _ProtectionPage(this.protection);
  @override
  State<_ProtectionPage> createState() => _ProtectionPageState();
}

class _ProtectionPageState extends State<_ProtectionPage> {
  List<ExchangeCoverage>? _exchanges;
  // Why turning it off didn't go through: Face ID or the passcode couldn't confirm.
  String? _problem;
  bool _asking = false;

  // On at once; off only once Face ID or the passcode says it's the owner, so someone holding the
  // unlocked phone can't quietly let a risky transfer through.
  Future<void> _set(bool on) async {
    final state = AppScope.read(context);
    setState(() => _problem = null);
    if (!on) {
      if (_asking) return;
      _asking = true;
      final result = await confirmed(() => state.vault.confirmed((_) async => true));
      _asking = false;
      if (!mounted) return;
      if (result.value != true) return setState(() => _problem = result.problem);
    }
    final prefs = state.preferences;
    await state.setPreferences(prefs.copyWith(protections: on ? {...prefs.protections, widget.protection} : ({...prefs.protections}..remove(widget.protection))));
  }

  @override
  void initState() {
    super.initState();
    if (widget.protection == Protection.exchangeSupport) {
      AppScope.read(context).exchangeLists.coverage().then((found) {
        if (mounted) setState(() => _exchanges = found);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.of(context);
    final prefs = state.preferences;
    final info = protectionInfo[widget.protection]!;
    final on = prefs.protections.contains(widget.protection);
    return _Page(
      title: 'Protection',
      heading: info.title,
      lead: info.lead,
      children: [
        _Card([
          _SwitchRow(
            'Protection',
            on
                ? 'On: risky transfers like these are stopped. Turning it off asks for ${state.faceIdAvailable ? 'Face ID or your passcode' : 'your passcode'}.'
                : 'Off: transfers like these go through unchecked.',
            on,
            _set,
          ),
        ]),
        if (_problem != null) ...[const SizedBox(height: 12), Notice(_problem!)],
        const _GroupTitle('How it works'),
        for (final (i, (title, text)) in info.steps.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 2 : 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
                  child: Text(
                    '${i + 1}',
                    style: geist(13, weight: FontWeight.w600, color: p.fg, features: tabular),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: geist(15, weight: FontWeight.w600, color: p.fg),
                        ),
                        const SizedBox(height: 3),
                        Text(text, style: geist(14, color: p.muted, height: 1.5)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (widget.protection == Protection.exchangeSupport) ...[
          const _GroupTitle('Exchanges', lead: 'The exchanges this check knows on Solana, and how far. Token lists come from the exchanges themselves and are kept up to date by Zandr\'s server.'),
          if (_exchanges == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Spinner()),
            )
          else
            _Card([for (final exchange in _exchanges!) _ExchangeRow(exchange)]),
        ],
        if (info.limits.isNotEmpty) ...[
          const _GroupTitle('What it can\'t catch'),
          for (final limit in info.limits)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 12, 0),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: p.fillStrong, shape: BoxShape.circle),
                    ),
                  ),
                  Expanded(
                    child: Text(limit, style: geist(14, color: p.muted, height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SubScreen(
      title: 'About',
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 32),
        children: [
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 88,
              height: 88,
              alignment: Alignment.center,
              // As the app icon: the mark on black, a hairline keeping it in shape on a black page.
              decoration: BoxDecoration(
                color: Palette.dark.bg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.hairline),
              ),
              child: BrandMark(size: 52, color: Palette.dark.fg),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Zandr',
            textAlign: TextAlign.center,
            style: geist(24, weight: FontWeight.w600, color: p.fg),
          ),
          const SizedBox(height: 4),
          Text(
            'Version $appVersion',
            textAlign: TextAlign.center,
            style: geist(14, color: p.muted, features: tabular),
          ),
          const SizedBox(height: 20),
          Text(
            'A Solana wallet that protects your funds from threats and from simple human error.',
            textAlign: TextAlign.center,
            style: geist(15, color: p.muted, height: 1.5),
          ),
          const SizedBox(height: 28),
          const _Card([
            _InfoRow('Your keys', 'On this iPhone only, in its Keychain, behind Face ID or the passcode. Never sent anywhere.'),
            _InfoRow('Prices and token names', 'From Jupiter, through Zandr\'s server.'),
            _InfoRow('Exchange lists', 'From the exchanges themselves, fetched whole, so the server never learns what you send where.'),
          ]),
        ],
      ),
    );
  }
}

// ---- The pieces ----

// A settings page: a lead under the bar's title (or a heading and a lead, for a protection), then
// its cards.
class _Page extends StatelessWidget {
  final String title;
  final String? heading;
  final String lead;
  final List<Widget> children;
  const _Page({required this.title, this.heading, required this.lead, required this.children});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SubScreen(
      title: title,
      child: ListView(
        physics: scrollIfNeeded,
        padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 40),
        children: [
          if (heading != null) ...[
            Text(
              heading!,
              style: geist(24, weight: FontWeight.w600, color: p.fg, height: 1.2),
            ),
            const SizedBox(height: 8),
          ],
          Text(lead, style: geist(15, color: p.muted, height: 1.5)),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String title;
  final String? lead;
  const _GroupTitle(this.title, {this.lead});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: geist(16, weight: FontWeight.w600, color: p.fg),
          ),
          if (lead != null) ...[const SizedBox(height: 4), Text(lead!, style: geist(14, color: p.muted, height: 1.5))],
        ],
      ),
    );
  }
}

// Rows on one grey card, hairlines between them.
class _Card extends StatelessWidget {
  final List<Widget> rows;
  const _Card(this.rows);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: p.fill,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius + 6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[if (i > 0) Divider(height: 1, thickness: 0.5, indent: 16, color: p.fillStrong), rows[i]],
        ],
      ),
    );
  }
}

// A section on the Settings page: its icon, its name, where it stands now.
class _NavRow extends StatelessWidget {
  final Glyph icon;
  final String title, value;
  final VoidCallback onTap;
  const _NavRow(this.icon, this.title, this.value, this.onTap);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(10)),
              child: ZIcon(icon, size: 18, color: p.fg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: geist(16, weight: FontWeight.w500, color: p.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: geist(14, color: p.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ZIcon(ZIcons.chevronRight, size: 18, color: p.muted),
          ],
        ),
      ),
    );
  }
}

// A row that opens something: a title and what it is, and what it shows at the end.
class _Row extends StatelessWidget {
  final String title, subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  const _Row({required this.title, required this.subtitle, this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: geist(16, weight: FontWeight.w500, color: p.fg),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, style: geist(14, color: p.muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ?trailing,
            const SizedBox(width: 4),
            ZIcon(ZIcons.chevronRight, size: 18, color: p.muted),
          ],
        ),
      ),
    );
  }
}

// A setting picked from a few: what it is above, the choices below it in a row.
class _ChoiceRow<T> extends StatelessWidget {
  final String title, subtitle;
  final List<T> options;
  final T value;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const _ChoiceRow(this.title, this.subtitle, {required this.options, required this.value, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: geist(16, weight: FontWeight.w500, color: p.fg),
          ),
          const SizedBox(height: 3),
          Text(subtitle, style: geist(14, color: p.muted, height: 1.4)),
          const SizedBox(height: 12),
          Segmented<T>(options: options, value: value, label: label, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title, text;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow(this.title, this.text, this.value, this.onChanged);

  void _toggle(bool next) {
    HapticFeedback.selectionClick();
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      onTap: () => _toggle(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: geist(16, weight: FontWeight.w500, color: p.fg),
                  ),
                  const SizedBox(height: 3),
                  Text(text, style: geist(14, color: p.muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(value: value, onChanged: _toggle),
          ],
        ),
      ),
    );
  }
}

// Something to read, not to change.
class _InfoRow extends StatelessWidget {
  final String title, text;
  final Color? color;
  final Widget? trailing;
  const _InfoRow(this.title, this.text, {this.color, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: geist(16, weight: FontWeight.w500, color: p.fg),
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: Text(
                    text,
                    key: ValueKey(text),
                    style: geist(14, color: color ?? p.muted, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

class _OnOff extends StatelessWidget {
  final bool on;
  const _OnOff(this.on);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text(
      on ? 'On' : 'Off',
      style: geist(15, weight: FontWeight.w500, color: on ? p.fg : p.muted),
    );
  }
}

// The exchanges' logos, as the extension shows them (src/assets/exchanges, rendered to PNG).
const _logos = {
  'Binance': 'binance',
  'Coinbase': 'coinbase',
  'OKX': 'okx',
  'Bybit': 'bybit',
  'Kraken': 'kraken',
  'Bitget': 'bitget',
  'KuCoin': 'kucoin',
  'Gate': 'gate',
  'MEXC': 'mexc',
  'HTX': 'htx',
  'AscendEX': 'ascendex',
  'Backpack': 'backpack',
  'Bitfinex': 'bitfinex',
  'Bitstamp': 'bitstamp',
  'CoinDCX': 'coindcx',
  'CoinList': 'coinlist',
  'Crypto.com': 'crypto-com',
  'LAToken': 'latoken',
  'Rollbit': 'rollbit',
  'Swissborg': 'swissborg',
};

final _day = DateFormat('MMM d', 'en_US');

class _ExchangeRow extends StatelessWidget {
  final ExchangeCoverage exchange;
  const _ExchangeRow(this.exchange);

  String get _detail {
    if (exchange.status == CoverageStatus.addresses) return 'Its wallets are recognized; its token list isn\'t public';
    final tokens = '${exchange.tokens} token${exchange.tokens == 1 ? '' : 's'}${exchange.status == CoverageStatus.traded ? ' it trades' : ''}';
    return '$tokens${exchange.updated == null ? '' : ' · updated ${_day.format(exchange.updated!.toLocal())}'}${exchange.status == CoverageStatus.partial ? ' · some tokens unknown' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final logo = _logos[exchange.name];
    final live = exchange.status == CoverageStatus.full;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.fill,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.hairline),
            ),
            child: logo == null
                ? Text(
                    exchange.name.substring(0, 1),
                    style: geist(14, weight: FontWeight.w600, color: p.muted),
                  )
                : Image.asset('assets/exchanges/$logo.png', width: 32, height: 32, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exchange.name,
                  style: geist(15, weight: FontWeight.w500, color: p.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  _detail,
                  style: geist(13, color: p.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: live ? p.fillStrong : p.fill, borderRadius: BorderRadius.circular(11)),
            child: Text(switch (exchange.status) {
              CoverageStatus.full => 'Full check',
              CoverageStatus.traded => 'Traded tokens',
              CoverageStatus.partial => 'Partial',
              CoverageStatus.addresses => 'Addresses only',
            }, style: geist(11, weight: FontWeight.w500, color: live ? p.fg : p.muted)),
          ),
        ],
      ),
    );
  }
}
