import 'dart:convert';

import '../brand.dart';

import 'package:http/http.dart' as http;

/// Talks to the WOCOM push service (push.wocomenterprise.com). Every signed-in
/// request carries the device token issued at sign-in.
class PushApi {
  PushApi(this.baseUrl);

  final String baseUrl;
  String? token;

  /// Set at start-up; the server records which build each phone runs.
  static String appVersion = '';

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (appVersion.isNotEmpty) 'X-App-Version': appVersion,
        'X-App-Brand': Brand.key,
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$baseUrl$path');
    late http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: _headers).timeout(const Duration(seconds: 20))
          : await http.post(uri, headers: _headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw ApiException('offline', "Can't reach WOCOM. Check your internet connection and try again.", 0);
    }
    Map<String, dynamic> data = {};
    try {
      data = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return data;
    throw ApiException(
      (data['error'] ?? 'error').toString(),
      (data['message'] ?? 'Something went wrong. Please try again.').toString(),
      r.statusCode,
    );
  }

  /// A multipart upload (chat files, voice notes). The server caps files at 5 MB.
  Future<Map<String, dynamic>> uploadFile(String path, String filePath, {required String fileName, String? mime}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/$path'));
    req.headers.addAll({..._headers}..remove('Content-Type'));
    if (mime != null) req.fields['mime_type'] = mime;
    req.files.add(await http.MultipartFile.fromPath('file', filePath, filename: fileName));
    late http.Response r;
    try {
      r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 120)));
    } catch (_) {
      throw ApiException('offline', "Couldn't send the file. Check your internet connection and try again.", 0);
    }
    Map<String, dynamic> data = {};
    try { data = jsonDecode(r.body) as Map<String, dynamic>; } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return data;
    final errs = data['errors'] is Map ? (data['errors'] as Map).values.expand((v) => v is List ? v : [v]).join(' ') : '';
    throw ApiException((data['error'] ?? 'error').toString(), (errs.isNotEmpty ? errs : (data['message'] ?? 'Something went wrong. Please try again.')).toString(), r.statusCode);
  }

  /// Hub-backed screens (team, recents, presence, meetings, chat), proxied by the push service.
  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _send('GET', '/$path${query == null || query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}');

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) => _send('POST', '/$path', body);

  Future<Map<String, dynamic>> login(String email, String password, Map<String, String> device) =>
      _send('POST', '/auth/login', {'email': email, 'password': password, 'device': device});

  /// Passwordless activation: who is this (email or mobile) → how can a code reach them.
  Future<Map<String, dynamic>> start(String identifier, Map<String, String> device) =>
      _send('POST', '/auth/start', {'identifier': identifier, 'device': device});

  Future<Map<String, dynamic>> sendCode(String challengeId, String channel) =>
      _send('POST', '/auth/send', {'challenge_id': challengeId, 'channel': channel});

  Future<Map<String, dynamic>> verify(String challengeId, String code) =>
      _send('POST', '/auth/verify', {'challenge_id': challengeId, 'code': code});

  Future<Map<String, dynamic>> resend(String challengeId) => _send('POST', '/auth/resend', {'challenge_id': challengeId});

  Future<Map<String, dynamic>> qr(String code, Map<String, String> device) =>
      _send('POST', '/auth/qr', {'code': code, 'device': device});

  Future<Map<String, dynamic>> me() => _send('GET', '/me');

  Future<Map<String, dynamic>> callingConfig() => _send('GET', '/calling/config');

  Future<void> logout() => _send('POST', '/auth/logout');
}

class ApiException implements Exception {
  ApiException(this.code, this.message, this.status);

  final String code;
  final String message;
  final int status;

  bool get signedOut => status == 401;

  @override
  String toString() => message;
}
