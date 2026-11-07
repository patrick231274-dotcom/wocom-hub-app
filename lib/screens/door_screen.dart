import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';

/// Office door: hold the button to open (technicians and managers, at the office). Outside
/// Mon–Fri 08:00–17:30 it asks the approver; approvers see and decide requests here too.
class DoorScreen extends StatefulWidget {
  const DoorScreen({super.key});
  @override
  State<DoorScreen> createState() => _DoorScreenState();
}

class _DoorScreenState extends State<DoorScreen> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _s;
  String? _error;
  String? _result;
  bool _resultGood = false;
  bool _busy = false;
  Timer? _poll;
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..addStatusListener((st) { if (st == AnimationStatus.completed) _open(); });

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.doorEvent.addListener(_load);
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _hold.dispose();
    TechHub.instance.doorEvent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await TechHub.instance.doorStatus();
      if (mounted) setState(() { _s = s; _error = null; });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<Map<String, dynamic>?> _where() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) { _show('Turn on location. You need to be at the office.', false); return null; }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) { _show('Allow location for WE App. The door only opens at the office.', false); return null; }
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 15)));
      return {'lat': pos.latitude, 'lng': pos.longitude, 'accuracy_m': pos.accuracy};
    } catch (_) {
      _show("Couldn't get your location. Try again near a window or outside.", false);
      return null;
    }
  }

  void _show(String m, bool good) { if (mounted) setState(() { _result = m; _resultGood = good; }); }

  Future<void> _open() async {
    _hold.reset();
    if (_busy) return;
    HapticFeedback.heavyImpact();
    setState(() { _busy = true; _result = 'Checking your location…'; _resultGood = true; });
    final loc = await _where();
    if (loc == null) { if (mounted) setState(() => _busy = false); return; }
    try {
      final r = await TechHub.instance.doorOpen(loc);
      if (r['pending'] == true) {
        _show(r['message']?.toString() ?? 'Request sent for approval.', true);
      } else {
        HapticFeedback.mediumImpact();
        _show(r['message']?.toString() ?? 'Door is opening.', true);
      }
      _load();
    } on ApiException catch (e) {
      _show(e.message, false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(int id, bool approve) async {
    try {
      await TechHub.instance.doorDecide(id, approve);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(approve ? 'Approved. The door is opening.' : 'Declined.')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    _load();
  }

  Future<void> _setOffice() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Set office location'),
      content: const Text('Do this while standing inside the office. Staff will only be able to open the door within about 150 m of this spot.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text("I'm at the office"))],
    ));
    if (ok != true) return;
    final loc = await _where();
    if (loc == null) return;
    try {
      await TechHub.instance.doorSetOffice(loc);
      _show('Office location saved.', true);
      _load();
    } on ApiException catch (e) {
      _show(e.message, false);
    }
  }

  String _time(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    return '${d.day}/${d.month} ${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final pending = ((s?['pending'] as List?) ?? const []).whereType<Map>().toList();
    final approver = s?['approver'] == true;
    final allowed = s?['allowed'] == true;
    final inHours = s?['in_hours'] == true;
    final my = s?['my_request'] is Map ? s!['my_request'] as Map : null;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FB),
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: Text((s?['name'] ?? 'Office door').toString())),
      body: s == null
          ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(18), children: [
                if (approver && pending.isNotEmpty) ...[
                  const Text('WAITING FOR YOUR APPROVAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFB45309), letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  for (final p in pending)
                    Card(
                      color: const Color(0xFFFFFBEB),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text('${p['name']}${(p['extension'] ?? '').toString().isNotEmpty ? ' · ext ${p['extension']}' : ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                          Text('Asked at ${_time(p['at']?.toString())} (outside office hours). They are at the office.', style: const TextStyle(color: wocomMuted)),
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(child: OutlinedButton(onPressed: () => _decide((p['id'] as num).toInt(), false), child: const Text('Decline'))),
                            const SizedBox(width: 10),
                            Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFF15803D)), onPressed: () => _decide((p['id'] as num).toInt(), true), child: const Text('Approve & open'))),
                          ]),
                        ]),
                      ),
                    ),
                  const SizedBox(height: 18),
                ],
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomLine)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _line(Icons.verified_user_outlined, allowed ? 'You have door access' : 'Door access is for technicians and managers only', allowed),
                    _line(Icons.schedule, inHours ? 'Office hours: opens straight away' : 'Outside office hours (Mon–Fri 8:00 AM – 5:30 PM): needs approval', inHours || approver),
                    _line(Icons.location_on_outlined, s['office_set'] == true ? 'You must be within ${s['radius_m'] ?? 150} m of the office' : 'Office location not set yet', s['office_set'] == true),
                    if (s['configured'] != true) _line(Icons.link_off, 'Door not connected yet (waiting for eWeLink)', false),
                  ]),
                ),
                const SizedBox(height: 28),
                Center(
                  child: GestureDetector(
                    onTapDown: (!allowed || _busy) ? null : (_) => _hold.forward(),
                    onTapUp: (_) { if (!_hold.isCompleted) _hold.reverse(); },
                    onTapCancel: () { if (!_hold.isCompleted) _hold.reverse(); },
                    child: AnimatedBuilder(
                      animation: _hold,
                      builder: (_, __) => SizedBox(
                        width: 210, height: 210,
                        child: Stack(alignment: Alignment.center, children: [
                          SizedBox(width: 210, height: 210, child: CircularProgressIndicator(value: _hold.value, strokeWidth: 10, backgroundColor: const Color(0xFFE5E7EB), color: const Color(0xFF15803D))),
                          Container(
                            width: 178, height: 178,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: allowed ? const LinearGradient(colors: [Color(0xFF009B3A), Color(0xFF0B5E2A)], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                              color: allowed ? null : const Color(0xFFD1D5DB),
                              boxShadow: allowed ? const [BoxShadow(color: Color(0x55009B3A), blurRadius: 24, offset: Offset(0, 8))] : null,
                            ),
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(_busy ? Icons.hourglass_top : Icons.meeting_room_outlined, size: 58, color: Colors.white),
                              const SizedBox(height: 6),
                              Text(_busy ? 'Working…' : (inHours || approver ? 'Hold to open' : 'Hold to request'), style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
                            ]),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (_result != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: _resultGood ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
                    child: Text(_result!, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _resultGood ? const Color(0xFF065F46) : const Color(0xFF991B1B))),
                  ),
                if (my != null && my['status'] != null) ...[
                  const SizedBox(height: 10),
                  Text(switch (my['status']) {
                    'pending' => 'Your request is waiting for approval…',
                    'approved' => 'Your last request was approved by ${my['decided_by'] ?? 'the approver'}.',
                    'declined' => 'Your last request was declined by ${my['decided_by'] ?? 'the approver'}.',
                    _ => 'Your last request expired. Hold the button to ask again.',
                  }, textAlign: TextAlign.center, style: const TextStyle(color: wocomMuted, fontWeight: FontWeight.w600)),
                ],
                if (s['last_opened'] is Map) ...[
                  const SizedBox(height: 14),
                  Text('Last opened by ${(s['last_opened'] as Map)['by']} · ${_time((s['last_opened'] as Map)['at']?.toString())}', textAlign: TextAlign.center, style: const TextStyle(color: wocomMuted, fontSize: 13)),
                ],
                if (approver) ...[
                  const SizedBox(height: 24),
                  TextButton.icon(onPressed: _setOffice, icon: const Icon(Icons.my_location), label: Text(s['office_set'] == true ? 'Reset office location (stand in the office)' : 'Set office location (stand in the office)')),
                ],
              ]),
            ),
    );
  }

  Widget _line(IconData i, String t, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(i, size: 20, color: ok ? const Color(0xFF15803D) : const Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(child: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
        ]),
      );
}
