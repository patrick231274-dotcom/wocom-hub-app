import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'diag.dart';
import 'session.dart';

/// Plays voicemail in the app. The audio is fetched through WOCOM (never stored on the phone
/// beyond a small cache), playing marks the message heard on the phone system, and delete
/// removes it everywhere.
class Voicemail extends ChangeNotifier {
  Voicemail._() {
    _player.playerStateStream.listen((_) => notifyListeners());
  }
  static final Voicemail instance = Voicemail._();

  final AudioPlayer _player = AudioPlayer();
  String? current;          // message id loaded in the player
  bool loading = false;
  String? error;
  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  Stream<Duration> get positions => _player.positionStream;
  Stream<PlayerState> get states => _player.playerStateStream;

  PushApi get _api => Session.instance.api;

  /// Load (download if needed) and start a message. Returns false if it could not play.
  Future<bool> play(String id) async {
    if (current == id) {
      if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
      await _player.play();
      notifyListeners();
      return true;
    }
    loading = true; error = null; current = id;
    notifyListeners();
    try {
      await _player.stop();
      final f = await _fetch(id);
      await _player.setFilePath(f.path);
      loading = false;
      notifyListeners();
      _player.play();
      return true;
    } catch (e) {
      Diag.log('voicemail', 'play failed: $e');
      loading = false; error = e is ApiException ? e.message : "Couldn't play this voicemail.";
      notifyListeners();
      return false;
    }
  }

  Future<void> pause() async { await _player.pause(); notifyListeners(); }
  Future<void> seek(Duration d) => _player.seek(d);
  Future<void> stop() async { await _player.stop(); current = null; notifyListeners(); }

  Future<File> _fetch(String id) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/vm-$id.wav');
    if (await f.exists() && await f.length() > 1000) return f;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse('${_api.baseUrl}/voicemail/$id/audio'));
      if (_api.token != null) req.headers.set('Authorization', 'Bearer ${_api.token}');
      req.headers.set('X-App-Version', PushApi.appVersion);
      final res = await req.close();
      if (res.statusCode != 200) throw ApiException('not_found', 'That voicemail is no longer available.', res.statusCode);
      final sink = f.openWrite();
      await res.pipe(sink);
      return f;
    } finally {
      client.close();
    }
  }

  Future<String?> delete(String id) async {
    try {
      if (current == id) await stop();
      await _api.post('voicemail/$id/delete');
      try { final f = File('${(await getTemporaryDirectory()).path}/vm-$id.wav'); if (await f.exists()) await f.delete(); } catch (_) {}
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<void> markHeard(String id) async {
    try { await _api.post('voicemail/$id/heard'); } catch (_) {}
  }
}
