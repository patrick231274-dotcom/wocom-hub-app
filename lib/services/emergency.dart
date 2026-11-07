import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'quick_dials.dart';
import 'session.dart';

/// When an emergency number is dialled, send the phone's position to WOCOM so the location
/// can be seen. Runs alongside the call and never delays or blocks it.
class Emergency {
  static Future<void> report(QuickDial dial) async {
    final body = <String, dynamic>{'dialed': dial.dial, 'service': dial.service};
    try {
      body['device_name'] = (await Session.deviceInfo())['name'];
    } catch (_) {}
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        body['error'] = 'Location permission not granted';
      } else if (!await Geolocator.isLocationServiceEnabled()) {
        body['error'] = 'Location is switched off on the phone';
      } else {
        Position? p;
        try {
          p = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)),
          );
        } catch (_) {
          p = await Geolocator.getLastKnownPosition();
          if (p != null) body['error'] = 'Last known position (no fresh fix)';
        }
        if (p == null) {
          body['error'] = 'No GPS fix within 10 seconds';
        } else {
          body['lat'] = p.latitude;
          body['lng'] = p.longitude;
          body['accuracy_m'] = p.accuracy.round();
        }
      }
    } catch (e) {
      body['error'] = 'Location error: $e';
    }
    try {
      await Session.instance.api.post('emergency', body);
    } on ApiException catch (e) {
      debugPrint('emergency report failed: ${e.message}');
    }
  }

  /// Ask for location up front (right after sign-in), so an emergency call never waits on a prompt.
  /// Before Android's own prompt, say plainly why (Google Play prominent-disclosure rule). Shown once.
  static Future<void> warmUpPermission(BuildContext context) async {
    try {
      if (await Geolocator.checkPermission() != LocationPermission.denied) return;
      final flag = File('${(await getApplicationSupportDirectory()).path}/location-explained');
      if (await flag.exists()) return;
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: const Text('Location for emergency calls'),
          content: const Text(
              'WOCOM HUB uses your location only when you dial an emergency number (119, 110 or 911). '
              'Your position is sent to WOCOM with that call so help can find you. '
              'It is not used at any other time and never in the background.\n\n'
              'This is optional. You can say no, or turn it off later in Settings → Apps → WOCOM HUB → Permissions. '
              'Emergency calls still go through without it.',
              style: TextStyle(fontSize: 14, height: 1.4)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
          ],
        ),
      );
      try { await flag.writeAsString('1'); } catch (_) {}
      if (go == true) await Geolocator.requestPermission();
    } catch (_) {}
  }
}
