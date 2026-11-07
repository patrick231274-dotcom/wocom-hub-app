import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/arrival.dart';
import '../services/techhub.dart';
import '../theme.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
String _d(dynamic v, {bool weekday = true}) {
  final d = _date(v);
  return d == null ? '' : '${weekday ? '${_days[d.weekday - 1]} ' : ''}${d.day} ${_months[d.month - 1]}';
}
String _time(dynamic v) {
  var d = _date(v);
  if (d == null) return (v ?? '').toString();
  if (d.isUtc) d = d.toLocal();
  return '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}
String _range(Map l) {
  final a = _d(l['start_date']), b = _d(l['end_date']);
  return a == b ? a : '$a – $b';
}

(String, Color) _statusTone(String s) => switch (s) {
      'approved' => ('Approved', const Color(0xFF15803D)),
      'declined' => ('Declined', const Color(0xFFB91C1C)),
      'cancelled' => ('Cancelled', const Color(0xFF6B7280)),
      _ => ('Waiting for approval', const Color(0xFFB45309)),
    };

Widget _pill(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(t, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );

Widget _card(String title, Widget child, {Widget? trailing}) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: wocomMuted, letterSpacing: 0.4))),
          ?trailing,
        ]),
        const SizedBox(height: 8),
        child,
      ]),
    );

