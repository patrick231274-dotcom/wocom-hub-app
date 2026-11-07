import 'package:flutter/material.dart';

import '../brand.dart';

import '../screens/about_screen.dart';
import '../screens/pulse_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/status_sheet.dart';
import '../services/api.dart';
import '../services/device_health.dart';
import '../services/hub.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import 'ui.dart';

/// The ☰ menu: everything in the app in one list, plus Settings and diagnostics.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.onTab});

  /// 0 team · 1 chats · 2 keypad · 3 recents · 4 meet
  final void Function(int tab, {int teamSource}) onTab;

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final p = Phone.instance;
    void go(int tab, {int teamSource = 0}) {
      Navigator.pop(context);
      onTab(tab, teamSource: teamSource);
    }
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            decoration: const BoxDecoration(gradient: wocomGradient),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const WocomLogo(height: 30, white: true),
              const SizedBox(height: 14),
              Row(children: [
                PersonAvatar(name: s.name, status: Hub.instance.myStatus, onDark: true, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                    Text('${p.extension.isEmpty ? '' : 'Ext ${p.extension} · '}${p.shownStatusText}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: wocomTintLight, fontSize: 12.5)),
                  ]),
                ),
              ]),
            ]),
          ),
          AnimatedBuilder(
            animation: DeviceHealth.instance,
            builder: (context, _) {
              final h = DeviceHealth.instance;
              if (!h.hasIssue) return const SizedBox.shrink();
              return InkWell(
                onTap: () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())); },
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFFFFF4DB),
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(children: [
                    const Icon(Icons.battery_alert_outlined, color: Color(0xFFB45309), size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(!h.batteryOk ? 'Battery setting may stop calls ringing' : !h.notificationsOk ? 'Notifications are off: calls can\'t ring' : !h.fullScreenOk ? 'Full-screen call alerts are off' : 'Wake-ups are blocked on this phone', style: const TextStyle(color: Color(0xFF92400E), fontSize: 13, fontWeight: FontWeight.w700))),
                    const Text('Fix', style: TextStyle(color: Color(0xFFB45309), fontSize: 13, fontWeight: FontWeight.w800)),
                    const Icon(Icons.chevron_right, color: Color(0xFFB45309), size: 18),
                  ]),
                ),
              );
            },
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              _item(Icons.groups_outlined, 'Team', () => go(0)),
              _item(Icons.contacts_outlined, 'Directory', () => go(0, teamSource: 1)),
              _item(Icons.contact_phone_outlined, 'My phone contacts', () => go(0, teamSource: 2)),
              _item(Icons.chat_bubble_outline, 'Chats', () => go(1)),
              _item(Icons.dialpad, 'Keypad', () => go(2)),
              _item(Icons.history, 'Recents & voicemail', () => go(3)),
              _item(Icons.videocam_outlined, 'Meetings', () => go(4)),
              if (PulseScreen.allowed) _item(Icons.monitor_heart_outlined, 'Pulse', () => go(5)),
              const Divider(height: 20),
              _item(Icons.circle, 'My status', () { Navigator.pop(context); showStatusSheet(context); }, color: statusColor(Hub.instance.myStatus)),
              _item(Icons.settings_outlined, 'Settings', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())); }),
              _item(Icons.info_outline, 'About ${Brand.name}', () { Navigator.pop(context); Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())); }),
            ]),
          ),
          Padding(padding: const EdgeInsets.all(14), child: Text('${Brand.name}  ·  v${PushApi.appVersion.isEmpty ? '?' : PushApi.appVersion}', style: const TextStyle(color: Color(0xFF8A8299), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1))),
        ]),
      ),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap, {Color? color}) => ListTile(
        leading: Icon(icon, color: color ?? wocomDeep, size: color == null ? 24 : 14),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        onTap: onTap,
        dense: true,
        minVerticalPadding: 10,
      );
}
