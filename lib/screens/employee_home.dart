import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../brand.dart';
import '../services/api.dart';
import '../services/app_update.dart';
import '../services/device_health.dart';
import '../services/diag.dart';
import '../services/dial_plan.dart';
import '../services/phone.dart';
import '../services/push_service.dart';
import '../services/techhub.dart';
import 'announcements_screen.dart';
import 'absence_screen.dart';
import 'attendance_screen.dart';
import '../services/arrival.dart';
import 'door_screen.dart';
import '../services/text_zoom.dart';
import '../services/we_location.dart';
import '../services/photo_queue.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'about_screen.dart';
import 'home_screen.dart';
import 'keypad_screen.dart';
import 'phone_contacts_view.dart';
import 'team_chat_screen.dart';
import 'techhub_screen.dart';

/// WE App (WOCOM Employee). Before sign-in: the welcome and Tech Hub sign-in. After: Tech Hub,
/// Team, Keypad and Recents, with the phone line on the engineer's office extension.
class EmployeeRoot extends StatelessWidget {
  const EmployeeRoot({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: TechHub.instance,
        builder: (context, _) {
          final th = TechHub.instance;
          if (!th.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          return th.signedIn ? const _EmployeeHome() : const Scaffold(body: TechHubScreen());
        },
      );
}

class _EmployeeHome extends StatefulWidget {
  const _EmployeeHome();
  @override
  State<_EmployeeHome> createState() => _EmployeeHomeState();
}

class _EmployeeHomeState extends State<_EmployeeHome> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    await [Permission.microphone, Permission.notification, Permission.bluetoothConnect].request();
    await PushService.instance.init();
    await TechHub.instance.registerDevice();
    Phone.instance.watchNetwork();
    Phone.instance.addListener(_onLine);
    TechHub.instance.addListener(_onDuty);
    WeLocation.instance.sync();
    PhotoQueue.instance.init();
    ArrivalCheck.instance.start();
    TechHub.instance.leaveEvent.addListener(_onLeaveEvent);
    TechHub.instance.idleEvent.addListener(_onIdleEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onIdleEvent()); // launched from the notification
    TechHub.instance.refreshMe().catchError((_) {});
    TechHub.instance.announcementsEvent.addListener(_popAnnouncement);
    TechHub.instance.doorEvent.addListener(_onDoorEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _popAnnouncement());
    if (TechHub.instance.calling) await Phone.instance.connect();
    _onLine();
    await DeviceHealth.instance.refresh();
    if (mounted) AppUpdate.instance.check(context);
  }

