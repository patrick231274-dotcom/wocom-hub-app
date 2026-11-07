import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// The company's shared address book (the Hub's Contacts), with a call button per number.
/// Numbers are cleaned up when dialled, so "(876) 960-1004" goes out as 18769601004.
class DirectoryView extends StatefulWidget {
  const DirectoryView({super.key, required this.query});

  final String query;

  @override
  State<DirectoryView> createState() => _DirectoryViewState();
}

class _DirectoryViewState extends State<DirectoryView> {
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await Session.instance.api.get('directory');
      setState(() {
        _contacts = ((r['contacts'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _call(String number) async {
    if (await Phone.instance.dial(number) && mounted) {
      // The call window opens by itself once the call exists (see main.dart).
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Your line isn't ready yet. Try again in a moment.")));
    }
  }

  void _pick(Map<String, dynamic> c) {
    final phones = (c['phones'] as List).cast<Map>();
    if (phones.length == 1) {
      _call(phones.first['number'] as String);
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Call ${c['name']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          for (final p in phones)
            ListTile(
              leading: const Icon(Icons.call, color: wocomDeep),
              title: Text(p['number'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text((p['label'] as String).isEmpty ? 'Phone' : p['label'] as String),
              onTap: () { Navigator.pop(s); _call(p['number'] as String); },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: load, child: const Text('Try again')));
    final q = widget.query.trim().toLowerCase();
    final list = _contacts.where((c) {
      if (q.isEmpty) return true;
      final nums = (c['phones'] as List).map((p) => (p as Map)['number'].toString().replaceAll(RegExp(r'\D'), '')).join(' ');
      return '${c['name']} ${c['company']} ${c['email']} $nums'.toLowerCase().contains(q) || nums.contains(q.replaceAll(RegExp(r'\D'), ''));
    }).toList();
    if (list.isEmpty) {
      return EmptyState(icon: Icons.contacts_outlined, text: _contacts.isEmpty ? 'No contacts in the company address book yet. Add them in the WOCOM Hub under Contacts.' : 'No contacts match that search.');
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, i) {
          final c = list[i];
          final phones = (c['phones'] as List).cast<Map>();
          final sub = [c['title'], c['company']].where((v) => (v ?? '').toString().isNotEmpty).join(' · ');
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomLine)),
            child: ListTile(
              minVerticalPadding: 10,
              leading: PersonAvatar(name: c['name'] as String),
              title: Text(c['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
              subtitle: Text(
                [if (sub.isNotEmpty) sub, if (phones.isNotEmpty) phones.first['number'] as String, if (phones.length > 1) '+${phones.length - 1} more']
                    .join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: wocomMuted, fontSize: 13),
              ),
              trailing: phones.isEmpty ? null : SoftIconButton(icon: Icons.call, label: 'Call ${c['name']}', onTap: () => _pick(c)),
              onTap: phones.isEmpty ? null : () => _pick(c),
            ),
          );
        },
      ),
    );
  }
}
