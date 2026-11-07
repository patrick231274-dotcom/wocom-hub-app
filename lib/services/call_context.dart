import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// "Who's calling" (WE App): Tech Hub pushes the caller's client, reason and open tickets while the
/// phone rings. Kept in secure storage too, so a push that woke the phone (background isolate) still
/// reaches the call screen. Matched to the call by the caller's number and time.
class CallContext extends ChangeNotifier {
  CallContext._();
  static final CallContext instance = CallContext._();
  static const _key = 'we_call_ctx';
  static const _store = FlutterSecureStorage();

  Map<String, dynamic>? _ctx;
  Map<String, dynamic>? summary;

  static Future<void> save(Map<String, dynamic> data) async {
    final d = {...data, 'received_at': DateTime.now().toIso8601String()};
    try { await _store.write(key: _key, value: jsonEncode(d)); } catch (_) {}
    instance._ctx = d;
    instance.notifyListeners();
  }

  void setSummary(Map<String, dynamic> d) { summary = d; notifyListeners(); }

  Future<void> reload() async {
    try {
      final s = await _store.read(key: _key);
      if (s != null) { _ctx = Map<String, dynamic>.from(jsonDecode(s) as Map); notifyListeners(); }
    } catch (_) {}
  }

  /// Stored context (from any isolate) if fresh and for this number.
  static Future<Map<String, dynamic>?> stored(String number) async {
    await instance.reload();
    return instance.forCall(number);
  }

  /// Name and second line for the native lock-screen ringer, which only has two text lines.
  static (String, String) ringerText(Map<String, dynamic> c, String number) {
    String g(String k) => (c[k] ?? '').toString().trim();
    final name = g('caller_name').isNotEmpty ? g('caller_name') : (g('company').isNotEmpty ? g('company') : number);
    final dept = g('department');
    final reason = g('reason');
    final short = g('reason_short');
    // First line (all a notification shows): "Calling <department> · <headline>". The lock-screen
    // ringer in the WE App build wraps over several lines, so the whole reason follows underneath.
    final head = dept.isNotEmpty ? 'Calling $dept' : '';
    final first = [head, short.isNotEmpty ? short : (reason.length <= 42 ? reason : '')].where((x) => x.isNotEmpty).join(' · ');
    final firstLine = first.isNotEmpty ? first : (g('company').isNotEmpty && g('company') != name ? g('company') : 'Incoming call');
    var line = firstLine;
    if (reason.isNotEmpty && reason != short && reason != firstLine) line = '$firstLine\n$reason';
    if (line.length > 400) line = '${line.substring(0, 397)}…';
    return (name, line);
  }

  static String _tail(String n) { final d = n.replaceAll(RegExp(r'\D'), ''); return d.length > 7 ? d.substring(d.length - 7) : d; }

  /// Context for the call on screen, if fresh (≤3 min) and the number matches.
  Map<String, dynamic>? forCall(String remoteNumber) {
    final c = _ctx;
    if (c == null) return null;
    final at = DateTime.tryParse((c['received_at'] ?? '').toString());
    if (at == null || DateTime.now().difference(at) > const Duration(minutes: 3)) return null;
    final want = _tail(remoteNumber), got = _tail((c['caller_number'] ?? '').toString());
    // Numbers can differ when the AI receptionist transfers; a very fresh context still belongs to this call.
    if (want.isNotEmpty && got.isNotEmpty && want != got && DateTime.now().difference(at) > const Duration(seconds: 45)) return null;
    return c;
  }
}
