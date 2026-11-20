// WE App: speak a ticket update instead of typing it. Record (max 2 min) → Tech Hub turns it into a tidy
// update (speech-to-text + rewrite) → the text lands in the normal box for the engineer to check and edit.
// Nothing is ever submitted automatically. Words the AI was unsure of come back as [❓word] and must be
// fixed or confirmed before the update can be saved (see [VoiceTextController.unsure]).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';

/// Text controller that highlights [❓word] markers so they stand out in the box.
class VoiceTextController extends TextEditingController {
  static final marker = RegExp(r'\[❓([^\]]*)\]');

  /// Words still marked as unsure; Save stays blocked until this is empty.
  List<String> get unsure => marker.allMatches(text).map((m) => m.group(1)!.trim()).toList();

  /// "That word is right": drop the marker, keep the word.
  void confirm(String word) {
    final i = text.indexOf('[❓$word]');
    if (i < 0) return;
    value = TextEditingValue(text: text.replaceRange(i, i + word.length + 3, word), selection: TextSelection.collapsed(offset: i + word.length));
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!text.contains('[❓')) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in marker.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(TextSpan(text: m.group(0), style: const TextStyle(backgroundColor: Color(0xFFFDE68A), color: Color(0xFF92400E), fontWeight: FontWeight.w700)));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}

/// Mic button + state for one update box. [target] tells Tech Hub which tone to write in:
/// 'client' (emailed to the customer) or 'internal' (staff note).
class VoiceNote extends StatefulWidget {
  const VoiceNote({super.key, required this.number, required this.controller, required this.target});
  final String number;
  final VoiceTextController controller;
  final String target;

  @override
  State<VoiceNote> createState() => _VoiceNoteState();
}

enum _Stage { idle, recording, working, failed }

class _VoiceNoteState extends State<VoiceNote> {
  static const maxSeconds = 120;
  _Stage _stage = _Stage.idle;
  AudioRecorder? _rec;
  String? _path; // kept after a failure so "Try again" needs no new recording
  DateTime? _started;
  Timer? _tick;
  String? _transcript;
  bool _showRaw = false;
  String? _failure;
  Map<String, dynamic>? _suggest;

  @override
  void dispose() {
    _tick?.cancel();
    _rec?.dispose();
    _discard();
    super.dispose();
  }

  void _discard() {
    final p = _path;
    _path = null;
    if (p != null) { try { File(p).deleteSync(); } catch (_) {} }
  }

