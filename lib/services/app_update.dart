import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../brand.dart';
import '../theme.dart';
import 'diag.dart';

/// In-app updates: WOCOM publishes downloads/version.json next to the APK; the app compares the
/// build number, offers the update, downloads it and hands it to Android's installer.
/// A `min_build` above the running build makes the update required (the prompt can't be dismissed).
class AppUpdate {
  AppUpdate._();
  static final AppUpdate instance = AppUpdate._();

  static const versionUrl = Brand.updateUrl;
  static const _ch = MethodChannel('wocom/app');

  DateTime? _lastCheck;
  int _snoozedBuild = 0;
  bool _showing = false;

  /// Fetch version.json. Null if unreachable.
  Future<Map<String, dynamic>?> fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$versionUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'));
      final res = await req.close();
      if (res.statusCode != 200) return null;
      return jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    } catch (e) {
      Diag.log('update', 'version check failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// The newer version on offer, or null when this build is current (or the check failed).
  Future<Map<String, dynamic>?> newer() async {
    if (Brand.playStore || !Platform.isAndroid) return null; // Play / App Store deliver updates
    final info = await fetch();
    if (info == null) return null;
    final current = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    return ((info['build'] as num?)?.toInt() ?? 0) > current ? info : null;
  }

  /// Check for a newer build and offer it. Returns true if an update was offered.
  /// Checks at most every 30 minutes unless [force] (a push from WOCOM forces one when a version ships).
  Future<bool> check(BuildContext context, {bool force = false}) async {
    if (Brand.playStore || !Platform.isAndroid || _showing) return false;
    if (await takePending()) force = true; // a version shipped while the app was asleep
    if (!force && _lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(minutes: 30)) return false;
    _lastCheck = DateTime.now();
    final info = await fetch();
    if (info == null) return false;
    final pkg = await PackageInfo.fromPlatform();
    final current = int.tryParse(pkg.buildNumber) ?? 0;
    final latest = (info['build'] as num?)?.toInt() ?? 0;
    final minBuild = (info['min_build'] as num?)?.toInt() ?? 0;
    final required = current < minBuild;
    if (latest <= current) return false;
    if (!required && !force && (_snoozedBuild == latest || await _snoozed(latest))) return false;
    Diag.log('update', 'v${info['version']} ($latest) available, running ${pkg.version} ($current)${required ? ', required' : ''}');
    if (!context.mounted) return false;
    _showing = true;
    bool? installing;
    try {
      installing = await showDialog<bool>(
        context: context,
        barrierDismissible: !required,
        builder: (_) => PopScope(canPop: !required, child: _UpdateDialog(info: info, current: pkg.version, required: required)),
      );
    } finally {
      _showing = false;
    }
    _snoozedBuild = latest;
    if (installing != true) await _snooze(latest); // "Later": stay quiet about this build for a day
    return true;
  }

  /// A push said a version shipped while the app was asleep: remember it so the next open offers it at once.
  static Future<void> markPending() async {
    if (Brand.playStore) return;
    try { await File('${(await getApplicationSupportDirectory()).path}/update-pending').writeAsString('1'); } catch (_) {}
  }

  static Future<bool> takePending() async {
    try {
      final f = File('${(await getApplicationSupportDirectory()).path}/update-pending');
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<File> _snoozeFile() async => File('${(await getApplicationSupportDirectory()).path}/update-snoozed');

  Future<bool> _snoozed(int build) async {
    try {
      final parts = (await (await _snoozeFile()).readAsString()).trim().split(' ');
      final at = DateTime.fromMillisecondsSinceEpoch(int.parse(parts[1]));
      return int.parse(parts[0]) == build && DateTime.now().difference(at) < const Duration(hours: 24);
    } catch (_) {
      return false;
    }
  }

  Future<void> _snooze(int build) async {
    try { await (await _snoozeFile()).writeAsString('$build ${DateTime.now().millisecondsSinceEpoch}'); } catch (_) {}
  }

  /// Download the APK to the cache folder, reporting progress 0..1.
  Future<String> download(String url, void Function(double) onProgress) async {
    final f = File('${(await getTemporaryDirectory()).path}/wocom-hub-update.apk');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) throw 'download failed (${res.statusCode})';
      final total = res.contentLength;
      var got = 0;
      final sink = f.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
      } finally {
        await sink.close();
      }
      Diag.log('update', 'downloaded ${(got / 1048576).toStringAsFixed(1)} MB');
      return f.path;
    } finally {
      client.close();
    }
  }

  /// Hand the file to Android's installer. 'ok' | 'needs_permission' | 'failed'.
  Future<String> install(String path) async {
    try {
      return (await _ch.invokeMethod('installApk', path))?.toString() ?? 'failed';
    } catch (e) {
      Diag.log('update', 'install failed: $e');
      return 'failed';
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.current, required this.required});
  final Map<String, dynamic> info;
  final String current;
  final bool required;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null = not started
  String? _path;
  String? _error;
  bool _needsPermission = false;

  Future<void> _update() async {
    setState(() { _error = null; _needsPermission = false; _progress = _path == null ? 0 : 1; });
    try {
      _path ??= await AppUpdate.instance.download((widget.info['url'] ?? '').toString(), (p) { if (mounted) setState(() => _progress = p); });
      final r = await AppUpdate.instance.install(_path!);
      if (!mounted) return;
      if (r == 'needs_permission') {
        setState(() { _needsPermission = true; _progress = null; });
      } else if (r != 'ok') {
        setState(() { _error = 'Could not open the installer. Download it from push.wocomenterprise.com instead.'; _progress = null; });
      } else if (!widget.required) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      Diag.log('update', 'update failed: $e');
      if (mounted) setState(() { _error = 'Download failed. Check your connection and try again.'; _progress = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = (widget.info['version'] ?? '').toString();
    final busy = _progress != null;
    Widget line(String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 88, child: Text(label, style: const TextStyle(fontSize: 13.5, color: wocomMuted))),
            Text(value, style: TextStyle(fontSize: 15, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: strong ? wocomDeep : wocomInk)),
          ]),
        );
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: const Text('New update available', style: TextStyle(fontSize: 18)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        line('Current', 'v${widget.current}'),
        line('New', 'v$v', strong: true),
        if (widget.required) ...[
          const SizedBox(height: 8),
          const Text('Needed to keep receiving calls.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
        ],
        if (busy) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(value: _progress! >= 1 ? null : _progress, minHeight: 5, borderRadius: BorderRadius.circular(3)),
          const SizedBox(height: 6),
          Text(_progress! >= 1 ? 'Opening the installer…' : 'Downloading… ${(_progress! * 100).round()}%', style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
        ],
        if (_needsPermission) ...[
          const SizedBox(height: 8),
          const Text('Allow ${Brand.name} to install updates on the screen that opened, then tap Install.', style: TextStyle(fontSize: 13, height: 1.35, color: Color(0xFFB45309))),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(fontSize: 13, height: 1.35, color: Color(0xFFB91C1C))),
        ],
      ]),
      actions: [
        if (!widget.required) TextButton(onPressed: busy ? null : () => Navigator.of(context).pop(), child: const Text('Later')),
        TextButton(onPressed: busy ? null : _update, child: Text(_path != null ? 'Install' : 'Update')),
      ],
    );
  }
}
