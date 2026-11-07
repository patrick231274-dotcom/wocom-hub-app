import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';
import 'visit_photos.dart';
import '../services/photo_queue.dart';

// ── shared look ──────────────────────────────────────────────────────────────

const _statusLabel = {
  'open': 'Open', 'in_progress': 'In progress', 'on_site': 'On site', 'escalated': 'Escalated', 'closed': 'Closed',
};

(Color, Color) _priorityTone(String p) => switch (p) {
      'urgent' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
      'high' => (const Color(0xFFFFF4DB), const Color(0xFF92400E)),
      'low' => (const Color(0xFFF3F4F6), const Color(0xFF4B5563)),
      _ => (const Color(0xFFF3F4F6), const Color(0xFF374151)),
    };

bool _isMe(Map t) {
  final me = TechHub.instance.engineer;
  if (me == null) return false;
  if (t['assigned_to_id'] != null && me['id'] != null) return '${t['assigned_to_id']}' == '${me['id']}';
  return (t['assigned_to'] ?? '').toString().trim().toLowerCase() == TechHub.instance.name.trim().toLowerCase();
}

Widget _pillTag(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );

Widget _assignee(Map t) {
  final name = (t['assigned_to'] ?? '').toString().trim();
  if (name.isEmpty) {
    return Row(children: [
      const Text('Assigned to ', style: TextStyle(color: wocomMuted, fontWeight: FontWeight.w600)),
      _pillTag('Unassigned', const Color(0xFFFEF3C7), const Color(0xFF92400E)),
    ]);
  }
  final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  final initials = (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  final since = _dt(t['assigned_at']);
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      CircleAvatar(radius: 18, backgroundColor: wocomDeep, child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ASSIGNED TO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: wocomMuted, letterSpacing: 0.4)),
        Text('$name${_isMe(t) ? ' (you)' : ''}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
        if (since != null) Text('since ${since.day} ${m[since.month - 1]} ${since.year}, ${since.hour % 12 == 0 ? 12 : since.hour % 12}:${since.minute.toString().padLeft(2, '0')} ${since.hour < 12 ? 'AM' : 'PM'}${t['assigned_ack_at'] == null ? ' · not accepted yet' : ''}', style: const TextStyle(fontSize: 12, color: wocomMuted)),
      ])),
    ]),
  );
}

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

String _dueLabel(Map t) {
  final due = _dt(t['due_at']);
  if (due == null || t['status'] == 'closed') return '';
  final mins = due.difference(DateTime.now()).inMinutes;
  if (mins < 0) {
    final late = -mins;
    return late < 60 ? 'overdue $late min' : 'overdue ${late ~/ 60} h';
  }
  final now = DateTime.now();
  final sameDay = due.year == now.year && due.month == now.month && due.day == now.day;
  final hm = TimeOfDay.fromDateTime(due);
  final time = '${hm.hourOfPeriod == 0 ? 12 : hm.hourOfPeriod}:${hm.minute.toString().padLeft(2, '0')} ${hm.period == DayPeriod.am ? 'AM' : 'PM'}';
  if (sameDay) return 'due $time';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return 'due ${days[due.weekday - 1]} $time';
}

bool _overdue(Map t) { final d = _dt(t['due_at']); return d != null && t['status'] != 'closed' && d.isBefore(DateTime.now()); }
bool _dueSoon(Map t) { final d = _dt(t['due_at']); return d != null && t['status'] != 'closed' && !_overdue(t) && d.difference(DateTime.now()).inMinutes <= 120; }

