import 'package:flutter/material.dart';

import '../brand.dart';

import '../theme.dart';
import 'sign_in_screen.dart';

/// First screen after installing: the brand, the team, what the app does, and Activate.
/// Design D (2026-11-07): clean white, W + WOCOM + HUB on one line, flag stripe, team photo
/// that fades into the white, Call/Chat/Meet tiles, gold and green waves at the foot.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final short = MediaQuery.of(context).size.height < 720;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
        const Positioned(left: 0, right: 0, bottom: 0, child: JmWaves(height: 130)),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: IntrinsicHeight(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SizedBox(height: short ? 18 : 40),
                        Center(child: BrandWordmark(fontSize: short ? 30 : 36)),
                        const SizedBox(height: 10),
                        const Center(child: JmBar(width: 120)),
                        const SizedBox(height: 10),
                        const Text('100% JAMAICAN', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 4, color: Color(0xFF008A3A))),
                        const SizedBox(height: 6),
                        const Text('Call. Chat. Meet. All in one place.', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF2B2438))),
                        SizedBox(height: short ? 8 : 16),
                        if (Brand.isWocom)
                          _TeamPhoto(height: short ? 150 : 205)
                        else
                          Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Center(child: WocomMark(size: short ? 100 : 130))),
                        Transform.translate(
                          offset: Offset(0, Brand.isWocom ? -26 : 0),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 40),
                            child: Row(children: [
                              Expanded(child: _Tile(icon: Icons.call, label: 'Call', color: Color(0xFF009B3A))),
                              SizedBox(width: 14),
                              Expanded(child: _Tile(icon: Icons.chat, label: 'Chat', color: Color(0xFFF2B705))),
                              SizedBox(width: 14),
                              Expanded(child: _Tile(icon: Icons.groups, label: 'Meet', color: Color(0xFF5B21B6))),
                            ]),
                          ),
                        ),
                        const Text('People. Business. Jamaica. Closer together.', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13.5, color: Color(0xFF2B2438))),
                        const SizedBox(height: 8),
                        const Center(child: JmBar(width: 64, thickness: 3)),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
                          child: FilledButton(
                            onPressed: onContinue,
                            style: FilledButton.styleFrom(
                              backgroundColor: wocomButton,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(54),
                              shape: const StadiumBorder(),
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Activate my phone'), SizedBox(width: 6), Icon(Icons.chevron_right)]),
                          ),
                        ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SignInScreen())),
                          style: TextButton.styleFrom(foregroundColor: wocomButton, textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          child: const Text('Already activated? Sign in'),
                        ),
                        const SizedBox(height: 110), // clear of the waves
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The team photo, fading into the white on every side (no hard edge).
class _TeamPhoto extends StatelessWidget {
  const _TeamPhoto({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.16, 0.62, 0.95],
          ).createShader(r),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.16, 0.84, 1],
            ).createShader(r),
            child: Image.asset('assets/wocom-team.png', fit: BoxFit.cover, alignment: Alignment.topCenter, filterQuality: FilterQuality.high),
          ),
        ),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Color(0x24281450), blurRadius: 16, offset: Offset(0, 6))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: wocomInk)),
        ]),
      );
}

/// A slow, subtle breathing scale on the logo.
class BreathingLogo extends StatefulWidget {
  const BreathingLogo({super.key, required this.child});

  final Widget child;

  @override
  State<BreathingLogo> createState() => _BreathingLogoState();
}

class _BreathingLogoState extends State<BreathingLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: Tween(begin: 0.97, end: 1.04).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)), child: widget.child);
}
