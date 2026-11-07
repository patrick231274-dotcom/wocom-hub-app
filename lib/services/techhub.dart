import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../brand.dart';
import 'api.dart';
import 'diag.dart';
import 'session.dart';

/// TechHub mobile API (WOCOM Employee App). The phone talks to TechHub directly with the
/// engineer's own per-device token; nothing goes through the WOCOM Hub platform.
class TechHub extends ChangeNotifier {
  TechHub._();
  static final TechHub instance = TechHub._();

  final _store = const FlutterSecureStorage();
  String? token;
  Map<String, dynamic>? engineer;
  bool ready = false;
  bool welcomed = false;

  /// The last person who signed in on this phone. Kept through sign-out and only replaced when a
  /// different person signs in successfully (owner's rule), so the phone stays tied to someone.
  Map<String, dynamic>? lastEngineer;

  bool get signedIn => token != null;
  bool get onDuty => engineer?['on_duty'] == true;
  bool get isLead => engineer?['is_team_lead'] == true;
  String get name => (engineer?['name'] ?? '').toString();

  /// Bumped when a ticket alert arrives so open screens reload.
  final changes = ValueNotifier<int>(0);

  Future<void> load() async {
    try {
      welcomed = (await _store.read(key: 'we_welcomed')) == '1';
      final last = await _store.read(key: 'techhub_last_engineer');
      if (last != null) lastEngineer = Map<String, dynamic>.from(jsonDecode(last) as Map);
      token = await _store.read(key: 'techhub_token');
      final e = await _store.read(key: 'techhub_engineer');
      if (e != null) engineer = Map<String, dynamic>.from(jsonDecode(e) as Map);
    } catch (_) {}
    ready = true;
    notifyListeners();
  }

  /// Re-read GET me (duty, sharing, unread announcements) and merge it into the cached profile.
  Future<void> refreshMe() async {
    if (token == null) return;
    final r = await _send('GET', 'me');
    final m = r['engineer'] is Map ? Map<String, dynamic>.from(r['engineer'] as Map) : (r['user'] is Map ? Map<String, dynamic>.from(r['user'] as Map) : Map<String, dynamic>.from(r));
    // Never let a refresh change who we are: keep the signed-in id.
    final keepId = engineer?['id'];
    engineer = {...?engineer, ...m, if (keepId != null) 'id': keepId, for (final k in ['announcements_unread', 'sharing', 'location_last_at', 'on_duty']) if (r.containsKey(k)) k: r[k]};
    notifyListeners();
  }

