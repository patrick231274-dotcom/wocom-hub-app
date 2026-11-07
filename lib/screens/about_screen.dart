import 'package:flutter/material.dart';

import '../brand.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/app_update.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// About WOCOM HUB: who owns it and how to reach support.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _phones = ['+18769067240', '+18779067240'];
  static const _email = 'support@wocomja.com';

  Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open ${uri.toString()}")));
  }

  @override
  Widget build(BuildContext context) {
    final version = PushApi.appVersion.isEmpty ? '' : 'Version ${PushApi.appVersion.split('+').first} (${PushApi.appVersion.split('+').last})';
    return Scaffold(
      body: Column(children: [
        BrandHeader(title: 'About', leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white), onPressed: () => Navigator.pop(context))),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 28, 20, 32), children: [
            const Center(child: WocomLogo(height: 56)),
            const SizedBox(height: 14),
            const Center(child: Text(Brand.name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: wocomInk))),
            if (version.isNotEmpty) Center(child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(version, style: const TextStyle(color: wocomMuted, fontSize: 13)))),
            const SizedBox(height: 26),
            _card(children: const [
              Text(Brand.isWocom ? '${Brand.name} is owned and operated by WOCOM Limited, a Jamaican company providing business phone and communications services.' : '${Brand.name} is powered by ${Brand.name}, a service of WOCOM Limited, a Jamaican company providing business phone and communications services.',
                  style: TextStyle(fontSize: 15, height: 1.45, color: wocomInk)),
              SizedBox(height: 10),
              Text('© 2026 WOCOM Limited. All rights reserved.', style: TextStyle(fontSize: 13.5, color: wocomMuted)),
            ]),
            // Only when this phone is behind: one tap to update.
            FutureBuilder<Map<String, dynamic>?>(
              future: AppUpdate.instance.newer(),
              builder: (context, snap) {
                final info = snap.data;
                if (info == null) return const SizedBox.shrink();
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 14),
                  _section('Update'),
                  _row(context, Icons.system_update_outlined, 'Update to v${info['version']}', 'A newer ${Brand.name} is available. Tap to install.',
                      () => AppUpdate.instance.check(context, force: true)),
                ]);
              },
            ),
            const SizedBox(height: 14),
            _section('Support'),
            for (final p in _phones)
              _row(context, Icons.call_outlined, _pretty(p), 'Tap to call', () => _open(context, Uri(scheme: 'tel', path: p)),
                  onLongPress: () => _copy(context, _pretty(p))),
            _row(context, Icons.mail_outline, _email, 'Tap to email', () => _open(context, Uri(scheme: 'mailto', path: _email, queryParameters: {'subject': '${Brand.name} support'})),
                onLongPress: () => _copy(context, _email)),
            _row(context, Icons.language, Brand.websiteLabel, 'Website', () => _open(context, Uri.parse(Brand.website))),
            const SizedBox(height: 14),
            _section('Company'),
            _row(context, Icons.business_outlined, 'About us', 'Who WOCOM is and what we do', () => _open(context, Uri.parse('https://wocomja.com/about.php'))),
            _row(context, Icons.privacy_tip_outlined, 'Privacy policy', 'How WOCOM handles your information', () => _open(context, Uri.parse('https://wocomja.com/privacy-policy.php'))),
            const SizedBox(height: 18),
            const Center(child: Text('Made in Jamaica', style: TextStyle(fontSize: 12.5, letterSpacing: 1, fontWeight: FontWeight.w700, color: Color(0xFF8A8299)))),
          ]),
        ),
      ]),
    );
  }

  static String _pretty(String p) {
    final d = p.replaceAll(RegExp(r'\D'), '');
    return '(${d.substring(1, 4)}) ${d.substring(4, 7)}-${d.substring(7)}';
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$text copied'), duration: const Duration(seconds: 1)));
  }

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: wocomLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _section(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 8), child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w800, color: Color(0xFF8A8299))));

  Widget _row(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap, {VoidCallback? onLongPress}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: wocomLine)),
        child: ListTile(
          leading: Container(width: 38, height: 38, decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: wocomDeep, size: 20)),
          title: Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: wocomInk)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
          trailing: const Icon(Icons.chevron_right, color: Color(0xFFB8B1C6)),
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      );
}
