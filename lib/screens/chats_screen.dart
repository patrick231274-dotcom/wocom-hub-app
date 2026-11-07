import 'package:flutter/material.dart';

import '../services/hub.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'chat_screen.dart';
import 'home_screen.dart';

/// Chats with colleagues and groups (the same conversations as the WOCOM Hub's chat):
/// search and filters in the header, who's online now, then one card per conversation.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, required this.onAvatarTap});

  final VoidCallback onAvatarTap;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String _query = '';
  int _filter = 0; // 0 all · 1 unread · 2 groups

  Future<void> _newChat() async {
    final people = Hub.instance.people.where((p) => p['is_me'] != true && p['hub_user_id'] != null).toList();
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('New chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          if (people.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No colleagues with a WOCOM Hub account yet.')),
          for (final p in people)
            ListTile(
              leading: PersonAvatar(name: p['name'] as String, status: p['status'] as String),
              title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('Ext ${p['extension']}'),
              onTap: () => Navigator.pop(c, p),
            ),
        ]),
      ),
    );
    if (picked != null && mounted) _openUser(picked);
  }

  void _openUser(Map<String, dynamic> p) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen.withUser(userId: p['hub_user_id'] as int, title: p['name'] as String)))
        .then((_) => Hub.instance.refreshChats());
  }

  void _openConversation(Map<String, dynamic> c) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: c['id'] as int, title: (c['name'] ?? 'Chat') as String, otherUserId: c['other_user_id'] as int?)))
        .then((_) => Hub.instance.refreshChats());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      primary: false,
      floatingActionButton: FloatingActionButton(
        onPressed: _newChat,
        backgroundColor: wocomDeep,
        foregroundColor: Colors.white,
        tooltip: 'New chat',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.edit_outlined),
      ),
      body: AnimatedBuilder(
        animation: Hub.instance,
        builder: (context, _) {
          final hub = Hub.instance;
          final q = _query.trim().toLowerCase();
          final list = hub.conversations.where((c) {
            if (q.isNotEmpty && !'${c['name']} ${c['last_message'] ?? ''}'.toLowerCase().contains(q)) return false;
            if (_filter == 1 && ((c['unread_count'] ?? 0) as int) == 0) return false;
            if (_filter == 2 && c['type'] == 'direct') return false;
            return true;
          }).toList();
          final online = hub.people.where((p) => p['is_me'] != true && p['hub_user_id'] != null && p['status'] != 'offline').take(12).toList();
          return Column(children: [
            BrandHeader(
              title: 'Chats',
              subtitle: hub.unreadChats > 0 ? '${hub.unreadChats} unread' : null,
              onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
              onAvatarTap: widget.onAvatarTap,
              myStatus: hub.myStatus,
              search: (v) => setState(() => _query = v),
              bottom: Row(children: [
                for (final (i, label) in ['All', 'Unread', 'Groups'].indexed) ...[
                  _FilterChip(label: label, selected: _filter == i, onTap: () => setState(() => _filter = i)),
                  const SizedBox(width: 8),
                ],
              ]),
            ),
            Expanded(
              child: hub.chatError != null
                  ? EmptyState(icon: Icons.chat_bubble_outline, text: hub.chatError!)
                  : RefreshIndicator(
                      onRefresh: hub.refreshChats,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                        children: [
                          if (online.isNotEmpty && q.isEmpty && _filter == 0) ...[
                            const _SectionLabel('Online now'),
                            SizedBox(
                              height: 86,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                itemCount: online.length,
                                separatorBuilder: (_, __) => const SizedBox(width: 14),
                                itemBuilder: (context, i) {
                                  final p = online[i];
                                  final first = (p['name'] as String).split(' ').first;
                                  return InkWell(
                                    onTap: () => _openUser(p),
                                    borderRadius: BorderRadius.circular(12),
                                    child: SizedBox(
                                      width: 60,
                                      child: Column(children: [
                                        PersonAvatar(name: p['name'] as String, status: p['status'] as String, size: 52),
                                        const SizedBox(height: 6),
                                        Text(first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: wocomInk)),
                                      ]),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                          if (list.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 60),
                              child: EmptyState(
                                icon: _filter == 1 ? Icons.mark_chat_read_outlined : Icons.forum_outlined,
                                text: hub.conversations.isEmpty
                                    ? 'No chats yet. Tap the pencil to message a colleague.'
                                    : _filter == 1 ? 'You\'re all caught up.' : _filter == 2 ? 'No group chats yet.' : 'No chats match that search.',
                              ),
                            ),
                          for (final c in list) _ConversationCard(c: c, person: hub.personByUserId(c['other_user_id'] as int?), onTap: () => _openConversation(c)),
                        ],
                      ),
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11.5, letterSpacing: 1, fontWeight: FontWeight.w800, color: Color(0xFF8A8299))),
      );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            border: Border.all(color: selected ? Colors.white : Colors.white.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: selected ? wocomPlum : Colors.white)),
        ),
      );
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.c, required this.person, required this.onTap});
  final Map<String, dynamic> c;
  final Map<String, dynamic>? person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = (c['unread_count'] ?? 0) as int;
    final group = c['type'] != 'direct';
    final name = (c['name'] ?? 'Chat') as String;
    final at = c['last_message_at'] != null ? DateTime.tryParse(c['last_message_at'] as String) : null;
    final preview = (c['last_message'] ?? '') as String;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: wocomLine)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            PersonAvatar(name: name, status: group ? null : person?['status'] as String?, group: group, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w700, color: wocomInk))),
                  if (at != null) Text(timeAgoLabel(at), style: TextStyle(fontSize: 11.5, fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500, color: unread > 0 ? wocomDeep : const Color(0xFF8A8299))),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(
                    child: Text(
                      preview.isEmpty ? 'No messages yet' : preview,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w500, color: unread > 0 ? wocomInk : wocomMuted),
                    ),
                  ),
                  if (unread > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: wocomDeep, borderRadius: BorderRadius.circular(10)),
                      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
