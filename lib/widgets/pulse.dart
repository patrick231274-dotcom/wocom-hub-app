import 'package:flutter/material.dart';

/// Soft "breathing" rings around a circular child: wide, moving rings while [active]
/// (ringing/connecting), a gentle slow breath otherwise.
class PulseRing extends StatefulWidget {
  const PulseRing({super.key, required this.child, required this.size, this.active = true, this.color = Colors.white});

  final Widget child;
  final double size;
  final bool active;
  final Color color;

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reach = widget.active ? 1.55 : 1.18;
    return SizedBox(
      width: widget.size * 1.6,
      height: widget.size * 1.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final rings = <Widget>[];
          for (var i = 0; i < (widget.active ? 3 : 1); i++) {
            final t = ((_c.value + i / 3) % 1.0);
            final scale = 1 + (reach - 1) * t;
            final opacity = (1 - t) * (widget.active ? 0.55 : 0.35);
            rings.add(Transform.scale(
              scale: scale,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: widget.color.withValues(alpha: opacity), width: 2)),
              ),
            ));
          }
          return Stack(alignment: Alignment.center, children: [...rings, child!]);
        },
        child: widget.child,
      ),
    );
  }
}
