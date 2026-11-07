import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'diag.dart';
import 'session.dart';

/// Can this phone be woken for a call? Reads Android's battery-optimisation and notification
/// state, reports it to WOCOM, and runs the silent wake-up self-test (WOCOM sends a push, the
/// app answers it, so the Hub can show "wake-ups working" or "blocked" per phone).
class DeviceHealth extends ChangeNotifier {
  DeviceHealth._();
  static final DeviceHealth instance = DeviceHealth._();
  static const _ch = MethodChannel('wocom/app');

  /// From Android: battery_unrestricted, power_save, notifications, full_screen, manufacturer, sdk, autostart_hint.
  Map<String, dynamic> health = {};
  /// From WOCOM: wake_status (ok|blocked|no_answer|testing|untested), wake_text, wake_tested_at, …
  Map<String, dynamic> wake = {};
  String _reported = '';

  bool get batteryOk => health['battery_unrestricted'] != false;
  bool get notificationsOk => health['notifications'] != false;
  bool get fullScreenOk => health['full_screen'] != false;
  bool get autostartHint => health['autostart_hint'] == true;
  String get manufacturer {
    final m = (health['manufacturer'] ?? '').toString();
    return m.isEmpty ? '' : m[0].toUpperCase() + m.substring(1).toLowerCase();
  }
  String get wakeStatus => (wake['wake_status'] ?? 'untested').toString();
  String get wakeText => (wake['wake_text'] ?? 'Wake-up not tested yet').toString();
  /// Something that can stop calls from ringing when the phone is asleep.
  bool get hasIssue => !batteryOk || !notificationsOk || !fullScreenOk || wakeStatus == 'blocked';

  /// Re-read Android's state and (if it changed) tell WOCOM.
  Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final m = await _ch.invokeMethod('health');
      health = Map<String, dynamic>.from(m as Map);
    } catch (e) {
      Diag.log('health', 'read failed: $e');
    }
    Diag.log('health', 'battery_unrestricted=${health['battery_unrestricted']} notifications=${health['notifications']} full_screen=${health['full_screen']} power_save=${health['power_save']} ${health['manufacturer']} sdk=${health['sdk']}');
    notifyListeners();
    if (!Session.instance.signedIn || health.isEmpty) return;
    final body = Map<String, dynamic>.from(health)..remove('model');
    final key = body.toString();
    if (key == _reported) return;
    try {
      wake = await Session.instance.api.post('device/health', body);
      _reported = key;
      notifyListeners();
    } on ApiException catch (e) {
      Diag.log('health', 'report failed: ${e.message}');
    } catch (e) {
      Diag.log('health', 'report failed: $e');
    }
  }

  /// Ask WOCOM for the latest wake-up verdict.
  Future<void> loadWake() async {
    if (!Session.instance.signedIn) return;
    try {
      wake = await Session.instance.api.get('device/wake-test');
      notifyListeners();
    } catch (_) {}
  }

  /// Ask WOCOM to send a silent wake-up. With [delay] it goes out within about a minute of
  /// then, so the phone can be locked first. Returns an error message, or null.
  Future<String?> requestWakeTest({int delay = 0}) async {
    try {
      final r = await Session.instance.api.post('device/wake-test', {'delay': delay});
      Diag.log('health', 'wake test requested (delay ${delay}s): ${r['scheduled'] == true ? 'scheduled' : 'sent'}');
      wake = {...wake, 'wake_status': 'testing', 'wake_text': 'Wake-up test in progress'};
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not start the test: $e';
    }
  }

  /// A wake-up test arrived (foreground or background): tell WOCOM, with how the app was found.
  static Future<void> ack(String nonce, String state) async {
    if (nonce.isEmpty) return;
    try {
      if (!Session.instance.signedIn) await Session.instance.load();
      final r = await Session.instance.api.post('device/wake-test/ack', {'nonce': nonce, 'state': state});
      Diag.log('health', 'wake test answered ($state): ${r['wake_text'] ?? r['error'] ?? ''}');
      if (state == 'open') {
        instance.wake = r;
        instance.notifyListeners();
      }
    } catch (e) {
      Diag.log('health', 'wake test ack failed: $e');
    }
  }

  Future<bool> _open(String method) async {
    try {
      return (await _ch.invokeMethod(method)) == true;
    } catch (e) {
      Diag.log('health', '$method failed: $e');
      return false;
    }
  }

  /// Android's "Allow background use" prompt for this app.
  Future<bool> fixBattery() => _open('requestBatteryUnrestricted');
  Future<bool> openNotificationSettings() => _open('openNotificationSettings');
  Future<bool> openFullScreenSettings() => _open('openFullScreenSettings');
  /// The maker's own auto-start / background page (Xiaomi, Huawei, Oppo, Vivo, Samsung, …).
  Future<bool> openAutoStart() => _open('openAutoStart');
  Future<bool> openAppInfo() => _open('openAppInfo');
}
