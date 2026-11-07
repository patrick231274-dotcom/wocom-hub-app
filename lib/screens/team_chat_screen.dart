import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';
import 'techhub_screen.dart';

/// WE App team chat, hosted by Tech Hub: department groups, "All staff" and direct chats.
class TeamChatsScreen extends StatefulWidget {
  const TeamChatsScreen({super.key});
  @override
  State<TeamChatsScreen> createState() => _TeamChatsScreenState();
}

class _TeamChatsScreenState extends State<TeamChatsScreen> {
  List<Map<String, dynamic>> _convs = [];
  bool _loading = true;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.chatEvent.addListener(_load);
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() { _poll?.cancel(); TechHub.instance.chatEvent.removeListener(_load); super.dispose(); }

  Future<void> _load() async {
    try {
      final c = await TechHub.instance.conversations();
      if (mounted) setState(() { _convs = c; _error = null; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    }
  }

  Future<void> _newChat() async {
    List<Map<String, dynamic>> people;
    try { people = await TechHub.instance.chatPeople(); } on ApiException catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); return; }
    if (!mounted) return;
    final me = TechHub.instance.engineer?['id'];
    final pick = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.7,
        builder: (c, sc) => ListView(controller: sc, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, 8), child: Text('New message', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
          for (final p in people.where((p) => p['id'] != me))
            ListTile(
              leading: PersonAvatar(name: (p['name'] ?? '').toString(), status: p['on_duty'] == true ? 'available' : null),
              title: Text((p['name'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([p['role'], if ((p['extension'] ?? '').toString().isNotEmpty) 'ext ${p['extension']}'].where((x) => x != null && x.toString().isNotEmpty).join(' · ')),
              onTap: () => Navigator.pop(c, p),
            ),
        ]),
      ),
    );
    if (pick == null) return;
    try {
      final id = await TechHub.instance.openChat((pick['id'] as num).toInt());
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TeamChatScreen(id: id, title: pick['name'].toString())));
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        BrandHeader(
          title: 'Chats',
          onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
          trailing: [IconButton(tooltip: 'New message', onPressed: _newChat, icon: const Icon(Icons.edit_square, color: Colors.white))],
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _convs.isEmpty
                          ? ListView(children: [const SizedBox(height: 80), EmptyState(icon: Icons.chat_bubble_outline, text: 'No chats yet.', action: TextButton(onPressed: _newChat, child: const Text('Start one')))])
                          : ListView.separated(
                              itemCount: _convs.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
                              itemBuilder: (_, i) {
                                final c = _convs[i];
                                final unread = (c['unread'] as num?)?.toInt() ?? 0;
                                final last = c['last_message'] is Map ? c['last_message'] as Map : const {};
                                final at = DateTime.tryParse((last['at'] ?? '').toString())?.toLocal();
                                final group = c['kind'] == 'group';
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                  leading: PersonAvatar(name: (c['title'] ?? '').toString(), group: group, size: 48),
                                  title: Text((c['title'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: unread > 0 ? FontWeight.w900 : FontWeight.w700)),
                                  subtitle: Text((last['text'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: unread > 0 ? wocomInk : wocomMuted, fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w400)),
                                  onLongPress: group ? null : () async {
                                    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                                      title: const Text('Delete this chat?'), content: const Text('It is removed for you only, and comes back if a new message arrives.'),
                                      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete'))],
                                    ));
                                    if (ok != true) return;
                                    try { await TechHub.instance.deleteChat(c['id'].toString()); _load(); } on ApiException catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); }
                                  },
                                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                    if (at != null) Text(_when(at), style: const TextStyle(fontSize: 11.5, color: wocomMuted)),
                                    if (unread > 0) ...[
                                      const SizedBox(height: 4),
                                      Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: wocomPurple, borderRadius: BorderRadius.circular(10)), child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800))),
                                    ],
                                  ]),
                                  onTap: () async {
                                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TeamChatScreen(id: c['id'].toString(), title: (c['title'] ?? '').toString(), group: group)));
                                    _load();
                                  },
                                );
                              },
                            ),
                    ),
        ),
      ]);
}

String _when(DateTime t) {
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
  return '${t.day}/${t.month}';
}

class TeamChatScreen extends StatefulWidget {
  const TeamChatScreen({super.key, required this.id, required this.title, this.group = false});
  final String id;
  final String title;
  final bool group;
  @override
  State<TeamChatScreen> createState() => _TeamChatScreenState();
}