void _toast(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

// ── root: sign-in or the hub ──────────────────────────────────────────────────

/// The Tech Hub tab of the WOCOM Employee App. Signed in to TechHub with the engineer's own
/// emailed code; nothing passes through the WOCOM Hub platform.
class TechHubScreen extends StatelessWidget {
  const TechHubScreen({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: TechHub.instance,
        builder: (context, _) {
          final th = TechHub.instance;
          if (!th.ready) return const Center(child: CircularProgressIndicator());
          if (th.signedIn) return const _Hub();
          return th.welcomed ? const _SignIn() : const _Welcome();
        },
      );
}

// ── welcome: WOCOM, with a Jamaican flag ──────────────────────────────────────

const _jaGreen = Color(0xFF009B3A);
const _jaGold = Color(0xFFFED100);
const _jaBlack = Color(0xFF111111);

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        body: Column(children: [
          // Flag hero: green and black fields with the gold saltire, the W in a white disc.
          SizedBox(
            height: 330,
            width: double.infinity,
            child: Stack(alignment: Alignment.center, children: [
              const Positioned.fill(child: CustomPaint(painter: _FlagPainter())),
              Container(
                width: 172, height: 172,
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: _jaGold, width: 6),
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 8))]),
                padding: const EdgeInsets.all(34),
                child: Image.asset('assets/wocom-mark.png', fit: BoxFit.contain),
              ),
            ]),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Wah gwaan, team!', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _jaGreen)),
                  const SizedBox(height: 6),
                  const Text('Welcome to WE', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, height: 1.05, letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  const Text('The WOCOM Employee App', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: wocomMuted)),
                  const SizedBox(height: 18),
                  _point(Icons.build_outlined, 'Your Tech Hub tickets, with alerts before they are due'),
                  _point(Icons.straighten, 'Site surveys with photos, straight from the site'),
                  _point(Icons.phone_in_talk_outlined, 'Calls on your office extension (coming soon)'),
                  const Spacer(),
                  Row(children: [
                    for (final c in [_jaGreen, _jaGold, _jaBlack, _jaGold, _jaGreen]) Expanded(child: Container(height: 4, margin: const EdgeInsets.symmetric(horizontal: 2), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)))),
                  ]),
                  const SizedBox(height: 6),
                  const Center(child: Text('ONE LOVE · ONE TEAM · 100% JAMAICAN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2))),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), backgroundColor: _jaGreen, textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    onPressed: () => TechHub.instance.markWelcomed(),
                    child: const Text("Let's go"),
                  ),
                ]),
              ),
            ),
          ),
        ]),
      );

  Widget _point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: const Color(0xFFE5F5EA), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: _jaGreen, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3))),
        ]),
      );
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter();
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height, c = Offset(w / 2, h / 2);
    canvas.drawRect(Offset.zero & s, Paint()..color = _jaGreen);
    final black = Paint()..color = _jaBlack;
    canvas.drawPath(Path()..moveTo(0, 0)..lineTo(c.dx, c.dy)..lineTo(0, h)..close(), black);
    canvas.drawPath(Path()..moveTo(w, 0)..lineTo(c.dx, c.dy)..lineTo(w, h)..close(), black);
    final gold = Paint()..color = _jaGold..strokeWidth = h * 0.16;
    canvas.drawLine(Offset.zero, Offset(w, h), gold);
    canvas.drawLine(Offset(w, 0), Offset(0, h), gold);
  }
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _SignIn extends StatefulWidget {
  const _SignIn();
  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  final _email = TextEditingController(text: (TechHub.instance.lastEngineer?['email'] ?? '').toString());
  final _code = TextEditingController();
  String? _challenge;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    setState(() { _busy = true; _error = null; });
    try {
      if (_challenge == null) {
        _challenge = await TechHub.instance.start(_email.text);
      } else {
        await TechHub.instance.verify(_challenge!, _code.text);
      }
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        const BrandHeader(title: 'Tech Hub'),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 12),
            Text(_challenge == null ? 'Sign in with your work email' : 'Enter the code we emailed you', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(_challenge == null ? 'Tech Hub sends a 6-digit code to the address on your Tech Hub account.' : 'It was sent to ${_email.text.trim()} and expires in 10 minutes. Check junk mail if it is not there.', style: const TextStyle(color: wocomMuted, height: 1.4)),
            if (_challenge == null && TechHub.instance.lastEngineer != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  PersonAvatar(name: (TechHub.instance.lastEngineer!['name'] ?? '').toString(), size: 36),
                  const SizedBox(width: 10),
                  Expanded(child: Text('This phone belongs to ${TechHub.instance.lastEngineer!['name'] ?? 'its last user'}${(TechHub.instance.lastEngineer!['extension'] ?? '').toString().isNotEmpty ? ' (ext ${TechHub.instance.lastEngineer!['extension']})' : ''} until someone else signs in.', style: const TextStyle(fontSize: 13, height: 1.35))),
                ]),
              ),
            ],
            const SizedBox(height: 20),
            if (_challenge == null)
              TextField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], decoration: const InputDecoration(labelText: 'Work email'))
            else
              TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6, autofocus: true, style: const TextStyle(fontSize: 24, letterSpacing: 6, fontWeight: FontWeight.w800), decoration: const InputDecoration(labelText: 'Code', counterText: '')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C)))),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: wocomDeep),
              onPressed: _busy ? null : _go,
              child: Text(_busy ? 'Please wait…' : (_challenge == null ? 'Send code' : 'Sign in')),
            ),
            if (_challenge != null) TextButton(onPressed: _busy ? null : () => setState(() { _challenge = null; _code.clear(); _error = null; }), child: const Text('Use a different email')),
          ]),
        ),
      ]);
}

