import 'dart:async';

import 'package:flutter/material.dart';

import '../services/dial_plan.dart';
import '../services/hub.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';

/// Pulse: the company's call picture for Hub administrators. Today / week / month tiles,
/// calls by hour or by day, trend against the previous period, and missed callers to recover.
class PulseScreen extends StatefulWidget {
  const PulseScreen({super.key, required this.onAvatarTap});

  final VoidCallback onAvatarTap;

  /// Hub administrators only (domain_admin, supervisor, superadmin, or a WOCOM role).
  static bool get allowed {
    final r = (Session.instance.user?['role'] ?? '').toString();
    return r == 'domain_admin' || r == 'supervisor' || r == 'superadmin';
  }

  @override
  State<PulseScreen> createState() => _PulseScreenState();
}

class _PulseScreenState extends State<PulseScreen> {
  String _range = 'today';
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    Hub.instance.callsEvent.addListener(_load);
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    Hub.instance.callsEvent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && _data == null) setState(() => _loading = true);
    try {
      final r = await Session.instance.api.get('pulse', {'range': _range});
      if (!mounted) return;
      setState(() { _data = r; _loading = false; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; if (_data == null) _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  void _setRange(String r) { if (_range == r) return; setState(() { _range = r; _loading = true; }); _load(); }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final open = (d?['open_missed'] as num?)?.toInt() ?? 0;
    return Column(children: [
      AnimatedBuilder(
        animation: Hub.instance,
        builder: (context, _) => BrandHeader(
          title: 'Pulse',
          subtitle: d == null ? null : '${d['company']} · live',
          onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
          onAvatarTap: widget.onAvatarTap,
          myStatus: Hub.instance.myStatus,
          bottom: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [_seg('today', 'Today'), _seg('week', 'This week'), _seg('month', 'This month')]),
            ),
            if (d != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                _tile('${d['tiles']['received']}', 'RECEIVED'),
                const SizedBox(width: 8),
                _tile('${d['tiles']['answered']}', 'ANSWERED'),
                const SizedBox(width: 8),
                _tile('${d['tiles']['missed']}', 'MISSED', amber: true),
                const SizedBox(width: 8),
                _tile('${d['tiles']['in_queue']}', 'IN QUEUE'),
              ]),
            ],
          ]),
        ),
      ),
      Expanded(
        child: _loading && d == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && d == null
                ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                : RefreshIndicator(
                    onRefresh: () => _load(quiet: true),
                    child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: [
                      _chartCard(d!),
                      const SizedBox(height: 12),
                      _missedCard(d, open),
                      const SizedBox(height: 12),
                      _trendRow(d),
                    ]),
                  ),
      ),
    ]);
  }

  Widget _seg(String key, String label) {
    final on = _range == key;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setRange(key),
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Text(label, style: TextStyle(color: on ? wocomPlum : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _tile(String value, String label, {bool amber = false}) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(color: amber ? const Color(0xFFFFF4DB) : Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Text(value, style: TextStyle(color: amber ? const Color(0xFF92400E) : Colors.white, fontSize: 22, fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()])),
            Text(label, style: TextStyle(color: amber ? const Color(0xFFB45309) : const Color(0xFFEDE4FF), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
          ]),
        ),
      );

  BoxDecoration get _card => BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(16));

  Widget _chartCard(Map<String, dynamic> d) {
    final series = (d['series'] as List?)?.cast<Map>() ?? [];
    final peak = d['peak'] as Map?;
    final maxCalls = series.fold<int>(0, (m, s) => (s['calls'] as num).toInt() > m ? (s['calls'] as num).toInt() : m);
    final title = _range == 'today' ? 'Calls by hour' : 'Calls by day';
    final peakText = peak == null ? 'no calls yet' : (_range == 'today' ? 'peak ${peak['label']} · ${peak['calls']} calls' : 'busiest ${peak['label']} · ${peak['calls']} calls');
    final labelEvery = series.length > 14 ? 5 : (series.length > 8 ? 2 : 1);
    return Container(
      decoration: _card,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text(peakText, style: const TextStyle(fontSize: 11.5, color: Color(0xFF5B5470), fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 90,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < series.length; i++) ...[
              Expanded(child: _bar((series[i]['calls'] as num).toInt(), (series[i]['missed'] as num).toInt(), maxCalls, peak != null && series[i]['label'] == peak['label'], '${series[i]['label']} · ${series[i]['calls']} calls, ${series[i]['missed']} missed')),
              if (i < series.length - 1) SizedBox(width: series.length > 14 ? 2 : 4),
            ],
          ]),
        ),
        const SizedBox(height: 4),
        Row(children: [
          for (var i = 0; i < series.length; i++) ...[
            Expanded(child: Text(i % labelEvery == 0 ? '${series[i]['label']}' : '', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.visible, softWrap: false, style: const TextStyle(fontSize: 9, color: Color(0xFF8A8299), fontWeight: FontWeight.w600))),
            if (i < series.length - 1) SizedBox(width: series.length > 14 ? 2 : 4),
          ],
        ]),
        const SizedBox(height: 6),
        const Row(children: [
          _Key(color: wocomPlum, label: 'Answered'),
          SizedBox(width: 12),
          _Key(color: Color(0xFFF59E0B), label: 'Missed'),
        ]),
      ]),
    );
  }

  Widget _bar(int calls, int missed, int max, bool peak, String tip) {
    if (calls == 0) return Container(height: 3, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(2)));
    final h = 6 + 84 * calls / (max == 0 ? 1 : max);
    final mh = h * missed / calls;
    return Tooltip(
      message: tip,
      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          child: SizedBox(
            height: h,
            child: Column(children: [
              Expanded(child: Container(color: peak ? wocomPlum : const Color(0xFFC4A6FF))),
              if (mh > 0) SizedBox(height: mh, child: Container(color: const Color(0xFFF59E0B))),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _missedCard(Map<String, dynamic> d, int open) {
    final missed = (d['missed'] as List?)?.cast<Map>() ?? [];
    return Container(
      decoration: _card,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(children: [
            const Text('Missed calls to recover', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: open > 0 ? const Color(0xFFFFF4DB) : const Color(0xFFE7F6EC), borderRadius: BorderRadius.circular(10)),
              child: Text(open > 0 ? '$open waiting' : 'all handled', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: open > 0 ? const Color(0xFFB45309) : const Color(0xFF15803D))),
            ),
          ]),
        ),
        if (missed.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(14, 6, 14, 18), child: Text('No missed calls from outside in this period.', style: TextStyle(fontSize: 12.5, color: Color(0xFF8A8299)))),
        for (final m in missed) _missedRow(m),
        if (missed.isNotEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(14, 10, 14, 12), child: Text('Tap a caller for call back, assign and mark handled. A caller who rang several lines shows once.', style: TextStyle(fontSize: 11.5, color: Color(0xFF8A8299), height: 1.4))),
      ]),
    );
  }

  Widget _missedRow(Map m) {
    final handled = m['handled'] == true;
    final number = (m['number'] ?? '').toString();
    final name = (m['name'] ?? '').toString();
    final pretty = prettyNumber(number);
    final title = name.isEmpty || name == number || name.replaceAll(RegExp(r'\D'), '') == number ? pretty : '$name · $pretty';
    final at = DateTime.tryParse((m['last_at'] ?? '').toString())?.toLocal();
    final when = at == null ? '' : (_range == 'today' ? _hm(at) : '${_dayName(at)} ${_hm(at)}');
    final lines = ((m['lines'] as List?) ?? []).join(', ');
    final attempts = (m['attempts'] as num?)?.toInt() ?? 1;
    final sub = handled
        ? '$when · ${m['handled_by'] == 'called back' ? 'called back' : 'handled by ${m['handled_by'] ?? 'someone'}'}'
        : [when, if (lines.isNotEmpty) 'rang $lines', if (attempts > 1) '$attempts attempts', if (m['assigned_to'] != null) 'assigned to ${m['assigned_to']}'].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _actions(m),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF1EDF7)))),
          child: Opacity(
            opacity: handled ? 0.55 : 1,
            child: Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(color: handled ? const Color(0xFFE7F6EC) : const Color(0xFFFFF4DB), shape: BoxShape.circle),
                child: Icon(handled ? Icons.check : Icons.phone_missed, color: handled ? const Color(0xFF15803D) : const Color(0xFFB45309), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, decoration: handled ? TextDecoration.lineThrough : null)),
                const SizedBox(height: 2),
                Text(sub, maxLines: 2, style: const TextStyle(fontSize: 12, color: Color(0xFF5B5470))),
              ])),
              if (!handled) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 42, height: 42,
                  child: Material(
                    color: const Color(0xFF22C55E), shape: const CircleBorder(),
                    child: InkWell(customBorder: const CircleBorder(), onTap: () => _callBack(number), child: const Icon(Icons.call, color: Colors.white, size: 20)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  String _dayName(DateTime t) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1] + ' ${t.day}';

  Future<void> _callBack(String number) async {
    if (number.isEmpty) return;
    await Phone.instance.dial(number.length == 11 && number.startsWith('1876') ? number.substring(1) : number);
  }

  Future<void> _act(String number, String action, {int? userId}) async {
    try {
      await Session.instance.api.post('pulse/missed', {'number': number, 'action': action, if (userId != null) 'user_id': userId});
      await _load(quiet: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _actions(Map m) async {
    final number = (m['number'] ?? '').toString();
    final handled = m['handled'] == true;
    final pretty = prettyNumber(number);
    final people = ((_data?['people'] as List?) ?? []).cast<Map>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 44, height: 5, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(3)))),
            const SizedBox(height: 14),
            Text(pretty, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            Text(handled ? 'Handled' : 'Missed · ${(m['attempts'] ?? 1)} attempt${(m['attempts'] ?? 1) == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12.5, color: Color(0xFF5B5470))),
            const SizedBox(height: 14),
            _sheetItem(Icons.call, 'Call back now', 'Shows the company number as caller ID', green: true, onTap: () { Navigator.pop(c); _callBack(number); }),
            if (!handled) _sheetItem(Icons.person_outline, 'Assign to someone', 'They get a push asking them to call back', onTap: () async { Navigator.pop(c); final id = await _pickPerson(people); if (id != null) _act(number, 'assign', userId: id); }),
            if (!handled) _sheetItem(Icons.check, 'Mark handled', 'Removes it from everyone\'s list', onTap: () { Navigator.pop(c); _act(number, 'handled'); }),
            if (handled) _sheetItem(Icons.undo, 'Reopen', 'Put it back on the list', onTap: () { Navigator.pop(c); _act(number, 'reopen'); }),
          ]),
        ),
      ),
    );
  }

  Widget _sheetItem(IconData icon, String title, String sub, {bool green = false, required VoidCallback onTap}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: green ? const Color(0xFFE7F6EC) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: green ? const Color(0xFF22C55E) : wocomLine, width: green ? 2 : 1)),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(width: 44, height: 44, decoration: BoxDecoration(color: green ? const Color(0xFF22C55E) : const Color(0xFFF0EBFF), shape: BoxShape.circle), child: Icon(icon, color: green ? Colors.white : wocomPlum, size: 20)),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
                  Text(sub, style: const TextStyle(fontSize: 12.5, color: Color(0xFF5B5470))),
                ])),
              ]),
            ),
          ),
        ),
      );

  Future<int?> _pickPerson(List<Map> people) => showModalBottomSheet<int>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (c) => SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 14, 8, 8), children: [
            const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: Text('Assign to', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
            for (final p in people)
              ListTile(leading: PersonAvatar(name: (p['name'] ?? '').toString(), size: 36), title: Text((p['name'] ?? '').toString()), onTap: () => Navigator.pop(c, (p['id'] as num).toInt())),
          ]),
        ),
      );

  Widget _trendRow(Map<String, dynamic> d) {
    final t = d['tiles'] as Map; final p = d['previous'] as Map;
    final prevLabel = _range == 'today' ? 'VS YESTERDAY' : (_range == 'week' ? 'VS LAST WEEK' : 'VS LAST MONTH');
    Widget cell(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF8A8299), fontWeight: FontWeight.w700, letterSpacing: 0.4)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
            ]),
          ),
        );
    String delta(num cur, num prev) => cur == prev ? '= $cur' : (cur > prev ? '▲ ${cur - prev}' : '▼ ${prev - cur}');
    Color up(num cur, num prev, {bool goodWhenUp = true}) => cur == prev ? const Color(0xFF1C1530) : ((cur > prev) == goodWhenUp ? const Color(0xFF15803D) : const Color(0xFFB45309));
    final talk = (t['avg_talk'] as num).toInt();
    return Row(children: [
      cell(prevLabel, 'Calls ${delta(t['received'], p['received'])}', up(t['received'], p['received'])),
      const SizedBox(width: 8),
      cell('MISSED', delta(t['missed'], p['missed']), up(t['missed'], p['missed'], goodWhenUp: false)),
      const SizedBox(width: 8),
      cell('AVG TALK', '${talk ~/ 60}:${(talk % 60).toString().padLeft(2, '0')}', const Color(0xFF1C1530)),
    ]);
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.label});
  final Color color; final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF5B5470), fontWeight: FontWeight.w600)),
      ]);
}
