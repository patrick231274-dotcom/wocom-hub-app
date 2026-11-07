import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'diag.dart';
import 'hub.dart';
import 'session.dart';

/// One WebSocket to the Hub's live-update server (Pusher protocol), so team status and chat
/// change the instant they change instead of every few seconds by polling. Channels and the
/// signed subscription come from WOCOM for this phone; polling stays on as a slow safety net.
class Realtime {
  Realtime._();
  static final Realtime instance = Realtime._();

  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  WebSocket? _ws;
  String? _socketId;
  bool _wanted = false;
  int _backoff = 2;
  Timer? _retry;
  Timer? _ping;
  Timer? _teamDebounce;
  final Set<String> _subscribed = {};
  List<String> _channels = [];

  PushApi get _api => Session.instance.api;

  /// Connect (or keep trying) while the app is open and signed in.
  Future<void> start() async {
    _wanted = true;
    if (_ws != null) return;
    await _connect();
  }

  void stop() {
    _wanted = false;
    _retry?.cancel();
    _ping?.cancel();
    _ws?.close();
    _ws = null;
    _socketId = null;
    _subscribed.clear();
    connected.value = false;
  }

  Future<void> _connect() async {
    if (!_wanted || !Session.instance.signedIn) return;
    try {
      final info = await _api.get('realtime');
      final url = (info['url'] ?? '').toString();
      _channels = ((info['channels'] as List?) ?? const []).map((e) => e.toString()).toList();
      if (url.isEmpty) throw 'no url';
      final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 10));
      _ws = ws;
      ws.listen(_onMessage, onDone: () => _dropped('closed'), onError: (e) => _dropped('error $e'), cancelOnError: true);
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 30), (_) => _send({'event': 'pusher:ping', 'data': {}}));
    } catch (e) {
      Diag.log('live', 'connect failed: $e');
      _dropped('connect failed');
    }
  }

  void _dropped(String why) {
    if (_ws != null || connected.value) Diag.log('live', 'disconnected ($why)');
    _ws = null;
    _socketId = null;
    _subscribed.clear();
    _ping?.cancel();
    connected.value = false;
    if (!_wanted) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(2, 60);
  }

  void _send(Map<String, dynamic> m) {
    try { _ws?.add(jsonEncode(m)); } catch (_) {}
  }

  Future<void> _onMessage(dynamic raw) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final event = (m['event'] ?? '').toString();
    final channel = (m['channel'] ?? '').toString();
    dynamic data = m['data'];
    if (data is String) { try { data = jsonDecode(data); } catch (_) {} }

    switch (event) {
      case 'pusher:connection_established':
        _socketId = (data is Map ? data['socket_id'] : null)?.toString();
        _backoff = 2;
        connected.value = true;
        Diag.log('live', 'connected, ${_channels.length} channels');
        for (final c in _channels) { await _subscribe(c); }
        return;
      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': {}});
        return;
      case 'pusher:error':
        Diag.log('live', 'server error: ${data is Map ? data['message'] : data}');
        return;
      case 'pusher_internal:subscription_succeeded':
        return;
    }
    // Something changed on a channel we follow.
    if (channel.startsWith('private-calls.') && (event.contains('end') || event.contains('hangup'))) {
      Timer(const Duration(seconds: 2), () => Hub.instance.callsEvent.value++);
    }
    if (channel.startsWith('presence-domain.') || channel.startsWith('private-calls.')) {
      // Presence, member joined/left: refresh the team (debounced: a busy office fires many at once).
      _teamDebounce?.cancel();
      _teamDebounce = Timer(const Duration(milliseconds: 600), () => Hub.instance.refreshTeam());
    } else if (channel.startsWith('private-chat.')) {
      final id = int.tryParse(channel.substring('private-chat.'.length)) ?? 0;
      Hub.instance.chatChanged(id);
    }
  }

  Future<void> _subscribe(String channel) async {
    if (_ws == null || _socketId == null || _subscribed.contains(channel)) return;
    try {
      final r = await _api.post('realtime/auth', {'socket_id': _socketId, 'channel_name': channel});
      _send({'event': 'pusher:subscribe', 'data': {'channel': channel, 'auth': r['auth'], if (r['channel_data'] != null) 'channel_data': r['channel_data']}});
      _subscribed.add(channel);
    } catch (e) {
      Diag.log('live', 'subscribe $channel failed: $e');
    }
  }

  /// Follow any chat conversations we didn't know about when we connected.
  Future<void> followChats(Iterable<int> conversationIds) async {
    if (!connected.value) return;
    for (final id in conversationIds) {
      final c = 'private-chat.$id';
      if (!_subscribed.contains(c)) await _subscribe(c);
    }
  }
}
