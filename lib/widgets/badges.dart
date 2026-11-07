import 'package:flutter/material.dart';

import '../services/quick_dials.dart';
import '../theme.dart';

/// Round glossy badge for a quick-dial number, drawn in code so it stays crisp at any size.
class QuickDialBadge extends StatelessWidget {
  const QuickDialBadge({super.key, required this.dial, this.size = 112});

  final QuickDial dial;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (colors, inner) = switch (dial.kind) {
      QuickDialKind.wocom => ([const Color(0xFF8B3DFF), wocomDeep, wocomPlum], _wocomInner(size)),
      QuickDialKind.police => ([const Color(0xFF3B82F6), const Color(0xFF1D4ED8), const Color(0xFF172554)], _emergencyInner('119', 'POLICE', size)),
      QuickDialKind.fire => ([const Color(0xFFF87171), const Color(0xFFDC2626), const Color(0xFF7F1D1D)], _emergencyInner('110', 'FIRE', size)),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(center: const Alignment(-0.35, -0.45), radius: 0.95, colors: colors, stops: const [0, 0.55, 1]),
        boxShadow: [BoxShadow(color: colors[2].withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Stack(alignment: Alignment.center, children: [
        // gloss
        Positioned(
          top: size * 0.07,
          child: Container(
            width: size * 0.62,
            height: size * 0.3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size),
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white.withValues(alpha: 0.42), Colors.white.withValues(alpha: 0.0)]),
            ),
          ),
        ),
        if (dial.emergency) _flagStripe(size),
        inner,
      ]),
    );
  }

  /// The WOCOM W mark in white, filling the coloured circle.
  Widget _wocomInner(double s) => SizedBox(
        width: s * 0.8,
        height: s * 0.8,
        child: Image.asset('assets/wocom-mark-white.png', fit: BoxFit.contain, filterQuality: FilterQuality.high, semanticLabel: 'WOCOM Limited'),
      );

  Widget _emergencyInner(String number, String word, double s) => Column(mainAxisSize: MainAxisSize.min, children: [
        Text(number, style: TextStyle(color: Colors.white, fontSize: s * 0.34, fontWeight: FontWeight.w900, height: 1, letterSpacing: -1, shadows: const [Shadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2))])),
        Text(word, style: TextStyle(color: Colors.white, fontSize: s * 0.13, fontWeight: FontWeight.w800, height: 1.2, letterSpacing: 1)),
        Container(
          margin: EdgeInsets.only(top: s * 0.03),
          padding: EdgeInsets.symmetric(horizontal: s * 0.06, vertical: s * 0.012),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(s)),
          child: Text('EMERGENCY', style: TextStyle(color: const Color(0xFF172554), fontSize: s * 0.065, fontWeight: FontWeight.w800, letterSpacing: 1)),
        ),
      ]);

  /// A thin Jamaican green–gold–black band across the badge, as on the sample.
  Widget _flagStripe(double s) => Positioned(
        top: s * 0.36,
        child: Opacity(
          opacity: 0.85,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: s * 0.98, height: s * 0.035, color: const Color(0xFF009B3A)),
            Container(width: s * 0.98, height: s * 0.035, color: const Color(0xFFFED100)),
            Container(width: s * 0.98, height: s * 0.035, color: Colors.black),
          ]),
        ),
      );
}
