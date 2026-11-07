import 'package:flutter/material.dart';

import 'brand.dart';

// Brand colours. The names are WOCOM's (purple, plum…) but the values come from the brand file
// at build time, so a client build simply reads its own set. Defaults: the Hub's purple blended
// into the logo's magenta.
const wocomPurple = Color(int.fromEnvironment('BRAND_ACCENT', defaultValue: 0xFF7B2FF2));      // accent
const wocomDeep = Color(int.fromEnvironment('BRAND_DEEP', defaultValue: 0xFF6D28D9));          // accent, darker (text on light)
const wocomMagenta = Color(int.fromEnvironment('BRAND_ACCENT2', defaultValue: 0xFF8E2DA1));    // second accent (headers blend to it)
const wocomPlum = Color(int.fromEnvironment('BRAND_DARK', defaultValue: 0xFF3B0764));          // deepest shade, call screens, headers
const wocomSoft = Color(int.fromEnvironment('BRAND_SOFT', defaultValue: 0xFFF0EBFF));          // light tint for chips and icon tiles
const wocomBg = Color(int.fromEnvironment('BRAND_BG', defaultValue: 0xFFF7F5FB));
const wocomInk = Color(int.fromEnvironment('BRAND_INK', defaultValue: 0xFF1C1530));
const wocomMuted = Color(int.fromEnvironment('BRAND_MUTED', defaultValue: 0xFF5B5470));
const wocomLine = Color(int.fromEnvironment('BRAND_LINE', defaultValue: 0xFFE8E2F3));
const wocomTint = Color(int.fromEnvironment('BRAND_TINT', defaultValue: 0xFFC4A6FF));          // avatars, strong tint on dark
const wocomTintLight = Color(int.fromEnvironment('BRAND_TINT_LIGHT', defaultValue: 0xFFEDE4FF)); // secondary text on dark

/// Header band on every main screen.
const wocomGradient = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [wocomDeep, wocomMagenta]);

/// Call screens: deeper, richer version of the same blend.
const wocomCallGradient = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [wocomPlum, wocomDeep, wocomMagenta], stops: [0, 0.55, 1]);

ThemeData wocomTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: wocomPurple, brightness: b, primary: dark ? const Color(0xFFC4A6FF) : wocomDeep);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF14101E) : wocomBg,
    fontFamily: 'Roboto',
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1E1830) : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: wocomLine)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: wocomLine)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: wocomPurple, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    // WOCOM buttons: outlined in purple, never a solid fill.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: scheme.primary, width: 2),
        foregroundColor: scheme.primary,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: scheme.primary, textStyle: const TextStyle(fontWeight: FontWeight.w600))),
    listTileTheme: const ListTileThemeData(iconColor: wocomMuted),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: const Color(0xFFEDE4FF),
      height: 74,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
            color: s.contains(WidgetState.selected) ? wocomDeep : const Color(0xFF4B4560),
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(size: 24, color: s.contains(WidgetState.selected) ? wocomDeep : const Color(0xFF4B4560))),
    ),
  );
}

/// The WOCOM "W" mark (from the logo).
class WocomMark extends StatelessWidget {
  const WocomMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) =>
      Image.asset(Brand.mark, width: size, height: size, filterQuality: FilterQuality.high, semanticLabel: Brand.name);
}

/// The full WOCOM logo: mark + wordmark. [white] for use on the purple brand background.
class WocomLogo extends StatelessWidget {
  const WocomLogo({super.key, this.height = 44, this.white = false});

  final double height;
  final bool white;

  @override
  Widget build(BuildContext context) =>
      Image.asset(white ? Brand.logoWhite : Brand.logo, height: height, filterQuality: FilterQuality.high, semanticLabel: Brand.name);
}


// ---- Sign-in design D (2026-11-07) ----

/// Solid button purple on the sign-in screens.
const wocomButton = Color(0xFF4C1D95);

/// W mark + WOCOM + HUB on one line, all the same height. Other brands: mark + name.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.fontSize = 34});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    // The mark PNG has padding: the visible tile is ~70% wide and ~60% tall, centred.
    // Size it so the tile's height matches the capital letters of the text.
    final s = fontSize * 1.2;
    final mark = ClipRect(
      child: Align(
        widthFactor: 0.70,
        heightFactor: 0.60,
        child: Image.asset(Brand.mark, width: s, height: s, filterQuality: FilterQuality.high),
      ),
    );
    final style = TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, letterSpacing: -0.5, height: 1);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
      mark,
      SizedBox(width: fontSize * 0.2),
      Text.rich(
        TextSpan(children: [
          TextSpan(text: Brand.isWocom ? 'WOCOM ' : Brand.name, style: const TextStyle(color: Color(0xFF6B2196))),
          if (Brand.isWocom) const TextSpan(text: 'HUB', style: TextStyle(color: Color(0xFF008A3A))),
        ]),
        style: style,
        semanticsLabel: Brand.name,
      ),
    ]);
  }
}

/// Green, gold and black stripe.
class JmBar extends StatelessWidget {
  const JmBar({super.key, this.width = 120, this.thickness = 4});

  final double width;
  final double thickness;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(thickness),
        child: SizedBox(
          width: width,
          height: thickness,
          child: const Row(children: [
            Expanded(child: ColoredBox(color: Color(0xFF009B3A))),
            Expanded(child: ColoredBox(color: Color(0xFFFED100))),
            Expanded(child: ColoredBox(color: Color(0xFF1C1530))),
          ]),
        ),
      );
}

/// Gold and green waves along the bottom of the sign-in screens.
class JmWaves extends StatelessWidget {
  const JmWaves({super.key, this.height = 110});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Stack(children: [
          Positioned.fill(child: ClipPath(clipper: const _Wave(rise: 0.0), child: const ColoredBox(color: Color(0xFFFED100)))),
          Positioned.fill(child: ClipPath(clipper: const _Wave(rise: 0.22), child: const ColoredBox(color: Color(0xFF009B3A)))),
        ]),
      );
}

class _Wave extends CustomClipper<Path> {
  const _Wave({required this.rise});

  final double rise;

  @override
  Path getClip(Size size) {
    final h = size.height, w = size.width, t = h * rise;
    return Path()
      ..moveTo(0, h * 0.62 + t)
      ..cubicTo(w * 0.32, h * 0.42 + t, w * 0.68, h * 0.40 + t, w, h * 0.08 + t)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
  }

  @override
  bool shouldReclip(_Wave old) => old.rise != rise;
}