/// "My attendance": the year at a glance, late days, office arrivals and vacation (balance, request, status).
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});
  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  int _year = DateTime.now().year;
  Map<String, dynamic>? _a;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.leaveEvent.addListener(_load);
  }

  @override
  void dispose() {
    TechHub.instance.leaveEvent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final a = await TechHub.instance.myAttendance(_year);
      ArrivalCheck.instance.setOffice((a['settings'] as Map?)?['office']);
      if (mounted) setState(() { _a = a; _error = null; });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _request() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'First and last day of vacation',
      saveText: 'Next',
    );
    if (r == null || !mounted) return;
    final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Request vacation'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r.start == r.end ? _d(r.start.toIso8601String()) : '${_d(r.start.toIso8601String())} – ${_d(r.end.toIso8601String())}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Weekends and public holidays are not counted.', style: TextStyle(color: wocomMuted, fontSize: 12.5)),
        const SizedBox(height: 10),
        TextField(controller: note, minLines: 1, maxLines: 4, decoration: const InputDecoration(labelText: 'Note for your manager (optional)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send request')),
      ],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await TechHub.instance.requestLeave(r.start, r.end, note.text);
      final days = (res['leave'] as Map?)?['days'];
      _toast('Request sent${days != null ? ' ($days working day${days == 1 ? '' : 's'})' : ''}. Your manager has been told.');
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map l) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Cancel this vacation?'),
      content: Text(_range(l)),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel vacation'))],
    ));
    if (ok != true) return;
    try { await TechHub.instance.cancelLeave((l['id'] as num).toInt()); _toast('Cancelled.'); await _load(); }
    on ApiException catch (e) { _toast(e.message); }
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final s = Map<String, dynamic>.from((a?['summary'] as Map?) ?? {});
    final set = Map<String, dynamic>.from((a?['settings'] as Map?) ?? {});
    final arrivals = ((a?['arrivals'] as List?) ?? []).whereType<Map>().toList();
    final leave = ((a?['leave'] as List?) ?? []).whereType<Map>().toList();
    final late = ((s['late_list'] as List?) ?? []).whereType<Map>().toList();
    final byType = Map<String, dynamic>.from((s['absent_by_type'] as Map?) ?? {});
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(
        backgroundColor: wocomPlum, foregroundColor: Colors.white,
        title: const Text('My attendance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        actions: [
          PopupMenuButton<int>(
            initialValue: _year,
            onSelected: (y) { setState(() { _year = y; _a = null; }); _load(); },
            itemBuilder: (_) => [for (var y = now.year; y >= now.year - 2; y--) PopupMenuItem(value: y, child: Text('$y'))],
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Row(children: [Text('$_year', style: const TextStyle(fontWeight: FontWeight.w800)), const Icon(Icons.arrow_drop_down)])),
          ),
        ],
      ),
      floatingActionButton: a == null ? null : FloatingActionButton.extended(
        onPressed: _busy ? null : _request, backgroundColor: wocomDeep, foregroundColor: Colors.white,
        icon: const Icon(Icons.beach_access_outlined), label: const Text('Request vacation'),
      ),
      body: a == null
          ? Center(child: _error != null ? Text(_error!, textAlign: TextAlign.center) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: EdgeInsets.fromLTRB(14, 14, 14, 96 + MediaQuery.of(context).viewPadding.bottom), children: [
                // ── summary cards
                GridView.count(
                  crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.9,
                  children: [
                    _stat('${s['vacation_left'] ?? '–'}', 'vacation days left', 'of ${s['vacation_allowance'] ?? '–'}', const Color(0xFF2563EB)),
                    _stat('${s['absent_days'] ?? 0}', 'days absent', [
                      if ((byType['sick'] ?? 0) != 0) '${byType['sick']} sick',
                      if ((byType['day_off'] ?? 0) != 0) '${byType['day_off']} day off',
                      if ((byType['emergency'] ?? 0) != 0) '${byType['emergency']} emergency',
                      if ((byType['other'] ?? 0) != 0) '${byType['other']} other',
                    ].join(' · '), const Color(0xFFDC2626)),
                    _stat('${s['late_days'] ?? 0}', 'late days', 'start ${set['work_start'] ?? '8:30'} + ${set['grace_min'] ?? 10} min', const Color(0xFFEA580C)),
                    _stat('${s['avg_arrival'] ?? '–'}', 'average arrival', '${s['arrival_days'] ?? 0} days logged', const Color(0xFF15803D)),
                  ],
                ),
                const SizedBox(height: 12),
                // ── vacation
                _card('Vacation $_year', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(spacing: 14, runSpacing: 4, children: [
                    Text('Taken ${s['vacation_taken'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('Booked ${s['vacation_booked'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('Waiting ${s['vacation_pending'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('Left ${s['vacation_left'] ?? '–'}', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF2563EB))),
                  ]),
                  if (leave.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No vacation requests yet.', style: TextStyle(color: wocomMuted))),
                  for (final l in leave) _leaveRow(l),
                ])),
                // ── late days
                _card('Late days (${late.length})', late.isEmpty
                    ? const Text('None this year. Well done!', style: TextStyle(color: wocomMuted))
                    : Column(children: [
                        for (final x in late)
                          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
                            Expanded(child: Text(_d(x['date']), style: const TextStyle(fontWeight: FontWeight.w700))),
                            Text(x['how'] == 'reported' ? 'Reported late${(x['time'] ?? '').toString().isNotEmpty ? ' · ${_time(x['time'])}' : ''}' : 'Arrived ${_time(x['time'])}', style: const TextStyle(color: wocomMuted)),
                          ])),
                      ])),
                // ── arrivals
                _card('Office arrivals', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Logged automatically when your phone is at the office in the morning. Used for your arrival time only.', style: TextStyle(color: wocomMuted, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  if (arrivals.isEmpty) const Text('No arrivals logged yet.', style: TextStyle(color: wocomMuted)),
                  for (final x in arrivals)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
                      Icon(x['late'] == true ? Icons.schedule : Icons.check_circle_outline, size: 18, color: x['late'] == true ? const Color(0xFFEA580C) : const Color(0xFF15803D)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_d(x['date']), style: const TextStyle(fontWeight: FontWeight.w700))),
                      Text(_time(x['arrived_at']), style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (x['late'] == true) Padding(padding: const EdgeInsets.only(left: 6), child: _pill('${x['late_min'] ?? ''} min late', const Color(0xFFEA580C))),
                      if (x['source'] == 'manual') const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.edit_note, size: 18, color: wocomMuted)),
                    ])),
                ])),
              ]),
            ),
    );
  }

  Widget _stat(String big, String label, String sub, Color c) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          FittedBox(child: Text(big, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: c))),
          Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: c, fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (sub.isNotEmpty) Text(sub, style: const TextStyle(color: wocomMuted, fontSize: 11.5), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );

  Widget _leaveRow(Map l) {
    final (label, c) = _statusTone((l['status'] ?? '').toString());
    final start = _date(l['start_date']);
    final today = DateTime.now();
    final canCancel = l['status'] == 'pending' || (l['status'] == 'approved' && start != null && start.isAfter(DateTime(today.year, today.month, today.day)));
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${_range(l)} · ${l['days'] ?? '?'} day${l['days'] == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800))),
          _pill(label, c),
        ]),
        if ((l['note'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(l['note'].toString(), style: const TextStyle(color: wocomMuted))),
        if ((l['decided_by'] ?? '').toString().isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 3), child: Text('${label == 'Declined' ? 'Declined' : 'Decided'} by ${l['decided_by']}${(l['decision_note'] ?? '').toString().isNotEmpty ? ': "${l['decision_note']}"' : ''}', style: const TextStyle(fontSize: 12.5))),
        if (canCancel) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _cancel(l), child: const Text('Cancel'))),
      ]),
    );
  }
}