  int _doorSeen = 0;
  void _onDoorEvent() {
    final v = TechHub.instance.doorEvent.value;
    if (v == _doorSeen || !mounted) return;
    _doorSeen = v;
    if (ModalRoute.of(context)?.isCurrent ?? true) Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DoorScreen()));
  }

  static final _idleSeen = <String>{};
  static final _idleShownAt = <String, DateTime>{};
  void _onIdleEvent() {
    final v = TechHub.instance.idleEvent.value;
    if (v.isEmpty || _idleSeen.contains(v) || !mounted || Phone.instance.call != null) return;
    _idleSeen.add(v);
    final parts = v.split('|');
    if (parts.first.isEmpty) return;
    final last = _idleShownAt[parts.first];
    if (last != null && DateTime.now().difference(last).inMinutes < 2) return; // push + tap of the same warning
    _idleShownAt[parts.first] = DateTime.now();
    showIdleTicketDialog(context, parts.first, parts.length > 2 ? parts[1] : '');
  }

  void _onLeaveEvent() {
    final v = TechHub.instance.leaveEvent.value;
    if (v.isEmpty || !mounted || Phone.instance.call != null) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return; // the open screen reloads itself
    final lead = v.startsWith('leave_request') && TechHub.instance.approvesLeave;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => lead ? const LeaveRequestsScreen() : const AttendanceScreen()));
  }

  void _popAnnouncement() {
    if (!mounted || Phone.instance.call != null) return; // never cover a call
    AnnouncementPopup.maybeShow(context);
  }

  bool? _wasOnDuty;
  void _onDuty() {
    final d = TechHub.instance.onDuty;
    if (d != _wasOnDuty) { _wasOnDuty = d; WeLocation.instance.sync(); }
  }

  DateTime _lastAutoDiag = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tell the push server how the line is doing; if it fails, send the log too (at most every 15 min).
  void _onLine() {
    final p = Phone.instance;
    final th = TechHub.instance;
    final status = th.calling ? p.status.name : 'not_set_up';
    TechHub.instance.reportLine(status, th.calling ? p.statusText : (th.callingNote ?? 'No office extension'));
    if ((p.status == LineStatus.failed || !th.calling) && DateTime.now().difference(_lastAutoDiag) > const Duration(minutes: 15)) {
      _lastAutoDiag = DateTime.now();
      Diag.instance.send(note: 'automatic: line ${th.calling ? p.status.name : 'not set up'} · ${th.calling ? p.statusText : th.callingNote ?? ''}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      TechHub.instance.changes.value++;
      _popAnnouncement();
      ArrivalCheck.instance.check();
      if (TechHub.instance.calling && Phone.instance.status != LineStatus.ready) Phone.instance.restart('app resumed');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Phone.instance.removeListener(_onLine);
    TechHub.instance.removeListener(_onDuty);
    TechHub.instance.announcementsEvent.removeListener(_popAnnouncement);
    TechHub.instance.doorEvent.removeListener(_onDoorEvent);
    TechHub.instance.leaveEvent.removeListener(_onLeaveEvent);
    TechHub.instance.idleEvent.removeListener(_onIdleEvent);
    ArrivalCheck.instance.stop();
    WeLocation.instance.stop();
    Phone.instance.disconnect();
    super.dispose();
  }

  void _go(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) => Scaffold(
        // Same key as the WOCOM HUB home, so every screen's ☰ button opens this menu.
        key: HomeScreen.scaffoldKey,
        drawer: _EmployeeDrawer(onTab: _go),
        body: IndexedStack(index: _tab, children: [
          const TechHubScreen(),
          const TeamChatsScreen(),
          const _TeamScreen(),
          AnimatedBuilder(
            animation: TechHub.instance,
            builder: (context, _) => TechHub.instance.calling ? KeypadScreen(onAvatarTap: () {}, onOpenDirectory: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _PhoneContactsPage()))) : _CallingOff(note: TechHub.instance.callingNote),
          ),
          const _RecentsScreen(),
        ]),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: wocomLine))),
          child: NavigationBar(
            selectedIndex: _tab,
            backgroundColor: Colors.transparent,
            elevation: 0,
            onDestinationSelected: _go,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.build_outlined), selectedIcon: Icon(Icons.build), label: 'Tech Hub'),
              NavigationDestination(icon: _ChatBadge(icon: Icons.chat_bubble_outline), selectedIcon: _ChatBadge(icon: Icons.chat_bubble), label: 'Chats'),
              NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Team'),
              NavigationDestination(icon: Icon(Icons.dialpad), label: 'Keypad'),
              NavigationDestination(icon: Icon(Icons.history), label: 'Recents'),
            ],
          ),
        ),
      );
}

// ── side menu ─────────────────────────────────────────────────────────────────

