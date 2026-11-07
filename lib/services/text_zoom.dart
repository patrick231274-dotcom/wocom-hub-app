import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pinch with two fingers anywhere to make the app's text bigger or smaller (WE App). The size is
/// remembered on the phone; Settings has a slider and a reset.
class TextZoom extends ValueNotifier<double> {
  TextZoom._() : super(1.0);
  static final TextZoom instance = TextZoom._();
  static const min = 0.85, max = 2.0;
  final _store = const FlutterSecureStorage();

  Future<void> load() async {
    try { value = (double.tryParse(await _store.read(key: 'we_text_zoom') ?? '') ?? 1.0).clamp(min, max); } catch (_) {}
  }

  void set(double v) {
    value = double.parse(v.clamp(min, max).toStringAsFixed(2));
    _store.write(key: 'we_text_zoom', value: '$value').catchError((_) {});
  }
}

/// Wraps the whole app: watches raw pointers (so scrolling and taps are untouched) and, while two
/// fingers are down, scales the text with the spread between them.
class PinchTextZoom extends StatefulWidget {
  const PinchTextZoom({super.key, required this.child});
  final Widget child;
  @override
  State<PinchTextZoom> createState() => _PinchTextZoomState();
}

class _PinchTextZoomState extends State<PinchTextZoom> {
  final Map<int, Offset> _pts = {};
  double? _startSpread;
  double _startZoom = 1;

  double _spread() { final p = _pts.values.toList(); return (p[0] - p[1]).distance; }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _pts[e.pointer] = e.position;
          if (_pts.length == 2) { _startSpread = _spread(); _startZoom = TextZoom.instance.value; }
        },
        onPointerMove: (e) {
          if (!_pts.containsKey(e.pointer)) return;
          _pts[e.pointer] = e.position;
          if (_pts.length == 2 && _startSpread != null && _startSpread! > 40) {
            final ratio = _spread() / _startSpread!;
            // Soften it a little so a small pinch is a small change.
            TextZoom.instance.set(_startZoom * pow(ratio, 0.8));
          }
        },
        onPointerUp: (e) { _pts.remove(e.pointer); if (_pts.length < 2) _startSpread = null; },
        onPointerCancel: (e) { _pts.remove(e.pointer); if (_pts.length < 2) _startSpread = null; },
        child: ValueListenableBuilder<double>(
          valueListenable: TextZoom.instance,
          builder: (context, z, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(z)), child: child!),
          child: widget.child,
        ),
      );
}