class _TeamChatScreenState extends State<TeamChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  List<Map<String, dynamic>> _reads = [];
  bool _busy = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.chatEvent.addListener(_onPush);
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _load(quiet: true));
  }

  void _onPush() { if (TechHub.instance.chatEvent.value.startsWith('${widget.id}@')) _load(quiet: true); }

  @override
  void dispose() { _poll?.cancel(); TechHub.instance.chatEvent.removeListener(_onPush); _text.dispose(); _scroll.dispose(); super.dispose(); }

  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await TechHub.instance.messages(widget.id);
      final raw = r['_raw'] is Map ? r['_raw'] as Map : r;
      final msgs = ((r['messages'] ?? raw['messages'] ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final reads = ((r['reads'] ?? raw['reads'] ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final grew = msgs.length != _msgs.length;
      if (!mounted) return;
      setState(() { _msgs = msgs; _reads = reads; _error = null; });
      if (grew) {
        WidgetsBinding.instance.addPostFrameCallback((_) { if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent); });
        final last = msgs.isEmpty ? null : (msgs.last['id'] as num?)?.toInt();
        if (last != null) TechHub.instance.markRead(widget.id, last);
      }
    } on ApiException catch (e) {
      if (!quiet && mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _busy) return;
    setState(() => _busy = true);
    try { await TechHub.instance.sendChat(widget.id, t); _text.clear(); await _load(); }
    on ApiException catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Color? _hex(dynamic v) {
    final h = (v ?? '').toString().replaceFirst('#', '');
    final n = int.tryParse(h, radix: 16);
    return (h.length == 6 && n != null) ? Color(0xFF000000 | n) : null;
  }

  Widget _avatar(Map m) {
    final name = (m['from_name'] ?? '?').toString();
    final initials = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    final color = _hex(m['from_color']) ?? wocomPurple;
    final url = (m['from_avatar_url'] ?? '').toString();
    return CircleAvatar(
      radius: 18,
      backgroundColor: color,
      foregroundImage: url.isEmpty ? null : NetworkImage(TechHub.instance.absUrl(url), headers: TechHub.instance.authHeaders),
      child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
    );
  }

  Future<void> _messageMenu(Map m, bool mine) async {
    final text = (m['text'] ?? '').toString();
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (text.isNotEmpty) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy text'), onTap: () => Navigator.pop(c, 'copy')),
        if (mine && m['kind'] != 'deleted') ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFB91C1C)), title: const Text('Delete for everyone', style: TextStyle(color: Color(0xFFB91C1C))), onTap: () => Navigator.pop(c, 'delete')),
      ])),
    );
    if (!mounted || choice == null) return;
    if (choice == 'copy') { await Clipboard.setData(ClipboardData(text: text)); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied'))); return; }
    try { await TechHub.instance.deleteMessage(widget.id, (m['id'] as num).toInt()); await _load(); }
    on ApiException catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.code == 'too_old' ? 'Messages can only be deleted within 24 hours.' : e.message))); }
  }

  /// Tap a sender's picture in a group to message them privately.
  Future<void> _private(Map m) async {
    final uid = (m['from_id'] as num?)?.toInt() ?? int.tryParse('${m['from_id']}');
    if (uid == null) return;
    try {
      final id = await TechHub.instance.openChat(uid);
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TeamChatScreen(id: id, title: (m['from_name'] ?? '').toString())));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _claim(int msgId) async {
    setState(() => _busy = true);
    try {
      final taken = await TechHub.instance.claim(widget.id, msgId);
      if (taken != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(taken)));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _photo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 80);
    if (x == null) return;
    setState(() => _busy = true);
    try { await TechHub.instance.chatPhoto(widget.id, x.path); await _load(); }
    on ApiException catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final me = TechHub.instance.engineer?['id'];
    final othersRead = _reads.where((r) => '${r['user_id']}' != '$me').map((r) => (r['last_read_id'] as num?)?.toInt() ?? 0).fold<int>(0, (a, b) => b > a ? b : a);
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: Text(widget.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        actions: [PopupMenuButton<String>(
          onSelected: (v) async {
            try {
              if (v == 'clear') { await TechHub.instance.clearChat(widget.id); await _load(); }
              if (v == 'delete') { await TechHub.instance.deleteChat(widget.id); if (mounted) Navigator.pop(context); }
            } on ApiException catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'clear', child: Text('Clear chat history (for me)')),
            if (!widget.group) const PopupMenuItem(value: 'delete', child: Text('Delete this chat (for me)')),
          ],
        )]),
      body: Column(children: [
        Expanded(
          child: _error != null && _msgs.isEmpty
              ? EmptyState(icon: Icons.cloud_off, text: _error!)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: _msgs.length,
                  itemBuilder: (_, i) {
                    final m = _msgs[i];
                    if (m['kind'] == 'system') {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Center(child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: const Color(0xFFE7F6EC), borderRadius: BorderRadius.circular(12)),
                          child: Text((m['text'] ?? '').toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF15803D))),
                        )),
                      );
                    }
                    final mine = m['mine'] == true || (me != null && '${m['from_id']}' == '$me');
                    final claimedBy = m['claimed_by'] is Map ? m['claimed_by'] as Map : null;
                    final at = DateTime.tryParse((m['at'] ?? '').toString())?.toLocal();
                    final id = (m['id'] as num?)?.toInt() ?? 0;
                    final firstOfRun = i == 0 || _msgs[i - 1]['from_id'] != m['from_id'] || _msgs[i - 1]['kind'] == 'system';
                    final showName = widget.group && !mine && firstOfRun;
                    final ticket = (m['ticket_number'] ?? '').toString();
                    final deleted = m['kind'] == 'deleted';
                    final bubble = GestureDetector(
                      onLongPress: () => _messageMenu(m, mine),
                      child: Container(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (widget.group && !mine ? 0.74 : 0.84)),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                        decoration: BoxDecoration(
                          // Mine: solid purple on the right. Others: a light tint of their own colour on the left.
                          color: mine ? wocomDeep : Color.alphaBlend((_hex(m['from_color']) ?? const Color(0xFF15803D)).withValues(alpha: 0.10), Colors.white),
                          border: mine ? null : Border.all(color: (_hex(m['from_color']) ?? const Color(0xFF15803D)).withValues(alpha: 0.35)),
                          borderRadius: BorderRadius.only(topLeft: const Radius.circular(16), topRight: const Radius.circular(16), bottomLeft: Radius.circular(mine ? 16 : 4), bottomRight: Radius.circular(mine ? 4 : 16)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (showName) Text('${m['from_name'] ?? ''}${(m['from_extension'] ?? '').toString().isNotEmpty ? ' · ${m['from_extension']}' : ''}', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _hex(m['from_color']) ?? wocomPurple)),
                          if (deleted) Text('Message deleted', style: TextStyle(fontSize: 15, fontStyle: FontStyle.italic, color: mine ? Colors.white70 : wocomMuted)),
                          if (ticket.isNotEmpty)
                            InkWell(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: ticket))),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: mine ? Colors.white.withValues(alpha: 0.15) : wocomSoft, borderRadius: BorderRadius.circular(10)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.build_outlined, size: 16, color: mine ? Colors.white : wocomDeep), const SizedBox(width: 6), Text(ticket, style: TextStyle(fontWeight: FontWeight.w800, color: mine ? Colors.white : wocomDeep))]),
                              ),
                            ),
                          if (m['kind'] == 'image' && m['attachment'] is Map)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(TechHub.instance.absUrl((m['attachment'] as Map)['url'].toString()), headers: TechHub.instance.authHeaders, width: 240, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Text('Photo', style: TextStyle(fontStyle: FontStyle.italic, color: mine ? Colors.white : wocomInk)))),
                            ),
                          if (!deleted && (m['text'] ?? '').toString().isNotEmpty) Text(m['text'].toString(), style: TextStyle(fontSize: 17, color: mine ? Colors.white : wocomInk, height: 1.38)),
                          if (claimedBy != null)
                            Padding(padding: const EdgeInsets.only(top: 4), child: Text('${claimedBy['name']} has this', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: mine ? wocomTintLight : const Color(0xFF15803D))))
                          else if (m['claimable'] == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: SizedBox(height: 32, child: FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E), padding: const EdgeInsets.symmetric(horizontal: 12)),
                                onPressed: _busy ? null : () => _claim(id),
                                child: const Text("I'll take it", style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                              )),
                            ),
                          const SizedBox(height: 2),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            if (at != null) Text(_when(at), style: TextStyle(fontSize: 12, color: mine ? Colors.white70 : wocomMuted)),
                            if (mine) ...[const SizedBox(width: 4), Icon(othersRead >= id ? Icons.done_all : Icons.done, size: 14, color: othersRead >= id ? wocomTintLight : Colors.white60)],
                          ]),
                        ]),
                      ),
                    );
                    if (mine) return Align(alignment: Alignment.centerRight, child: bubble);
                    if (!widget.group) return Align(alignment: Alignment.centerLeft, child: bubble);
                    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      SizedBox(width: 38, child: firstOfRun ? Padding(padding: const EdgeInsets.only(bottom: 8), child: GestureDetector(onTap: () => _private(m), child: _avatar(m))) : null),
                      const SizedBox(width: 6),
                      Flexible(child: bubble),
                    ]);
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: wocomLine))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(tooltip: 'Photo', onPressed: _busy ? null : _photo, icon: const Icon(Icons.photo_outlined, color: wocomDeep)),
              Expanded(child: TextField(controller: _text, minLines: 1, maxLines: 4, textCapitalization: TextCapitalization.sentences, style: const TextStyle(fontSize: 17), decoration: InputDecoration(hintText: 'Message', contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), filled: true, fillColor: wocomBg, border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none)))),
              const SizedBox(width: 6),
              IconButton.filled(style: IconButton.styleFrom(backgroundColor: wocomDeep), onPressed: _busy ? null : _send, icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20)),
            ]),
          ),
        ),
      ]),
    );
  }
}
