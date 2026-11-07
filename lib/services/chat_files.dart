import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'diag.dart';
import 'session.dart';

/// Chat attachments on the phone: fetched once through the push service (with the device
/// token), cached in the temp folder, opened with the phone's own apps, or played inline when
/// they are audio (voice notes).
class ChatFiles extends ChangeNotifier {
  ChatFiles._() {
    _player.playerStateStream.listen((_) => notifyListeners());
  }
  static final ChatFiles instance = ChatFiles._();

  final AudioPlayer _player = AudioPlayer();
  final Map<String, Future<File>> _fetching = {};
  String? current;       // token loaded in the player
  bool loading = false;
  bool get playing => _player.playing;
  bool get completed => _player.processingState == ProcessingState.completed;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  Stream<Duration> get positions => _player.positionStream;

  PushApi get _api => Session.instance.api;

  /// The local copy of an attachment, downloading it the first time.
  Future<File> fetch(String token, String name) {
    return _fetching.putIfAbsent(token, () async {
      try {
        final dir = await getTemporaryDirectory();
        final ext = name.contains('.') ? '.${name.split('.').last.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}' : '';
        final f = File('${dir.path}/chat-$token$ext');
        if (await f.exists() && await f.length() > 0) return f;
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
        try {
          final req = await client.getUrl(Uri.parse('${_api.baseUrl}/chat/file/$token'));
          if (_api.token != null) req.headers.set('Authorization', 'Bearer ${_api.token}');
          req.headers.set('X-App-Version', PushApi.appVersion);
          final res = await req.close();
          if (res.statusCode != 200) throw ApiException('not_found', 'That file is no longer available.', res.statusCode);
          final sink = f.openWrite();
          await res.pipe(sink);
          return f;
        } finally {
          client.close();
        }
      } catch (e) {
        _fetching.remove(token);
        rethrow;
      }
    });
  }

  /// Download (if needed) and hand the file to the phone's apps. Returns an error to show, or null.
  Future<String?> open(String token, String name) async {
    try {
      final f = await fetch(token, name);
      final r = await OpenFilex.open(f.path);
      if (r.type != ResultType.done) return r.type == ResultType.noAppToOpen ? 'No app on this phone can open "$name".' : r.message;
      return null;
    } catch (e) {
      Diag.log('chat', 'open failed: $e');
      return e is ApiException ? e.message : "Couldn't open this file.";
    }
  }

  Future<bool> play(String token, String name) async {
    if (current == token) {
      if (completed) await _player.seek(Duration.zero);
      await _player.play();
      notifyListeners();
      return true;
    }
    loading = true; current = token;
    notifyListeners();
    try {
      await _player.stop();
      final f = await fetch(token, name);
      await _player.setFilePath(f.path);
      loading = false;
      notifyListeners();
      _player.play();
      return true;
    } catch (e) {
      Diag.log('chat', 'play failed: $e');
      loading = false; current = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> pause() async { await _player.pause(); notifyListeners(); }
  Future<void> seek(Duration d) => _player.seek(d);
}
