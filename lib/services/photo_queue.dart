import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'diag.dart';
import 'techhub.dart';

/// Location photos waiting to reach Tech Hub. Survives app restarts and no signal:
/// each photo is copied into app storage first, then sent one at a time and retried
/// when the network comes back.
class PhotoQueue extends ChangeNotifier {
  PhotoQueue._();
  static final instance = PhotoQueue._();

  final List<Map<String, dynamic>> items = [];
  /// Bumped with the ticket number after a photo lands, so open screens reload.
  final uploaded = ValueNotifier<String>('');
  /// Last permanent failure (shown once as a message).
  final failure = ValueNotifier<String?>(null);

  Directory? _dir;
  bool _ready = false, _running = false;
  StreamSubscription? _net;
  Timer? _retry;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      _dir = Directory('${(await getApplicationDocumentsDirectory()).path}/photo_queue');
      await _dir!.create(recursive: true);
      final f = File('${_dir!.path}/queue.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString());
        if (list is List) {
          for (final e in list) {
            final m = Map<String, dynamic>.from(e as Map);
            if (File(m['path'].toString()).existsSync()) items.add(m);
          }
        }
      }
    } catch (e) { Diag.log('photos', 'queue load failed: $e'); }
    _net ??= Connectivity().onConnectivityChanged.listen((r) { if (!r.contains(ConnectivityResult.none)) kick(); });
    notifyListeners();
    kick();
  }

  List<Map<String, dynamic>> pendingFor(String number, int visitId) =>
      items.where((e) => e['number'] == number && e['visit_id'] == visitId).toList();

  Future<void> add(String number, int visitId, String srcPath, String caption) async {
    await init();
    final ext = srcPath.toLowerCase().endsWith('.png') ? 'png' : (srcPath.toLowerCase().endsWith('.webp') ? 'webp' : 'jpg');
    final dest = '${_dir!.path}/${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(srcPath).copy(dest);
    items.add({'number': number, 'visit_id': visitId, 'path': dest, 'caption': caption, 'tries': 0});
    await _save();
    notifyListeners();
    kick();
  }

  Future<void> remove(Map<String, dynamic> item) async {
    items.remove(item);
    try { await File(item['path'].toString()).delete(); } catch (_) {}
    await _save();
    notifyListeners();
  }

  Future<void> kick() async {
    if (_running || items.isEmpty || TechHub.instance.token == null) return;
    _running = true;
    _retry?.cancel();
    try {
      while (items.isNotEmpty) {
        final it = items.first;
        try {
          await TechHub.instance.visitPhotoUpload(it['number'].toString(), (it['visit_id'] as num).toInt(), it['path'].toString(), (it['caption'] ?? '').toString());
          await remove(it);
          uploaded.value = '${it['number']}#${DateTime.now().microsecondsSinceEpoch}';
        } on ApiException catch (e) {
          if (e.status == 0 || e.status >= 500 || e.status == 429) {
            it['tries'] = ((it['tries'] as num?) ?? 0) + 1;
            await _save();
            break; // no signal / server trouble: try again later
          }
          // 403/404/409/413/415/422: this photo will never go — drop it and say why.
          failure.value = "A photo for ${it['number']} wasn't added: ${e.message}";
          await remove(it);
        }
      }
    } finally {
      _running = false;
      if (items.isNotEmpty) _retry = Timer(const Duration(seconds: 60), kick);
    }
  }

  Future<void> _save() async {
    try { await File('${_dir!.path}/queue.json').writeAsString(jsonEncode(items)); } catch (_) {}
  }
}

/// Tech Hub images need the Bearer header; keep a copy on disk so a location's
/// photos open instantly the second time and without signal.
class AuthImageCache {
  static final _mem = <String, Future<File?>>{};

  static Future<File?> get(String url) => _mem[url] ??= _fetch(url).then((f) {
        if (f == null) _mem.remove(url);
        return f;
      });

  static Future<File?> _fetch(String url) async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/th_img');
      await dir.create(recursive: true);
      final f = File('${dir.path}/${url.hashCode.toUnsigned(32)}_${url.length}');
      if (await f.exists() && await f.length() > 0) return f;
      final r = await http.get(Uri.parse(TechHub.instance.absUrl(url)), headers: TechHub.instance.authHeaders).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      await f.writeAsBytes(r.bodyBytes, flush: true);
      return f;
    } catch (_) {
      return null;
    }
  }
}