// ── the hub: tickets, surveys, duty ──────────────────────────────────────────

class _Hub extends StatefulWidget {
  const _Hub();
  @override
  State<_Hub> createState() => _HubState();
}

class _HubState extends State<_Hub> {
  String _scope = 'mine'; // mine | team | closed | surveys
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _mine = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.changes.addListener(_load);
  }

  @override
  void dispose() {
    TechHub.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final th = TechHub.instance;
      final items = _scope == 'surveys' ? await th.surveys() : await th.tickets(_scope);
      final mine = _scope == 'mine' ? items : await th.tickets('mine');
      if (!mounted) return;
      setState(() { _items = items; _mine = mine; _error = null; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    }
  }

  void _setScope(String s) { setState(() { _scope = s; _loading = true; }); _load(); }

  @override
  Widget build(BuildContext context) {
    final th = TechHub.instance;
    final open = _mine.where((t) => t['status'] != 'closed').toList();
    final dueToday = open.where((t) { final d = _dt(t['due_at']); final n = DateTime.now(); return d != null && d.year == n.year && d.month == n.month && d.day == n.day && !_overdue(t); }).length;
    final overdue = open.where(_overdue).length;
    final tabs = [('mine', 'Mine'), if (th.isLead) ('team', 'Team'), ('closed', 'Closed'), ('surveys', 'Surveys')];
    return Column(children: [
      BrandHeader(
        title: 'Tech Hub',
        subtitle: [th.name, if (th.extension.isNotEmpty) 'Ext ${th.extension}'].where((x) => x.isNotEmpty).join(' · '),
        onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
        trailing: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) async { if (v == 'out') await th.signOut(); },
            itemBuilder: (_) => const [PopupMenuItem(value: 'out', child: Text('Sign out of Tech Hub'))],
          ),
        ],
        bottom: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Text('On duty', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Switch(value: th.onDuty, activeThumbColor: Colors.white, activeTrackColor: const Color(0xFF22C55E), onChanged: (v) async {
              try { await th.setDuty(v); } on ApiException catch (e) { if (context.mounted) _toast(context, e.message); }
            }),
            const Spacer(),
            Text(th.onDuty ? 'All alerts' : 'Urgent alerts only', style: const TextStyle(color: Color(0xFFE9DDFF), fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          // Compact counts (were three big cards): one slim row, so the tabs below have room.
          Row(children: [
            _pill('${open.length}', 'assigned', Colors.white.withValues(alpha: 0.16), Colors.white),
            const SizedBox(width: 6),
            _pill('$dueToday', 'due today', const Color(0xFFFFF4DB), const Color(0xFF92400E)),
            const SizedBox(width: 6),
            _pill('$overdue', 'overdue', overdue > 0 ? const Color(0xFFFEE2E2) : Colors.white.withValues(alpha: 0.16), overdue > 0 ? const Color(0xFF991B1B) : Colors.white),
          ]),
        ]),
      ),
      // Tabs on a white bar under the header: full names, bigger, scroll sideways if needed.
      Container(
        color: Colors.white,
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          children: [for (final (k, l) in tabs) _seg(k, l)],
        ),
      ),
      const Divider(height: 1, color: wocomLine),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _items.isEmpty
                        ? ListView(children: [const SizedBox(height: 80), EmptyState(icon: Icons.task_alt, text: _scope == 'surveys' ? 'No site surveys assigned to you.' : 'No tickets here.')])
                        : ListView.builder(
                            padding: const EdgeInsets.all(14),
                            itemCount: _items.length,
                            itemBuilder: (_, i) => _scope == 'surveys' ? _surveyCard(_items[i]) : _ticketCard(_items[i]),
                          ),
                  ),
      ),
    ]);
  }

  Widget _pill(String v, String l, Color bg, Color fg) => Expanded(
        child: GestureDetector(
          onTap: () => _setScope('mine'),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(17)),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$v ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: fg)),
              TextSpan(text: l, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
            ]), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );

  Widget _seg(String k, String l) {
    final on = _scope == k;
    final cover = k == 'cover';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _setScope(k),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? (cover ? const Color(0xFFB91C1C) : wocomDeep) : Colors.white,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: on ? Colors.transparent : (cover ? const Color(0xFFFCA5A5) : wocomLine), width: 1.5),
          ),
          child: Text(l, style: TextStyle(color: on ? Colors.white : (cover ? const Color(0xFFB91C1C) : wocomInk), fontSize: 14.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _ticketCard(Map<String, dynamic> t) {
    final pr = (t['priority'] ?? 'normal').toString();
    final (bg, fg) = _priorityTone(pr);
    final due = _dueLabel(t);
    final edge = _overdue(t) ? const Color(0xFFEF4444) : _dueSoon(t) ? const Color(0xFFF59E0B) : wocomLine;
    return Card(
      elevation: 0, color: Colors.white, margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: edge, width: edge == wocomLine ? 1 : 1.5)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: t['ticket_number'].toString()))); _load(); },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text((t['ticket_number'] ?? '').toString(), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: wocomMuted)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                child: Text([pr.toUpperCase(), if (due.isNotEmpty) due].join(' · '), style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 6),
            Text((t['subject'] ?? '').toString(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text([t['client_name'], t['site_address'] ?? t['service_address']].where((x) => x != null && x.toString().isNotEmpty).join(' · '), style: const TextStyle(fontSize: 12.5, color: Color(0xFF4B4560))),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              _chip(_statusLabel[t['status']] ?? (t['status'] ?? '').toString(), wocomSoft, wocomDeep),
              if ((t['ticket_type'] ?? '').toString().isNotEmpty) _chip(t['ticket_type'].toString().replaceAll('_', ' '), const Color(0xFFF3F4F6), const Color(0xFF374151)),
              if (t['assigned_to'] == null) _chip('Unassigned', const Color(0xFFFEF3C7), const Color(0xFF92400E)) else if (!_isMe(t)) _chip('→ ${t['assigned_to']}', const Color(0xFFE0F2FE), const Color(0xFF0369A1)),
              if (t['needs_cover'] == true) _chip('Needs cover${(t['absent_name'] ?? '').toString().isNotEmpty ? ' · ${t['absent_name']} out' : ''}', const Color(0xFFFEE2E2), const Color(0xFFB91C1C)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _surveyCard(Map<String, dynamic> s) {
    final when = _dt(s['scheduled_date'] ?? s['scheduled_at']);
    return Card(
      elevation: 0, color: Colors.white, margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: wocomLine)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(width: 42, height: 42, decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.straighten, color: wocomDeep)),
        title: Text((s['client_name'] ?? s['title'] ?? 'Site survey').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text([s['site_address'] ?? s['address'], if (when != null) '${when.day}/${when.month}', s['status']].where((x) => x != null && x.toString().isNotEmpty).join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SurveyScreen(id: s['id'].toString()))); _load(); },
      ),
    );
  }
}

