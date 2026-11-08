import 'dart:io' show Platform;
import 'dart:async';

import 'package:flutter/material.dart';

import '../brand.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_update.dart';
import '../services/device_health.dart';
import '../services/diag.dart';
import '../services/dial_plan.dart';
import '../services/hub.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Settings: who's signed in, the phone line, ringing-when-asleep checks, support and sign out.
/// Grouped cards with one row per item; a green tick means nothing to do, a small button means
/// there is.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  String _version = '';
  bool _sending = false;
  bool _checking = false;
  Timer? _poll;

  static const _good = Color(0xFF15803D);
  static const _goodBg = Color(0xFFE7F6EC);
  static const _warn = Color(0xFFB45309);
  static const _warnBg = Color(0xFFFFF4DB);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PackageInfo.fromPlatform().then((p) { if (mounted) setState(() => _version = 'v${p.version} (${p.buildNumber})'); });
    DeviceHealth.instance.refresh();
    DeviceHealth.instance.loadWake();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back from a system settings page, or from the lock screen after a wake-up test.
      DeviceHealth.instance.refresh();
      DeviceHealth.instance.loadWake();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  // ── actions ────────────────────────────────────────────────────────────────

  Future<void> _sendDiagnostics() async {
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send diagnostics to WOCOM'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Sends the app\'s connection and call log from the last while, plus your extension and phone model. No call audio or messages are included.', style: TextStyle(fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 12),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'What happened? (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _sending = true);
    final err = await Diag.instance.send(note: note.text.trim());
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Diagnostics sent. Thank you.')));
  }

  Future<void> _editMobile() async {
    final s = Session.instance;
    final c = TextEditingController(text: s.mobile);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your mobile number'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Used to call you with an activation code when you set up a new phone.', style: TextStyle(fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 12),
          TextField(controller: c, keyboardType: TextInputType.phone, autofocus: true, decoration: const InputDecoration(labelText: 'Mobile number', hintText: '876 555 1234')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (go != true) return;
    final err = await s.saveMobile(c.text.trim());
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? (c.text.trim().isEmpty ? 'Mobile number removed.' : 'Mobile number saved.'))));
  }

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    final offered = await AppUpdate.instance.check(context, force: true);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!offered) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have the latest version.')));
  }

  Future<void> _wakeTest() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Test wake-ups'),
        content: const Text('WOCOM will send this phone a silent wake-up within about a minute, the same way an incoming call does.\n\nTap Start, then lock your phone and leave it for a minute. Come back here to see the result.', style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start')),
        ],
      ),
    );
    if (go != true) return;
    final err = await DeviceHealth.instance.requestWakeTest(delay: 20);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Test on its way. Lock your phone now.')));
    if (err != null) return;
    _poll?.cancel();
    var n = 0;
    _poll = Timer.periodic(const Duration(seconds: 10), (t) {
      DeviceHealth.instance.loadWake();
      if (++n >= 18 || DeviceHealth.instance.wakeStatus == 'ok') t.cancel();
    });
  }

  Future<void> _signOut() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('This phone will stop receiving calls and messages until it is set up again.', style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    Navigator.pop(context);
    Hub.instance.stop();
    Phone.instance.disconnect();
    await Session.instance.signOut();
  }

  /// Apple (and Google) require account deletion to start inside the app.
  Future<void> _deleteAccount() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
            'We will delete your WOCOM HUB account and its data: your sign-in, the phones linked to it, '
            'your chat messages and voice notes, and your personal details. Your company\'s administrator '
            'will be told. Records your company or WOCOM must keep by law, such as billing, are kept only as '
            'long as required.\n\nThis phone will be signed out now. We complete deletions within 30 days.',
            style: TextStyle(fontSize: 14, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), style: TextButton.styleFrom(foregroundColor: const Color(0xFFB42318)), child: const Text('Delete my account')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await Session.instance.api.post('account/delete-request', {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("We couldn't send your request. Check your connection and try again, or use wocomja.com/wocom-hub/delete-account.")));
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
    Hub.instance.stop();
    Phone.instance.disconnect();
    await Session.instance.forceSignedOut();
  }

  // ── screen ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    return Scaffold(
      body: Column(children: [
        BrandHeader(title: 'Settings', subtitle: s.company, myStatus: Hub.instance.myStatus, leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white), onPressed: () => Navigator.pop(context))),
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([Phone.instance, DeviceHealth.instance]),
            builder: (context, _) {
              final p = Phone.instance;
              final h = DeviceHealth.instance;
              final lineOk = p.shownStatus == LineStatus.ready;
              final wakeOk = h.wakeStatus == 'ok';
              final wakeBad = h.wakeStatus == 'blocked' || h.wakeStatus == 'no_answer';
              return ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 28), children: [
                // Who's signed in.
                _card([
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Row(children: [
                      PersonAvatar(name: s.name, status: Hub.instance.myStatus, size: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: wocomInk)),
                          const SizedBox(height: 2),
                          Text('${p.extension.isEmpty ? '' : 'Ext ${p.extension} · '}${s.company}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: wocomMuted)),
                          const SizedBox(height: 8),
                          _chip(lineOk ? 'Line ready' : p.shownStatusText, lineOk ? _good : _warn, lineOk ? _goodBg : _warnBg, icon: lineOk ? Icons.check_circle : Icons.sync_problem),
                        ]),
                      ),
                    ]),
                  ),
                  const Divider(height: 1, color: wocomLine),
                  _row(Icons.refresh, 'Reconnect line', lineOk ? 'Drop and re-register the line' : 'Try connecting again', action: _button('Reconnect', () => p.restart('settings'))),
                ]),

                _title('Ringing when asleep'),
                _card([
                  _row(
                    wakeOk ? Icons.notifications_active_outlined : Icons.notifications_none,
                    'Wake-up test', h.wakeText,
                    tone: wakeOk ? _good : wakeBad ? _warn : null,
                    action: _button(h.wakeStatus == 'testing' ? 'Testing…' : 'Test', h.wakeStatus == 'testing' ? null : _wakeTest),
                  ),
                  if (h.health.isNotEmpty) ...[
                    const Divider(height: 1, indent: 60, color: wocomLine),
                    _row(Icons.battery_charging_full_outlined, 'Battery', h.batteryOk ? 'Unrestricted' : 'Optimised: calls may not wake the phone',
                        tone: h.batteryOk ? _good : _warn, action: h.batteryOk ? _tick() : _button('Allow', () => h.fixBattery())),
                    const Divider(height: 1, indent: 60, color: wocomLine),
                    _row(Icons.notifications_outlined, 'Notifications', h.notificationsOk ? 'On' : 'Off: incoming calls can\'t show',
                        tone: h.notificationsOk ? _good : _warn, action: h.notificationsOk ? _tick() : _button('Open', () => h.openNotificationSettings())),
                    if ((h.health['sdk'] ?? 0) >= 34) ...[
                      const Divider(height: 1, indent: 60, color: wocomLine),
                      _row(Icons.fullscreen, 'Full-screen call alerts', h.fullScreenOk ? 'On' : 'Off: calls won\'t show on the lock screen',
                          tone: h.fullScreenOk ? _good : _warn, action: h.fullScreenOk ? _tick() : _button('Open', () => h.openFullScreenSettings())),
                    ],
                    if (h.autostartHint) ...[
                      const Divider(height: 1, indent: 60, color: wocomLine),
                      _row(Icons.phonelink_setup_outlined, '${h.manufacturer} background settings', 'Allow auto-start / no restrictions for ${Brand.name}',
                          action: _button('Open', () async { if (!await h.openAutoStart()) await h.openAppInfo(); })),
                    ],
                    if (h.health['power_save'] == true) ...[
                      const Divider(height: 1, indent: 60, color: wocomLine),
                      _row(Icons.power_settings_new, 'Power saving', 'Battery saver is on, which can slow wake-ups', tone: _warn),
                    ],
                  ],
                ]),

                _title('Support'),
                _card([
                  _row(Icons.bug_report_outlined, _sending ? 'Sending diagnostics…' : 'Send diagnostics to WOCOM', 'Connection and call log, no audio or messages',
                      onTap: _sending ? null : _sendDiagnostics, action: const Icon(Icons.chevron_right, color: Color(0xFFB8B1C6))),
                  const Divider(height: 1, indent: 60, color: wocomLine),
                  _row(Icons.system_update_outlined, 'App version', _version.isEmpty ? '—' : _version,
                      action: Brand.playStore || Platform.isIOS ? null : _button(_checking ? 'Checking…' : 'Check', _checking ? null : _checkUpdates)),
                  const Divider(height: 1, indent: 60, color: wocomLine),
                  _row(Icons.cloud_outlined, 'Service', 'push.wocomenterprise.com'),
                ]),

                const SizedBox(height: 22),
                Center(
                  child: TextButton.icon(
                    onPressed: _signOut,
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF6B6480)),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out of this phone', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _deleteAccount,
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFB42318)),
                    child: const Text('Delete my account', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  // ── pieces ─────────────────────────────────────────────────────────────────

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
        child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 11.5, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Color(0xFF8A8299))),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: wocomLine),
          boxShadow: const [BoxShadow(color: Color(0x0F3B0764), blurRadius: 10, offset: Offset(0, 3))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _row(IconData icon, String title, String subtitle, {Color? tone, Widget? action, VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: tone == _good ? _goodBg : tone == _warn ? _warnBg : wocomSoft, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 19, color: tone ?? wocomDeep),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: wocomInk)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.3, color: tone ?? wocomMuted, fontWeight: tone == null ? FontWeight.w500 : FontWeight.w600)),
              ]),
            ),
            if (action != null) ...[const SizedBox(width: 10), action],
          ]),
        ),
      );

  Widget _button(String label, VoidCallback? onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          side: const BorderSide(color: wocomDeep, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label),
      );

  Widget _tick() => const Icon(Icons.check_circle, color: _good, size: 22);

  Widget _chip(String text, Color fg, Color bg, {IconData? icon}) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 5)],
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg)),
        ]),
      );
}
