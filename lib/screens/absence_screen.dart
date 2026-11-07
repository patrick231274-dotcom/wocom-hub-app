import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';

/// "Report absence / running late": tells Tech Hub, which offers the person's scheduled work
/// for that time to the rest of the team and lets supervisors see who is out.
class AbsenceScreen extends StatefulWidget {
  const AbsenceScreen({super.key});
  @override
  State<AbsenceScreen> createState() => _AbsenceScreenState();
}

class _AbsenceScreenState extends State<AbsenceScreen> {
  static const _types = [
    ('sick', 'I\'m sick', Icons.sick_outlined, Color(0xFFDC2626)),
    ('late', 'Running late', Icons.schedule, Color(0xFFEA580C)),
    ('day_off', 'Day off', Icons.beach_access_outlined, Color(0xFF2563EB)),
    ('emergency', 'Emergency', Icons.warning_amber_rounded, Color(0xFF7C2D12)),
    ('other', 'Other', Icons.more_horiz, Color(0xFF4B5563)),
  ];
  String? _type;
  String _span = 'today'; // today | tomorrow | range
  DateTimeRange? _range;
  TimeOfDay? _eta;
  final _note = TextEditingController();
  bool _busy = false;
  List<Map<String, dynamic>> _mine = [];

  @override
  void initState() { super.initState(); _loadMine(); }

  Future<void> _loadMine() async {
    try { final l = await TechHub.instance.myAbsences(); if (mounted) setState(() => _mine = l); } catch (_) {}
  }

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _submit() async {
    if (_type == null) return;
    final now = DateTime.now();
    DateTime from = now;
    DateTime? to;
    DateTime? eta;
    if (_type == 'late') {
      if (_eta == null) { _toast('Pick the time you expect to arrive.'); return; }
      eta = DateTime(now.year, now.month, now.day, _eta!.hour, _eta!.minute);
      to = eta;
    } else if (_span == 'tomorrow') {
      from = _startOfDay(now.add(const Duration(days: 1)));
      to = from.add(const Duration(hours: 23, minutes: 59));
    } else if (_span == 'range') {
      if (_range == null) { _toast('Pick the days you will be out.'); return; }
      from = _startOfDay(_range!.start).isBefore(now) ? now : _startOfDay(_range!.start);
      to = _startOfDay(_range!.end).add(const Duration(hours: 23, minutes: 59));
    }
    setState(() => _busy = true);
    try {
      final r = await TechHub.instance.reportAbsence(type: _type!, from: from, to: to, eta: eta, note: _note.text);
      final affected = (r['affected'] as List?)?.whereType<Map>().toList() ?? [];
      if (!mounted) return;
      await showDialog(context: context, builder: (c) => AlertDialog(
        title: const Text('Sent to Tech Hub'),
        content: Text(affected.isEmpty
            ? 'Your supervisor can see it. You had no jobs scheduled in that time.'
            : 'Your supervisor can see it. These ${affected.length} job${affected.length == 1 ? '' : 's'} have been offered to the team:\n\n${affected.map((a) => '• ${a['ticket_number']} · ${a['client_name'] ?? a['subject'] ?? ''}').join('\n')}'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ));
      setState(() { _type = null; _note.clear(); _eta = null; _range = null; _span = 'today'; });
      _loadMine();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))); }

  String _fmt(dynamic iso) {
    final d = DateTime.tryParse((iso ?? '').toString())?.toLocal();
    if (d == null) return '';
    return '${d.day}/${d.month} ${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final late = _type == 'late';
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FB),
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Absence / running late')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('What is happening?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.3,
          children: [
            for (final t in _types)
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _type = t.$1),
                child: Container(
                  decoration: BoxDecoration(
                    color: _type == t.$1 ? t.$4.withValues(alpha: 0.12) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _type == t.$1 ? t.$4 : wocomLine, width: _type == t.$1 ? 2 : 1),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(t.$3, color: t.$4),
                    const SizedBox(width: 8),
                    Text(t.$2, style: TextStyle(fontWeight: FontWeight.w800, color: t.$4, fontSize: 15)),
                  ]),
                ),
              ),
          ],
        ),
        if (_type != null) ...[
          const SizedBox(height: 18),
          if (late) ...[
            const Text('When will you get in?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () async { final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)))); if (t != null) setState(() => _eta = t); },
              icon: const Icon(Icons.schedule),
              label: Text(_eta == null ? 'Pick arrival time' : 'Arriving about ${_eta!.format(context)}', style: const TextStyle(fontSize: 16)),
            ),
          ] else ...[
            const Text('For how long?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('Today'), selected: _span == 'today', onSelected: (_) => setState(() => _span = 'today')),
              ChoiceChip(label: const Text('Tomorrow'), selected: _span == 'tomorrow', onSelected: (_) => setState(() => _span = 'tomorrow')),
              ChoiceChip(
                label: Text(_range == null ? 'Pick days' : '${_range!.start.day}/${_range!.start.month} – ${_range!.end.day}/${_range!.end.month}'),
                selected: _span == 'range',
                onSelected: (_) async {
                  final now = DateTime.now();
                  final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 120)));
                  if (r != null) setState(() { _range = r; _span = 'range'; });
                },
              ),
            ]),
          ],
          const SizedBox(height: 14),
          TextField(controller: _note, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Note for your supervisor (optional)', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), backgroundColor: wocomDeep),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Sending…' : 'Send to Tech Hub', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 6),
          const Text('Your supervisor is told, and any jobs you had in that time are offered to the team.', style: TextStyle(color: wocomMuted, fontSize: 13)),
        ],
        if (_mine.isNotEmpty) ...[
          const SizedBox(height: 26),
          const Text('YOUR REPORTED ABSENCES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: wocomMuted, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          for (final a in _mine)
            Card(
              child: ListTile(
                title: Text(_types.firstWhere((t) => t.$1 == a['type'], orElse: () => _types.last).$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(a['type'] == 'late' ? 'Arriving ${_fmt(a['eta'])}' : '${_fmt(a['from'])}${a['to'] != null ? ' → ${_fmt(a['to'])}' : ' (rest of day)'}'),
                trailing: TextButton(
                  onPressed: () async {
                    try { await TechHub.instance.cancelAbsence((a['id'] as num).toInt()); _toast('Cancelled. Welcome back!'); _loadMine(); }
                    on ApiException catch (e) { _toast(e.message); }
                  },
                  child: const Text("I'm in after all"),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}