Widget _chip(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700)),
    );

// ── ticket ───────────────────────────────────────────────────────────────────

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key, required this.number});
  final String number;
  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  Widget _visitTile(Map<String, dynamic> v) {
    final survey = v['kind'] == 'survey';
    final done = v['completed_at'] != null || v['status'] == 'done' || v['status'] == 'completed';
    final at = DateTime.tryParse((v['visit_at'] ?? '').toString())?.toLocal();
    final when = at == null ? 'Not scheduled' : '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][at.weekday - 1]} ${at.day}/${at.month} · ${at.hour % 12 == 0 ? 12 : at.hour % 12}:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}${v['duration_min'] != null ? ' · ${v['duration_min']} min' : ''}';
    final address = (v['address'] ?? '').toString();
    final phone = (v['contact_phone'] ?? '').toString();
    final color = done ? const Color(0xFF15803D) : (survey ? const Color(0xFF7C3AED) : const Color(0xFFEA580C));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? Icons.check_circle : (survey ? Icons.straighten : Icons.handyman_outlined), color: color, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text('${survey ? 'Site survey' : 'Visit'}${v['seq'] != null ? ' ${v['seq']}' : ''}${v['is_priority'] == true ? ' · PRIORITY' : ''}', style: TextStyle(fontWeight: FontWeight.w900, color: color))),
          if (done) Text('Done', style: TextStyle(fontWeight: FontWeight.w800, color: color)),
        ]),
        const SizedBox(height: 4),
        Text(when, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        if ((v['location_name'] ?? '').toString().isNotEmpty) Text(v['location_name'].toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
        if (address.isNotEmpty) Text(address, style: const TextStyle(color: wocomMuted)),
        if ((v['contact_name'] ?? '').toString().isNotEmpty) Text('Contact: ${v['contact_name']}${phone.isNotEmpty ? ' · $phone' : ''}', style: const TextStyle(color: wocomMuted)),
        if ((v['notes'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(v['notes'].toString(), style: const TextStyle(fontStyle: FontStyle.italic))),
        if (done && (v['findings'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Findings: ${v['findings']}')),
        VisitPhotos(number: widget.number, visit: v, onChanged: _load),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          if (address.isNotEmpty) OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(address)}'), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.directions, size: 18), label: const Text('Directions'),
          ),
          if (phone.isNotEmpty) OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse('tel:$phone')), icon: const Icon(Icons.call, size: 18), label: const Text('Call contact')),
          if (!done && v['needs_cover'] == true) FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
            onPressed: _busy ? null : () => _takeVisit(v),
            icon: const Icon(Icons.pan_tool_alt_outlined, size: 18), label: const Text('Needs cover · Take it'),
          ),
          if (!done && v['needs_cover'] != true) FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF15803D)),
            onPressed: _busy ? null : () => _markVisitDone(v),
            icon: const Icon(Icons.check, size: 18), label: const Text('Mark done'),
          ),
        ]),
      ]),
    );
  }

  Future<void> _takeVisit(Map<String, dynamic> v) async {
    setState(() => _busy = true);
    try {
      await TechHub.instance.take(widget.number, visitId: (v['id'] as num).toInt());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("It's yours. The team and supervisor have been told.")));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markVisitDone(Map<String, dynamic> v) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(v['kind'] == 'survey' ? 'Site survey done' : 'Visit done'),
      content: TextField(controller: ctl, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'What did you find? (optional)')),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark done'))],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await TechHub.instance.visitDone(widget.number, (v['id'] as num).toInt(), ctl.text);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['all_done'] == true ? 'All visits on this ticket are done.' : 'Marked done.')));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _t;
  String? _error;
  String? _status;
  final _comment = TextEditingController();
  final _note = TextEditingController();
  final _resolution = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    PhotoQueue.instance.init();
    PhotoQueue.instance.uploaded.addListener(_onPhotoUploaded);
    PhotoQueue.instance.failure.addListener(_onPhotoFailed);
  }

  @override
  void dispose() {
    PhotoQueue.instance.uploaded.removeListener(_onPhotoUploaded);
    PhotoQueue.instance.failure.removeListener(_onPhotoFailed);
    super.dispose();
  }

  void _onPhotoUploaded() { if (PhotoQueue.instance.uploaded.value.startsWith('${widget.number}#')) _load(); }
  void _onPhotoFailed() {
    final m = PhotoQueue.instance.failure.value;
    if (m != null && mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))); PhotoQueue.instance.failure.value = null; }
  }

  Future<void> _load() async {
    try {
      final t = await TechHub.instance.ticket(widget.number);
      if (mounted) setState(() { _t = t; _status = t['status']?.toString(); _error = null; });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await TechHub.instance.update(widget.number,
          status: _status != _t?['status'] ? _status : null, comment: _comment.text, internalNote: _note.text,
          resolution: _status == 'closed' ? _resolution.text : null);
      _comment.clear(); _note.clear(); _resolution.clear();
      if (mounted) _toast(context, 'Saved to Tech Hub.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) _toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _photo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2000, imageQuality: 80);
    if (x == null) return;
    setState(() => _busy = true);
    try { await TechHub.instance.attach(widget.number, x.path); if (mounted) _toast(context, 'Photo added to the ticket.'); await _load(); }
    on ApiException catch (e) { if (mounted) _toast(context, e.message); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final phone = (t?['client_phone'] ?? t?['caller_phone'] ?? '').toString();
    final address = (t?['site_address'] ?? t?['service_address'] ?? '').toString();
    final history = ((t?['history'] ?? t?['comments'] ?? const []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final files = ((t?['attachments'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    List<Map<String, dynamic>> hFiles(Map h) => ((h['attachments'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: Text(widget.number, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
      body: t == null
          ? (_error != null ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again'))) : const Center(child: CircularProgressIndicator()))
          : ListView(padding: EdgeInsets.fromLTRB(14, 14, 14, 32 + MediaQuery.of(context).viewPadding.bottom), children: [
              Text((t['subject'] ?? '').toString(), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text([t['client_name'], address, _dueLabel(t)].where((x) => x != null && x.toString().isNotEmpty).join(' · '), style: const TextStyle(color: wocomMuted)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _pillTag(_statusLabel[t['status']] ?? (t['status'] ?? '').toString(), wocomSoft, wocomDeep),
                if ((t['priority'] ?? '').toString().isNotEmpty) _pillTag(t['priority'].toString().toUpperCase(), _priorityTone(t['priority'].toString()).$1, _priorityTone(t['priority'].toString()).$2),
              ]),
              const SizedBox(height: 10),
              _assignee(t),
              const SizedBox(height: 12),
              idleBanner(t, () async { if (await showIdleTicketDialog(context, widget.number, (t['idle_close_at'] ?? '').toString(), offerOpen: false)) _load(); }),
              if (t['needs_cover'] == true && t['status'] != 'closed')
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFCA5A5))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${t['absent_name'] ?? 'The assigned tech'} is out. This job needs someone to cover it.', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF991B1B))),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: const Color(0xFF15803D)),
                      onPressed: _busy ? null : () async {
                        setState(() => _busy = true);
                        try { await TechHub.instance.take(widget.number); if (context.mounted) _toast(context, 'It\'s yours. The team and supervisor have been told.'); await _load(); }
                        on ApiException catch (e) { if (context.mounted) _toast(context, e.message); }
                        finally { if (mounted) setState(() => _busy = false); }
                      },
                      icon: const Icon(Icons.pan_tool_alt_outlined),
                      label: const Text('Take it', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                    ),
                  ]),
                ),
              if (t['assigned_ack_at'] == null && t['status'] != 'closed' && t['needs_cover'] != true)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46), backgroundColor: wocomDeep),
                    onPressed: _busy ? null : () async { try { await TechHub.instance.accept(widget.number); await _load(); } on ApiException catch (e) { if (context.mounted) _toast(context, e.message); } },
                    child: const Text('Accept ticket'),
                  ),
                ),
              Row(children: [
                Expanded(child: _action(Icons.call, 'Call client', phone.isEmpty ? null : () => launchUrl(Uri.parse('tel:$phone')), green: true)),
                const SizedBox(width: 8),
                Expanded(child: _action(Icons.directions, 'Directions', address.isEmpty ? null : () => launchUrl(Uri.parse('https://maps.google.com/?q=${Uri.encodeComponent(address)}'), mode: LaunchMode.externalApplication))),
                const SizedBox(width: 8),
                Expanded(child: _action(Icons.photo_camera_outlined, 'Photo', _busy ? null : _photo)),
              ]),
              const SizedBox(height: 12),
              _box('What the client reported', Text((t['description'] ?? '').toString(), style: const TextStyle(height: 1.45))),
              if (t['visits'] is List && (t['visits'] as List).isNotEmpty) ...[
                const SizedBox(height: 12),
                _box('Site visits', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final v in (t['visits'] as List).whereType<Map>()) _visitTile(Map<String, dynamic>.from(v)),
                ])),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                _box('Photos & files (${files.length})', TicketAttachments(number: widget.number, items: files)),
              ],
              const SizedBox(height: 12),
              _box('Update the ticket', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in ['in_progress', 'on_site', 'escalated', 'closed'])
                    ChoiceChip(label: Text(_statusLabel[s]!), selected: _status == s, onSelected: (_) => setState(() => _status = s)),
                ]),
                const SizedBox(height: 10),
                TextField(controller: _comment, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Comment to the client (emailed)')),
                const SizedBox(height: 8),
                TextField(controller: _note, minLines: 1, maxLines: 4, decoration: const InputDecoration(labelText: 'Internal note (staff only)')),
                if (_status == 'closed') ...[
                  const SizedBox(height: 8),
                  TextField(controller: _resolution, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Resolution')),
                ],
                const SizedBox(height: 12),
                FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: wocomDeep), onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save to Tech Hub')),
              ])),
              if (history.isNotEmpty) ...[
                const SizedBox(height: 12),
                _box('History', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final h in history)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('${(h['at'] ?? h['created_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first} · ${h['by'] ?? h['author'] ?? ''}\n${h['text'] ?? h['comment'] ?? h['status'] ?? ''}', style: const TextStyle(fontSize: 12.5, height: 1.4)),
                        if (hFiles(h).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: TicketAttachments(number: widget.number, items: hFiles(h), size: 56)),
                      ]),
                    ),
                ])),
              ],
            ]),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap, {bool green = false}) => SizedBox(
        height: 52,
        child: green
            ? FilledButton.icon(onPressed: onTap, style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)), icon: Icon(icon, size: 18), label: Text(label, style: const TextStyle(fontSize: 12)))
            : OutlinedButton.icon(onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label, style: const TextStyle(fontSize: 12))),
      );
}

