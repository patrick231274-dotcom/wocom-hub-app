import 'dart:collection';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show FlutterError;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'phone.dart';
import 'session.dart';
import 'techhub.dart';
import '../brand.dart';

/// A rolling log of what the app's line, calls, network and push are doing, which the person
/// can send to WOCOM from the menu ("Send diagnostics") so problems can be read, not guessed.
class Diag {
  Diag._();
  static final Diag instance = Diag._();

  final Queue<String> _lines = Queue<String>();
  static const _max = 600;
  File? _file;

  /// Open the on-disk log (kept across restarts, so a call that failed before the app was
  /// reopened is still in the report). Safe to call from the push background isolate too.
  Future<void> init({String tag = 'app'}) async {
    if (_file != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/wocom-diag${tag == 'app' ? '' : '-$tag'}.log');
      if (await _file!.exists()) {
        final old = (await _file!.readAsLines()).where((l) => l.trim().isNotEmpty).toList();
        final keep = old.length > _max ? old.sublist(old.length - _max) : old;
        _lines.addAll(keep);
        if (old.length > _max * 2) await _file!.writeAsString('${keep.join('\n')}\n');
      }
    } catch (e) {
      debugPrint('diag file: $e');
    }
    final d = DateTime.now();
    log('diag', '— $tag started ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} —');
  }

  Future<void> flush() async {}

  static const _iosAudio = MethodChannel('wocom/ios-audio');

  /// iPhone: logs the live audio session (sample rate, IO buffer, input/output latency, mode,
  /// category, route) so call-audio problems such as hiss or a growing delay can be read.
  static Future<void> iosAudioStats(String when) async {
    if (!Platform.isIOS) return;
    try {
      final m = await _iosAudio.invokeMapMethod<String, dynamic>('stats');
      if (m == null) return;
      String ms(Object? v) => v is num ? '${(v * 1000).toStringAsFixed(1)}ms' : '?';
      log('audio', '$when: ${m['sampleRate']}Hz (pref ${m['preferredSampleRate']}) io=${ms(m['ioBufferDuration'])} '
          'in=${ms(m['inputLatency'])} out=${ms(m['outputLatency'])} mode=${m['mode']} cat=${m['category']} '
          'route in=${m['inputs']} out=${m['outputs']}');
    } catch (e) {
      log('audio', '$when: stats failed: $e');
    }
  }

  static void log(String area, String message) {
    final t = DateTime.now();
    final stamp = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 100)}';
    final line = '$stamp [$area] $message';
    debugPrint(line);
    final q = instance._lines;
    q.addLast(line);
    while (q.length > _max) q.removeFirst();
    try { instance._file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true); } catch (_) {}
  }

  /// Route unhandled Dart/Flutter errors into the log, so a crash leaves a trace in the next upload.
  static void captureErrors() {
    FlutterError.onError = (details) {
      log('error', 'flutter: ${details.exceptionAsString()} @ ${details.stack?.toString().split('\n').take(3).join(' | ')}');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      log('error', 'uncaught: $e @ ${st.toString().split('\n').take(3).join(' | ')}');
      return true;
    };
  }

  List<String> get lines => _lines.toList();

  /// Upload the log plus a snapshot of the current state. Returns an error message, or null.
  Future<String?> send({String note = ''}) async {
    final p = Phone.instance;
    Map<String, dynamic> state = {
      'line_status': p.status.name, 'line_text': p.statusText, 'extension': p.extension,
      'in_call': p.call != null, 'call_state': p.callState?.name,
    };
    try {
      state['connectivity'] = (await Connectivity().checkConnectivity()).map((c) => c.name).join(',');
      final pkg = await PackageInfo.fromPlatform();
      state['app_version'] = '${pkg.version}+${pkg.buildNumber}';
      state['device'] = await Session.deviceInfo();
      state['signed_in_as'] = Brand.isEmployee ? TechHub.instance.name : Session.instance.name;
      if (Brand.isEmployee) {
        state['techhub_extension'] = TechHub.instance.extension;
        state['calling'] = TechHub.instance.calling;
        state['calling_note'] = TechHub.instance.callingNote;
        state['on_duty'] = TechHub.instance.onDuty;
      }
    } catch (_) {}
    try {
      await flush();
      // Merge this process's file with the push wake-up process's file, in time order.
      var all = lines;
      try {
        final merged = <String>[];
        for (final name in ['wocom-diag.log', 'wocom-diag-push.log']) {
          if (_file == null) break;
          final f = File('${_file!.parent.path}/$name');
          if (await f.exists()) merged.addAll((await f.readAsLines()).where((l) => RegExp(r'^\d\d:\d\d:\d\d\.\d ').hasMatch(l)));
        }
        if (merged.length >= all.length) {
          merged.sort((a, b) => a.substring(0, 10).compareTo(b.substring(0, 10)));
          all = merged.length > _max ? merged.sublist(merged.length - _max) : merged;
        }
      } catch (_) {}
      final body = {'note': note, 'state': state, 'log': all.join('\n')};
      if (Brand.isEmployee) {
        await TechHub.instance.sendDiagnostics(body);
      } else {
        await Session.instance.api.post('diagnostics', body);
      }
      log('diag', 'diagnostics sent');
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}
