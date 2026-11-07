import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../services/techhub.dart';
import '../theme.dart';

/// WE App inbox for Tech Hub broadcasts: announcements, ads and alerts, newest first.
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});
  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    TechHub.instance.announcementsEvent.addListener(_load);
  }

  @override
  void dispose() {
    TechHub.instance.announcementsEvent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await TechHub.instance.announcements();
      if (!mounted) return;
      setState(() { _items = list; _loading = false; _error = null; });
      for (final a in list.where((a) => a['read'] != true)) {
        TechHub.instance.markAnnouncementRead((a['id'] as num).toInt()).catchError((_) {});
      }
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.message; });
    }
  }

  ({Color color, IconData icon, String label}) _style(String kind) => switch (kind) {
        'alert' => (color: const Color(0xFFB91C1C), icon: Icons.warning_amber_rounded, label: 'ALERT'),
        'ad' => (color: const Color(0xFFCA8A04), icon: Icons.local_offer_outlined, label: 'OFFER'),
        _ => (color: const Color(0xFF15803D), icon: Icons.campaign_outlined, label: 'ANNOUNCEMENT'),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FB),
      appBar: AppBar(backgroundColor: wocomPlum, foregroundColor: Colors.white, title: const Text('Announcements')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(children: [Padding(padding: const EdgeInsets.all(40), child: Text(_error ?? 'No announcements right now.', textAlign: TextAlign.center, style: const TextStyle(color: wocomMuted, fontSize: 16)))])
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final a = _items[i];
                        final st = _style((a['kind'] ?? '').toString());
                        final img = (a['image_url'] ?? '').toString();
                        final link = (a['link_url'] ?? '').toString();
                        final at = DateTime.tryParse((a['sent_at'] ?? '').toString())?.toLocal();
                        final high = a['priority'] == 'high';
                        return Dismissible(
                          key: ValueKey(a['id']),
                          direction: DismissDirection.endToStart,
                          background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_outline, color: wocomMuted)),
                          onDismissed: (_) { setState(() => _items.removeAt(i)); TechHub.instance.dismissAnnouncement((a['id'] as num).toInt()).catchError((_) {}); },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: high ? st.color : wocomLine, width: high ? 2 : 1)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              if (img.isNotEmpty) Image.network(TechHub.instance.absUrl(img), headers: TechHub.instance.authHeaders, height: 170, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                              Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Icon(st.icon, size: 18, color: st.color),
                                    const SizedBox(width: 6),
                                    Text(st.label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.6, color: st.color)),
                                    const Spacer(),
                                    if (at != null) Text('${at.day}/${at.month} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 12, color: wocomMuted)),
                                  ]),
                                  const SizedBox(height: 6),
                                  Text((a['title'] ?? '').toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                                  const SizedBox(height: 4),
                                  Text((a['body'] ?? '').toString(), style: const TextStyle(fontSize: 15.5, height: 1.4)),
                                  if (link.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    OutlinedButton.icon(
                                      onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
                                      icon: const Icon(Icons.open_in_new, size: 18),
                                      label: const Text('Open link'),
                                    ),
                                  ],
                                ]),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// Pops the newest unread announcement up over the app, with an ✕ to close it. Runs when the app
/// opens, when it comes back to the front, and when an announcement push arrives.
class AnnouncementPopup {
  static final Set<int> _shown = {};
  static bool _open = false;

  static Future<void> maybeShow(BuildContext context) async {
    if (_open || !TechHub.instance.signedIn) return;
    List<Map<String, dynamic>> list;
    try { list = await TechHub.instance.announcements(); } catch (_) { return; }
    final next = list.where((a) => a['read'] != true && !_shown.contains((a['id'] as num).toInt())).toList();
    if (next.isEmpty || !context.mounted) return;
    final a = next.first;
    final id = (a['id'] as num).toInt();
    _shown.add(id);
    _open = true;
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      transitionDuration: const Duration(milliseconds: 280),
      transitionBuilder: (_, anim, __, child) => ScaleTransition(scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack), child: FadeTransition(opacity: anim, child: child)),
      pageBuilder: (c, _, __) => _PopupCard(a: a),
    );
    _open = false;
    TechHub.instance.markAnnouncementRead(id).catchError((_) {});
    if (next.length > 1 && context.mounted) maybeShow(context);
  }
}

class _PopupCard extends StatelessWidget {
  const _PopupCard({required this.a});
  final Map<String, dynamic> a;

  @override
  Widget build(BuildContext context) {
    final kind = (a['kind'] ?? '').toString();
    final img = (a['image_url'] ?? '').toString();
    final link = (a['link_url'] ?? '').toString();
    final (accent, label, icon) = switch (kind) {
      'alert' => (const Color(0xFFDC2626), 'ALERT', Icons.warning_amber_rounded),
      'ad' => (const Color(0xFFFED100), 'SPECIAL OFFER', Icons.local_offer),
      _ => (const Color(0xFF009B3A), 'ANNOUNCEMENT', Icons.campaign),
    };
    return SafeArea(
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 18),
            constraints: const BoxConstraints(maxWidth: 440),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 30, offset: Offset(0, 12))]),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Stack(children: [
                  img.isNotEmpty
                      ? Image.network(TechHub.instance.absUrl(img), headers: TechHub.instance.authHeaders, height: 220, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _hero(accent, icon))
                      : _hero(accent, icon),
                  Positioned(
                    top: 10, right: 10,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: const CircleBorder(),
                      child: IconButton(tooltip: 'Close', icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop()),
                    ),
                  ),
                  Positioned(
                    left: 14, bottom: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(20)),
                      child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: kind == 'ad' ? Colors.black : Colors.white)),
                    ),
                  ),
                ]),
                // Jamaican stripe
                Row(children: const [
                  Expanded(child: SizedBox(height: 5, child: ColoredBox(color: Color(0xFF009B3A)))),
                  Expanded(child: SizedBox(height: 5, child: ColoredBox(color: Color(0xFFFED100)))),
                  Expanded(child: SizedBox(height: 5, child: ColoredBox(color: Color(0xFF111111)))),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text((a['title'] ?? '').toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, height: 1.2)),
                    const SizedBox(height: 10),
                    Text((a['body'] ?? '').toString(), style: const TextStyle(fontSize: 16, height: 1.45, color: Color(0xFF3F3A52))),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                  child: Row(children: [
                    if (link.isNotEmpty) ...[
                      Expanded(child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50), side: const BorderSide(color: Color(0xFF009B3A), width: 2), foregroundColor: const Color(0xFF007A2E), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new, size: 18), label: const Text('Learn more', style: TextStyle(fontWeight: FontWeight.w800)),
                      )),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 50), backgroundColor: const Color(0xFF009B3A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Got it', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                    )),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero(Color accent, IconData icon) => Container(
        height: 200,
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF009B3A), Color(0xFF0B3D1F), Color(0xFF111111)])),
        child: Center(child: Icon(icon, size: 84, color: const Color(0xFFFED100))),
      );
}
