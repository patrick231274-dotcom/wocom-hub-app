import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api.dart';
import '../services/dial_plan.dart';
import '../services/hub.dart';
import '../services/phone.dart';
import '../services/quick_dials.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';

/// Keypad under the same header as every other screen. Keys register the instant a finger
/// touches them (not on release), so fast dialling never drops a digit.
class KeypadScreen extends StatefulWidget {
  const KeypadScreen({super.key, required this.onAvatarTap, required this.onOpenDirectory});

  final VoidCallback onAvatarTap;
  final VoidCallback onOpenDirectory;

  @override
  State<KeypadScreen> createState() => _KeypadScreenState();
}

class _KeypadScreenState extends State<KeypadScreen> {
  String _number = '';

  static const _keys = [
    ['1', ''], ['2', 'ABC'], ['3', 'DEF'],
    ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'],
    ['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ'],
    ['*', ''], ['0', '+'], ['#', ''],
  ];

  void _press(String d) {
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
    setState(() => _number += d);
  }

  void _plus() {
    // Holding 0 turns it into +, as on a normal phone.
    if (_number.endsWith('0')) {
      HapticFeedback.mediumImpact();
      setState(() => _number = '${_number.substring(0, _number.length - 1)}+');
    }
  }

  Future<void> _call() async {
    if (_number.isEmpty) return;
    final problem = dialProblem(_number);
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    if (!await Phone.instance.dial(_number)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Your line isn't ready yet. Wait for \"Ready\" and try again.")));
      return;
    }
    // The call window opens by itself once the call exists (see main.dart).
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Only the header listens to line/team changes; the keys never rebuild mid-tap.
      AnimatedBuilder(
        animation: Listenable.merge([Phone.instance, Hub.instance]),
        builder: (context, _) {
          final p = Phone.instance;
          final (badgeBg, badgeFg, badgeText) = switch (p.shownStatus) {
            LineStatus.ready => (const Color(0x3322C55E), const Color(0xFFBBF7D0), 'Ready'),
            LineStatus.connecting => (const Color(0x33FDE68A), const Color(0xFFFDE68A), 'Connecting'),
            _ => (const Color(0x33FECACA), const Color(0xFFFECACA), 'Offline · tap to retry'),
          };
          return BrandHeader(
            title: Session.instance.name.isEmpty ? 'Keypad' : Session.instance.name,
            subtitle: '${p.extension.isEmpty ? Session.instance.company : 'Ext ${p.extension} · ${Session.instance.company}'} · v${PushApi.appVersion.split('+').first}',
            onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
            onAvatarTap: widget.onAvatarTap,
            myStatus: Hub.instance.myStatus,
            trailing: [
              InkWell(
                onTap: p.shownStatus == LineStatus.ready ? null : () => p.connect(),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(15)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: badgeFg, shape: BoxShape.circle)),
                    const SizedBox(width: 7),
                    Text(badgeText, style: TextStyle(color: badgeFg, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ],
          );
        },
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > box.maxHeight; // phone turned sideways, or an unfolded foldable
          // Key size follows the space available in both directions, so nothing overlaps.
          final byHeight = ((wide ? box.maxHeight - 40 : box.maxHeight - 220) / 4) - 12;
          final byWidth = ((wide ? box.maxWidth * 0.55 : box.maxWidth) - 48) / 3 - 24;
          final key = byHeight.clamp(50.0, 80.0).clamp(50.0, byWidth.clamp(50.0, 80.0));

          final keys = Column(mainAxisSize: MainAxisSize.min, children: [
            for (var row = 0; row < 4; row++)
              Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                for (var col = 0; col < 3; col++)
                  _Key(
                    digit: _keys[row * 3 + col][0],
                    letters: _keys[row * 3 + col][1],
                    size: key,
                    onPress: _press,
                    onHold: _keys[row * 3 + col][0] == '0' ? _plus : null,
                  ),
              ]),
          ]);
          final quick = quickDialFor(_number);
          final number = SizedBox(
            height: 52,
            child: quick != null
                ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(_number, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: wocomInk, height: 1.05)),
                    Text(quick.name, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: quick.emergency ? const Color(0xFFB91C1C) : wocomDeep)),
                  ])
                : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_number.isEmpty ? ' ' : _number,
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: wocomInk, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
          );
          final callButton = SizedBox(
            width: 74,
            height: 74,
            child: Material(
              color: const Color(0xFF16A34A),
              shape: const CircleBorder(),
              elevation: 4,
              shadowColor: const Color(0x8016A34A),
              child: InkWell(customBorder: const CircleBorder(), onTap: _call, child: const Icon(Icons.call, color: Colors.white, size: 32, semanticLabel: 'Call')),
            ),
          );
          // ← removes one digit (hold: clear all); 🔍 opens the company directory.
          final deleteButton = SizedBox(
            width: 56,
            height: 56,
            child: IconButton(
              tooltip: 'Delete (hold to clear)',
              icon: Icon(Icons.keyboard_backspace, size: 32, color: _number.isEmpty ? const Color(0xFFC9C2D6) : wocomDeep),
              onPressed: _number.isEmpty ? null : () => setState(() => _number = _number.substring(0, _number.length - 1)),
              onLongPress: () => setState(() => _number = ''),
            ),
          );
          final directoryButton = SizedBox(
            width: 56,
            height: 56,
            child: IconButton(
              tooltip: 'Directory',
              icon: const Icon(Icons.search, size: 30, color: wocomDeep),
              onPressed: widget.onOpenDirectory,
            ),
          );

          if (wide) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Row(children: [
                  Expanded(child: Center(child: keys)),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      number,
                      const SizedBox(height: 18),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [directoryButton, const SizedBox(width: 16), callButton, const SizedBox(width: 16), deleteButton]),
                    ]),
                  ),
                ]),
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                number,
                const SizedBox(height: 10),
                keys,
                const SizedBox(height: 30),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [SizedBox(width: key + 24, child: Center(child: directoryButton)), callButton, SizedBox(width: key + 24, child: Center(child: deleteButton))]),
              ]),
            ),
          );
        }),
      ),
    ]);
  }
}

/// One key. Uses raw pointer events (no gesture arena), so a touch counts immediately and a
/// slightly sliding thumb still registers. The whole square around the circle is tappable.
class _Key extends StatefulWidget {
  const _Key({required this.digit, required this.letters, required this.size, required this.onPress, this.onHold});

  final String digit;
  final String letters;
  final double size;
  final void Function(String) onPress;
  final VoidCallback? onHold;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;
  Timer? _hold;

  void _onDown(PointerDownEvent _) {
    setState(() => _down = true);
    widget.onPress(widget.digit);
    _hold?.cancel();
    if (widget.onHold != null) _hold = Timer(const Duration(milliseconds: 550), () => widget.onHold!());
  }

  void _onUp(PointerEvent _) {
    _hold?.cancel();
    if (mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Semantics(
          button: true,
          label: widget.digit,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: s,
            height: s,
            decoration: BoxDecoration(
              color: _down ? wocomSoft : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: _down ? wocomPurple : wocomLine, width: 1.5),
              boxShadow: _down ? const [] : const [BoxShadow(color: Color(0x14321062), blurRadius: 8, offset: Offset(0, 3))],
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(widget.digit, style: TextStyle(fontSize: s * 0.37, fontWeight: FontWeight.w600, height: 1.0, color: wocomInk)),
              SizedBox(
                height: 13,
                child: Text(widget.letters, style: const TextStyle(fontSize: 9.5, letterSpacing: 1.5, color: Color(0xFF8A8299), height: 1.3)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