class _EmployeeDrawer extends StatelessWidget {
  const _EmployeeDrawer({required this.onTab});
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final th = TechHub.instance;
    void go(int i) { Navigator.pop(context); onTab(i); }
    return Drawer(
      backgroundColor: Colors.white,
      child: Column(children: [
        AnimatedBuilder(
          animation: Listenable.merge([th, Phone.instance]),
          builder: (context, _) {
            final ready = Phone.instance.status == LineStatus.ready;
            return Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 20, 20, 18),
              color: wocomPlum,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                PersonAvatar(name: th.name.isEmpty ? 'WE' : th.name, size: 56, onDark: true),
                const SizedBox(height: 12),
                Text(th.name.isEmpty ? 'WOCOM employee' : th.name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                Text((th.engineer?['email'] ?? '').toString(), style: const TextStyle(color: wocomTintLight, fontSize: 12.5)),
                const SizedBox(height: 10),
                Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: ready ? const Color(0xFF22C55E) : const Color(0xFFF59E0B))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    th.extension.isEmpty ? 'No office extension yet' : 'Extension ${th.extension} · ${ready ? 'ready for calls' : (th.calling ? 'connecting…' : 'calls not set up')}',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                  )),
                ]),
              ]),
            );
          },
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
            _item(Icons.build_outlined, 'Tech Hub', () => go(0)),
            _item(Icons.chat_bubble_outline, 'Team chat', () => go(1)),
            _item(Icons.groups_outlined, 'Team & contacts', () => go(2)),
            _item(Icons.dialpad, 'Keypad', () => go(3)),
            _item(Icons.history, 'Recent calls', () => go(4)),
            const Divider(height: 20),
            AnimatedBuilder(
              animation: th,
              builder: (context, _) => SwitchListTile(
                secondary: const Icon(Icons.work_outline),
                title: const Text('On duty', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: AnimatedBuilder(
                  animation: WeLocation.instance,
                  builder: (context, _) => Text(th.onDuty
                      ? (WeLocation.instance.sharing ? 'All ticket alerts · sharing location' : (WeLocation.instance.problem ?? 'All ticket alerts'))
                      : 'Urgent alerts only · location not shared'),
                ),
                value: th.onDuty,
                onChanged: (v) async { try { await th.setDuty(v); } on ApiException catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); } },
              ),
            ),
            _item(Icons.meeting_room_outlined, 'Office door', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DoorScreen())); }),
            _item(Icons.event_busy_outlined, 'Absence / running late', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AbsenceScreen())); }),
            _item(Icons.event_available_outlined, 'My attendance & vacation', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AttendanceScreen())); }),
            if (TechHub.instance.approvesLeave) _item(Icons.fact_check_outlined, 'Vacation requests', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LeaveRequestsScreen())); }),
            ListTile(
              leading: const Icon(Icons.campaign_outlined, color: wocomDeep),
              title: const Text('Announcements', style: TextStyle(fontWeight: FontWeight.w600)),
              trailing: th.announcementsUnread > 0 ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFDC2626), borderRadius: BorderRadius.circular(10)),
                child: Text('${th.announcementsUnread}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
              ) : null,
              onTap: () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AnnouncementsScreen())); },
            ),
            _item(Icons.settings_outlined, 'Settings', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _EmployeeSettings())); }),
            _item(Icons.info_outline, 'About ${Brand.name}', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())); }),
            const Divider(height: 20),
            _item(Icons.logout, 'Sign out', () async {
              Navigator.pop(context);
              final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
                title: const Text('Sign out?'),
                content: const Text('This phone stops receiving your ticket alerts and office calls until you sign in again.'),
                actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out'))],
              ));
              if (ok == true) { Phone.instance.disconnect(); await th.signOut(); }
            }, color: const Color(0xFFB91C1C)),
          ]),
        ),
        Padding(padding: const EdgeInsets.all(14), child: Text('${Brand.name}  ·  v${PushApi.appVersion}', style: const TextStyle(color: wocomMuted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1))),
      ]),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
        leading: Icon(icon, color: color ?? wocomDeep),
        title: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        onTap: onTap,
      );
}

class _EmployeeSettings extends StatefulWidget {
  const _EmployeeSettings();
  @override
  State<_EmployeeSettings> createState() => _EmployeeSettingsState();
}

class _EmployeeSettingsState extends State<_EmployeeSettings> {
  @override
  void initState() { super.initState(); DeviceHealth.instance.refresh().then((_) { if (mounted) setState(() {}); }); }

  @override
  Widget build(BuildContext context) {
    final h = DeviceHealth.instance;
    return Scaffold(
      backgroundColor: wocomBg,
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        _card('Calls and alerts', [
          ListTile(
            leading: Icon(h.batteryOk ? Icons.battery_full : Icons.battery_alert, color: h.batteryOk ? const Color(0xFF15803D) : const Color(0xFFB45309)),
            title: const Text('Battery optimisation'),
            subtitle: Text(h.batteryOk ? 'Off: calls and alerts can wake this phone' : 'On: Android may stop calls and alerts reaching you'),
            trailing: h.batteryOk ? null : TextButton(onPressed: () async { await h.fixBattery(); await h.refresh(); if (mounted) setState(() {}); }, child: const Text('Fix')),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined, color: wocomDeep),
            title: const Text('Notifications'),
            subtitle: const Text('Open Android settings for this app'),
            onTap: () => openAppSettings(),
          ),
          ListTile(
            leading: const Icon(Icons.rocket_launch_outlined, color: wocomDeep),
            title: const Text('Auto-start'),
            subtitle: const Text('Some phones need this so the app can wake for calls'),
            onTap: () => h.openAutoStart(),
          ),
        ]),
        const SizedBox(height: 12),
        _card('Text size', [
          ValueListenableBuilder<double>(
            valueListenable: TextZoom.instance,
            builder: (context, z, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${(z * 100).round()}%  ·  or pinch with two fingers on any screen', style: const TextStyle(color: wocomMuted)),
                Slider(value: z, min: TextZoom.min, max: TextZoom.max, divisions: 23, onChanged: TextZoom.instance.set),
                Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => TextZoom.instance.set(1.0), child: const Text('Reset to normal'))),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _card('App', [
          ListTile(
            leading: const Icon(Icons.bug_report_outlined, color: wocomDeep),
            title: const Text('Send diagnostics'),
            subtitle: const Text('Sends the call log and line status to WOCOM support'),
            onTap: () async {
              final err = await Diag.instance.send(note: 'sent from Settings');
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Sent. Thank you.')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined, color: wocomDeep),
            title: const Text('Check for updates'),
            subtitle: Text('Version ${PushApi.appVersion}'),
            onTap: () async {
              final found = await AppUpdate.instance.check(context, force: true);
              if (!found && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have the latest version.')));
            },
          ),
        ]),
      ]),
    );
  }

  Widget _card(String title, List<Widget> rows) => Container(
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: wocomLine), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: wocomMuted, letterSpacing: 0.5))),
          ...rows,
        ]),
      );
}