/// Leads: vacation requests waiting for a decision (and recent ones).
class LeaveRequestsScreen extends StatefulWidget {
  const LeaveRequestsScreen({super.key});
  @override
  State<LeaveRequestsScreen> createState() => _LeaveRequestsScreenState();
}

class _LeaveRequestsScreenState extends State<LeaveRequestsScreen> {
  String _status = 'pending';
  List<Map<String, dynamic>>? _l;
  String? _error;
  final _busy = <int>{};

  @override
  void initState() { super.initState(); _load(); TechHub.instance.leaveEvent.addListener(_load); }
  @override
  void dispose() { TechHub.instance.leaveEvent.removeListener(_load); super.dispose(); }

  Future<void> _load() async {
    try { final l = await TechHub.instance.teamLeave(_status); if (mounted) setState(() { _l = l; _error = null; }); }
    on ApiException catch (e) { if (mounted) setState(() => _error = e.message); }
  }

  Future<void> _decide(Map l, bool approve) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('${approve ? 'Approve' : 'Decline'} ${l['name'] ?? ''}?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_range(l)} · ${l['days']} day${l['days'] == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(controller: note, minLines: 1, maxLines: 3, decoration: InputDecoration(labelText: approve ? 'Note (optional)' : 'Reason (optional)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Back')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: approve ? const Color(0xFF15803D) : const Color(0xFFB91C1C)), onPressed: () => Navigator.pop(c, true), child: Text(approve ? 'Approve' : 'Decline')),
      ],
    ));
    if (ok != true) return;
    final id = (l['id'] as num).toInt();
    setState(() => _busy.add(id));
    try {
      await TechHub.instance.decideLeave(id, approve, note.text);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(approve ? 'Approved. ${l['name'] ?? 'They'} has been told.' : 'Declined. ${l['name'] ?? 'They'} has been told.')));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Vacation requests', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'pending', label: Text('Waiting')), ButtonSegment(value: 'all', label: Text('All'))],
            selected: {_status},
            onSelectionChanged: (v) { setState(() { _status = v.first; _l = null; }); _load(); },
          ),
        ),
        Expanded(child: l == null
            ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)) : const CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: l.isEmpty
                    ? ListView(children: [const SizedBox(height: 80), Center(child: Text(_status == 'pending' ? 'No requests waiting.' : 'No vacation requests.', style: const TextStyle(color: wocomMuted)))])
                    : ListView(padding: EdgeInsets.fromLTRB(14, 8, 14, 24 + MediaQuery.of(context).viewPadding.bottom), children: [
                        for (final x in l) _row(x),
                      ]),
              )),
      ]),
    );
  }

  Widget _row(Map x) {
    final (label, c) = _statusTone((x['status'] ?? '').toString());
    final id = (x['id'] as num).toInt();
    final left = x['days_left_after'];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text((x['name'] ?? '').toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
          _pill(label, c),
        ]),
        const SizedBox(height: 4),
        Text('${_range(x)} · ${x['days']} working day${x['days'] == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w700)),
        if (left != null) Text('$left day${left == 1 ? '' : 's'} left after this', style: TextStyle(color: (left is num && left < 0) ? const Color(0xFFB91C1C) : wocomMuted)),
        if ((x['note'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('"${x['note']}"', style: const TextStyle(fontStyle: FontStyle.italic))),
        if ((x['decided_by'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('By ${x['decided_by']}${(x['decision_note'] ?? '').toString().isNotEmpty ? ': "${x['decision_note']}"' : ''}', style: const TextStyle(fontSize: 12.5, color: wocomMuted))),
        if (x['status'] == 'pending') ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _busy.contains(id) ? null : () => _decide(x, false), style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C)), child: const Text('Decline'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton(onPressed: _busy.contains(id) ? null : () => _decide(x, true), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF15803D)), child: const Text('Approve'))),
          ]),
        ],
      ]),
    );
  }
}
