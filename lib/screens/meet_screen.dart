import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/hub.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'home_screen.dart';

/// WOCOM Meet: start now, schedule, and join today's meetings (opens the meeting room).
class MeetScreen extends StatefulWidget {
  const MeetScreen({super.key, required this.onAvatarTap});

  final VoidCallback onAvatarTap;

  @override
  State<MeetScreen> createState() => _MeetScreenState();
}

class _MeetScreenState extends State<MeetScreen> {
  List<Map<String, dynamic>> _meetings = [];
  bool _enabled = true;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _tab = 0;                       // 0 Meetings · 1 Tasks
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _people = [];
  bool _canAssign = false;
  Timer? _taskPoll;

  PushApi get _api => Session.instance.api;

  @override
  void initState() {
    super.initState();
    _load();
    _taskPoll = Timer.periodic(const Duration(seconds: 45), (_) => _loadTasks());
    Hub.instance.tasksEvent.addListener(_loadTasks);
  }

  @override
  void dispose() {
    _taskPoll?.cancel();
    Hub.instance.tasksEvent.removeListener(_loadTasks);
    super.dispose();
  }

  Future<void> _loadTasks() async {
    try {
      final t = await _api.get('tasks');
      if (!mounted) return;
      setState(() {
        _tasks = ((t['tasks'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _people = ((t['people'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _canAssign = t['can_assign'] == true;
      });
      Hub.instance.setOpenTasks((t['open'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<void> _load() async {
    _loadTasks();
    try {
      final r = await _api.get('meetings');
      setState(() {
        _enabled = r['enabled'] != false;
        _meetings = ((r['meetings'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Future<Map<String, dynamic>> Function() getLink) async {
    setState(() => _busy = true);
    try {
      final r = await getLink();
      final url = Uri.tryParse((r['url'] ?? '') as String);
      if (url == null || !await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw ApiException('open', "Couldn't open the meeting.", 0);
      }
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _schedule() async {
    final title = TextEditingController();
    final guestField = TextEditingController();
    DateTime when = DateTime.now().add(const Duration(hours: 1)).copyWith(minute: 0, second: 0);
    int minutes = 30;
    final guests = <String>{};
    final teammates = Hub.instance.people.where((p) => p['is_me'] != true && (p['email'] ?? '').toString().contains('@')).toList();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(c).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Schedule a meeting', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(controller: title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text('${when.day}/${when.month}/${when.year} at ${TimeOfDay.fromDateTime(when).format(c)}'),
              trailing: const Text('Change'),
              onTap: () async {
                final d = await showDatePicker(context: c, initialDate: when, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d == null || !c.mounted) return;
                final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(when));
                if (t == null) return;
                set(() => when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
              },
            ),
            Wrap(spacing: 8, children: [
              for (final m in [15, 30, 45, 60, 90, 120])
                ChoiceChip(label: Text(m < 60 ? '$m min' : '${m ~/ 60}${m % 60 == 0 ? '' : '.5'} h'), selected: minutes == m, onSelected: (_) => set(() => minutes = m)),
            ]),
            const SizedBox(height: 14),
            const Text('INVITE', style: TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w700, color: Color(0xFF6B6478))),
            const SizedBox(height: 6),
            if (teammates.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final p in teammates)
                  FilterChip(
                    label: Text(p['name'] as String),
                    selected: guests.contains(p['email']),
                    onSelected: (on) => set(() => on ? guests.add(p['email'] as String) : guests.remove(p['email'])),
                  ),
              ]),
            const SizedBox(height: 8),
            TextField(
              controller: guestField,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Guest email',
                hintText: 'name@company.com',
                suffixIcon: IconButton(icon: const Icon(Icons.add), tooltip: 'Add guest', onPressed: () {
                  final e = guestField.text.trim().toLowerCase();
                  if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) set(() { guests.add(e); guestField.clear(); });
                }),
              ),
              onSubmitted: (v) {
                final e = v.trim().toLowerCase();
                if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) set(() { guests.add(e); guestField.clear(); });
              },
            ),
            if (guests.where((g) => !teammates.any((p) => p['email'] == g)).isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in guests.where((g) => !teammates.any((p) => p['email'] == g)))
                  InputChip(label: Text(g), onDeleted: () => set(() => guests.remove(g))),
              ]),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Schedule')),
          ]),
        );
      }),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await _api.post('meetings/schedule', {'title': title.text.trim(), 'starts_at': when.toUtc().toIso8601String(), 'duration_minutes': minutes, 'guests': guests.toList()});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(guests.isEmpty ? 'Meeting scheduled.' : 'Meeting scheduled; ${guests.length} invitation${guests.length == 1 ? '' : 's'} sent.')));
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      AnimatedBuilder(
        animation: Hub.instance,
        builder: (context, _) => BrandHeader(
          title: _tab == 0 ? 'Meetings' : 'Tasks',
          onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
            onAvatarTap: widget.onAvatarTap,
          myStatus: Hub.instance.myStatus,
          bottom: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [_seg(0, 'Meetings'), _seg(1, _openCount == 0 ? 'Tasks' : 'Tasks · $_openCount')]),
            ),
            if (_tab == 0 && _enabled) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _headerButton(Icons.videocam, 'Meet now', () => _open(() => _api.post('meetings/now', {})), strong: true)),
                const SizedBox(width: 10),
                Expanded(child: _headerButton(Icons.event, 'Schedule', _schedule)),
              ]),
            ],
            if (_tab == 1) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _headerButton(Icons.add_task, _canAssign ? 'Assign a task' : 'Add a task', _newTask, strong: true)),
              ]),
            ],
          ]),
        ),
      ),
      Expanded(
        child: _tab == 1
            ? _tasksBody()
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : !_enabled
                ? const EmptyState(icon: Icons.videocam_off_outlined, text: "Meetings aren't switched on for your company yet.")
                : _error != null
                    ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _meetings.isEmpty
                            ? ListView(children: const [SizedBox(height: 80), EmptyState(icon: Icons.event_available, text: 'No upcoming meetings. Start one now or schedule one.')])
                            : ListView.builder(
                                padding: const EdgeInsets.all(14),
                                itemCount: _meetings.length,
                                itemBuilder: (context, i) => _card(_meetings[i]),
                              ),
                      ),
      ),
    ]);
  }

  int get _openCount => _tasks.where((t) => t['status'] == 'open' && t['mine'] == true).length;

  Widget _seg(int i, String label) {
    final on = _tab == i;
    return Expanded(
      child: GestureDetector(
        onTap: () { setState(() => _tab = i); if (i == 1) _loadTasks(); },
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Text(label, style: TextStyle(color: on ? wocomPlum : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  // ── Tasks ──────────────────────────────────────────────────────────────────

  Widget _tasksBody() {
    final now = DateTime.now();
    final open = _tasks.where((t) => t['status'] == 'open').toList();
    final done = _tasks.where((t) => t['status'] != 'open').toList();
    // Meeting reminders: anything on the calendar in the next 24 hours sits with the tasks.
    final reminders = _meetings.where((m) {
      final at = m['starts_at'] != null ? DateTime.tryParse(m['starts_at'] as String)?.toLocal() : null;
      return at != null && at.isAfter(now.subtract(const Duration(minutes: 30))) && at.isBefore(now.add(const Duration(hours: 24)));
    }).toList();
    final mineOpen = open.where((t) => t['mine'] == true).toList();
    final theirsOpen = open.where((t) => t['mine'] != true).toList();
    if (reminders.isEmpty && open.isEmpty && done.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [SizedBox(height: 80), EmptyState(icon: Icons.task_alt, text: 'Nothing on your list. Call-backs assigned from Pulse and tasks from your team show here.')]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        if (reminders.isNotEmpty) ...[
          _sectionLabel('Coming up'),
          for (final m in reminders) _reminderCard(m),
        ],
        if (mineOpen.isNotEmpty) ...[
          _sectionLabel('To do'),
          for (final t in mineOpen) _taskCard(t),
        ],
        if (theirsOpen.isNotEmpty) ...[
          _sectionLabel('Assigned by me'),
          for (final t in theirsOpen) _taskCard(t),
        ],
        if (done.isNotEmpty) ...[
          _sectionLabel('Done this week'),
          for (final t in done) _taskCard(t),
        ],
      ]),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 0, 8),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: wocomMuted)),
      );

  Widget _reminderCard(Map<String, dynamic> m) {
    final at = DateTime.tryParse(m['starts_at'] as String)!.toLocal();
    final mins = at.difference(DateTime.now()).inMinutes;
    final when = mins <= 0 ? 'Starting now' : mins < 60 ? 'In $mins min' : (at.day == DateTime.now().day ? 'Today' : 'Tomorrow') + ' at ${TimeOfDay.fromDateTime(at).format(context)}';
    return Card(
      elevation: 0, color: Colors.white, margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: mins <= 15 ? wocomDeep : wocomLine, width: mins <= 15 ? 1.5 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.videocam_outlined, color: wocomDeep)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((m['title'] ?? 'Meeting') as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
            Text('$when · ${m['duration_minutes'] ?? 30} min', style: const TextStyle(color: wocomMuted, fontSize: 12.5)),
          ])),
          SizedBox(height: 38, child: OutlinedButton(onPressed: _busy ? null : () => _open(() => _api.post('meetings/${m['code']}/join', {})), style: OutlinedButton.styleFrom(minimumSize: const Size(64, 38), padding: const EdgeInsets.symmetric(horizontal: 14)), child: const Text('Join'))),
        ]),
      ),
    );
  }

  Widget _taskCard(Map<String, dynamic> t) {
    final done = t['status'] != 'open';
    final callback = t['type'] == 'callback' && (t['number'] ?? '').toString().isNotEmpty;
    final due = t['due_at'] != null ? DateTime.tryParse(t['due_at'] as String)?.toLocal() : null;
    final overdue = due != null && !done && due.isBefore(DateTime.now());
    final parts = <String>[
      if (t['assigned_by'] != null && t['mine'] == true) 'from ${t['assigned_by']}',
      if (t['mine'] != true) 'for ${t['assignee']}',
      if (due != null) (overdue ? 'was due ' : 'due ') + (due.day == DateTime.now().day && due.month == DateTime.now().month ? TimeOfDay.fromDateTime(due).format(context) : _dueLabel(due)),
      if (done && t['done_by'] != null) 'done by ${t['done_by']}',
    ];
    return Card(
      elevation: 0, color: Colors.white, margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: overdue ? const Color(0xFFF59E0B) : wocomLine, width: overdue ? 1.5 : 1)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _taskActions(t),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Opacity(
            opacity: done ? 0.55 : 1,
            child: Row(children: [
              SizedBox(
                width: 42, height: 42,
                child: Material(
                  color: done ? const Color(0xFFE7F6EC) : (callback ? const Color(0xFFFFF4DB) : wocomSoft),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _setTask(t, !done),
                    child: Icon(done ? Icons.check : (callback ? Icons.phone_callback_outlined : Icons.radio_button_unchecked), color: done ? const Color(0xFF15803D) : (callback ? const Color(0xFFB45309) : wocomDeep), size: 21),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((t['title'] ?? '') as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, decoration: done ? TextDecoration.lineThrough : null)),
                if ((t['note'] ?? '').toString().isNotEmpty) Text(t['note'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF4B4560), fontSize: 12.5)),
                if (parts.isNotEmpty) Text(parts.join(' · '), style: TextStyle(color: overdue ? const Color(0xFFB45309) : wocomMuted, fontSize: 12, fontWeight: overdue ? FontWeight.w700 : FontWeight.w500)),
              ])),
              if (callback && !done) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 42, height: 42,
                  child: Material(
                    color: const Color(0xFF22C55E), shape: const CircleBorder(),
                    child: InkWell(customBorder: const CircleBorder(), onTap: () => _callNumber(t['number'] as String), child: const Icon(Icons.call, color: Colors.white, size: 20)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _callNumber(String number) async {
    await Phone.instance.dial(number.length == 11 && number.startsWith('1876') ? number.substring(1) : number);
  }

  Future<void> _setTask(Map<String, dynamic> t, bool done) async {
    try {
      await _api.post('tasks/${t['id']}/${done ? 'done' : 'reopen'}');
      await _loadTasks();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _taskActions(Map<String, dynamic> t) async {
    final done = t['status'] != 'open';
    final callback = t['type'] == 'callback' && (t['number'] ?? '').toString().isNotEmpty;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(3)))),
            const SizedBox(height: 14),
            Text((t['title'] ?? '') as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            if ((t['note'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(t['note'] as String, style: const TextStyle(fontSize: 13.5, color: Color(0xFF4B4560)))),
            const SizedBox(height: 10),
            if (callback && !done) ListTile(leading: const Icon(Icons.call, color: Color(0xFF15803D)), title: const Text('Call now', style: TextStyle(fontWeight: FontWeight.w700)), onTap: () { Navigator.pop(c); _callNumber(t['number'] as String); }),
            ListTile(leading: Icon(done ? Icons.undo : Icons.check_circle_outline, color: wocomDeep), title: Text(done ? 'Reopen' : 'Mark done', style: const TextStyle(fontWeight: FontWeight.w700)), onTap: () { Navigator.pop(c); _setTask(t, !done); }),
          ]),
        ),
      ),
    );
  }

  bool _isQuickPick(DateTime d) {
    final n = DateTime.now();
    return d == DateTime(n.year, n.month, n.day, 17) || d == DateTime(n.year, n.month, n.day + 1, 9);
  }

  String _dueLabel(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${TimeOfDay.fromDateTime(d).format(context)}';
  }

  /// New task: title, note, who (managers), and an optional due time.
  Future<void> _newTask() async {
    final title = TextEditingController();
    final note = TextEditingController();
    int? assignee = _canAssign ? null : Hub.instance.meUserId;
    DateTime? due;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(c).viewInsets.bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: wocomLine, borderRadius: BorderRadius.circular(3)))),
            const SizedBox(height: 14),
            Text(_canAssign ? 'Assign a task' : 'Add a task', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            TextField(controller: title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'What needs doing')),
            const SizedBox(height: 10),
            TextField(controller: note, minLines: 1, maxLines: 3, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Details (optional)')),
            if (_canAssign) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: assignee,
                decoration: const InputDecoration(labelText: 'For'),
                items: [
                  DropdownMenuItem(value: Hub.instance.meUserId, child: const Text('Myself')),
                  for (final p in _people) if (p['id'] != Hub.instance.meUserId) DropdownMenuItem(value: (p['id'] as num).toInt(), child: Text((p['name'] ?? '') as String)),
                ],
                onChanged: (v) => setS(() => assignee = v),
              ),
            ],
            const SizedBox(height: 10),
            // Due: quick picks, or a date and time of your own.
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Due', style: TextStyle(fontWeight: FontWeight.w700, color: wocomMuted)),
              for (final (label, d) in [('None', null), ('Today 5 PM', DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, 17)), ('Tomorrow 9 AM', DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day + 1, 9))])
                ChoiceChip(label: Text(label, style: const TextStyle(fontSize: 12)), selected: due == d, onSelected: (_) => setS(() => due = d)),
              ActionChip(
                avatar: const Icon(Icons.event, size: 16),
                label: Text(due != null && !_isQuickPick(due!) ? _dueLabel(due!) : 'Pick date & time', style: const TextStyle(fontSize: 12)),
                backgroundColor: due != null && !_isQuickPick(due!) ? wocomSoft : null,
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: c, initialDate: due ?? now, firstDate: now.subtract(const Duration(days: 1)), lastDate: now.add(const Duration(days: 365)));
                  if (d == null || !c.mounted) return;
                  final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(due ?? DateTime(now.year, now.month, now.day, 9)));
                  if (t == null) return;
                  setS(() => due = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                },
              ),
            ]),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: wocomDeep),
              onPressed: () => Navigator.pop(c, title.text.trim().isNotEmpty),
              child: Text(_canAssign && assignee != Hub.instance.meUserId ? 'Assign' : 'Add'),
            ),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _api.post('tasks', {'title': title.text.trim(), 'note': note.text.trim(), if (assignee != null) 'user_id': assignee, if (due != null) 'due_at': due!.toUtc().toIso8601String()});
      await _loadTasks();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(assignee == Hub.instance.meUserId || assignee == null ? 'Added to your list.' : 'Assigned. They have been notified.')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _headerButton(IconData icon, String label, VoidCallback onTap, {bool strong = false}) => SizedBox(
        height: 50,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : onTap,
          icon: Icon(icon, size: 20),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            foregroundColor: Colors.white,
            side: BorderSide(color: strong ? Colors.white : Colors.white54, width: 2),
          ),
        ),
      );

  Widget _card(Map<String, dynamic> m) {
    final starts = m['starts_at'] != null ? DateTime.tryParse(m['starts_at'] as String)?.toLocal() : null;
    final instant = m['is_instant'] == true || starts == null;
    final soon = starts != null && starts.difference(DateTime.now()).inMinutes <= 15;
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: soon || instant ? wocomDeep : wocomLine, width: soon || instant ? 1.5 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 56,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              Text(instant ? 'Now' : TimeOfDay.fromDateTime(starts).format(context).split(' ').first, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF6E2381), fontSize: 15)),
              if (!instant) Text(starts.hour < 12 ? 'AM' : 'PM', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6E2381))),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((m['title'] ?? 'Meeting') as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
              Text(
                instant ? 'Open room' : '${starts.day == DateTime.now().day ? 'Today' : timeAgoLabel(starts)} · ${m['duration_minutes'] ?? 30} min${m['is_recurring'] == true ? ' · ${m['recurrence']}' : ''}',
                style: const TextStyle(color: Color(0xFF5E5670), fontSize: 13),
              ),
            ]),
          ),
          SizedBox(
            height: 40,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _open(() => _api.post('meetings/${m['code']}/join', {})),
              style: OutlinedButton.styleFrom(minimumSize: const Size(72, 40), padding: const EdgeInsets.symmetric(horizontal: 16)),
              child: const Text('Join'),
            ),
          ),
        ]),
      ),
    );
  }
}
