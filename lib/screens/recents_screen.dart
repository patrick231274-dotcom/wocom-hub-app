import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/hub.dart';
import '../services/names.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../services/voicemail.dart';
import '../services/dial_plan.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';

/// Calls on my extension (from the phone system, so every device's calls show) and voicemail.
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({super.key, required this.onAvatarTap});

  final VoidCallback onAvatarTap;

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  int _view = 0; // 0 all, 1 missed, 2 voicemail
  List<Map<String, dynamic>> _calls = [];
  List<Map<String, dynamic>> _vm = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    Hub.instance.callsEvent.addListener(_load); // a call just ended: show it
  }

  @override
  void dispose() {
    Hub.instance.callsEvent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Session.instance.api.get('recents');
      setState(() {
        _calls = ((r['calls'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _vm = ((r['voicemail'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _callBack(String number) async {
    if (number.isEmpty) return;
    if (await Phone.instance.dial(number) && mounted) {
      // The call window opens by itself once the call exists (see main.dart).
    }
  }

  @override
  Widget build(BuildContext context) {
    final missed = _calls.where((c) => c['kind'] == 'missed').toList();
    final newVm = _vm.where((v) => v['new'] == true).length;
    return Column(children: [
      AnimatedBuilder(
        animation: Hub.instance,
        builder: (context, _) => BrandHeader(
          title: 'Recents',
          onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
            onAvatarTap: widget.onAvatarTap,
          myStatus: Hub.instance.myStatus,
          bottom: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              _seg(0, 'All calls'),
              _seg(1, missed.isEmpty ? 'Missed' : 'Missed · ${missed.length}'),
              _seg(2, newVm == 0 ? 'Voicemail' : 'Voicemail · $newVm'),
            ]),
          ),
        ),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                : RefreshIndicator(onRefresh: _load, child: _view == 2 ? _voicemail() : _callList(_view == 1 ? missed : _calls)),
      ),
    ]);
  }

  Widget _seg(int i, String label) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _view = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _view == i ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: _view == i ? FontWeight.w800 : FontWeight.w600, color: _view == i ? wocomDeep : wocomTintLight)),
          ),
        ),
      );

  Widget _callList(List<Map<String, dynamic>> list) {
    if (list.isEmpty) return ListView(children: const [SizedBox(height: 80), EmptyState(icon: Icons.history, text: 'No calls here yet.')]);
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[i];
        final kind = c['kind'] as String;
        final title = ((c['name'] as String).isNotEmpty ? c['name'] as String : null) ?? Names.instance.lookup(c['number'] as String) ?? c['number'] as String;
        final (icon, tint, bg, label) = switch (kind) {
          'missed' => (Icons.call_missed, const Color(0xFFB91C1C), const Color(0xFFFDE7E7), 'Missed'),
          'outgoing' => (Icons.call_made, const Color(0xFF4A4256), wocomLine, 'Outgoing'),
          'voicemail' => (Icons.voicemail, wocomDeep, wocomSoft, 'Voicemail'),
          _ => (Icons.call_received, const Color(0xFF4A4256), wocomLine, 'Incoming'),
        };
        final secs = c['seconds'] as int;
        return ListTile(
          leading: CircleAvatar(backgroundColor: bg, child: Icon(icon, color: tint, size: 20)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: kind == 'missed' ? const Color(0xFFB91C1C) : null)),
          subtitle: Text('$label${title != c['number'] ? ' · ${c['number']}' : ''}${secs > 0 ? ' · ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}' : ''}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(timeAgoLabel(DateTime.parse(c['at'] as String)), style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B6478))),
            const SizedBox(width: 6),
            SoftIconButton(icon: Icons.call, label: 'Call back', onTap: () => _callBack(c['number'] as String)),
          ]),
        );
      },
    );
  }

  Widget _voicemail() {
    if (_vm.isEmpty) return ListView(children: const [SizedBox(height: 80), EmptyState(icon: Icons.voicemail, text: 'No voicemail.')]);
    return AnimatedBuilder(
      animation: Voicemail.instance,
      builder: (context, _) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        itemCount: _vm.length,
        itemBuilder: (context, i) => _VoicemailTile(
          v: _vm[i],
          onCallBack: () => _callBack(_vm[i]['number'] as String),
          onHeard: () => setState(() => _vm[i]['new'] = false),
          onDeleted: () => setState(() => _vm.removeAt(i)),
        ),
      ),
    );
  }
}