Widget _box(String title, Widget child) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title.toUpperCase(), style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: wocomMuted, letterSpacing: 0.4)),
        const SizedBox(height: 8),
        child,
      ]),
    );

// ── site survey ──────────────────────────────────────────────────────────────

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({super.key, required this.id});
  final String id;
  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  Map<String, dynamic>? _s;
  String? _error;
  final _issues = TextEditingController();
  final _findings = TextEditingController();
  DateTime? _install;
  int _photos = 0;
  bool _busy = false;

  @override
  void initState() { super.initState(); _load(); }

  static String _contact(dynamic c) => c is Map ? [c['name'], c['phone']].where((x) => x != null && x.toString().isNotEmpty).join(' · ') : (c ?? '').toString();

  Future<void> _load() async {
    try {
      final s = await TechHub.instance.survey(widget.id);
      if (mounted) setState(() { _s = s; _photos = (s['photo_count'] as num?)?.toInt() ?? ((s['photos'] ?? const []) as List).length; _issues.text = (s['issues_found'] ?? '').toString(); _findings.text = (s['findings_notes'] ?? '').toString(); });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _photo(ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src, maxWidth: 2000, imageQuality: 80);
    if (x == null) return;
    setState(() => _busy = true);
    try { await TechHub.instance.surveyPhoto(widget.id, x.path); setState(() => _photos++); }
    on ApiException catch (e) { if (mounted) _toast(context, e.message); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _submit() async {
    if (_findings.text.trim().isEmpty) { _toast(context, 'Add your findings first.'); return; }
    setState(() => _busy = true);
    try {
      await TechHub.instance.submitSurvey(widget.id, issues: _issues.text.trim(), findings: _findings.text.trim(),
          installDate: _install == null ? null : '${_install!.year}-${_install!.month.toString().padLeft(2, '0')}-${_install!.day.toString().padLeft(2, '0')}');
      if (mounted) { _toast(context, 'Survey submitted.'); Navigator.pop(context); }
    } on ApiException catch (e) {
      if (mounted) _toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final address = (s?['site_address'] ?? s?['address'] ?? '').toString();
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Site survey', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
      body: s == null
          ? (_error != null ? EmptyState(icon: Icons.cloud_off, text: _error!) : const Center(child: CircularProgressIndicator()))
          : ListView(padding: EdgeInsets.fromLTRB(14, 14, 14, 32 + MediaQuery.of(context).viewPadding.bottom), children: [
              Text((s['client_name'] ?? 'Site survey').toString(), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              if (address.isNotEmpty) Text(address, style: const TextStyle(color: wocomMuted)),
              const SizedBox(height: 10),
              if ((s['instructions'] ?? '').toString().isNotEmpty) _box('Instructions', Text(s['instructions'].toString())),
              if (_contact(s['site_contact']).isNotEmpty) ...[const SizedBox(height: 10), _box('Site contact', Text(_contact(s['site_contact'])))],
              const SizedBox(height: 10),
              _box('Photos · $_photos', Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _photo(ImageSource.camera), icon: const Icon(Icons.photo_camera_outlined), label: const Text('Camera'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _photo(ImageSource.gallery), icon: const Icon(Icons.photo_outlined), label: const Text('Gallery'))),
              ])),
              const SizedBox(height: 10),
              _box('Findings', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: _issues, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Issues found')),
                const SizedBox(height: 8),
                TextField(controller: _findings, minLines: 3, maxLines: 8, decoration: const InputDecoration(labelText: 'Findings and recommendations')),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)), initialDate: _install ?? DateTime.now().add(const Duration(days: 7)));
                    if (d != null) setState(() => _install = d);
                  },
                  icon: const Icon(Icons.event),
                  label: Text(_install == null ? 'Recommended install date' : 'Install ${_install!.day}/${_install!.month}/${_install!.year}'),
                ),
              ])),
              const SizedBox(height: 14),
              FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: wocomDeep), onPressed: _busy ? null : _submit, child: Text(_busy ? 'Please wait…' : 'Submit survey')),
            ]),
    );
  }
}

