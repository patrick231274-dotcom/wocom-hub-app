import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/chat_files.dart';
import '../services/hub.dart';
import '../services/realtime.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// One conversation. Opened from the chat list (conversationId) or from Team (userId, which
/// opens or creates the direct chat). Date chips, avatars on incoming messages, sent/read ticks
/// on ours, file cards, a typing indicator, quick replies and the composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, required this.title, this.otherUserId}) : userId = null;
  const ChatScreen.withUser({super.key, required int this.userId, required this.title})
      : conversationId = null,
        otherUserId = userId;

  final int? conversationId;
  final int? userId;
  final int? otherUserId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  int? _conversationId;
  List<Map<String, dynamic>> _messages = [];
  String? _error;
  bool _sending = false;
  bool _uploading = false;
  Timer? _poll;
  Timer? _statusPoll;
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _typedAt = DateTime.fromMillisecondsSinceEpoch(0);
  List<String> _typing = [];
  DateTime? _otherReadAt;

  static const _quickReplies = ['On it', 'Call me', 'In a meeting, 10 min', 'Thanks!'];

  void _onLive() {
    if (Hub.instance.changedConversation == _conversationId) {
      _load(quiet: true);
      _status();
    }
  }

  PushApi get _api => Session.instance.api;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    _load();
    // Live socket tells us when this conversation changes; polling is the slow safety net.
    Hub.instance.chatEvent.addListener(_onLive);
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (Realtime.instance.connected.value && DateTime.now().difference(_loadedAt) < const Duration(seconds: 30)) return;
      _load(quiet: true);
    });
    // Typing and read receipts are short-lived; ask every few seconds while the screen is open.
    _statusPoll = Timer.periodic(const Duration(seconds: 3), (_) => _status());
    _text.addListener(_onTyped);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _statusPoll?.cancel();
    Hub.instance.chatEvent.removeListener(_onLive);
    _text.removeListener(_onTyped);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    _loadedAt = DateTime.now();
    try {
      final r = _conversationId == null
          ? await _api.post('chat/open', {'user_id': widget.userId})
          : await _api.get('chat/$_conversationId/messages');
      final list = ((r['messages'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final grew = list.length != _messages.length;
      if (!mounted) return;
      setState(() {
        _conversationId = (r['conversation_id'] as int?) ?? _conversationId;
        _messages = list;
        _error = null;
      });
      if (grew) _toBottom();
    } on ApiException catch (e) {
      if (!quiet && mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _status() async {
    if (_conversationId == null) return;
    try {
      final r = await _api.get('chat/$_conversationId/status');
      final typing = ((r['typing'] as List?) ?? const []).map((e) => e.toString()).toList();
      final read = r['other_last_read_at'] != null ? DateTime.tryParse(r['other_last_read_at'].toString()) : null;
      if (!mounted) return;
      if (typing.join() != _typing.join() || read != _otherReadAt) {
        final startedTyping = typing.isNotEmpty && _typing.isEmpty;
        setState(() { _typing = typing; _otherReadAt = read; });
        if (startedTyping) _toBottom();
      }
    } catch (_) {}
  }

  /// Tell the other side we're typing (at most every 2.5 s while the text keeps changing).
  void _onTyped() {
    if (_conversationId == null || _text.text.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_typedAt) < const Duration(milliseconds: 2500)) return;
    _typedAt = now;
    _api.post('chat/$_conversationId/typing').catchError((_) => <String, dynamic>{});
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  Future<void> _send([String? preset]) async {
    final body = (preset ?? _text.text).trim();
    if (body.isEmpty || _conversationId == null || _sending) return;
    setState(() => _sending = true);
    try {
      final r = await _api.post('chat/$_conversationId/send', {'body': body});
      if (preset == null) _text.clear();
      setState(() => _messages = [..._messages, Map<String, dynamic>.from(r['message'] as Map)]);
      _toBottom();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _call(String ext) async {
    await Phone.instance.dial(ext); // the call window opens by itself once the call exists
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message copied'), duration: Duration(seconds: 1)));
  }

  static const _maxBytes = 5 * 1024 * 1024;

  void _attach() {
    if (_conversationId == null || _uploading) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(3)))),
            const SizedBox(height: 14),
            const Text('Send', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            const Text('Photos and voice notes, up to 5 MB', style: TextStyle(fontSize: 12, color: wocomMuted)),
            const SizedBox(height: 12),
            Row(children: [
              _attachOption(c, Icons.photo_outlined, 'Photo', () => _pickImage(ImageSource.gallery)),
              _attachOption(c, Icons.photo_camera_outlined, 'Camera', () => _pickImage(ImageSource.camera)),
              _attachOption(c, Icons.mic_none, 'Voice note', _recordVoiceNote),
            ]),
            const SizedBox(height: 6),
          ]),
        ),
      ),
    );
  }

  Widget _attachOption(BuildContext sheet, IconData icon, String label, VoidCallback go) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () { Navigator.pop(sheet); go(); },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(18)), child: Icon(icon, color: wocomDeep, size: 26)),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );

  Future<void> _pickImage(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 85);
      if (x == null) return;
      await _sendFile(x.path, x.name, mime: x.mimeType ?? 'image/jpeg');
    } catch (e) {
      _toast("Couldn't get that photo: $e");
    }
  }

  Future<void> _sendFile(String path, String name, {String? mime}) async {
    if (_conversationId == null) return;
    final size = await File(path).length();
    if (size > _maxBytes) { _toast('That file is ${_size(size)}. Files up to 5 MB can be sent.'); return; }
    setState(() => _uploading = true);
    try {
      final r = await _api.uploadFile('chat/$_conversationId/upload', path, fileName: name, mime: mime);
      if (!mounted) return;
      setState(() => _messages = [..._messages, Map<String, dynamic>.from(r['message'] as Map)]);
      _toBottom();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Photos open full screen inside the app: pinch to zoom, tap the X or swipe down to close.
  Future<void> _viewImage(String token, String name) async {
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => _ImageViewer(token: token, name: name),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  Future<void> _openFile(String token, String name) async {
    _toast('Opening "$name"…');
    final err = await ChatFiles.instance.open(token, name);
    if (err != null) _toast(err);
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Record a voice note: starts at once, shows the clock, Send uploads it as an m4a file.
  Future<void> _recordVoiceNote() async {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) { _toast('Allow the microphone to record a voice note.'); return; }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1), path: path);
    } catch (e) {
      _toast("Couldn't start recording: $e");
      return;
    }
    final started = DateTime.now();
    if (!mounted) return;
    final send = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => _VoiceNoteSheet(started: started, recorder: rec, maxSeconds: 300),
    );
    String? recorded;
    try { recorded = await rec.stop(); } catch (_) {}
    rec.dispose();
    if (send != true || recorded == null) { try { await File(path).delete(); } catch (_) {} return; }
    final secs = DateTime.now().difference(started).inSeconds;
    if (secs < 1) { _toast('That was too short.'); try { await File(path).delete(); } catch (_) {} return; }
    final now = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    await _sendFile(recorded, 'Voice note ${now.day} ${months[now.month - 1]} $h.${now.minute.toString().padLeft(2, '0')} ${now.hour < 12 ? 'AM' : 'PM'}.m4a', mime: 'audio/mp4');
  }

  // ── building the list ──────────────────────────────────────────────────────

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (diff < 7) return days[d.weekday - 1];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _size(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  static (String, Color, Color) _fileBadge(String? mime, String name) {
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : 'FILE';
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/')) return ('IMG', const Color(0xFFE7F6EC), const Color(0xFF15803D));
    if (m.contains('pdf')) return ('PDF', const Color(0xFFFEE2E2), const Color(0xFFB91C1C));
    if (m.contains('sheet') || m.contains('excel') || ext == 'CSV') return (ext.length <= 4 ? ext : 'XLS', const Color(0xFFDCFCE7), const Color(0xFF166534));
    if (m.contains('word') || ext == 'DOC' || ext == 'DOCX') return ('DOC', const Color(0xFFE0F2FE), const Color(0xFF0369A1));
    if (m.startsWith('audio/')) return ('AUD', const Color(0xFFF0EBFF), wocomDeep);
    return (ext.length <= 4 ? ext : 'FILE', const Color(0xFFF3F4F6), const Color(0xFF374151));
  }

  @override
  Widget build(BuildContext context) {
    final person = Hub.instance.personByUserId(widget.otherUserId);
    final me = Hub.instance.meUserId;
    final top = MediaQuery.of(context).padding.top;
    final group = widget.otherUserId == null;
    final maxBubble = MediaQuery.of(context).size.width * 0.78;

    // Rows: date chips between days, then messages; a typing row at the end.
    final rows = <Widget>[];
    DateTime? lastDay;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final at = DateTime.tryParse((m['created_at'] ?? '') as String)?.toLocal();
      if (at != null && (lastDay == null || lastDay.year != at.year || lastDay.month != at.month || lastDay.day != at.day)) {
        rows.add(_DayChip(_dayLabel(at)));
        lastDay = at;
      }
      final mine = m['sender_id'] == me;
      final prev = i > 0 ? _messages[i - 1] : null;
      final firstOfRun = prev == null || prev['sender_id'] != m['sender_id'];
      rows.add(_bubble(m, mine: mine, at: at, showAvatar: !mine && firstOfRun, showName: !mine && group && firstOfRun, maxWidth: maxBubble));
    }
    if (_typing.isNotEmpty) rows.add(_TypingRow(name: _typing.first));

    return Scaffold(
      backgroundColor: wocomBg,
      body: Column(children: [
        // Header
        Container(
          padding: EdgeInsets.fromLTRB(4, top + 8, 10, 12),
          color: wocomPlum,
          child: Row(children: [
            IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white), onPressed: () => Navigator.pop(context)),
            PersonAvatar(name: widget.title, status: person?['status'] as String?, onDark: true, size: 42, group: group),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                Text(
                  _typing.isNotEmpty
                      ? 'typing…'
                      : person != null
                          ? '${person['status_label']} · Ext ${person['extension']}'
                          : group ? 'Group chat' : '',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: wocomTintLight, fontSize: 12, fontWeight: FontWeight.w500, fontStyle: _typing.isNotEmpty ? FontStyle.italic : FontStyle.normal),
                ),
              ]),
            ),
            if (person != null)
              IconButton(
                tooltip: 'Call ${widget.title}',
                style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.12)),
                icon: const Icon(Icons.call_outlined, color: Colors.white, size: 21),
                onPressed: () => _call(person['extension'] as String),
              ),
          ]),
        ),
        // Messages
        Expanded(
          child: _error != null && _messages.isEmpty
              ? EmptyState(icon: Icons.chat_bubble_outline, text: _error!)
              : _messages.isEmpty
                  ? const EmptyState(icon: Icons.waving_hand_outlined, text: 'Say hello! Messages appear here and in the WOCOM Hub.')
                  : ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(14, 14, 14, 8), children: rows),
        ),
        // Composer
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: wocomLine))),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_uploading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Sending…', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: wocomMuted)),
                  ]),
                ),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _quickReplies.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => InkWell(
                    onTap: _sending ? null : () => _send(_quickReplies[i]),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: wocomSoft, border: Border.all(color: const Color(0xFFDCCFFB)), borderRadius: BorderRadius.circular(14)),
                      child: Text(_quickReplies[i], style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: wocomDeep)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(
                  tooltip: 'Attach',
                  style: IconButton.styleFrom(backgroundColor: wocomSoft, fixedSize: const Size(44, 44)),
                  onPressed: _attach,
                  icon: const Icon(Icons.add, color: wocomDeep),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Message ${widget.title.split(' ').first}…',
                      filled: true,
                      fillColor: wocomBg,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: wocomLine)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: wocomLine)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: wocomPurple, width: 1.5)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  style: IconButton.styleFrom(backgroundColor: wocomDeep, fixedSize: const Size(44, 44)),
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m, {required bool mine, DateTime? at, required bool showAvatar, required bool showName, required double maxWidth}) {
    final isFile = m['type'] == 'file';
    final att = m['attachment'] is Map ? Map<String, dynamic>.from(m['attachment'] as Map) : null;
    final body = (m['body'] ?? '') as String;
    final read = mine && at != null && _otherReadAt != null && !_otherReadAt!.isBefore(at);
    final sender = (m['sender_name'] ?? '') as String;

    Widget content;
    final token = (att?['token'] ?? '') as String;
    final mimeType = ((att?['mime_type'] ?? '') as String).toLowerCase();
    final fileName = ((att?['file_name'] ?? body) as String).toLowerCase();
    final isAudio = mimeType.startsWith('audio/') || RegExp(r'\.(m4a|mp3|wav|ogg|oga|opus|aac|amr)$').hasMatch(fileName) || fileName.startsWith('voice note');
    if (isFile && token.isNotEmpty && isAudio) {
      final name = (att?['file_name'] ?? body) as String;
      content = _AudioCard(token: token, name: name, mine: mine, voiceNote: name.startsWith('Voice note'));
    } else if (isFile && token.isNotEmpty && mimeType.startsWith('image/')) {
      final name = (att?['file_name'] ?? body) as String;
      content = _ImageCard(token: token, name: name, mine: mine, onOpen: () => _viewImage(token, name));
    } else if (isFile) {
      final name = (att?['file_name'] ?? body) as String;
      final (tag, bg, fg) = _fileBadge(att?['mime_type'] as String?, name);
      content = InkWell(
        onTap: token.isEmpty ? null : () => _openFile(token, name),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minWidth: 220),
          padding: const EdgeInsets.all(10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)), child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: fg))),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: mine ? Colors.white : wocomInk)),
                Text('${_size(att?['file_size'] as int?)}${att?['file_size'] != null ? ' · ' : ''}${token.isEmpty ? 'Open in the Hub' : 'Tap to open'}', style: TextStyle(fontSize: 11.5, color: mine ? const Color(0xFFE9DDFF) : const Color(0xFF8A8299))),
              ]),
            ),
          ]),
        ),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: LinkedText(body, style: TextStyle(color: mine ? Colors.white : wocomInk, fontSize: 15, height: 1.4), linkColor: mine ? const Color(0xFFFFE08A) : wocomDeep),
      );
    }

    final bubble = GestureDetector(
      onLongPress: () => _copy(body),
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: mine ? wocomDeep : Colors.white,
          border: mine ? null : Border.all(color: wocomLine),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 6), bottomRight: Radius.circular(mine ? 6 : 18),
          ),
        ),
        child: content,
      ),
    );

    final meta = Padding(
      padding: EdgeInsets.only(top: 3, left: mine ? 0 : 6, right: mine ? 4 : 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (at != null) Text(_clock(at), style: const TextStyle(fontSize: 11, color: Color(0xFF8A8299))),
        if (mine) ...[
          const SizedBox(width: 4),
          Icon(read ? Icons.done_all : Icons.done, size: 15, color: read ? wocomDeep : const Color(0xFFB8B1C6)),
        ],
      ]),
    );

    if (mine) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 36),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [bubble, meta]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        SizedBox(width: 28, height: 28, child: showAvatar ? PersonAvatar(name: sender.isEmpty ? widget.title : sender, size: 28) : null),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showName) Padding(padding: const EdgeInsets.only(left: 6, bottom: 3), child: Text(sender, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: wocomDeep))),
            bubble,
            meta,
          ]),
        ),
      ]),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: wocomMuted)),
        ),
      );
}