// ── team & phone contacts ─────────────────────────────────────────────────────

/// WE App team colours (owner's choice): available green, on a call orange, offline red.
Color _weColor(String s) => switch (s) {
      'available' => const Color(0xFF16A34A),
      'on_call' => const Color(0xFFEA580C),
      'ringing' => const Color(0xFF2563EB),
      'away' => const Color(0xFFCA8A04),
      _ => const Color(0xFFDC2626),
    };
Color _weTextColor(String s) => switch (s) {
      'available' => const Color(0xFF15803D),
      'on_call' => const Color(0xFFC2410C),
      'ringing' => const Color(0xFF1D4ED8),
      'away' => const Color(0xFF854D0E),
      _ => const Color(0xFFB91C1C),
    };

String _statusLabel(String s) => switch (s) {
      'available' => 'Available', 'on_call' => 'On a call', 'ringing' => 'Ringing', 'dnd' => 'Do not disturb', 'away' => 'Away', _ => 'Offline',
    };

String _withWhom(Map p) {
  final w = p['in_call_with'];
  if (w is! Map) return '';
  final who = (w['name'] ?? '').toString().isNotEmpty ? w['name'].toString() : prettyNumber((w['number'] ?? '').toString());
  return who.isEmpty ? '' : ' with $who';
}

