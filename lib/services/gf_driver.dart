import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../brand.dart';
import 'api.dart';
import 'diag.dart';
import 'session.dart';

/// Delivery-driver build (first client: Gorgeous Flowers). The driver signs in to the app with
/// their WOCOM HUB account as usual; this service then signs in to the company's own CRM with a
/// short-lived statement from the push server (one sign-in), and talks to the CRM's driver API
/// directly: deliveries, package scans, delivery outcomes, photos, signatures, shift and
/// location. Calls to customers go through the phone system as *7 + the delivery's dial code,
/// so the driver never sees the customer's number.
///
/// Status changes, photos and signatures are queued on the phone first (so nothing is lost
/// without signal) and sent in order; each carries a client_event_id so a retry never doubles.
class GfDriver extends ChangeNotifier {
  GfDriver._();
  static final GfDriver instance = GfDriver._();

  static const _store = FlutterSecureStorage();
  static final _rnd = Random.secure();
  static String _newId() {
    final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  String? _token;
  DateTime? _tokenUntil;
  Map<String, dynamic>? driver;
  Map<String, String> reasons = const {
    'not_home': 'Nobody home', 'wrong_address': 'Wrong address', 'unreachable': 'Could not reach',
    'refused': 'Refused', 'access_denied': 'Could not get access', 'other': 'Other',
  };

  String day = '';
  List<Map<String, dynamic>> deliveries = [];
  bool loading = false;
  String? error;
  DateTime? loadedAt;

  bool onShift = false;
  String? shiftProblem;
  StreamSubscription<Position>? _gps;
  final List<Map<String, dynamic>> _points = [];
  DateTime _pointsSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── CRM session ─────────────────────────────────────────────────────────────

  Future<void> _ensureSession() async {
    if (_token != null && _tokenUntil != null && DateTime.now().isBefore(_tokenUntil!)) return;
    _token ??= await _store.read(key: 'gfd_token');
    final until = int.tryParse(await _store.read(key: 'gfd_until') ?? '');
    if (_token != null && until != null && DateTime.now().millisecondsSinceEpoch < until) {
      _tokenUntil = DateTime.fromMillisecondsSinceEpoch(until);
      return;
    }
    // One sign-in: the push server vouches for this Hub account for 5 minutes.
    final a = await Session.instance.api.post('crm/assertion');
    final assertion = (a['assertion'] ?? '').toString();
    if (assertion.isEmpty) throw ApiException('no_assertion', 'Could not sign in to deliveries. Try again.', 0);
    final r = await _raw('POST', 'session', body: {'assertion': assertion}, auth: false);
    _token = (r['token'] ?? '').toString();
    final secs = (r['expires_in'] as num?)?.toInt() ?? 43200;
    _tokenUntil = DateTime.now().add(Duration(seconds: secs - 120));
    driver = r['driver'] is Map ? Map<String, dynamic>.from(r['driver'] as Map) : null;
    if (r['reasons'] is Map) reasons = (r['reasons'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    await _store.write(key: 'gfd_token', value: _token);
    await _store.write(key: 'gfd_until', value: _tokenUntil!.millisecondsSinceEpoch.toString());
  }

  Future<void> signOut() async {
    await setShift(false).catchError((_) {});
    _token = null;
    _tokenUntil = null;
    driver = null;
    deliveries = [];
    await _store.delete(key: 'gfd_token');
    await _store.delete(key: 'gfd_until');
    notifyListeners();
  }

  Future<Map<String, dynamic>> _raw(String method, String path, {Map<String, dynamic>? body, bool auth = true}) async {
    final uri = Uri.parse('${Brand.crmUrl}/$path');
    final headers = {'Accept': 'application/json', 'Content-Type': 'application/json', if (auth && _token != null) 'Authorization': 'Bearer $_token'};
    late http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: headers).timeout(const Duration(seconds: 20))
          : await http.post(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw ApiException('offline', 'No connection. Your changes are saved and will be sent when you are back online.', 0);
    }
    return _decode(r, auth);
  }

  Map<String, dynamic> _decode(http.Response r, bool auth) {
    Map<String, dynamic> d = {};
    try { d = Map<String, dynamic>.from(jsonDecode(r.body) as Map); } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return d;
    if (r.statusCode == 401 && auth) { _token = null; _tokenUntil = null; _store.delete(key: 'gfd_until'); }
    throw ApiException((d['error'] ?? 'error').toString(), (d['message'] ?? 'Something went wrong. Please try again.').toString(), r.statusCode, d);
  }

  /// A signed-in call to the CRM; signs in again once if the CRM token has ended.
  Future<Map<String, dynamic>> _call(String method, String path, {Map<String, dynamic>? body}) async {
    await _ensureSession();
    try {
      return await _raw(method, path, body: body);
    } on ApiException catch (e) {
      if (e.status != 401) rethrow;
      await _ensureSession();
      return _raw(method, path, body: body);
    }
  }

  // ── deliveries ──────────────────────────────────────────────────────────────

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      final r = await _call('GET', 'deliveries');
      day = (r['day'] ?? '').toString();
      deliveries = ((r['deliveries'] ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (r['reasons'] is Map) reasons = (r['reasons'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      error = null;
      loadedAt = DateTime.now();
      unawaited(_cache());
    } on ApiException catch (e) {
      error = e.message;
      if (deliveries.isEmpty) await _loadCache();
    } finally {
      loading = false;
      notifyListeners();
    }
    unawaited(flush());
  }

  Future<File> _file(String name) async => File('${(await getApplicationSupportDirectory()).path}/$name');

  Future<void> _cache() async {
    try { await (await _file('gfd_deliveries.json')).writeAsString(jsonEncode({'day': day, 'deliveries': deliveries})); } catch (_) {}
  }

  Future<void> _loadCache() async {
    try {
      final m = jsonDecode(await (await _file('gfd_deliveries.json')).readAsString()) as Map;
      day = (m['day'] ?? '').toString();
      deliveries = ((m['deliveries'] ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {}
  }

  /// Scan a package label. Returns the CRM's answer ({delivery_id, label, order_no, order_complete}).
  Future<Map<String, dynamic>> scan(String qr) async {
    final r = await _call('POST', 'scan', body: {'qr': qr, 'client_event_id': _newId()});
    unawaited(refresh());
    return r;
  }

  Future<void> undoScan(String packageId) async {
    await _call('POST', 'scan/undo', body: {'package_id': packageId, 'client_event_id': _newId()});
    unawaited(refresh());
  }

  // ── outcomes (queued) ──────────────────────────────────────────────────────

  final List<Map<String, dynamic>> _queue = [];
  bool _queueLoaded = false;
  bool _flushing = false;
  int get pending => _queue.length;

  Future<void> _loadQueue() async {
    if (_queueLoaded) return;
    _queueLoaded = true;
    try {
      final l = jsonDecode(await (await _file('gfd_queue.json')).readAsString()) as List;
      _queue.addAll(l.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {}
  }

  Future<void> _saveQueue() async {
    try { await (await _file('gfd_queue.json')).writeAsString(jsonEncode(_queue)); } catch (_) {}
  }

  /// Record an outcome for a delivery. Photo/signature files (already on the phone) follow the
  /// status in the same order, as the CRM attaches them to the latest outcome.
  Future<void> report(String deliveryId, Map<String, dynamic> status, {String? photoPath, String? signaturePath}) async {
    await _loadQueue();
    Position? p;
    try { p = await Geolocator.getLastKnownPosition(); } catch (_) {}
    final at = DateTime.now().toUtc().toIso8601String();
    _queue.add({'kind': 'status', 'delivery_id': deliveryId, 'body': {...status, 'at': at, if (p != null) 'lat': p.latitude, if (p != null) 'lng': p.longitude, 'client_event_id': _newId()}});
    if (photoPath != null) _queue.add({'kind': 'photo', 'delivery_id': deliveryId, 'path': await _keep(photoPath, 'jpg'), 'client_event_id': _newId()});
    if (signaturePath != null) _queue.add({'kind': 'signature', 'delivery_id': deliveryId, 'path': await _keep(signaturePath, 'png'), 'client_event_id': _newId()});
    await _saveQueue();
    // Show it straight away in the list.
    final i = deliveries.indexWhere((d) => d['delivery_id'].toString() == deliveryId);
    if (i >= 0) { deliveries[i] = {...deliveries[i], 'status': status['status'], 'status_label': _labelFor(status['status'].toString()), '_pending': true}; }
    notifyListeners();
    unawaited(flush());
  }

  String _labelFor(String s) => switch (s) {
        'delivered' => 'Delivered', 'not_delivered' => 'Not delivered', 'rescheduled' => 'Rescheduled', 'returned_to_shop' => 'Returned to shop', _ => s,
      };

  /// Copy a picked/captured file into app storage so the upload survives a restart.
  Future<String> _keep(String path, String ext) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/gfd_files');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = '${dir.path}/${_newId()}.$ext';
    await File(path).copy(dest);
    return dest;
  }

  /// Send queued outcomes in order. Stops at the first network failure (tries again later);
  /// a rejected item (4xx) is dropped with a note in the log so it can't block the rest.
  Future<void> flush() async {
    await _loadQueue();
    if (_flushing || _queue.isEmpty) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.first;
        try {
          final id = item['delivery_id'];
          if (item['kind'] == 'status') {
            await _call('POST', 'deliveries/$id/status', body: Map<String, dynamic>.from(item['body'] as Map));
          } else {
            await _upload('deliveries/$id/${item['kind']}', item['kind'].toString(), item['path'].toString(), item['client_event_id'].toString());
            try { File(item['path'].toString()).deleteSync(); } catch (_) {}
          }
        } on ApiException catch (e) {
          if (e.status == 0 || e.status >= 500 || e.status == 429) break; // offline / server trouble: later
          Diag.log('driver', 'outcome rejected (${e.status} ${e.code}): ${e.message}');
          lastRejected = e.message;
        }
        _queue.removeAt(0);
        await _saveQueue();
      }
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  String? lastRejected;

  Future<void> _upload(String path, String field, String filePath, String eventId) async {
    await _ensureSession();
    final req = http.MultipartRequest('POST', Uri.parse('${Brand.crmUrl}/$path'));
    req.headers.addAll({'Accept': 'application/json', 'Authorization': 'Bearer $_token'});
    req.fields['client_event_id'] = eventId;
    req.files.add(await http.MultipartFile.fromPath(field, filePath));
    late http.Response r;
    try {
      r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 90)));
    } catch (_) {
      throw ApiException('offline', 'No connection.', 0);
    }
    _decode(r, true);
  }

  // ── shift + location ────────────────────────────────────────────────────────

  Future<void> setShift(bool on) async {
    await _call('POST', 'shift', body: {'on': on});
    onShift = on;
    if (on) { await _startGps(); } else { await _stopGps(); }
    notifyListeners();
  }

  Future<void> _startGps() async {
    if (_gps != null) return;
    if (!await Geolocator.isLocationServiceEnabled()) { shiftProblem = 'Location is switched off on this phone.'; return; }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) { shiftProblem = 'Allow location so the shop can see deliveries on the map.'; return; }
    shiftProblem = null;
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high, distanceFilter: 100, intervalDuration: const Duration(seconds: 60),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'On shift', notificationText: 'Sharing your location with the shop while you are on shift.',
        notificationIcon: AndroidResource(name: 'ic_stat_wocom', defType: 'drawable'), enableWakeLock: false, setOngoing: true,
      ),
    );
    _gps = Geolocator.getPositionStream(locationSettings: settings).listen((p) {
      _points.add({'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy, 'at': p.timestamp.toUtc().toIso8601String()});
      if (_points.length > 300) _points.removeRange(0, _points.length - 300);
      if (DateTime.now().difference(_pointsSentAt) > const Duration(seconds: 55)) unawaited(_sendPoints());
    }, onError: (e) => Diag.log('driver', 'gps: $e'));
  }

  Future<void> _sendPoints() async {
    if (_points.isEmpty) return;
    _pointsSentAt = DateTime.now();
    final batch = List<Map<String, dynamic>>.from(_points);
    try {
      await _call('POST', 'location', body: {'points': batch});
      _points.removeRange(0, batch.length.clamp(0, _points.length));
    } on ApiException catch (e) {
      if (e.code == 'off_shift') { onShift = false; await _stopGps(); notifyListeners(); }
    }
  }

  Future<void> _stopGps() async {
    await _gps?.cancel();
    _gps = null;
    _points.clear();
  }
}
