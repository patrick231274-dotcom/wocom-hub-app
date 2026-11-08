import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/diag.dart';

/// WOCOM support can ask for this phone's app log, but it is only sent when the user agrees
/// (Apple 5.1.1 / Google user data policy: no collection without the user's knowledge).
class DiagConsent {
  static bool _asking = false;

  static Future<File> _flag() async => File('${(await getApplicationSupportDirectory()).path}/diag-requested');

  /// A support request arrived (app open or asleep): remember it until the user answers.
  static Future<void> mark() async {
    try { await (await _flag()).writeAsString('1'); } catch (_) {}
  }

  /// If WOCOM support asked for the log, ask the user once whether to send it.
  static Future<void> askIfRequested(BuildContext context) async {
    if (_asking) return;
    try {
      final f = await _flag();
      if (!await f.exists()) return;
      _asking = true;
      await f.delete();
    } catch (_) { return; }
    if (!context.mounted) { _asking = false; return; }
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send your app log to WOCOM?'),
        content: const Text(
            'WOCOM support asked for this phone\'s app log to fix a problem. It holds connection details and '
            'recent call times and numbers. It does not include call audio or chat messages.',
            style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    );
    _asking = false;
    if (go == true) {
      Diag.log('diag', 'support request: user agreed to send');
      await Diag.instance.send(note: 'requested by WOCOM support, user agreed');
    } else {
      Diag.log('diag', 'support request: user declined');
    }
  }
}
