// Saved addresses: named, so a transfer to one shows its name, and so a lookalike of one is
// caught. Encrypted on the phone under a key from the vault key; one changed outside Zandr fails
// to open rather than being trusted.
import 'package:flutter/material.dart';

import '../app/vault.dart';
import '../core/base58.dart';
import 'app.dart';
import 'format.dart';
import 'icons.dart';
import 'scan.dart';
import 'theme.dart';
import 'widgets.dart';

class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key});
  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  List<Contact>? _contacts;
  bool _tampered = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final contacts = await AppScope.read(context).vault.readAddressBook();
      if (mounted) setState(() => _contacts = contacts);
    } on TamperedError {
      if (mounted) setState(() => _tampered = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = AppScope.read(context);
    final contacts = _contacts;
    return SubScreen(
      title: 'Address book',
      bottom: _tampered
          ? PrimaryButton(
              'Clear the address book',
              danger: true,
              onPressed: () async {
                await state.vault.clearAddressBook();
                setState(() {
                  _tampered = false;
                  _contacts = [];
                });
              },
            )
          : PrimaryButton(
              'Add address',
              onPressed: contacts == null
                  ? null
                  : () async {
                      final added = await showSheet<Contact>(context, (_) => const _AddContact());
                      if (added != null) _load();
                    },
            ),
      child: _tampered
          ? const Padding(
              padding: EdgeInsets.all(gutter),
              child: Notice('The address book failed verification', body: 'It was changed outside Zandr, so none of it can be trusted. Clear it and add your addresses again.'),
            )
          : contacts == null
          ? const SizedBox()
          : contacts.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(gutter),
              child: Text(
                'Save the addresses you send to. Zandr then shows their names, and stops a transfer to an address made to look like one of them.',
                style: geist(15, color: p.muted, height: 1.45),
              ),
            )
          : ListView(
              physics: scrollIfNeeded,
              children: [
                for (final contact in contacts)
                  Dismissible(
                    key: ValueKey(contact.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: p.danger,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: ZIcon(ZIcons.trash, color: p.onDanger),
                    ),
                    onDismissed: (_) async {
                      await state.vault.removeContact(contact.id);
                      _load();
                    },
                    // Tapped, it copies the address, and says so in place of it.
                    child: Momentary(
                      builder: (context, copied, run) => ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 2),
                        leading: Monogram(contact.name, contact.address),
                        title: Text(
                          contact.name,
                          style: geist(16, weight: FontWeight.w600, color: p.fg),
                        ),
                        subtitle: Text(copied ? 'Copied' : shortAddress(contact.address), style: geist(14, color: p.muted)),
                        trailing: ZIcon(copied ? ZIcons.check : ZIcons.copy, size: 18, color: p.muted),
                        onTap: () => run(() => copyText(contact.address)),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _AddContact extends StatefulWidget {
  const _AddContact();
  @override
  State<_AddContact> createState() => _AddContactState();
}

class _AddContactState extends State<_AddContact> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  String? _problem;

  Future<void> _add() async {
    try {
      final contact = await AppScope.read(context).vault.addContact(_name.text, _address.text);
      if (mounted) Navigator.pop(context, contact);
    } on ContactRefused catch (refused) {
      setState(
        () => _problem = switch (refused.error) {
          ContactError.name => 'Give it a name of up to $contactNameMaxLength characters.',
          ContactError.invalidAddress => 'This isn\'t a valid Solana address.',
          ContactError.ownAddress => 'That\'s this wallet\'s own address.',
          ContactError.duplicate => 'It\'s saved already, as ${refused.conflict}.',
          ContactError.lookalike => 'It starts and ends like ${refused.conflict}\'s address but isn\'t it: a common trick. Check where it came from.',
        },
      );
    }
  }

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
              'Add address',
              style: geist(20, weight: FontWeight.w600, color: p.fg),
            ),
            const SizedBox(height: 16),
            Field(_name, hint: 'Name', autofocus: true, autocorrect: true, onChanged: (_) => setState(() => _problem = null)),
            const SizedBox(height: 10),
            Field(
              _address,
              hint: 'Solana address',
              maxLines: 2,
              onChanged: (_) => setState(() => _problem = null),
              suffix: IconButton(
                onPressed: () async {
                  final scanned = await scan(context);
                  if (scanned != null) setState(() => _address.text = scanned.address);
                },
                icon: ZIcon(ZIcons.scan, color: p.muted),
                tooltip: 'Scan',
              ),
            ),
            if (_problem != null) ...[const SizedBox(height: 10), Text(_problem!, style: geist(14, color: p.danger, height: 1.35))],
            const SizedBox(height: 16),
            PrimaryButton('Save', onPressed: _name.text.trim().isEmpty || !isAddress(_address.text.trim()) ? null : _add),
          ],
        ),
      ),
    );
  }
}
