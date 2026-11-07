import 'package:flutter/material.dart';

import '../brand.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Phone;
import 'package:flutter_contacts/flutter_contacts.dart' as fc show Phone;
import 'package:permission_handler/permission_handler.dart';

import '../services/phone.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// The phone's own contacts, called through the WOCOM line. Numbers are cleaned up when
/// dialled, so a contact saved as "(876) 960-1004" goes out as 18769601004.
class PhoneContactsView extends StatefulWidget {
  const PhoneContactsView({super.key, required this.query});

  final String query;

  @override
  State<PhoneContactsView> createState() => _PhoneContactsViewState();
}

class _PhoneContactsViewState extends State<PhoneContactsView> {
  List<Contact> _contacts = [];
  bool _loading = true;
  bool _denied = false;
  bool _permanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() { _loading = true; _denied = false; });
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      setState(() { _loading = false; _denied = true; _permanentlyDenied = status.isPermanentlyDenied; });
      return;
    }
    final list = (await FlutterContacts.getAll(properties: {ContactProperty.name, ContactProperty.phone})).where((c) => c.phones.isNotEmpty).toList();
    list.sort((a, b) => _name(a).toLowerCase().compareTo(_name(b).toLowerCase()));
    if (mounted) setState(() { _contacts = list; _loading = false; });
  }

  static String _name(Contact c) => (c.displayName ?? '').trim().isEmpty ? (c.phones.first.number) : c.displayName!.trim();

  static String _label(fc.Phone p) => p.label.customLabel ?? p.label.label.name;

  Future<void> _call(String number) async {
    if (await Phone.instance.dial(number) && mounted) {
      // The call window opens by itself once the call exists (see main.dart).
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Your line isn't ready yet. Try again in a moment.")));
    }
  }

  void _pick(Contact c) {
    if (c.phones.length == 1) {
      _call(c.phones.first.number);
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Call ${_name(c)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          for (final p in c.phones)
            ListTile(
              leading: const Icon(Icons.call, color: wocomDeep),
              title: Text(p.number, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(_label(p)),
              onTap: () { Navigator.pop(s); _call(p.number); },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_denied) {
      return EmptyState(
        icon: Icons.contact_phone_outlined,
        text: _permanentlyDenied
            ? '${Brand.name} needs permission to read your contacts. Turn it on in your phone\'s Settings → Apps → WOCOM HUB → Permissions.'
            : 'Allow ${Brand.name} to read your contacts to call them through your WOCOM line.',
        action: OutlinedButton(
          onPressed: _permanentlyDenied ? openAppSettings : load,
          style: OutlinedButton.styleFrom(minimumSize: const Size(200, 44)),
          child: Text(_permanentlyDenied ? 'Open settings' : 'Allow contacts'),
        ),
      );
    }
    final q = widget.query.trim().toLowerCase();
    final qd = q.replaceAll(RegExp(r'\D'), '');
    final list = _contacts.where((c) {
      if (q.isEmpty) return true;
      if (_name(c).toLowerCase().contains(q)) return true;
      return qd.isNotEmpty && c.phones.any((p) => p.number.replaceAll(RegExp(r'\D'), '').contains(qd));
    }).toList();
    if (list.isEmpty) return EmptyState(icon: Icons.contacts_outlined, text: _contacts.isEmpty ? 'No contacts with phone numbers on this phone.' : 'No contacts match that search.');
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        itemCount: list.length,
        separatorBuilder: (_, i) => const SizedBox(height: 6),
        itemBuilder: (context, i) {
          final c = list[i];
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomLine)),
            child: ListTile(
              minVerticalPadding: 10,
              leading: PersonAvatar(name: _name(c)),
              title: Text(_name(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
              subtitle: Text(
                '${c.phones.first.number}${c.phones.length > 1 ? ' · +${c.phones.length - 1} more' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: wocomMuted, fontSize: 13),
              ),
              trailing: SoftIconButton(icon: Icons.call, label: 'Call ${_name(c)}', onTap: () => _pick(c)),
              onTap: () => _pick(c),
            ),
          );
        },
      ),
    );
  }
}