  Future<void> markWelcomed() async {
    welcomed = true;
    try { await _store.write(key: 'we_welcomed', value: '1'); } catch (_) {}
    notifyListeners();
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-App-Version': PushApi.appVersion,
        'X-App-Brand': Brand.key,
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(String method, String path, {Map<String, dynamic>? body, Map<String, String>? query}) async {
    final uri = Uri.parse('${Brand.techhubUrl}/$path').replace(queryParameters: (query == null || query.isEmpty) ? null : query);
    late http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: _headers).timeout(const Duration(seconds: 20))
          : method == 'DELETE'
              ? await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 20))
              : await http.post(uri, headers: _headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 20));
    } catch (e) {
      Diag.log('techhub', '$method $path failed: $e');
      throw ApiException('offline', "Can't reach Tech Hub. Check your internet connection and try again.", 0);
    }
    return _decode(r, path);
  }

  Map<String, dynamic> _decode(http.Response r, String path) {
    Map<String, dynamic> data = {};
    try { data = Map<String, dynamic>.from(jsonDecode(r.body) as Map); } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) {
      // Tech Hub wraps payloads as {status, data}; keep the outer object too for list keys.
      if (data['data'] is Map) {
        final inner = Map<String, dynamic>.from(data['data'] as Map);
        inner['_raw'] = data;
        return inner;
      }
      return data;
    }
    if (r.statusCode == 401 && token != null && !path.startsWith('auth/')) { _clear(); }
    throw ApiException((data['error'] ?? 'error').toString(), (data['message'] ?? 'Tech Hub could not do that. Please try again.').toString(), r.statusCode);
  }

  // ── sign-in ───────────────────────────────────────────────────────────────

  Future<String> start(String email) async {
    final r = await _send('POST', 'auth/start', body: {'email': email.trim().toLowerCase()});
    return (r['challenge_id'] ?? '').toString();
  }

  Future<void> verify(String challengeId, String code) async {
    final dev = await Session.deviceInfo();
    final r = await _send('POST', 'auth/verify', body: {
      'challenge_id': challengeId, 'code': code.trim(),
      'device': {'id': await Session.instance.deviceUuid(), 'name': dev['name'] ?? 'Android phone', 'platform': Platform.operatingSystem, 'app_version': PushApi.appVersion},
    });
    token = (r['token'] ?? '').toString();
    engineer = r['engineer'] is Map ? Map<String, dynamic>.from(r['engineer'] as Map) : {};
    await _store.write(key: 'techhub_token', value: token);
    await _store.write(key: 'techhub_engineer', value: jsonEncode(engineer));
    // Only a successful sign-in replaces the remembered user.
    lastEngineer = {...?engineer, 'signed_in_at': DateTime.now().toUtc().toIso8601String()};
    await _store.write(key: 'techhub_last_engineer', value: jsonEncode(lastEngineer));
    notifyListeners();
    registerPushToken();
  }

  Future<void> signOut() async {
    try { if (token != null) await _send('POST', 'auth/logout'); } catch (_) {}
    await _clear();
  }

  Future<void> _clear() async {
    token = null; engineer = null;
    try { await _store.delete(key: 'techhub_token'); await _store.delete(key: 'techhub_engineer'); } catch (_) {}
    notifyListeners();
  }

  /// A phone signed out from Tech Hub's Mobile devices page (push type token_revoked).
  Future<void> revoked() => _clear();

  // ── duty ──────────────────────────────────────────────────────────────────

  Future<void> setDuty(bool on) async {
    final r = await _send('POST', 'me/duty', body: {'on_duty': on});
    engineer = {...?engineer, 'on_duty': r['on_duty'] ?? on};
    try { await _store.write(key: 'techhub_engineer', value: jsonEncode(engineer)); } catch (_) {}
    notifyListeners();
  }

  // ── push ──────────────────────────────────────────────────────────────────

  String? _pushToken;
  Future<void> registerPushToken([String? fcm]) async {
    if (fcm != null) _pushToken = fcm;
    if (token == null || _pushToken == null) return;
    registerDevice();
    try { await _send('POST', 'device/push-token', body: {'fcm_token': _pushToken, 'platform': Platform.operatingSystem, 'app_version': PushApi.appVersion}); }
    catch (e) { Diag.log('techhub', 'push token: $e'); }
  }

  // ── office calls (workspace PBX, through the push server) ─────────────────

  static const _pushWs = 'https://push.wocomenterprise.com/api/ws/v1';

  /// Tell the push server this phone belongs to the signed-in engineer, so the workspace PBX
  /// can wake it for calls to their extension. Safe to call often.
  Future<String?> registerDevice() async {
    if (token == null) return null;
    try {
      final dev = await Session.deviceInfo();
      final r = await http.post(Uri.parse('$_pushWs/device'), headers: _headers, body: jsonEncode({
        'device_id': await Session.instance.deviceUuid(), 'fcm_token': _pushToken, 'app_version': PushApi.appVersion, 'device_name': dev['name'] ?? '',
      })).timeout(const Duration(seconds: 15));
      final d = jsonDecode(r.body) as Map;
      if (r.statusCode == 200) { calling = true; callingNote = null; notifyListeners(); return d['extension']?.toString(); }
      calling = false; callingNote = (d['message'] ?? 'Office calling is not available.').toString(); notifyListeners();
    } catch (e) {
      Diag.log('techhub', 'device register: $e');
    }
    return null;
  }

  /// Support visibility: the line's state and the diagnostics log go to the push server.
  String _lastLine = '';
  Future<void> reportLine(String status, String text) async {
    if (token == null || '$status|$text' == _lastLine) return;
    _lastLine = '$status|$text';
    try {
      await http.post(Uri.parse('$_pushWs/status'), headers: _headers, body: jsonEncode({
        'device_id': await Session.instance.deviceUuid(), 'line_status': status, 'line_text': text, 'app_version': PushApi.appVersion,
      })).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  Future<void> sendDiagnostics(Map<String, dynamic> body) async {
    late http.Response r;
    try {
      r = await http.post(Uri.parse('$_pushWs/diagnostics'), headers: _headers, body: jsonEncode({...body, 'device_id': await Session.instance.deviceUuid()})).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw ApiException('offline', "Couldn't send diagnostics. Check your connection.", 0);
    }
    if (r.statusCode != 200) {
      String msg = 'Diagnostics could not be sent.';
      try { msg = (jsonDecode(r.body) as Map)['message']?.toString() ?? msg; } catch (_) {}
      throw ApiException('error', msg, r.statusCode);
    }
  }

  /// Whether this engineer has an office extension the app can use, and if not, why.
  bool calling = false;
  String? callingNote;

  /// SIP settings for the phone line, same shape the Hub build uses.
  Future<Map<String, dynamic>> callingConfig() async {
    late http.Response r;
    try {
      r = await http.get(Uri.parse('$_pushWs/calling/config'), headers: {..._headers, 'X-Device-Id': await Session.instance.deviceUuid()}).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw ApiException('offline', "Can't reach the office phone system. Check your connection.", 0);
    }
    Map<String, dynamic> d = {};
    try { d = Map<String, dynamic>.from(jsonDecode(r.body) as Map); } catch (_) {}
    if (r.statusCode == 200) return d;
    if (r.statusCode == 401) await _clear();
    throw ApiException((d['error'] ?? 'error').toString(), (d['message'] ?? 'Office calling is not available.').toString(), r.statusCode);
  }

  /// The signed-in engineer's office extension (from Tech Hub), shown in the app.
  String get extension => (engineer?['extension'] ?? '').toString();

  Future<Map<String, dynamic>> _ws(String path) async {
    late http.Response r;
    try { r = await http.get(Uri.parse('$_pushWs/$path'), headers: _headers).timeout(const Duration(seconds: 20)); }
    catch (_) { throw ApiException('offline', "Can't reach the office phone system. Check your connection.", 0); }
    Map<String, dynamic> d = {};
    try { d = Map<String, dynamic>.from(jsonDecode(r.body) as Map); } catch (_) {}
    if (r.statusCode == 200) return d;
    if (r.statusCode == 401) await _clear();
    throw ApiException((d['error'] ?? 'error').toString(), (d['message'] ?? 'Not available yet.').toString(), r.statusCode);
  }

  Future<Map<String, dynamic>> _wsPost(String path, Map<String, dynamic> body) async {
    late http.Response r;
    try { r = await http.post(Uri.parse('$_pushWs/$path'), headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 25)); }
    catch (_) { throw ApiException('offline', "Can't reach the server. Check your connection.", 0); }
    Map<String, dynamic> d = {};
    try { d = Map<String, dynamic>.from(jsonDecode(r.body) as Map); } catch (_) {}
    if (r.statusCode == 200 || r.statusCode == 202) return d;
    if (r.statusCode == 401) await _clear();
    if (r.statusCode == 429) throw ApiException('busy', 'Too many tries. Wait a minute and try again.', 429);
    throw ApiException((d['error'] ?? 'error').toString(), (d['message'] ?? 'Not available yet.').toString(), r.statusCode);
  }

  /// Full "Who's calling" details for a call this person was rung for.
  Future<Map<String, dynamic>> callContextFull(String callId) async {
    final r = await _send('GET', 'calls/${Uri.encodeComponent(callId)}/context');
    return r['context'] is Map ? Map<String, dynamic>.from(r['context'] as Map) : r;
  }

  // ── office door (push server → eWeLink) ───────────────────────────────────

  final doorEvent = ValueNotifier<int>(0);
  Future<Map<String, dynamic>> doorStatus() => _ws('door/status');
  Future<Map<String, dynamic>> doorOpen(Map<String, dynamic> loc) => _wsPost('door/open', loc);
  Future<Map<String, dynamic>> doorDecide(int id, bool approve) => _wsPost('door/requests/$id/decide', {'approve': approve});
  Future<Map<String, dynamic>> doorSetOffice(Map<String, dynamic> loc) => _wsPost('door/office', loc);

  /// Office extensions with their live status (workspace PBX, through the push server).
  Future<List<Map<String, dynamic>>> team() async => ((await _ws('team'))['extensions'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// This engineer's office calls, newest first.
  Future<List<Map<String, dynamic>>> recents() async => ((await _ws('recents'))['calls'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  // ── tickets ───────────────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _list(Map<String, dynamic> r, String key) =>
      ((r[key] ?? r['items'] ?? (r['_raw'] is Map ? (r['_raw'] as Map)[key] : null) ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<List<Map<String, dynamic>>> tickets(String scope) async => _list(await _send('GET', 'tickets', query: {'scope': scope}), 'tickets');
  Future<Map<String, dynamic>> ticket(String number) async {
    final r = await _send('GET', 'tickets/${Uri.encodeComponent(number)}');
    final t = r['ticket'] is Map ? Map<String, dynamic>.from(r['ticket'] as Map) : r;
    if (t['visits'] == null && r['visits'] != null) t['visits'] = r['visits'];
    return t;
  }

  // ── attendance ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> reportAbsence({required String type, required DateTime from, DateTime? to, DateTime? eta, String? note}) =>
      _send('POST', 'me/absence', body: {
        'type': type, 'from': from.toUtc().toIso8601String(), 'to': to?.toUtc().toIso8601String(),
        'eta': eta?.toUtc().toIso8601String(), 'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
      });
  Future<List<Map<String, dynamic>>> myAbsences() async => _list(await _send('GET', 'me/absences'), 'absences');
  Future<void> cancelAbsence(int id) => _send('DELETE', 'me/absences/$id');

  // ── attendance, vacation, office arrival ─────────────────────────────────
  /// '<push type>@<ms>' when a leave_request / leave_decided push arrives.
  final leaveEvent = ValueNotifier<String>('');
  /// '<ticket>|<close_at>|<ms>' when a ticket_idle warning arrives or is tapped.
  final idleEvent = ValueNotifier<String>('');
  String get role => (engineer?['role'] ?? '').toString();
  bool get approvesLeave => role == 'admin' || role == 'profile_admin' || (role.isEmpty && isLead);
  String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  Future<Map<String, dynamic>> myAttendance(int year) => _send('GET', 'me/attendance', query: {'year': '$year'});
  Future<Map<String, dynamic>> requestLeave(DateTime start, DateTime end, String note) => _send('POST', 'me/leave', body: {
        'start_date': _ymd(start), 'end_date': _ymd(end), if (note.trim().isNotEmpty) 'note': note.trim(),
      });
  Future<void> cancelLeave(int id) => _send('DELETE', 'me/leave/$id');
  Future<List<Map<String, dynamic>>> teamLeave(String status) async => _list(await _send('GET', 'team/leave', query: {'status': status}), 'leave');
  Future<void> decideLeave(int id, bool approve, String note) =>
      _send('POST', 'team/leave/$id/${approve ? 'approve' : 'decline'}', body: {if (note.trim().isNotEmpty) 'note': note.trim()});
  Future<Map<String, dynamic>> sendArrival(double lat, double lng, double? accuracy) =>
      _send('POST', 'me/arrival', body: {'lat': lat, 'lng': lng, if (accuracy != null) 'accuracy_m': accuracy.round()});
  /// Pick up work someone else can't do (they reported an absence).
  Future<void> take(String number, {int? visitId}) =>
      _send('POST', visitId == null ? 'tickets/${Uri.encodeComponent(number)}/take' : 'tickets/${Uri.encodeComponent(number)}/visits/$visitId/take');

  /// Mark a site survey or visit on a ticket as done, with what was found.
  Future<Map<String, dynamic>> visitDone(String number, int visitId, String findings) =>
      _send('POST', 'tickets/${Uri.encodeComponent(number)}/visits/$visitId/done', body: {if (findings.trim().isNotEmpty) 'findings': findings.trim()});
  Future<void> accept(String number) => _send('POST', 'tickets/${Uri.encodeComponent(number)}/accept');
  Future<void> update(String number, {String? status, String? comment, String? internalNote, String? resolution}) => _send('POST', 'tickets/${Uri.encodeComponent(number)}/update', body: {
        if (status != null) 'status': status,
        if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
        if (internalNote != null && internalNote.trim().isNotEmpty) 'internal_note': internalNote.trim(),
        if (resolution != null && resolution.trim().isNotEmpty) 'resolution': resolution.trim(),
      });
  Future<void> attach(String number, String filePath) => _upload('tickets/${Uri.encodeComponent(number)}/attachments', filePath, 'file');

  // ── announcements (broadcasts from Tech Hub) ──────────────────────────────

  final announcementsEvent = ValueNotifier<int>(0);
  int get announcementsUnread => (engineer?['announcements_unread'] as num?)?.toInt() ?? 0;
  Future<List<Map<String, dynamic>>> announcements() async {
    final r = await _send('GET', 'announcements');
    return ((r['announcements'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
  Future<void> markAnnouncementRead(int id) async {
    await _send('POST', 'announcements/$id/read');
    final n = announcementsUnread;
    if (n > 0) { engineer = {...?engineer, 'announcements_unread': n - 1}; notifyListeners(); }
  }
  Future<void> dismissAnnouncement(int id) => _send('POST', 'announcements/$id/dismiss');

  // ── live location (while on duty) ─────────────────────────────────────────

  Future<void> sendLocation(List<Map<String, dynamic>> points) =>
      _send('POST', 'me/location', body: points.length == 1 ? points.first : {'points': points});

  // ── team chat ─────────────────────────────────────────────────────────────

  /// Bumped when a chat push arrives (value = conversation id) so open chat screens reload.
  final chatEvent = ValueNotifier<String>('');
  int unread = 0;

  List<Map<String, dynamic>> _rows(dynamic v) => ((v ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<List<Map<String, dynamic>>> chatPeople() async { final r = await _send('GET', 'chat/people'); return _rows(r['people'] ?? (r['_raw'] is Map ? (r['_raw'] as Map)['people'] : null)); }
  Future<List<Map<String, dynamic>>> conversations() async {
    final r = await _send('GET', 'chat/conversations');
    final list = _rows(r['conversations'] ?? (r['_raw'] is Map ? (r['_raw'] as Map)['conversations'] : null));
    final n = list.fold<int>(0, (a, c) => a + ((c['unread'] as num?)?.toInt() ?? 0));
    if (n != unread) { unread = n; notifyListeners(); }
    return list;
  }
  Future<String> openChat(int userId) async => ((await _send('POST', 'chat/open', body: {'user_id': userId}))['conversation_id']).toString();
  Future<Map<String, dynamic>> messages(String id, {int? beforeId}) => _send('GET', 'chat/$id/messages', query: {'limit': '50', if (beforeId != null) 'before_id': '$beforeId'});
  Future<Map<String, dynamic>> sendChat(String id, String text, {String? ticket}) => _send('POST', 'chat/$id/send', body: {'text': text, if (ticket != null) 'ticket_number': ticket});
  /// "I'll take it" on a group message. Returns null, or who already has it.
  Future<String?> claim(String conv, int msgId) async {
    try { await _send('POST', 'chat/$conv/messages/$msgId/claim'); return null; }
    on ApiException catch (e) { if (e.code == 'already_claimed') return 'Someone already has this.'; rethrow; }
  }
  Future<void> deleteMessage(String conv, int msgId) => _send('DELETE', 'chat/$conv/messages/$msgId');
  Future<void> deleteChat(String conv) => _send('DELETE', 'chat/$conv');
  Future<void> clearChat(String conv) => _send('POST', 'chat/$conv/clear');

  /// Tech Hub hands out paths like /api/mobile/v1/…; make them absolute for image loading.
  String absUrl(String u) => u.startsWith('http') ? u : 'https://techhub.wocomenterprise.com${u.startsWith('/') ? '' : '/'}$u';
  Map<String, String> get authHeaders => {if (token != null) 'Authorization': 'Bearer $token', 'Accept': 'application/json'};

  Future<void> chatPhoto(String id, String path) => _upload('chat/$id/attachments', path, 'photo');
  Future<void> markRead(String id, int upTo) async { try { await _send('POST', 'chat/$id/read', body: {'up_to_id': upTo}); } catch (_) {} }

  // ── site surveys ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> surveys() async => _list(await _send('GET', 'surveys', query: {'scope': 'mine'}), 'surveys');
  Future<Map<String, dynamic>> survey(String id) async { final r = await _send('GET', 'surveys/${Uri.encodeComponent(id)}'); return r['survey'] is Map ? Map<String, dynamic>.from(r['survey'] as Map) : r; }
  Future<void> surveyPhoto(String id, String filePath) => _upload('surveys/${Uri.encodeComponent(id)}/photos', filePath, 'photo');
  Future<void> submitSurvey(String id, {required String issues, required String findings, String? installDate}) => _send('POST', 'surveys/${Uri.encodeComponent(id)}/submit', body: {
        'issues_found': issues, 'findings_notes': findings, if (installDate != null && installDate.isNotEmpty) 'recommended_install_date': installDate,
      });

  Future<Map<String, dynamic>> _upload(String path, String filePath, String field, {Map<String, String>? fields}) async {
    final req = http.MultipartRequest('POST', Uri.parse('${Brand.techhubUrl}/$path'));
    req.headers.addAll({..._headers}..remove('Content-Type'));
    if (fields != null) req.fields.addAll(fields);
    req.files.add(await http.MultipartFile.fromPath(field, filePath));
    late http.Response r;
    try { r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 120))); }
    catch (_) { throw ApiException('offline', "Couldn't upload the photo. Check your connection and try again.", 0); }
    if (r.statusCode == 413) throw ApiException('too_large', 'That photo is too large (10 MB max).', 413);
    return _decode(r, path);
  }

  // ── per-location photos on survey/visit tickets ───────────────────────────

  Future<Map<String, dynamic>> visitPhotoUpload(String number, int visitId, String filePath, String caption) =>
      _upload('tickets/${Uri.encodeComponent(number)}/visits/$visitId/photos', filePath, 'file',
          fields: {if (caption.trim().isNotEmpty) 'caption': caption.trim().length > 300 ? caption.trim().substring(0, 300) : caption.trim()});
  Future<void> visitPhotoDelete(String number, int visitId, int photoId) =>
      _send('DELETE', 'tickets/${Uri.encodeComponent(number)}/visits/$visitId/photos/$photoId');

  // ── alerts ────────────────────────────────────────────────────────────────

  static const pushTypes = {'assigned', 'reassigned', 'status', 'due_60', 'due_30', 'due_now', 'overdue', 'survey_due', 'survey_check', 'visit_due', 'visit_check', 'cover_needed', 'absence', 'cover_taken'};

  /// Title and body for a Tech Hub push (its payload carries data, not text).
  static (String, String)? alertText(Map<String, dynamic> d) {
    final type = (d['type'] ?? '').toString();
    if (type == 'chat' && d['claimed'] == 'true') return ('${d['claimed_by_name'] ?? 'Someone'} has this', (d['text'] ?? '').toString());
    if (type == 'chat' && d.containsKey('from_name')) return ((d['from_name'] ?? 'Team chat').toString(), (d['text'] ?? '').toString());
    if (type == 'chat_unclaimed') return ('Still waiting: ${d['from_name'] ?? 'a colleague'}', '${d['text'] ?? ''}\nNobody has taken this yet.');
    if (const {'survey_due', 'survey_check', 'visit_due', 'visit_check'}.contains(type)) {
      final what = type.startsWith('survey') ? 'Site survey' : 'Site visit';
      final place = (d['location_name'] ?? '').toString();
      final n = (d['ticket_number'] ?? '').toString();
      final atRaw = DateTime.tryParse((d['visit_at'] ?? '').toString())?.toLocal();
      final at = atRaw == null ? '' : '${atRaw.hour % 12 == 0 ? 12 : atRaw.hour % 12}:${atRaw.minute.toString().padLeft(2, '0')} ${atRaw.hour < 12 ? 'AM' : 'PM'}';
      final pr = d['priority'] == 'urgent' || d['priority'] == 'high' ? '${d['priority'].toString().toUpperCase()} · ' : '';
      final title = switch ((d['when'] ?? '').toString()) {
        'eve' => '$what tomorrow${at.isNotEmpty ? ' at $at' : ''}',
        'hour' => '$what in about an hour${at.isNotEmpty ? ' ($at)' : ''}',
        'missed' => '$what not marked done',
        _ => type.endsWith('check') ? '$what: please mark it done' : '$what coming up',
      };
      return (title, '$pr${place.isNotEmpty ? '$place · ' : ''}$n');
    }
    if (type == 'cover_needed') {
      final reason = switch ((d['reason'] ?? '').toString()) { 'sick' => 'is out sick', 'late' => 'is running late', 'day_off' => 'is off today', 'vacation' => 'is on vacation', 'emergency' => 'has an emergency', _ => 'is out' };
      return ('Cover needed: ${d['absent_name'] ?? 'a colleague'} $reason', '${d['ticket_number'] ?? ''} · ${d['client_name'] ?? d['subject'] ?? ''}${(d['when'] ?? '').toString().isNotEmpty ? ' · ${d['when']}' : ''}\nTap to take it.');
    }
    if (type == 'cover_taken') return ('${d['taken_by_name'] ?? 'A colleague'} is covering ${d['ticket_number'] ?? 'a job'}', 'Your job has been picked up. Thank you, team!');
    if (type == 'absence') {
      final what = switch ((d['absence_type'] ?? '').toString()) { 'sick' => 'is out sick', 'late' => 'is running late', 'day_off' => 'is taking a day off', 'vacation' => 'is on vacation', 'emergency' => 'has an emergency', _ => 'is out' };
      final n = int.tryParse('${d['affected_count'] ?? 0}') ?? 0;
      return ('${d['absent_name'] ?? 'A tech'} $what', n > 0 ? '$n job${n == 1 ? '' : 's'} need cover.' : 'No jobs affected.');
    }
    if (type == 'ticket_idle') return ((d['title'] ?? 'No client update for 48 h: ${d['ticket_number'] ?? ''}').toString(), (d['body'] ?? 'It closes automatically in 24 h unless you send the client an update. Tap to update.').toString());
    if (type == 'leave_request' || type == 'leave_decided') return ((d['title'] ?? (type == 'leave_request' ? 'Vacation request: ${d['name'] ?? 'a colleague'}' : 'Vacation request ${d['status'] ?? 'decided'}')).toString(), (d['body'] ?? 'Open WE App to see it.').toString());
    if (type == 'call_summary') return ('Call summary: ${(d['caller_name'] ?? '').toString().isNotEmpty ? d['caller_name'] : 'last call'}${(d['company'] ?? '').toString().isNotEmpty ? ' · ${d['company']}' : ''}', (d['summary'] ?? '').toString());
    if (type == 'door_request') return ('Door request: ${d['name'] ?? 'a colleague'}${(d['extension'] ?? '').toString().isNotEmpty ? ' (${d['extension']})' : ''}', 'Wants to open the ${(d['door'] ?? 'office door').toString().toLowerCase()} outside office hours. Open WE App to approve or decline.');
    if (type == 'door_decision') return (d['approved'] == 'true' ? 'Door approved: opening now' : 'Door request declined', d['approved'] == 'true' ? '${d['by'] ?? 'The approver'} approved it.' : '${d['by'] ?? 'The approver'} declined your request.');
    if (type == 'announcement') {
      final k = (d['kind'] ?? '').toString();
      return ('${k == 'alert' ? 'ALERT: ' : ''}${d['title'] ?? 'Announcement'}', (d['body'] ?? '').toString());
    }
    if (!pushTypes.contains(type)) return null;
    final n = (d['ticket_number'] ?? '').toString();
    final subject = (d['subject'] ?? '').toString();
    final client = (d['client_name'] ?? '').toString();
    final pr = (d['priority'] ?? '').toString().toUpperCase();
    final title = switch (type) {
      'assigned' => 'New ticket assigned to you',
      'reassigned' => 'Ticket reassigned',
      'status' => 'Ticket updated',
      'due_60' => 'Due in 1 hour',
      'due_30' => 'Due in 30 minutes',
      'due_now' => 'Due now',
      _ => 'Overdue ticket',
    };
    final body = [if (pr.isNotEmpty) pr, if (client.isNotEmpty) client, if (subject.isNotEmpty) subject, if (n.isNotEmpty) n].join(' · ');
    return (title, body);
  }
}
