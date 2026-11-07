import 'package:flutter/material.dart';

import '../services/hub.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';
import 'chat_screen.dart';
import 'directory_view.dart';
import 'phone_contacts_view.dart';

/// Who's online: everyone in the company with a live status, filters, and one-tap call or chat.
class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key, required this.onAvatarTap, required this.onOpenKeypad});

  final VoidCallback onAvatarTap;
  final VoidCallback onOpenKeypad;

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  String _filter = 'all';
  String _query = '';
  int _source = 0; // 0 colleagues · 1 company directory · 2 the phone's own contacts

  @override
  void initState() {
    super.initState();
    Hub.instance.teamSource.addListener(_jump);
  }

  void _jump() => setState(() => _source = Hub.instance.teamSource.value);

  @override
  void dispose() {
    Hub.instance.teamSource.removeListener(_jump);
    super.dispose();
  }

  Future<void> _call(String ext) async {
    if (await Phone.instance.dial(ext) && mounted) {
      // The call window opens by itself once the call exists (see main.dart).
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Your line isn't ready yet. Try again in a moment.")));
    }
  }

  void _chat(Map<String, dynamic> p) {
    final id = p['hub_user_id'] as int?;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${p['name']} has no WOCOM Hub account, so chat isn\'t available.')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen.withUser(userId: id, title: p['name'] as String)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Hub.instance,
      builder: (context, _) {
        final hub = Hub.instance;
        final everyone = hub.people.where((p) => p['is_me'] != true).toList();
        final online = everyone.where((p) => p['status'] != 'offline').length;
        final q = _query.trim().toLowerCase();
        final shown = everyone.where((p) {
          if (_filter == 'online' && p['status'] == 'offline') return false;
          if (_filter != 'all' && _filter != 'online' && p['department'] != _filter) return false;
          return q.isEmpty || '${p['name']} ${p['extension']}'.toLowerCase().contains(q);
        }).toList();
        final me = hub.people.where((p) => p['is_me'] == true);
        final myLabel = me.isNotEmpty ? me.first['status_label'] : 'Available';

        return Column(children: [
          BrandHeader(
            title: 'Team',
            subtitle: '${Session.instance.company} · ${Phone.instance.extension.isEmpty ? '' : 'Ext ${Phone.instance.extension} · '}$myLabel',
            onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
            onAvatarTap: widget.onAvatarTap,
            myStatus: hub.myStatus,
            search: (v) => setState(() => _query = v),
            bottom: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [_seg(0, 'Team · $online'), _seg(1, 'Directory'), _seg(2, 'My phone')]),
            ),
          ),
          if (_source == 1) Expanded(child: DirectoryView(query: _query))
          else if (_source == 2) Expanded(child: PhoneContactsView(query: _query))
          else ...[
          SizedBox(
            height: 54,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              children: [
                _chip('all', 'All · ${everyone.length}'),
                _chip('online', 'Online · $online'),
                for (final d in hub.departments) _chip(d, d),
              ],
            ),
          ),
          Expanded(
            child: hub.teamError != null && hub.people.isEmpty
                ? EmptyState(icon: Icons.cloud_off, text: hub.teamError!, action: TextButton(onPressed: hub.refreshTeam, child: const Text('Try again')))
                : hub.people.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : shown.isEmpty
                        ? const EmptyState(icon: Icons.person_search, text: 'Nobody matches that search.')
                        : RefreshIndicator(
                            onRefresh: hub.refreshTeam,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              itemCount: shown.length,
                              itemBuilder: (context, i) {
                                final p = shown[i];
                                final status = p['status'] as String;
                                return ListTile(
                                  minVerticalPadding: 10,
                                  leading: PersonAvatar(name: p['name'] as String, status: status),
                                  title: Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
                                  subtitle: Text('${p['status_label']} · Ext ${p['extension']}', style: TextStyle(color: statusTextColor(status), fontSize: 13)),
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    if (p['hub_user_id'] == null)
                                      const Tooltip(message: 'Desk phone only — no chat', child: SizedBox(width: 44, height: 44, child: Icon(Icons.phone_in_talk_outlined, color: Color(0xFFA8A0B4), size: 21)))
                                    else
                                      SoftIconButton(icon: Icons.chat_bubble_outline, label: 'Chat with ${p['name']}', filled: false, onTap: () => _chat(p)),
                                    const SizedBox(width: 4),
                                    SoftIconButton(icon: Icons.call, label: 'Call ${p['name']}', onTap: () => _call(p['extension'] as String)),
                                  ]),
                                );
                              },
                            ),
                          ),
          ),
          ],
        ]);
      },
    );
  }

  Widget _seg(int src, String label) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _source = src),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _source == src ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: _source == src ? FontWeight.w800 : FontWeight.w600, color: _source == src ? wocomDeep : Colors.white)),
          ),
        ),
      );

  Widget _chip(String value, String label) {
    final on = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => setState(() => _filter = value),
        showCheckmark: false,
        selectedColor: wocomSoft,
        backgroundColor: Colors.white,
        side: BorderSide(color: on ? wocomPurple : wocomLine, width: 1.5),
        labelStyle: TextStyle(color: on ? wocomDeep : const Color(0xFF4A4256), fontWeight: on ? FontWeight.w700 : FontWeight.w600),
        shape: const StadiumBorder(),
      ),
    );
  }
}