class _TeamScreen extends StatefulWidget {
  const _TeamScreen();
  @override
  State<_TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<_TeamScreen> {
  int _source = 0; // 0 office · 1 availability
  List<Map<String, dynamic>> _people = []; // Tech Hub people (with availability)
  List<Map<String, dynamic>> _cover = [];  // jobs that need cover
  String _q = '';
  List<Map<String, dynamic>> _team = [];
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(quiet: true));
  }

  @override
  void dispose() { _poll?.cancel(); super.dispose(); }

  /// Workspace extension → Tech Hub chat person id, so anyone on Team can be messaged.
  Map<String, int> _chatIds = {};
  /// Workspace extension → Tech Hub availability (absence) when someone is out or late.
  Map<String, Map<String, dynamic>> _away = {};
  DateTime _chatIdsAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _loadChatIds() async {
    if (DateTime.now().difference(_chatIdsAt) < const Duration(minutes: 1)) return;
    try {
      final people = await TechHub.instance.chatPeople();
      final m = <String, int>{};
      final away = <String, Map<String, dynamic>>{};
      for (final p in people) {
        final ext = (p['extension'] ?? '').toString();
        final id = (p['id'] as num?)?.toInt() ?? int.tryParse('${p['id']}');
        if (ext.isNotEmpty && id != null) m[ext] = id;
        final av = p['availability'];
        if (ext.isNotEmpty && av is Map && av['state'] != null) away[ext] = Map<String, dynamic>.from(av);
      }
      _chatIds = m;
      _away = away;
      _people = people;
      _chatIdsAt = DateTime.now();
    } catch (_) {}
  }

  Future<void> _message(Map<String, dynamic> p) async {
    final ext = (p['extension'] ?? '').toString();
    final name = (p['name'] ?? ext).toString();
    await _loadChatIds();
    final id = _chatIds[ext] ?? int.tryParse('${p['techhub_user_id'] ?? ''}');
    if (id == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$name isn't on Tech Hub chat yet, so they can only be called.")));
      return;
    }
    try {
      final conv = await TechHub.instance.openChat(id);
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TeamChatScreen(id: conv, title: name)));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _load({bool quiet = false}) async {
    _loadChatIds().then((_) { if (mounted) setState(() {}); });
    if (_source == 1) TechHub.instance.tickets('cover').then((l) { if (mounted) setState(() => _cover = l); }).catchError((_) {});
    try {
      final t = await TechHub.instance.team();
      if (mounted) setState(() { _team = t; _error = null; _loading = false; });
    } on ApiException catch (e) {
      if (mounted && (!quiet || _team.isEmpty)) setState(() { _error = e.message; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = TechHub.instance.extension;
    final q = _q.trim().toLowerCase();
    final list = _team.where((p) => q.isEmpty || '${p['name']} ${p['extension']}'.toLowerCase().contains(q)).toList();
    // People: you first, then available, on a call, ringing, away, offline; departments after.
    const order = {'available': 0, 'on_call': 1, 'ringing': 2, 'away': 3, 'offline': 4};
    // People whose account was disabled in Tech Hub are not shown.
    final people = list.where((p) => (p['type'] ?? 'extension') == 'extension' && p['disabled'] != true).toList()
      ..sort((a, b) {
        if (a['extension'] == me) return -1;
        if (b['extension'] == me) return 1;
        final sa = _away.containsKey(a['extension']) ? 'offline' : a['status'];
        final sb = _away.containsKey(b['extension']) ? 'offline' : b['status'];
        final o = (order[sa] ?? 5).compareTo(order[sb] ?? 5);
        return o != 0 ? o : (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
      });
    final depts = list.where((p) => (p['type'] ?? 'extension') != 'extension').toList();
    return Column(children: [
      BrandHeader(
        title: 'Team',
        subtitle: me.isEmpty ? null : 'You are ext $me',
        onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
        search: (v) => setState(() => _q = v),
        bottom: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [_seg(0, 'Office'), _seg(1, _away.isEmpty ? 'Availability' : 'Availability · ${_away.length} out')]),
        ),
      ),
      Expanded(
        child: _source == 1
            ? _availability(list, me)
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                          // Legend: what each colour means, always visible.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Wrap(spacing: 12, runSpacing: 6, children: [
                              for (final s in ['available', 'on_call', 'ringing', 'away', 'offline']) Row(mainAxisSize: MainAxisSize.min, children: [
                                Container(width: 10, height: 10, decoration: BoxDecoration(color: _weColor(s), shape: BoxShape.circle)),
                                const SizedBox(width: 5),
                                Text(_statusLabel(s), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: wocomMuted)),
                              ]),
                            ]),
                          ),
                          if (people.isNotEmpty) _section('People', '${people.where((p) => p['status'] == 'available' && !_away.containsKey(p['extension'])).length} available of ${people.length}'),
                          for (final p in people) _personRow(p, me),
                          if (depts.isNotEmpty) _section('Departments', 'Ring groups and queues'),
                          for (final d in depts) _deptRow(d),
                        ]),
                      ),
      ),
    ]);
  }

  /// Who is out or late, who is free right now, and the jobs that need someone to cover them.
  Widget _availability(List<Map<String, dynamic>> office, String me) {
    final q = _q.trim().toLowerCase();
    bool match(Map p) => q.isEmpty || '${p['name']} ${p['extension']}'.toLowerCase().contains(q);
    final away = _people.where((p) => p['availability'] is Map && (p['availability'] as Map)['state'] != null && match(p)).toList()
      ..sort((a, b) => ((a['availability'] as Map)['state'] == 'late' ? 0 : 1).compareTo((b['availability'] as Map)['state'] == 'late' ? 0 : 1));
    final free = office.where((p) => (p['type'] ?? 'extension') == 'extension' && p['status'] == 'available' && !_away.containsKey(p['extension'])).toList();
    final busy = office.where((p) => (p['type'] ?? 'extension') == 'extension' && (p['status'] == 'on_call' || p['status'] == 'ringing') && !_away.containsKey(p['extension'])).toList();
    final late = away.where((p) => (p['availability'] as Map)['state'] == 'late').length;
    Widget count(String n, String l, Color c) => Expanded(child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.35))),
          child: Column(children: [
            Text(n, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: c)),
            Text(l, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c)),
          ]),
        ));
    return RefreshIndicator(
      onRefresh: () async { _chatIdsAt = DateTime.fromMillisecondsSinceEpoch(0); await _load(); },
      child: ListView(padding: const EdgeInsets.only(bottom: 20), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(children: [
            count('${free.length}', 'Available', const Color(0xFF16A34A)),
            const SizedBox(width: 8),
            count('${busy.length}', 'On a call', const Color(0xFFEA580C)),
            const SizedBox(width: 8),
            count('$late', 'Late', const Color(0xFFCA8A04)),
            const SizedBox(width: 8),
            count('${away.length - late}', 'Out', const Color(0xFFDC2626)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: wocomDeep, side: const BorderSide(color: wocomDeep, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: () async { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AbsenceScreen())); _chatIdsAt = DateTime.fromMillisecondsSinceEpoch(0); _load(); },
            icon: const Icon(Icons.event_busy_outlined),
            label: const Text('Report my absence / running late', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
        _section('Not available', away.isEmpty ? 'Everyone is in today' : '${away.length} ${away.length == 1 ? 'person' : 'people'}'),
        for (final p in away) _awayRow(p),
        if (_cover.isNotEmpty) ...[
          _section('Jobs that need cover', 'Tap one to take it'),
          for (final t in _cover)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFCA5A5))),
              child: ListTile(
                leading: const Icon(Icons.pan_tool_alt_outlined, color: Color(0xFFB91C1C)),
                title: Text('${t['ticket_number'] ?? ''} · ${t['client_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text('${t['subject'] ?? ''}${(t['absent_name'] ?? '').toString().isNotEmpty ? '\n${t['absent_name']} is out' : ''}'),
                isThreeLine: (t['absent_name'] ?? '').toString().isNotEmpty,
                trailing: const Icon(Icons.chevron_right),
                onTap: () async { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketScreen(number: t['ticket_number'].toString()))); _load(); },
              ),
            ),
        ],
        _section('Available now', free.isEmpty ? 'Nobody free at the moment' : '${free.length} free to take work or calls'),
        for (final p in free.where(match)) _personRow(p, me),
      ]),
    );
  }

  Widget _awayRow(Map<String, dynamic> p) {
    final av = p['availability'] as Map;
    final late = av['state'] == 'late';
    final c = late ? const Color(0xFFCA8A04) : const Color(0xFFDC2626);
    final ext = (p['extension'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomLine)),
      child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 6, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)))),
        Expanded(child: ListTile(
          leading: PersonAvatar(name: (p['name'] ?? ext).toString(), size: 44),
          title: Text((p['name'] ?? ext).toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          subtitle: Text('${ext.isNotEmpty ? 'Ext $ext · ' : ''}${av['label'] ?? (late ? 'Running late' : 'Out')}', style: TextStyle(fontWeight: FontWeight.w800, color: c)),
          trailing: IconButton(
            tooltip: 'Message',
            style: IconButton.styleFrom(backgroundColor: const Color(0xFFEDE9FE), fixedSize: const Size(46, 46)),
            icon: const Icon(Icons.chat_bubble_outline, color: wocomDeep),
            onPressed: () => _message({'extension': ext, 'name': p['name'], 'techhub_user_id': p['id']}),
          ),
        )),
      ])),
    );
  }

  Widget _section(String title, String sub) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Row(children: [
          Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.6, color: wocomInk)),
          const SizedBox(width: 8),
          Expanded(child: Text(sub, style: const TextStyle(fontSize: 12, color: wocomMuted))),
        ]),
      );

  Widget _personRow(Map<String, dynamic> p, String me) {
    final ext = (p['extension'] ?? '').toString();
    final away = _away[ext];
    // Reported out or late in Tech Hub: always "Not available", whatever the phone line says.
    final status = away != null ? 'offline' : (p['status'] ?? 'offline').toString();
    final isMe = ext == me;
    final c = _weColor(status);
    final devs = p['devices'] is Map ? p['devices'] as Map : const {};
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomLine)),
      child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 6, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)))),
        Expanded(child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          leading: Stack(clipBehavior: Clip.none, children: [
            PersonAvatar(name: (p['name'] ?? ext).toString(), size: 44),
            Positioned(right: -1, bottom: -1, child: Container(width: 15, height: 15, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2.5)))),
          ]),
          title: Text('${p['name'] ?? ext}${isMe ? '  (you)' : ''}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Ext $ext', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: wocomInk)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                child: Text(away != null
                    ? 'Not available · ${(away['label'] ?? (away['state'] == 'late' ? 'Running late' : 'Out')).toString()}'
                    : '${_statusLabel(status)}${_withWhom(p)}${(p['status_reason'] ?? '').toString().isNotEmpty ? ' · ${p['status_reason']}' : ''}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: away != null && away['state'] == 'late' ? const Color(0xFFC2410C) : _weTextColor(status))),
              ),
              if (devs['app'] == true) const Icon(Icons.phone_android, size: 15, color: wocomMuted),
              if (devs['phone'] == true) const Icon(Icons.phone_outlined, size: 15, color: wocomMuted),
            ]),
          ),
          trailing: isMe ? null : Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Message ${p['name'] ?? ext}',
              style: IconButton.styleFrom(backgroundColor: _chatIds.containsKey(ext) ? const Color(0xFFEDE9FE) : const Color(0xFFF3F4F6), fixedSize: const Size(46, 46)),
              icon: Icon(Icons.chat_bubble_outline, color: _chatIds.containsKey(ext) ? wocomDeep : const Color(0xFF9CA3AF)),
              onPressed: () => _message(p),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Call $ext',
              style: IconButton.styleFrom(backgroundColor: const Color(0xFFE7F6EC), fixedSize: const Size(46, 46)),
              icon: const Icon(Icons.call, color: Color(0xFF15803D)),
              onPressed: () => Phone.instance.dial(ext),
            ),
          ]),
        )),
      ])),
    );
  }

  Widget _deptRow(Map<String, dynamic> d) {
    final ext = (d['extension'] ?? '').toString();
    final queue = d['type'] == 'queue';
    final waiting = (d['waiting'] as num?)?.toInt() ?? 0;
    final agents = (d['available_agents'] as num?)?.toInt();
    final members = (d['members'] is List) ? (d['members'] as List).length : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(color: const Color(0xFFF2F7FF), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFCFE0F7))),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: const Color(0xFF1D4ED8), borderRadius: BorderRadius.circular(12)),
          child: Icon(queue ? Icons.support_agent : Icons.apartment, color: Colors.white),
        ),
        title: Text((d['name'] ?? ext).toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        subtitle: Text(
          [ 'Department · Ext $ext', if (queue && agents != null) '$agents available', if (queue && waiting > 0) '$waiting waiting', if (!queue && members != null) '$members people' ].join(' · '),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: waiting > 0 ? const Color(0xFFB45309) : const Color(0xFF1E3A8A)),
        ),
        trailing: IconButton(
          tooltip: 'Call $ext',
          style: IconButton.styleFrom(backgroundColor: const Color(0xFFDBEAFE), fixedSize: const Size(46, 46)),
          icon: const Icon(Icons.call, color: Color(0xFF1D4ED8)),
          onPressed: () => Phone.instance.dial(ext),
        ),
      ),
    );
  }

  Widget _seg(int i, String label) {
    final on = _source == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _source = i),
        child: Container(
          height: 34, alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Text(label, style: TextStyle(color: on ? wocomPlum : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}

// ── recents ──────────────────────────────────────────────────────────────────

class _RecentsScreen extends StatefulWidget {
  const _RecentsScreen();
  @override
  State<_RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<_RecentsScreen> {
  List<Map<String, dynamic>> _calls = [];
  bool _loading = true;
  bool _missedOnly = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    Phone.instance.addListener(_onPhone);
  }

  bool _wasOnCall = false;
  void _onPhone() {
    final on = Phone.instance.call != null;
    if (_wasOnCall && !on) Future.delayed(const Duration(seconds: 2), _load); // a call just ended
    _wasOnCall = on;
  }

  @override
  void dispose() { Phone.instance.removeListener(_onPhone); super.dispose(); }

  Future<void> _load() async {
    try {
      final c = await TechHub.instance.recents();
      if (mounted) setState(() { _calls = c; _error = null; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _missedOnly ? _calls.where((c) => c['missed'] == true).toList() : _calls;
    final missed = _calls.where((c) => c['missed'] == true).length;
    return Column(children: [
      BrandHeader(
        title: 'Recents',
        onMenuTap: () => HomeScreen.scaffoldKey.currentState?.openDrawer(),
        bottom: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [_seg(false, 'All calls'), _seg(true, missed == 0 ? 'Missed' : 'Missed · $missed')]),
        ),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(icon: Icons.cloud_off, text: _error!, action: TextButton(onPressed: _load, child: const Text('Try again')))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: list.isEmpty
                        ? ListView(children: const [SizedBox(height: 80), EmptyState(icon: Icons.history, text: 'No calls yet.')])
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                            itemBuilder: (_, i) => _row(list[i]),
                          ),
                  ),
      ),
    ]);
  }

  Widget _seg(bool missed, String label) {
    final on = _missedOnly == missed;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _missedOnly = missed),
        child: Container(
          height: 34, alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Text(label, style: TextStyle(color: on ? wocomPlum : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> c) {
    final dir = (c['direction'] ?? 'in').toString();
    final missed = c['missed'] == true;
    final number = (c['other_number'] ?? '').toString();
    final name = (c['other_name'] ?? '').toString();
    final at = DateTime.tryParse((c['started_at'] ?? '').toString())?.toLocal();
    final secs = (c['duration_s'] as num?)?.toInt() ?? 0;
    final icon = missed ? Icons.call_missed : (dir == 'out' ? Icons.call_made : Icons.call_received);
    final color = missed ? const Color(0xFFB91C1C) : (dir == 'out' ? wocomDeep : const Color(0xFF15803D));
    final when = at == null ? '' : '${at.day}/${at.month} ${TimeOfDay.fromDateTime(at).format(context)}';
    return ListTile(
      leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle), child: Icon(icon, color: color)),
      title: Text(name.isEmpty ? prettyNumber(number) : name, style: TextStyle(fontWeight: FontWeight.w700, color: missed ? const Color(0xFFB91C1C) : null)),
      subtitle: Text([
        if (name.isNotEmpty) prettyNumber(number), when,
        if (c['in_progress'] == true) 'in progress' else if (c['answered'] == true && secs > 0) '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
        if (c['answered'] != true && c['answered_by'] is Map) 'answered by ${(c['answered_by'] as Map)['name'] ?? (c['answered_by'] as Map)['extension']}',
        if (c['voicemail'] == true) 'voicemail',
      ].where((x) => x.isNotEmpty).join(' · ')),
      trailing: number.isEmpty ? null : IconButton(
        tooltip: 'Call back',
        style: IconButton.styleFrom(backgroundColor: const Color(0xFFE7F6EC)),
        icon: const Icon(Icons.call, color: Color(0xFF15803D)),
        onPressed: () => Phone.instance.dial(number),
      ),
    );
  }
}

// ── calling not available ─────────────────────────────────────────────────────

class _CallingOff extends StatelessWidget {
  const _CallingOff({this.note});
  final String? note;
  @override
  Widget build(BuildContext context) => SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 72, height: 72, decoration: const BoxDecoration(color: wocomSoft, shape: BoxShape.circle), child: const Icon(Icons.phone_disabled_outlined, color: wocomDeep, size: 34)),
              const SizedBox(height: 16),
              Text(TechHub.instance.extension.isEmpty ? 'No office extension yet' : 'Extension ${TechHub.instance.extension}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(note ?? 'Once Tech Hub gives you an office extension, you can make and take calls here.', textAlign: TextAlign.center, style: const TextStyle(color: wocomMuted, height: 1.4)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () async { if (await TechHub.instance.registerDevice() != null) Phone.instance.connect(); }, child: const Text('Check again')),
            ]),
          ),
        ),
      );
}

class _ChatBadge extends StatelessWidget {
  const _ChatBadge({required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: TechHub.instance,
        builder: (context, _) => Badge(isLabelVisible: TechHub.instance.unread > 0, label: Text('${TechHub.instance.unread}'), child: Icon(icon)),
      );
}


/// The phone's own contacts (moved here from Team; opened from the keypad's search button).
class _PhoneContactsPage extends StatefulWidget {
  const _PhoneContactsPage();
  @override
  State<_PhoneContactsPage> createState() => _PhoneContactsPageState();
}

class _PhoneContactsPageState extends State<_PhoneContactsPage> {
  String _q = '';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Phone contacts')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search contacts', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
          Expanded(child: PhoneContactsView(query: _q)),
        ]),
      );
}