/// One voicemail: caller, when, length, transcript, and an inline player once tapped.
class _VoicemailTile extends StatelessWidget {
  const _VoicemailTile({required this.v, required this.onCallBack, required this.onHeard, required this.onDeleted});
  final Map<String, dynamic> v;
  final VoidCallback onCallBack;
  final VoidCallback onHeard;
  final VoidCallback onDeleted;

  static String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _delete(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this voicemail?'),
        content: const Text('It is removed from the phone system and every device.', style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final err = await Voicemail.instance.delete(v['id'] as String);
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      onDeleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = Voicemail.instance;
    final id = v['id'] as String;
    final secs = v['seconds'] as int;
    final isNew = v['new'] == true;
    final name = (v['name'] as String).isNotEmpty ? v['name'] as String : prettyNumber(v['number'] as String);
    final active = vm.current == id;
    final transcript = (v['transcript'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: active ? wocomPurple : isNew ? wocomTint : wocomLine, width: active ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          if (active && vm.playing) {
            vm.pause();
          } else {
            final ok = await vm.play(id);
            if (ok && isNew) onHeard();
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              // Play / pause button
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: active ? wocomDeep : wocomSoft, shape: BoxShape.circle),
                child: active && vm.loading
                    ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : Icon(active && vm.playing ? Icons.pause : Icons.play_arrow, color: active ? Colors.white : wocomDeep, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (isNew) Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 6), decoration: const BoxDecoration(color: wocomPurple, shape: BoxShape.circle)),
                    Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: isNew ? FontWeight.w800 : FontWeight.w700, fontSize: 15, color: wocomInk))),
                  ]),
                  const SizedBox(height: 2),
                  Text('${timeAgoLabel(DateTime.parse(v['at'] as String))} · ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
                ]),
              ),
              IconButton(tooltip: 'Call back', icon: const Icon(Icons.call_outlined, color: wocomDeep), onPressed: onCallBack),
              IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: Color(0xFF8A8299)), onPressed: () => _delete(context)),
            ]),
            if (active && !vm.loading) ...[
              const SizedBox(height: 4),
              StreamBuilder<Duration>(
                stream: vm.positions,
                builder: (context, snap) {
                  final total = vm.duration ?? Duration(seconds: secs);
                  final pos = snap.data ?? Duration.zero;
                  final max = total.inMilliseconds <= 0 ? 1.0 : total.inMilliseconds.toDouble();
                  return Row(children: [
                    Text(_fmt(pos), style: const TextStyle(fontSize: 11.5, color: wocomMuted, fontFeatures: [FontFeature.tabularFigures()])),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7), overlayShape: const RoundSliderOverlayShape(overlayRadius: 14), activeTrackColor: wocomDeep, inactiveTrackColor: wocomLine, thumbColor: wocomDeep),
                        child: Slider(value: pos.inMilliseconds.clamp(0, max.toInt()).toDouble(), max: max, onChanged: (x) => vm.seek(Duration(milliseconds: x.toInt()))),
                      ),
                    ),
                    Text(_fmt(total), style: const TextStyle(fontSize: 11.5, color: wocomMuted, fontFeatures: [FontFeature.tabularFigures()])),
                  ]);
                },
              ),
            ],
            if (active && vm.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(vm.error!, style: const TextStyle(fontSize: 12.5, color: Color(0xFFB91C1C)))),
            if (transcript.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                decoration: BoxDecoration(color: wocomBg, borderRadius: BorderRadius.circular(12)),
                child: Text(transcript, style: const TextStyle(fontSize: 13.5, height: 1.45, color: wocomInk)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
