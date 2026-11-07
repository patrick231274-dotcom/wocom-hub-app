import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';

import 'diag.dart';
import 'techhub.dart';

/// Office arrival log: when the app is open (or comes back to the front) on a workday morning and the
/// phone is inside the office area, tell Tech Hub once per day. Used for the arrival time only:
/// nothing is sent while the phone is outside the office area, and it never asks for location itself.
class ArrivalCheck {
  ArrivalCheck._();
  static final instance = ArrivalCheck._();

  static const _store = FlutterSecureStorage();
  Map<String, dynamic>? _office; // {lat, lng, radius_m}
  DateTime _officeAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _doneDay;
  bool _busy = false;
  Timer? _timer;

  String _today() { final n = DateTime.now(); return '${n.year}-${n.month}-${n.day}'; }

  /// Office area from Tech Hub (settings.office), refreshed every 12 h. Also fed by the attendance screen.
  void setOffice(dynamic office) {
    if (office is Map && office['lat'] != null && office['lng'] != null) { _office = Map<String, dynamic>.from(office); _officeAt = DateTime.now(); }
  }

  /// Called on app start and resume; also re-checks every 5 minutes while the app is open in the morning.
  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 5), (_) => check());
    check();
  }

  void stop() { _timer?.cancel(); _timer = null; }

  Future<void> check() async {
    final now = DateTime.now();
    if (_busy || !TechHub.instance.signedIn) return;
    if (now.weekday > 5 || now.hour < 5 || now.hour >= 14) return; // workday mornings only
    _doneDay ??= await _store.read(key: 'we_arrival_day').catchError((_) => null);
    if (_doneDay == _today()) return;
    _busy = true;
    try {
      if (_office == null || now.difference(_officeAt).inHours >= 12) {
        final a = await TechHub.instance.myAttendance(now.year);
        setOffice((a['settings'] as Map?)?['office']);
      }
      final o = _office;
      if (o == null) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return; // never prompts
      final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
      final d = Geolocator.distanceBetween(p.latitude, p.longitude, (o['lat'] as num).toDouble(), (o['lng'] as num).toDouble());
      final radius = ((o['radius_m'] as num?) ?? 150).toDouble();
      if (d > radius + (p.accuracy > 100 ? 100 : p.accuracy) || p.accuracy > 250) return; // not at the office: send nothing
      final r = await TechHub.instance.sendArrival(p.latitude, p.longitude, p.accuracy);
      if (r['recorded'] == true || r['arrival'] != null) {
        _doneDay = _today();
        await _store.write(key: 'we_arrival_day', value: _doneDay);
        Diag.log('arrival', 'office arrival logged (${d.round()} m)');
      }
    } catch (e) {
      Diag.log('arrival', 'check skipped: $e');
    } finally {
      _busy = false;
    }
  }
}
