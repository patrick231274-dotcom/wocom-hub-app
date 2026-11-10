import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sip_ua/sip_ua.dart' show CallStateEnum;

import '../brand.dart';
import '../services/call_context.dart';
import '../services/hub.dart';
import 'techhub_screen.dart';
import '../services/techhub.dart';
import '../widgets/pulse.dart';
import '../services/names.dart';
import '../services/phone.dart';
import '../theme.dart';
import '../widgets/badges.dart';
import '../widgets/ui.dart';

/// Incoming, ringing and connected call screen. Closes itself when the call ends.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  /// True while a call window is on screen (one at a time).
  static bool open = false;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  bool _keypad = false;
  String _tones = '';

  @override
  void initState() {
    super.initState();
    if (Brand.isEmployee) {
      // A push that woke the phone is saved by another isolate: keep checking while it rings.
      CallContext.instance.reload();
      _ctxPoll = Timer.periodic(const Duration(seconds: 1), (t) {
        final p = Phone.instance;
        if (!mounted || p.call == null || _lockedCtx != null || t.tick > 900) { t.cancel(); return; } // details can land after answering
        if (CallContext.instance.forCall(p.remoteNumber) == null) CallContext.instance.reload();
      });
    }
    CallScreen.open = true;
    Phone.instance.addListener(_onPhone);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    if (Phone.instance.call == null && !Phone.instance.autoAnswerPending) _closeSoon();
  }

  void _onPhone() {
    if (!mounted) return;
    if (Phone.instance.call == null) {
      if (Phone.instance.autoAnswerPending) { setState(() {}); } else { _closeSoon(); }
    } else {
      setState(() {});
    }
  }

  /// The call is over: go straight back to where the person was (no "call ended" page).
  void _closeSoon() {
    setState(() {});
    // A push-woken call that never reached this phone: say why for a moment, then go back.
    final note = Phone.instance.endedNote;
    if (note != null) {
      Future.delayed(const Duration(seconds: 3), () { if (mounted && Phone.instance.call == null && !Phone.instance.autoAnswerPending) { Phone.instance.endedNote = null; Phone.instance.pendingCaller = null; Navigator.of(context).maybePop(); } });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.of(context).maybePop(); });
  }

  @override
  void dispose() {
    _ctxPoll?.cancel();
    CallScreen.open = false;
    Phone.instance.removeListener(_onPhone);
    _tick?.cancel();
    super.dispose();
  }

  String get _status {
    final p = Phone.instance;
    if (p.call == null) return 'Call ended';
    if (p.held) return 'On hold';
    if (p.connected && p.connectedAt != null) {
      final s = DateTime.now().difference(p.connectedAt!).inSeconds;
      return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    }
    if (p.incoming) return 'Incoming call';
    return p.callState == CallStateEnum.PROGRESS ? 'Ringing…' : 'Connecting…';
  }

  Timer? _ctxPoll;
  Map<String, dynamic>? _lockedCtx;
  Map<String, dynamic>? _full;
  String? _fullFor;

  void _fetchFull(String callId) {
    if (callId.isEmpty || _fullFor == callId) return;
    _fullFor = callId;
    TechHub.instance.callContextFull(callId).then((f) { if (mounted) setState(() => _full = f); }).catchError((_) {});
  }

  /// Ringing with Tech Hub details: the caller big at the top, what they want below, easy to read
  /// before answering.
  /// Anything worth showing beyond a name/number? If not, the normal call screen is used.
  bool _hasNotes(Map<String, dynamic> c) {
    final f = _full ?? const <String, dynamic>{};
    bool has(String k) => ((f[k] ?? c[k]) ?? '').toString().trim().isNotEmpty;
    final n = int.tryParse('${c['open_tickets_count'] ?? 0}') ?? 0;
    return has('reason') || has('last_call') || has('summary_text') || has('callback_number') || n > 0 || (f['open_tickets'] is List && (f['open_tickets'] as List).isNotEmpty);
  }

  Widget _ringingWithContext(Phone p, Map<String, dynamic> c, {bool inCall = false}) {
    _fetchFull((c['call_id'] ?? '').toString());
    final f = _full ?? const <String, dynamic>{};
    String pick(String k) => ((f[k] ?? c[k]) ?? '').toString();
    final name = pick('caller_name').isNotEmpty ? pick('caller_name') : (pick('company').isNotEmpty ? pick('company') : p.remoteNumber);
    final company = pick('company');
    final label = (f['client'] is Map ? (f['client'] as Map)['label'] : null)?.toString() ?? (c['client_label'] ?? '').toString();
    final dept = pick('department');
    final viaAi = (f['via_ai'] ?? c['via_ai']).toString() == 'true';
    final pill = dept.isNotEmpty ? 'Calling $dept' : (viaAi ? 'Via AI receptionist' : 'Direct call');
    final reason = pick('reason');
    final callback = pick('callback_number');
    final lastObj = f['last_call'] is Map ? f['last_call'] as Map : null;
    final last = lastObj != null
        ? [lastObj['at'], lastObj['outcome'], lastObj['reason'], lastObj['agent']].where((x) => x != null && x.toString().isNotEmpty).join(' · ')
        : (c['last_call'] ?? '').toString();
    final tickets = f['open_tickets'] is List
        ? (f['open_tickets'] as List).whereType<Map>().map((t) => [t['ticket_number'].toString(), (t['subject'] ?? '').toString(), (t['status'] ?? '').toString()]).toList()
        : (c['open_tickets'] ?? '').toString().split('\n').where((l) => l.trim().isNotEmpty).map((l) { final x = l.split('|'); return [x.first.trim(), x.length > 1 ? x.sublist(1).join('|').trim() : '', '']; }).toList();
    final summary = (f['summary_text'] ?? '').toString();
    Widget head(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: Color(0xFFFED100))));
    return Scaffold(
      backgroundColor: wocomPlum,
      body: Container(
        decoration: const BoxDecoration(gradient: wocomCallGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(inCall ? _status : 'Incoming call', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(height: 6),
              Text(name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900, height: 1.1)),
              if (company.isNotEmpty && company != name || label.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text([if (company != name) company, label].where((x) => x.isNotEmpty).join(' · '), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE9DDFF), fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              const SizedBox(height: 10),
              Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFFFED100), borderRadius: BorderRadius.circular(20)),
                child: Text(pill, style: const TextStyle(color: Color(0xFF1C1530), fontSize: 15, fontWeight: FontWeight.w900)),
              )),
              const SizedBox(height: 14),
              if (inCall && _keypad) Expanded(child: _tonePad(withHide: true)) else Expanded(
                child: ShaderMask(
                  // fade the text out at the bottom edge instead of a hard box
                  shaderCallback: (r) => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, Colors.white, Colors.transparent], stops: [0, 0.92, 1]).createShader(r),
                  blendMode: BlendMode.dstIn,
                  child: ListView(padding: const EdgeInsets.fromLTRB(6, 0, 6, 16), children: [
                    if (reason.isNotEmpty) ...[head('Calling about'), Text(reason, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.3, color: Colors.white))],
                    if (callback.isNotEmpty) ...[head('Call-back number'), Text(callback, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white))],
                    if (last.isNotEmpty) ...[head('Last call'), Text(last, style: const TextStyle(fontSize: 16, height: 1.35, color: Color(0xFFE9DDFF)))],
                    if (tickets.isNotEmpty) ...[
                      head('Open tickets (${tickets.length})'),
                      for (final t in tickets)
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: t[0]))),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                            child: Row(children: [
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(t[0], style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white, fontSize: 15)),
                                if ([t[1], t[2]].any((x) => x.isNotEmpty)) Text([t[1], t[2]].where((x) => x.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 13.5, color: Color(0xFFE9DDFF))),
                              ])),
                              const Icon(Icons.chevron_right, color: Colors.white70),
                            ]),
                          ),
                        ),
                    ],
                    if (summary.isNotEmpty) ...[head('Summary'), Text(summary, style: const TextStyle(fontSize: 15.5, height: 1.4, color: Colors.white))],
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              if (inCall) ...[
                _controls(p),
                const SizedBox(height: 14),
                Center(child: _round(Icons.call_end, const Color(0xFFDC2626), 'End call', p.hangup)),
              ] else
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _round(Icons.call_end, const Color(0xFFDC2626), 'Decline', p.hangup),
                  _round(Icons.call, const Color(0xFF16A34A), 'Answer', p.answer),
                ]),
            ]),
          ),
        ),
      ),
    );
  }

  /// Tech Hub's "Who's calling" card: client, why they're calling, last call, open tickets.
  Widget _contextCard(Map<String, dynamic> c) {
    final company = (c['company'] ?? '').toString();
    final label = (c['client_label'] ?? c['client_type'] ?? '').toString();
    final reason = (c['reason'] ?? '').toString();
    final last = (c['last_call'] ?? '').toString();
    final tickets = (c['open_tickets'] ?? '').toString().split('\n').where((l) => l.trim().isNotEmpty).toList();
    final n = int.tryParse('${c['open_tickets_count'] ?? 0}') ?? 0;
    final ai = c['via_ai'] == 'true';
    Widget row(IconData i, String t, {Color color = Colors.white}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 16, color: const Color(0xFFFED100)),
            const SizedBox(width: 8),
            Expanded(child: Text(t, style: TextStyle(color: color, fontSize: 14, height: 1.3))),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.badge_outlined, color: Color(0xFFFED100), size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text([if ((c['caller_name'] ?? '').toString().isNotEmpty) c['caller_name'], if (company.isNotEmpty) company].join(' · ').isNotEmpty ? [if ((c['caller_name'] ?? '').toString().isNotEmpty) c['caller_name'], if (company.isNotEmpty) company].join(' · ') : 'Caller details', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900))),
          if (label.isNotEmpty) Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFF009B3A), borderRadius: BorderRadius.circular(10)),
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          ),
        ]),
        if (reason.isNotEmpty) row(ai ? Icons.smart_toy_outlined : Icons.chat_outlined, '${ai ? 'Told the AI: ' : 'Reason: '}$reason'),
        if (last.isNotEmpty) row(Icons.history, 'Last call: $last', color: Colors.white70),
        if (n > 0) row(Icons.confirmation_number_outlined, '$n open ticket${n == 1 ? '' : 's'}'),
        for (final t in tickets.take(3))
          Builder(builder: (context) {
            final parts = t.split('|');
            return InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: parts.first.trim()))),
              child: Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Text('${parts.first.trim()}${parts.length > 1 ? ' · ${parts.sublist(1).join('|').trim()}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFBBF7D0), fontSize: 13.5, fontWeight: FontWeight.w700, decoration: TextDecoration.underline, decorationColor: Color(0xFFBBF7D0))),
              ),
            );
          }),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Phone.instance;
    final ringingIn = p.incoming && !p.connected;
    final quick = p.remoteQuickDial;
    // A display name that is just the number again is no name at all.
    final sipName = RegExp(r'^[0-9+ ()\-]*$').hasMatch(p.remoteName) ? '' : p.remoteName;
    final waiting = p.call == null && p.autoAnswerPending;
    final title = p.call == null ? (waiting ? (p.pendingCaller ?? 'Incoming call') : 'Call ended') : (quick?.name ?? (sipName.isNotEmpty ? sipName : (Names.instance.lookup(p.remoteNumber) ?? p.remoteNumber)));
    // Keypad open mid-call: drop the big picture and size the keys from what's left, so all four
    // rows AND the End call button fit on small phones (iPhone 12/13 mini/SE, 667-844 pt).
    final pad = _keypad && !ringingIn && p.call != null;
    final normal = Scaffold(
      backgroundColor: wocomPlum,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(gradient: wocomCallGradient),
        child: SafeArea(
        child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, pad ? 12 : 32, 24, pad ? 12 : 32),
          child: Column(children: [
            if (!pad) const SizedBox(height: 8),
            // Breathing rings around the picture: lively while ringing/connecting, calm once connected.
            if (!pad) PulseRing(
              size: quick != null ? 128 : 92,
              active: !p.connected,
              child: quick != null
                  ? QuickDialBadge(dial: quick, size: 128)
                  : CircleAvatar(radius: 46, backgroundColor: Colors.white24, child: Text(title.isEmpty ? '?' : title[0].toUpperCase(), style: const TextStyle(fontSize: 38, color: Colors.white, fontWeight: FontWeight.w700))),
            ),
            if (!pad) const SizedBox(height: 4),
            Text(title.isEmpty ? 'Call' : title, textAlign: TextAlign.center, maxLines: pad ? 1 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: pad ? 22 : 28, fontWeight: FontWeight.w700)),
            if (quick != null || title != p.remoteNumber) Text(quick != null && quick.emergency ? 'Your location is being sent to WOCOM' : p.remoteNumber, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            SizedBox(height: pad ? 4 : 10),
            if (p.call == null && !waiting && p.endedNote != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(p.endedNote!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 17))),
            if (p.call != null || waiting) Text(waiting ? (p.status == LineStatus.ready ? 'Connecting your call…' : 'Connecting to the office line…') : _status, style: const TextStyle(color: Colors.white70, fontSize: 18, fontFeatures: [FontFeature.tabularFigures()])),
            if (Brand.isEmployee && !_keypad)
              AnimatedBuilder(
                animation: CallContext.instance,
                builder: (context, _) {
                  final c = CallContext.instance.forCall(p.remoteNumber);
                  return c == null ? const SizedBox.shrink() : Flexible(child: SingleChildScrollView(child: _contextCard(c)));
                },
              ),
            if (pad) Expanded(child: _tonePad()) else ...[
              const Spacer(),
              if (!ringingIn) _controls(p),
            ],
            SizedBox(height: pad ? 8 : 28),
            if (waiting)
              _round(Icons.call_end, const Color(0xFFDC2626), 'Cancel', () { p.autoAnswerPending = false; Navigator.of(context).maybePop(); })
            else if (p.call == null)
              _round(Icons.close, Colors.white24, 'Close', () => Navigator.of(context).maybePop())
            else if (ringingIn)
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _round(Icons.call_end, const Color(0xFFDC2626), 'Decline', p.hangup),
                _round(Icons.call, const Color(0xFF16A34A), 'Answer', p.answer),
              ])
            else if (pad)
              // Hide keypad sits beside End call, so both are always on screen.
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(width: 96),
                _round(Icons.call_end, const Color(0xFFDC2626), 'End call', p.hangup),
                SizedBox(width: 96, child: TextButton(onPressed: () => setState(() => _keypad = false), style: TextButton.styleFrom(foregroundColor: Colors.white), child: const Text('Hide\nkeypad', textAlign: TextAlign.center))),
              ])
            else
              _round(Icons.call_end, const Color(0xFFDC2626), 'End call', p.hangup),
          ]),
        ),
        ),
        ),
        ),
      ),
    );
    // WE App: with Tech Hub caller details, the notes stay on screen while ringing AND during the call.
    if (!Brand.isEmployee || p.call == null || !p.incoming) return normal;
    return AnimatedBuilder(
      animation: CallContext.instance,
      builder: (context, _) {
        final c = _lockedCtx ?? CallContext.instance.forCall(p.remoteNumber);
        if (c != null && _lockedCtx == null) _lockedCtx = c; // keep it for the whole call, however long
        return (c == null || !_hasNotes(c)) ? normal : _ringingWithContext(p, c, inCall: !ringingIn);
      },
    );
  }

  Widget _controls(Phone p) => Wrap(spacing: 22, runSpacing: 20, alignment: WrapAlignment.center, children: [
        _toggle(p.muted ? Icons.mic_off : Icons.mic_none, 'Mute', p.muted, p.connected ? p.toggleMute : null),
        _toggle(Icons.dialpad, 'Keypad', false, p.connected ? () => setState(() => _keypad = true) : null),
        p.audioRoutes.contains('bluetooth')
            ? _toggle(_routeIcon(p.audioRoute), _routeLabel(p, p.audioRoute), p.audioRoute != 'earpiece', () => _audioPicker(p))
            : _toggle(p.speaker ? Icons.volume_up : Icons.volume_up_outlined, 'Speaker', p.speaker, p.toggleSpeaker),
        _toggle(p.held ? Icons.play_arrow : Icons.pause, p.held ? 'Resume' : 'Hold', p.held, p.connected ? p.toggleHold : null),
        _toggle(Icons.phone_forwarded, 'Transfer', false, p.connected ? _transfer : null),
      ]);

  static IconData _routeIcon(String r) => switch (r) {
        'speaker' => Icons.volume_up,
        'bluetooth' => Icons.bluetooth_audio,
        'wired' => Icons.headset,
        _ => Icons.phone_in_talk,
      };

  static String _routeLabel(Phone p, String r) => switch (r) {
        'speaker' => 'Speaker',
        'bluetooth' => 'Bluetooth',
        'wired' => 'Headset',
        _ => 'Phone',
      };

  /// Shown when a Bluetooth headset is connected: pick where the call audio goes.
  Future<void> _audioPicker(Phone p) async {
    await p.refreshRoutes();
    if (!mounted) return;
    final order = ['bluetooth', 'wired', 'earpiece', 'speaker'].where(p.audioRoutes.contains).toList();
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Audio', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          for (final r in order)
            ListTile(
              leading: Icon(_routeIcon(r)),
              title: Text(r == 'bluetooth' && (p.bluetoothName ?? '').isNotEmpty ? p.bluetoothName! : _routeLabel(p, r)),
              subtitle: r == 'bluetooth' ? const Text('Bluetooth') : null,
              trailing: p.audioRoute == r ? const Icon(Icons.check, color: wocomDeep) : null,
              onTap: () => Navigator.pop(s, r),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (pick != null) await p.chooseRoute(pick);
  }

  /// Blind transfer: type a number or pick a colleague; the caller is sent straight there.
  Future<void> _transfer() async {
    final ctrl = TextEditingController();
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(s).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Transfer call to', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.phone,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Extension or number'),
            onSubmitted: (v) => Navigator.pop(s, v),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => Navigator.pop(s, ctrl.text), child: const Text('Transfer now')),
          const SizedBox(height: 16),
          const Text('OR PICK A COLLEAGUE', style: TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w700, color: Color(0xFF6B6478))),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView(shrinkWrap: true, children: [
              for (final c in Hub.instance.people.where((p) => p['is_me'] != true && p['status'] != 'offline'))
                ListTile(
                  dense: true,
                  leading: PersonAvatar(name: c['name'] as String, status: c['status'] as String, size: 36),
                  title: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${c['status_label']} · Ext ${c['extension']}'),
                  onTap: () => Navigator.pop(s, c['extension'] as String),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (target == null || target.trim().isEmpty) return;
    final ok = Phone.instance.transfer(target);
    if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't transfer the call.")));
  }

  /// DTMF keypad. Fills the height it is given: keys shrink (down to 44 pt) on short screens
  /// instead of pushing the rows below the bottom edge.
  Widget _tonePad({bool withHide = false}) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return LayoutBuilder(builder: (context, box) {
      final hideH = withHide ? 44.0 : 0.0;
      final fromH = box.maxHeight.isFinite ? (box.maxHeight - 40 - hideH) / 4 - 12 : 64.0;
      final fromW = box.maxWidth.isFinite ? box.maxWidth / 3 - 16 : 64.0;
      final k = fromH < fromW ? fromH : fromW;
      final key = k > 72 ? 72.0 : (k < 44 ? 44.0 : k);
      return Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 34, child: FittedBox(fit: BoxFit.scaleDown, child: Text(_tones.isEmpty ? ' ' : _tones, style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 2)))),
        const SizedBox(height: 6),
        for (var r = 0; r < 4; r++)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var c = 0; c < 3; c++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: SizedBox(
                  width: key,
                  height: key,
                  child: Material(
                    color: Colors.white12,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () { Phone.instance.sendTone(keys[r * 3 + c]); setState(() => _tones += keys[r * 3 + c]); },
                      child: Center(child: Text(keys[r * 3 + c], style: TextStyle(color: Colors.white, fontSize: key * 0.4))),
                    ),
                  ),
                ),
              ),
          ]),
        if (withHide) TextButton(onPressed: () => setState(() => _keypad = false), style: TextButton.styleFrom(foregroundColor: Colors.white), child: const Text('Hide keypad')),
      ]);
    });
  }

  Widget _toggle(IconData icon, String label, bool on, VoidCallback? onTap) => Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 64,
          height: 64,
          child: Material(
            color: on ? Colors.white : Colors.white12,
            shape: const CircleBorder(),
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Icon(icon, color: on ? wocomDeep : (onTap == null ? Colors.white30 : Colors.white), size: 28)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: onTap == null ? Colors.white30 : Colors.white70, fontSize: 13)),
      ]);

  Widget _round(IconData icon, Color color, String label, VoidCallback onTap) => Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 76,
          height: 76,
          child: Material(color: color, shape: const CircleBorder(), child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Icon(icon, color: Colors.white, size: 34))),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ]);
}
