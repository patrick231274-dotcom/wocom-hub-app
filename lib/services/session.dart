import 'dart:math';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'diag.dart';

const pushBaseUrl = 'https://push.wocomenterprise.com/api/v1';

/// Who is signed in on this phone. The device token lives in the phone's
/// encrypted storage (Android Keystore / iOS Keychain), never in plain files.
class Session extends ChangeNotifier {
  Session._();
  static final Session instance = Session._();

  final api = PushApi(pushBaseUrl);
  final _store = const FlutterSecureStorage(); // encrypted by default (Android Keystore / iOS Keychain)

  String? _deviceUuid;

  /// One UUID per install. The SIP registration is keyed on it (Call-ID and contact), so a new
  /// copy of the app replaces this phone's registration instead of adding a second one, and
  /// whichever copy registered last is the only one the switch rings.
  Future<String> deviceUuid() async {
    if (_deviceUuid != null) return _deviceUuid!;
    String? v;
    try { v = await _store.read(key: 'device_uuid'); } catch (_) {}
    if (v == null || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(v)) {
      final r = Random.secure();
      final b = List<int>.generate(16, (_) => r.nextInt(256));
      b[6] = (b[6] & 0x0f) | 0x40; // version 4
      b[8] = (b[8] & 0x3f) | 0x80; // variant
      final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      v = '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      try { await _store.write(key: 'device_uuid', value: v); } catch (_) {}
    }
    _deviceUuid = v;
    return v;
  }

  Map<String, dynamic>? user;
  bool ready = false;
  bool welcomed = true;

  bool get signedIn => api.token != null;
  String get name => (user?['name'] ?? '').toString();
  String get company => (user?['company'] ?? '').toString();
  String get mobile => (user?['mobile'] ?? '').toString();
  bool get hasAccount => (user?['id'] ?? user?['hub_user_id']) != null;

  /// Save the mobile number on my Hub profile (used for activation codes by phone call).
  Future<String?> saveMobile(String mobile) async {
    try {
      final r = await api.post('profile/mobile', {'mobile': mobile});
      user?['mobile'] = (r['mobile'] ?? '').toString();
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
  List<dynamic> get extensions => (user?['extensions'] as List?) ?? const [];

  /// Re-read the profile (role, name, mobile) without touching the stored token: called when
  /// the app comes back to the front so a role change on the Hub shows without a restart.
  Future<void> refreshUser() async {
    if (api.token == null) return;
    try {
      final u = (await api.me())['user'] as Map<String, dynamic>?;
      if (u != null && u.toString() != user.toString()) { user = u; notifyListeners(); }
    } catch (_) {}
  }

  Future<void> load() async {
    welcomed = (await _store.read(key: 'welcomed')) == '1';
    api.token = await _store.read(key: 'device_token');
    if (api.token != null) {
      try {
        user = (await api.me())['user'] as Map<String, dynamic>?;
      } on ApiException catch (e) {
        if (e.signedOut) await _clear();
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<void> markWelcomed() async {
    welcomed = true;
    await _store.write(key: 'welcomed', value: '1');
    notifyListeners();
  }

  Future<void> signedInWith(Map<String, dynamic> result) async {
    api.token = result['token'] as String;
    final u = result['user'];
    user = u is Map ? Map<String, dynamic>.from(u) : null;
    // Save the sign-in, but never let a Keychain/Keystore hiccup strand the person on the
    // sign-in screen: the server has already spent their one-time code.
    try {
      await _store.write(key: 'device_token', value: api.token);
    } catch (e) {
      Diag.log('session', 'saving sign-in failed, retrying: $e');
      try {
        await _store.delete(key: 'device_token');
        await _store.write(key: 'device_token', value: api.token);
      } catch (e2) {
        Diag.log('session', 'saving sign-in failed again (signed in for this run only): $e2');
      }
    }
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await api.logout();
    } catch (_) {}
    await _clear();
    notifyListeners();
  }

  /// Called when the server says this phone was signed out (from the Hub, or a password change).
  Future<void> forceSignedOut() async {
    await _clear();
    notifyListeners();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    await _store.delete(key: 'device_token');
  }

  /// What the server records about this phone.
  static Future<Map<String, String>> deviceInfo() async {
    final pkg = await PackageInfo.fromPlatform();
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return {
        'platform': 'android',
        'name': '${a.manufacturer} ${a.model}'.trim(),
        'model': a.model,
        'os_version': 'Android ${a.version.release}',
        'app_version': pkg.version,
      };
    }
    final i = await info.iosInfo;
    return {
      'platform': 'ios',
      'name': i.name,
      'model': i.utsname.machine,
      'os_version': 'iOS ${i.systemVersion}',
      'app_version': pkg.version,
    };
  }
}