  void _toast(String t) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t))); }

  Future<bool> _micAllowed() async {
    if (await Permission.microphone.isGranted) return true;
    if (!mounted) return false;
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      icon: const Icon(Icons.mic_none, size: 36),
      title: const Text('Speak your update'),
      content: const Text('WE App needs the microphone to record your update. The recording goes to Tech Hub, '
          'is turned into text for you to check, and is deleted straight after. Nothing is sent to the client until you tap Save.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Continue')),
      ],
    ));
    if (go != true) return false;
    final s = await Permission.microphone.request();
    if (!s.isGranted) _toast('Microphone is off for WE App. You can switch it on in Settings › Apps › WE App › Permissions.');
    return s.isGranted;
  }

  Future<void> _start() async {
    if (!await _micAllowed()) return;
    _discard();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/ticket-voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    final rec = _rec ??= AudioRecorder();
    try {
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 16000, numChannels: 1), path: path);
    } catch (e) {
      _toast("Couldn't start recording: $e");
      return;
    }
    _path = path;
    _started = DateTime.now();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (DateTime.now().difference(_started!).inSeconds >= maxSeconds) { _stop(); return; }
      setState(() {});
    });
    setState(() { _stage = _Stage.recording; _failure = null; });
  }

  Future<void> _stop() async {
    _tick?.cancel();
    String? done;
    try { done = await _rec?.stop(); } catch (_) {}
    final secs = DateTime.now().difference(_started ?? DateTime.now()).inSeconds;
    if (done == null || secs < 1) {
      _discard();
      if (mounted) setState(() => _stage = _Stage.idle);
      _toast('That was too short. Tap the mic and speak your update.');
      return;
    }
    await _send();
  }

  Future<void> _cancelRecording() async {
    _tick?.cancel();
    try { await _rec?.stop(); } catch (_) {}
    _discard();
    if (mounted) setState(() => _stage = _Stage.idle);
  }

  Future<void> _send() async {
    final p = _path;
    if (p == null) return;
    setState(() { _stage = _Stage.working; _failure = null; });
    try {
      final r = await TechHub.instance.voiceNote(widget.number, p, widget.target);
      final text = (r['rewritten'] ?? '').toString().trim();
      if (text.isEmpty) throw ApiException('empty', "We couldn't make out any words. Try again closer to the phone.", 0);
      final c = widget.controller;
      // Add to what is already typed, never replace it.
      c.text = c.text.trim().isEmpty ? text : '${c.text.trim()}\n$text';
      c.selection = TextSelection.collapsed(offset: c.text.length);
      _transcript = (r['transcript'] ?? '').toString();
      _suggest = r['suggestions'] is Map ? Map<String, dynamic>.from(r['suggestions'] as Map) : null;
      _discard();
      if (mounted) setState(() => _stage = _Stage.idle);
    } on ApiException catch (e) {
      if (mounted) setState(() { _stage = _Stage.failed; _failure = e.message; });
    }
  }

  void _typeInstead() {
    _discard();
    setState(() { _stage = _Stage.idle; _failure = null; });
  }

  String get _clock {
    final s = DateTime.now().difference(_started ?? DateTime.now()).inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} / 2:00';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final unsure = c.unsure;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          switch (_stage) {
            _Stage.idle => Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: _start, icon: const Icon(Icons.mic_none), label: Text(widget.target == 'client' ? 'Speak the client update' : 'Speak the note')),
              ),
            _Stage.recording => Row(children: [
                const Icon(Icons.fiber_manual_record, color: Color(0xFFDC2626), size: 16),
                const SizedBox(width: 6),
                Text('Recording  $_clock', style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                const Spacer(),
                TextButton(onPressed: _cancelRecording, child: const Text('Cancel')),
                FilledButton.icon(onPressed: _stop, style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)), icon: const Icon(Icons.stop), label: const Text('Done')),
              ]),
            _Stage.working => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10), Text('Tidying up…', style: TextStyle(fontWeight: FontWeight.w700))]),
              ),
            _Stage.failed => Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(_failure ?? "Couldn't turn your recording into text.", style: const TextStyle(color: Color(0xFF991B1B))),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(onPressed: _typeInstead, child: const Text('Type instead')),
                    FilledButton(onPressed: _send, child: const Text('Try again')),
                  ]),
                ]),
              ),
          },
          if (unsure.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Check ${unsure.length == 1 ? 'this word' : 'these words'}: fix ${unsure.length == 1 ? 'it' : 'them'} in the box, or tap to confirm.',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF92400E), fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final w in unsure.toSet())
                ActionChip(
                  avatar: const Icon(Icons.check, size: 16),
                  label: Text(w.isEmpty ? '(blank)' : w),
                  backgroundColor: const Color(0xFFFEF3C7),
                  onPressed: () => c.confirm(w),
                ),
            ]),
          ],
          if (_suggest != null && (_suggest!['status_label'] ?? _suggest!['follow_up'] ?? _suggest!['parts']) != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text([
                if ((_suggest!['status_label'] ?? '').toString().isNotEmpty) 'Suggested status: ${_suggest!['status_label']}',
                if (_suggest!['parts'] is List && (_suggest!['parts'] as List).isNotEmpty) 'Parts: ${(_suggest!['parts'] as List).join(', ')}',
                if ((_suggest!['follow_up'] ?? '').toString().isNotEmpty) 'Follow-up: ${_suggest!['follow_up']}',
              ].join(' · '), style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
            ),
          if ((_transcript ?? '').isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => setState(() => _showRaw = !_showRaw), child: Text(_showRaw ? 'Hide what I said' : 'Show what I said')),
            ),
            if (_showRaw)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(12)),
                child: SelectableText(_transcript!, style: const TextStyle(fontSize: 13.5, height: 1.4)),
              ),
          ],
        ]);
      },
    );
  }
}
