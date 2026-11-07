import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'diag.dart';
import 'techhub.dart';

/// WE App live location: only while the engineer is On duty and signed in to Tech Hub. Runs as an
/// Android foreground service (visible notification "Sharing your location"), every ~30 s or 50 m.
/// Positions go straight to Tech Hub; points taken while offline are sent as a batch later.
class WeLocation extends ChangeNotifier {
  WeLocation._();
  static final WeLocation instance = WeLocation._();

  StreamSubscription<Position>? _sub;
  final List<Map<String, dynamic>> _pending = [];
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool sharing = false;
  String? problem; // why it is not sharing (permission, GPS off), shown in the app

  /// Start or stop to match the engineer's duty state. Safe to call often.
  Future<void> sync() async {
    final th = TechHub.instance;
    if (th.signedIn && th.onDuty) {
      await _start();
    } else {
      await stop();
    }
  }

  Future<void> _start() async {
    if (_sub != null) return;
    if (!await Geolocator.isLocationServiceEnabled()) { problem = 'Location is switched off on this phone.'; sharing = false; notifyListeners(); return; }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) { problem = 'Allow location for WE App so the office can see you while on duty.'; sharing = false; notifyListeners(); return; }
    problem = null;
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 50,
      intervalDuration: const Duration(seconds: 30),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'WE App · On duty',
        notificationText: 'Sharing your location with the office while you are on duty.',
        notificationIcon: AndroidResource(name: 'ic_stat_wocom', defType: 'drawable'),
        enableWakeLock: false,
        setOngoing: true,
      ),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition, onError: (e) => Diag.log('gps', 'stream error: $e'));
    sharing = true;
    notifyListeners();
    Diag.log('gps', 'sharing started');
  }

  Future<void> stop() async {
    if (_sub == null && !sharing) return;
    await _sub?.cancel();
    _sub = null;
    sharing = false;
    notifyListeners();
    Diag.log('gps', 'sharing stopped');
  }

  Future<void> _onPosition(Position p) async {
    _pending.add({
      'lat': p.latitude, 'lng': p.longitude, 'accuracy_m': p.accuracy,
      if (p.speed >= 0) 'speed_mps': p.speed, if (p.heading >= 0) 'heading': p.heading,
      'at': p.timestamp.toUtc().toIso8601String(), 'source': 'gps',
    });
    if (_pending.length > 500) _pending.removeRange(0, _pending.length - 500);
    if (DateTime.now().difference(_lastSent) < const Duration(seconds: 16)) return;
    _lastSent = DateTime.now();
    final batch = List<Map<String, dynamic>>.from(_pending);
    try {
      await TechHub.instance.sendLocation(batch);
      _pending.removeRange(0, batch.length.clamp(0, _pending.length));
    } on ApiException catch (e) {
      if (e.code == 'off_duty') { await stop(); }
      Diag.log('gps', 'send failed: ${e.message}');
    }
  }
}
