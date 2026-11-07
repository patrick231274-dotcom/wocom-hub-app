import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import 'api.dart';
import 'phone.dart';
import 'realtime.dart';
import 'session.dart';

/// Live data from the WOCOM Hub for the main screens. Changes arrive over the live socket
/// ([Realtime]); polling stays on as a slow safety net (fast only while the socket is down).
class Hub extends ChangeNotifier {
  Hub._();
  static final Hub instance = Hub._();

  PushApi get _api => Session.instance.api;

  List<Map<String, dynamic>> people = [];
  List<String> departments = [];
  int? meUserId;
  String myStatus = 'available';
  /// Queue membership: 'Available', 'On Break', 'Logged Out', or null when not an agent.
  String? myQueueStatus;
  bool inQueue = false;
  bool get queueBenched => inQueue && myQueueStatus != null && myQueueStatus != 'Available';

  /// Put myself back on the queue (or take a break).
  Future<String?> setQueueStatus(String status) async {
    try {
      await _api.post('queue/status', {'status': status});
      myQueueStatus = status;
      notifyListeners();
      refreshTeam();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
  String? teamError;

  List<Map<String, dynamic>> conversations = [];
  int unreadChats = 0;
  /// Missed callers nobody has called back (Pulse badge; administrators only).
  int openMissed = 0;
  /// Open tasks on my list (Meet tab badge); the Meet screen and the push handler keep it fresh.
  int openTasks = 0;
  final tasksEvent = ValueNotifier<int>(0);
  void setOpenTasks(int n) { if (n != openTasks) { openTasks = n; notifyListeners(); } }
  String? chatError;

  Timer? _teamTimer;
  Timer? _chatTimer;
  int? _lastUnread;

  /// Set by the app shell so a new-message banner can show on any screen.
  GlobalKey<ScaffoldMessengerState>? messenger;

  /// Which section the Team tab should show (0 team · 1 directory · 2 my phone); set by shortcuts.
  final ValueNotifier<int> teamSource = ValueNotifier<int>(0);

  DateTime _teamAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _chatsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bumped when a call ends (mine, or anyone's via the live link): Recents reloads.
  final ValueNotifier<int> callsEvent = ValueNotifier<int>(0);

  /// A conversation that just changed (its id), for the open chat screen to refresh.
  final ValueNotifier<int> chatEvent = ValueNotifier<int>(0);
  int _chatEventId = 0;

  bool _wasInCall = false;
  Timer? _callRefresh;

  /// My own call starting or ending changes my dot (on a call ↔ available): refresh right after.
  void _onPhone() {
    final inCall = Phone.instance.call != null;
    if (inCall == _wasInCall) return;
    _wasInCall = inCall;
    _callRefresh?.cancel();
    _callRefresh = Timer(const Duration(milliseconds: 1500), () {
      refreshTeam();
      if (!inCall) Timer(const Duration(seconds: 2), () => callsEvent.value++); // the record is written a moment after hang-up
    });
  }

  void start() {
    refreshTeam();
    refreshChats();
    Realtime.instance.start();
    Phone.instance.removeListener(_onPhone);
    Phone.instance.addListener(_onPhone);
    // With the live socket up these only catch anything it missed: team every 20 s, chats every 2 min.
    _teamTimer ??= Timer.periodic(const Duration(seconds: 6), (_) {
      if (Realtime.instance.connected.value && DateTime.now().difference(_teamAt) < const Duration(seconds: 20)) return;
      refreshTeam();
    });
    _chatTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (Realtime.instance.connected.value && DateTime.now().difference(_chatsAt) < const Duration(seconds: 120)) return;
      refreshChats();
    });
  }

  void stop() {
    _teamTimer?.cancel();
    _chatTimer?.cancel();
    _teamTimer = null;
    _chatTimer = null;
    Phone.instance.removeListener(_onPhone);
    Realtime.instance.stop();
  }

  /// The live socket says a conversation changed: refresh the list now and tell the open screen.
  void chatChanged(int conversationId) {
    _chatEventId = conversationId;
    refreshChats();
    chatEvent.value = chatEvent.value + 1;
  }

  int get changedConversation => _chatEventId;

  Future<void> refreshTeam() async {
    try {
      final r = await _api.get('team');
      people = ((r['people'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      departments = ((r['departments'] as List?) ?? const []).map((e) => e.toString()).toList();
      meUserId = r['me_user_id'] as int?;
      _teamAt = DateTime.now();
      final me = people.where((p) => p['is_me'] == true);
      if (me.isNotEmpty) {
        myStatus = me.first['status'] as String;
        myQueueStatus = me.first['queue_status'] as String?;
        inQueue = ((me.first['queues'] ?? 0) as int) > 0;
      }
      teamError = null;
    } on ApiException catch (e) {
      if (e.signedOut) await Session.instance.forceSignedOut();
      teamError = e.message;
    }
    notifyListeners();
    _refreshPulseCount();
  }

  Future<void> refreshChats() async {
    try {
      final r = await _api.get('chat/conversations');
      conversations = ((r['conversations'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      unreadChats = conversations.fold(0, (n, c) => n + ((c['unread_count'] ?? 0) as int));
      chatError = null;
      _chatsAt = DateTime.now();
      Realtime.instance.followChats(conversations.map((c) => (c['id'] as num?)?.toInt() ?? 0).where((id) => id > 0));
      // More unread than last time: a new message arrived while the app is open.
      if (_lastUnread != null && unreadChats > _lastUnread!) {
        FlutterRingtonePlayer().playNotification();
        final from = conversations.where((c) => ((c['unread_count'] ?? 0) as int) > 0).map((c) => c['name']).whereType<String>().firstOrNull;
        messenger?.currentState?.showSnackBar(SnackBar(
          content: Text(from == null ? 'New message' : 'New message from $from'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      }
      _lastUnread = unreadChats;
    } on ApiException catch (e) {
      chatError = e.code == 'no_account' ? e.message : (conversations.isEmpty ? e.message : null);
    }
    notifyListeners();
  }

  Future<void> _refreshPulseCount() async {
    try {
      final t = await _api.get('tasks');
      setOpenTasks((t['open'] as num?)?.toInt() ?? 0);
    } catch (_) {}
    final role = (Session.instance.user?['role'] ?? '').toString();
    if (role != 'domain_admin' && role != 'supervisor' && role != 'superadmin') return;
    try {
      final r = await _api.get('pulse', {'range': 'today'});
      final n = (r['open_missed'] as num?)?.toInt() ?? 0;
      if (n != openMissed) { openMissed = n; notifyListeners(); }
    } catch (_) {}
  }

  /// Available / away / dnd … — the same states as the Hub (non-available sends calls to voicemail).
  Future<String?> setStatus(String status) async {
    try {
      await _api.post('presence', {'status': status});
      myStatus = status;
      notifyListeners();
      refreshTeam();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Map<String, dynamic>? personByUserId(int? id) {
    if (id == null) return null;
    for (final p in people) {
      if (p['hub_user_id'] == id) return p;
    }
    return null;
  }
}
