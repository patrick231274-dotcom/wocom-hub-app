import '../brand.dart';
import 'dart:io' show File, exit;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_update.dart';
import '../services/device_health.dart';
import '../services/emergency.dart';
import '../services/diag.dart';
import '../widgets/diag_consent.dart';
import '../services/hub.dart';
import '../services/names.dart';
import '../services/push_service.dart';
import '../services/session.dart';
import '../services/phone.dart';
import '../theme.dart';
import '../widgets/app_drawer.dart';
import 'call_screen.dart';
import 'chats_screen.dart';
import 'keypad_screen.dart';
import 'meet_screen.dart';
import 'pulse_screen.dart';
import 'recents_screen.dart';
import 'status_sheet.dart';
import 'team_screen.dart';

/// The signed-in app: Team · Chats · Keypad · Recents · Meet, all under the same plum brand.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// So any tab can open the ☰ menu.
  static final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;

  void _goTab(int tab, {int teamSource = 0}) {
    if (tab == 0) Hub.instance.teamSource.value = teamSource;
    setState(() => _tab = tab);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Session.instance.addListener(_onSession);
    _start();
  }

  Future<void> _start() async {
    await [Permission.microphone, Permission.notification, Permission.bluetoothConnect].request();
    if (mounted) await Emergency.warmUpPermission(context);
    Hub.instance.start();
    Phone.instance.watchNetwork();
    Names.instance.load();
    // No background service: a sleeping or closed app is woken by push for each call, which
    // avoids a hidden second engine holding the line while the screen shows nothing.
    PushService.instance.registerToken();
    await Phone.instance.connect();
    await DeviceHealth.instance.refresh();
    DeviceHealth.instance.loadWake();
    if (!DeviceHealth.instance.batteryOk) await _askBatteryOnce();
    if (mounted) AppUpdate.instance.check(context);
    if (mounted) DiagConsent.askIfRequested(context);
  }

  /// Once per install: ask Android to let the app run unrestricted, or calls may not wake the phone.
  Future<void> _askBatteryOnce() async {
    File? flag;
    try {
      flag = File('${(await getApplicationSupportDirectory()).path}/battery-asked');
      if (await flag.exists()) return;
    } catch (_) {}
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Let calls wake this phone'),
        content: Text(Brand.playStore
            ? 'Android\'s battery optimisation can stop WOCOM HUB from ringing when the phone is asleep. Tap Open settings, choose All apps, find WOCOM HUB and pick "Don\'t optimise" so calls always come through.'
            : 'Android\'s battery optimisation can stop WOCOM HUB from ringing when the phone is asleep. Tap Allow, then choose "Allow" on the next screen so calls always come through.', style: const TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(Brand.playStore ? 'Open settings' : 'Allow')),
        ],
      ),
    );
    try { await flag?.writeAsString('1'); } catch (_) {}
    if (go == true) await DeviceHealth.instance.fixBattery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Diag.log('app', 'lifecycle ${state.name}');
    if (state == AppLifecycleState.detached) {
      // The screen is gone (app swiped away) but this engine would live on, hold the line, and
      // then take the next call while a second engine draws the screen without it. End the
      // process instead: the next call or tap starts one clean copy, woken by push.
      if (Phone.instance.call == null) {
        Diag.log('app', 'screen detached with no call: exiting so the next start is clean');
        Future.delayed(const Duration(milliseconds: 400), () => exit(0));
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      // Back in the app: refresh everything and reconnect the line if it dropped.
      Hub.instance.start();
      Session.instance.refreshUser();
      DeviceHealth.instance.refresh();
      if (Phone.instance.call == null) AppUpdate.instance.check(context);
      if (Phone.instance.call == null) DiagConsent.askIfRequested(context);
      if (Phone.instance.status != LineStatus.ready) Phone.instance.restart('app resumed');
      // Brought to the front during a call (e.g. after Answer on Android's call screen): show it.
      if (Phone.instance.call != null && !CallScreen.open) Phone.instance.poke();
    } else if (state == AppLifecycleState.paused) {
      Hub.instance.stop();
    }
  }

  @override
  void dispose() {
    Session.instance.removeListener(_onSession);
    WidgetsBinding.instance.removeObserver(this);
    Hub.instance.stop();
    super.dispose();
  }

  void _onSession() { if (mounted) setState(() {}); }

  void _openStatus() => showStatusSheet(context);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: HomeScreen.scaffoldKey,
      drawer: AppDrawer(onTab: _goTab),
      body: IndexedStack(index: PulseScreen.allowed || _tab < 5 ? _tab : 0, children: [
        TeamScreen(onAvatarTap: _openStatus, onOpenKeypad: () => setState(() => _tab = 2)),
        ChatsScreen(onAvatarTap: _openStatus),
        KeypadScreen(onAvatarTap: _openStatus, onOpenDirectory: () { Hub.instance.teamSource.value = 1; setState(() => _tab = 0); }),
        RecentsScreen(onAvatarTap: _openStatus),
        MeetScreen(onAvatarTap: _openStatus),
        if (PulseScreen.allowed) PulseScreen(onAvatarTap: _openStatus),
      ]),
      bottomNavigationBar: AnimatedBuilder(
        animation: Listenable.merge([Hub.instance, Session.instance]),
        builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          if (Hub.instance.queueBenched)
            Material(
              color: const Color(0xFFFFF4DB),
              child: InkWell(
                onTap: () async {
                  final err = await Hub.instance.setQueueStatus('Available');
                  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(children: [
                    const Icon(Icons.pause_circle_outline, color: Color(0xFFB45309), size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Queue: ${Hub.instance.myQueueStatus}. You are not getting queue calls.', style: const TextStyle(color: Color(0xFF92400E), fontSize: 13, fontWeight: FontWeight.w700))),
                    const Text('Go available', style: TextStyle(color: Color(0xFFB45309), fontSize: 13, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),
            ),
          Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: wocomLine)),
            boxShadow: [BoxShadow(color: Color(0x14321062), blurRadius: 16, offset: Offset(0, -4))],
          ),
          child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            setState(() => _tab = i);
            if (i == 1) Hub.instance.refreshChats();
          },
          backgroundColor: Colors.transparent,
          elevation: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Team'),
            NavigationDestination(
              icon: Badge(isLabelVisible: Hub.instance.unreadChats > 0, label: Text('${Hub.instance.unreadChats}'), child: const Icon(Icons.chat_bubble_outline)),
              selectedIcon: Badge(isLabelVisible: Hub.instance.unreadChats > 0, label: Text('${Hub.instance.unreadChats}'), child: const Icon(Icons.chat_bubble)),
              label: 'Chats',
            ),
            const NavigationDestination(icon: Icon(Icons.dialpad), selectedIcon: Icon(Icons.dialpad), label: 'Keypad'),
            const NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history), label: 'Recents'),
            NavigationDestination(
              icon: Badge(isLabelVisible: Hub.instance.openTasks > 0, label: Text('${Hub.instance.openTasks}'), child: const Icon(Icons.videocam_outlined)),
              selectedIcon: Badge(isLabelVisible: Hub.instance.openTasks > 0, label: Text('${Hub.instance.openTasks}'), child: const Icon(Icons.videocam)),
              label: 'Meet',
            ),
            // Hub administrators get a sixth tab: the company's call picture.
            if (PulseScreen.allowed)
              NavigationDestination(
                icon: Badge(isLabelVisible: Hub.instance.openMissed > 0, label: Text('${Hub.instance.openMissed}'), child: const Icon(Icons.monitor_heart_outlined)),
                selectedIcon: Badge(isLabelVisible: Hub.instance.openMissed > 0, label: Text('${Hub.instance.openMissed}'), child: const Icon(Icons.monitor_heart)),
                label: 'Pulse',
              ),
          ],
          ),
        ),
        ]),
      ),
    );
  }
}