// ── idle-ticket rule: 48 h without a client update → closes 24 h later unless the client hears from us ──

String _closeLabel(String iso) {
  final d = _dt(iso);
  if (d == null) return 'in 24 hours';
  final now = DateTime.now();
  final day = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  final t = '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  return switch (day) { 0 => 'today at $t', 1 => 'tomorrow at $t', _ => '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]} ${d.day}/${d.month} at $t' };
}

/// Red strip on ticket detail while the idle rule is counting down (ticket.idle_close_at).
Widget idleBanner(Map t, VoidCallback onUpdate) {
  final at = (t['idle_close_at'] ?? '').toString();
  if (at.isEmpty || t['status'] == 'closed') return const SizedBox.shrink();
  return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFCA5A5))),
    child: Row(children: [
      const Icon(Icons.timer_outlined, color: Color(0xFFB91C1C)),
      const SizedBox(width: 8),
      Expanded(child: Text('Closes ${_closeLabel(at)} unless the client gets an update', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF991B1B)))),
      TextButton(onPressed: onUpdate, child: const Text('Update')),
    ]),
  );
}

/// "No update for 48 h" dialog (from the ticket_idle push, or the banner). Returns true when sent.
Future<bool> showIdleTicketDialog(BuildContext context, String number, String closeAt, {bool offerOpen = true}) async {
  final ctl = TextEditingController();
  var busy = false;
  String? err;
  final r = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: Text(number),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(10)),
          child: Text('No update for 48 h. It closes ${_closeLabel(closeAt)} unless you update the client.', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF991B1B))),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: ctl, autofocus: true, minLines: 3, maxLines: 6,
          onChanged: (_) { if (err != null) set(() => err = null); },
          decoration: InputDecoration(labelText: 'Update for the client (e-mailed to them)', errorText: err, border: const OutlineInputBorder()),
        ),
      ])),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(c, 'later'), child: const Text('Later')),
        if (offerOpen) TextButton(onPressed: busy ? null : () => Navigator.pop(c, 'open'), child: const Text('Open ticket')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF15803D)),
          onPressed: busy ? null : () async {
            if (ctl.text.trim().length < 3) { set(() => err = 'Write the update for the client first.'); return; }
            set(() => busy = true);
            try {
              await TechHub.instance.update(number, comment: ctl.text);
              if (c.mounted) Navigator.pop(c, 'sent');
            } on ApiException catch (e) {
              set(() { busy = false; err = e.message; });
            }
          },
          child: Text(busy ? 'Sending…' : 'Send update & keep open'),
        ),
      ],
    )),
  );
  if (!context.mounted) return r == 'sent';
  if (r == 'sent') ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update sent to the client. $number stays open.')));
  if (r == 'open') await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: number)));
  return r == 'sent';
}