/// Three dots while the other person types.
class _TypingRow extends StatefulWidget {
  const _TypingRow({required this.name});
  final String name;

  @override
  State<_TypingRow> createState() => _TypingRowState();
}

class _TypingRowState extends State<_TypingRow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          PersonAvatar(name: widget.name, size: 28),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomRight: Radius.circular(18), bottomLeft: Radius.circular(6))),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Opacity(
                    opacity: 0.35 + 0.65 * ((1 + _sin(_c.value, i)) / 2),
                    child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: wocomMuted, shape: BoxShape.circle)),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      );

  static double _sin(double t, int i) => math.sin(((t - i * 0.2) % 1.0) * 2 * math.pi);
}

/// Message text with web addresses, emails and phone numbers tappable (tap opens; a long press
/// on the message copies it).
class LinkedText extends StatelessWidget {
  const LinkedText(this.text, {super.key, required this.style, required this.linkColor});

  final String text;
  final TextStyle style;
  final Color linkColor;

  static final _pattern = RegExp(
    r"((?:https?://|www\.)[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'\x22])|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})|(\+?\d[\d\s().-]{6,}\d)",
  );

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final raw = m.group(0)!;
      Uri? uri;
      if (m.group(1) != null) {
        uri = Uri.tryParse(raw.startsWith('www.') ? 'https://$raw' : raw);
      } else if (m.group(2) != null) {
        uri = Uri(scheme: 'mailto', path: raw);
      } else {
        final digits = raw.replaceAll(RegExp(r'[^\d+]'), '');
        uri = digits.length >= 7 ? Uri(scheme: 'tel', path: digits) : null;
      }
      if (uri == null) {
        spans.add(TextSpan(text: raw));
      } else {
        final u = uri;
        spans.add(TextSpan(
          text: raw,
          style: TextStyle(color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor, fontWeight: FontWeight.w600),
          recognizer: TapGestureRecognizer()..onTap = () async {
            final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
            if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open $raw")));
          },
        ));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}


/// A voice note or audio file: play/pause, a progress bar and the clock, played in place.
class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.token, required this.name, required this.mine, required this.voiceNote});
  final String token;
  final String name;
  final bool mine;
  final bool voiceNote;

  static String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final fg = mine ? Colors.white : wocomInk;
    final dim = mine ? const Color(0xFFE9DDFF) : wocomMuted;
    return AnimatedBuilder(
      animation: ChatFiles.instance,
      builder: (context, _) {
        final cf = ChatFiles.instance;
        final active = cf.current == token;
        final playing = active && cf.playing && !cf.completed;
        return Container(
          constraints: const BoxConstraints(minWidth: 230, maxWidth: 280),
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          child: Row(children: [
            SizedBox(
              width: 42, height: 42,
              child: Material(
                color: mine ? Colors.white.withValues(alpha: 0.18) : wocomSoft,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => playing ? cf.pause() : cf.play(token, name),
                  child: active && cf.loading
                      ? Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: mine ? Colors.white : wocomDeep))
                      : Icon(playing ? Icons.pause : Icons.play_arrow, color: mine ? Colors.white : wocomDeep, size: 26),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(voiceNote ? 'Voice note' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: fg)),
                const SizedBox(height: 6),
                StreamBuilder<Duration>(
                  stream: active ? cf.positions : null,
                  builder: (context, snap) {
                    final total = active ? (cf.duration ?? Duration.zero) : Duration.zero;
                    final pos = active ? (snap.data ?? cf.position) : Duration.zero;
                    final frac = total.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      GestureDetector(
                        onTapDown: total.inMilliseconds == 0 ? null : (d) {
                          final box = context.findRenderObject() as RenderBox?;
                          if (box == null) return;
                          cf.seek(total * (d.localPosition.dx / box.size.width).clamp(0.0, 1.0));
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(value: frac, minHeight: 5, backgroundColor: mine ? Colors.white.withValues(alpha: 0.25) : wocomLine, color: mine ? Colors.white : wocomDeep),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(active && total > Duration.zero ? '${_clock(pos)} / ${_clock(total)}' : 'Tap to play', style: TextStyle(fontSize: 11, color: dim)),
                    ]);
                  },
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// A photo in the conversation, shown in place once fetched; tap opens it full size.
class _ImageCard extends StatelessWidget {
  const _ImageCard({required this.token, required this.name, required this.mine, required this.onOpen});
  final String token;
  final String name;
  final bool mine;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: FutureBuilder<File>(
            future: ChatFiles.instance.fetch(token, name),
            builder: (context, snap) {
              if (snap.hasData) {
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
                  child: Image.file(snap.data!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder(Icons.broken_image_outlined)),
                );
              }
              return _placeholder(snap.hasError ? Icons.broken_image_outlined : Icons.image_outlined);
            },
          ),
        ),
      );

  Widget _placeholder(IconData icon) => Container(
        width: 220, height: 150,
        color: mine ? Colors.white.withValues(alpha: 0.12) : wocomBg,
        child: Icon(icon, size: 36, color: mine ? Colors.white : wocomMuted),
      );
}

/// Recording in progress: clock, pulsing dot, Cancel or Send.
class _VoiceNoteSheet extends StatefulWidget {
  const _VoiceNoteSheet({required this.started, required this.recorder, required this.maxSeconds});
  final DateTime started;
  final AudioRecorder recorder;
  final int maxSeconds;

  @override
  State<_VoiceNoteSheet> createState() => _VoiceNoteSheetState();
}

class _VoiceNoteSheetState extends State<_VoiceNoteSheet> {
  Timer? _tick;
  int _secs = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final s = DateTime.now().difference(widget.started).inSeconds;
      if (s != _secs && mounted) setState(() => _secs = s);
      if (s >= widget.maxSeconds && mounted) Navigator.pop(context, true);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 5, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(3))),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: _secs.isEven ? const Color(0xFFDC2626) : const Color(0xFFFCA5A5), shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Text('${_secs ~/ 60}:${(_secs % 60).toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 4),
            const Text('Recording voice note · up to 5 minutes', style: TextStyle(fontSize: 12.5, color: wocomMuted)),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50), foregroundColor: wocomMuted, side: const BorderSide(color: wocomLine)),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 50), backgroundColor: wocomDeep),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send'),
                ),
              ),
            ]),
          ]),
        ),
      );
}


/// Full-screen photo: pinch and drag to zoom, close with the X.
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.token, required this.name});
  final String token;
  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(
            child: FutureBuilder<File>(
              future: ChatFiles.instance.fetch(token, name),
              builder: (context, snap) => snap.hasData
                  ? InteractiveViewer(minScale: 1, maxScale: 5, child: Center(child: Image.file(snap.data!, fit: BoxFit.contain)))
                  : Center(child: snap.hasError ? const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48) : const CircularProgressIndicator(color: Colors.white)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8, right: 12,
            child: IconButton(
              tooltip: 'Close',
              style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.18)),
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            left: 16, right: 16, bottom: MediaQuery.of(context).padding.bottom + 16,
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
        ]),
      );
}
