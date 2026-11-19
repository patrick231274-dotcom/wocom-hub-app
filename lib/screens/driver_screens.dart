import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Phone;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../brand.dart';
import '../services/api.dart';
import '../services/gf_driver.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';

/// Delivery-driver build: "My deliveries" replaces the keypad. Drivers can only call the
/// customer of their own active deliveries (*7 + dial code, checked by the phone system with
/// the CRM), the shop, and emergency numbers.

const _green = Color(0xFF15803D);
const _red = Color(0xFFB91C1C);
const _amber = Color(0xFFB45309);

(Color, Color) _tone(String s) => switch (s) {
      'delivered' => (const Color(0xFFDCFCE7), _green),
      'not_delivered' || 'delivery_failed' => (const Color(0xFFFEE2E2), _red),
      'rescheduled' || 'returned_to_shop' => (const Color(0xFFFEF3C7), _amber),
      'out_for_delivery' => (const Color(0xFFDBEAFE), const Color(0xFF1D4ED8)),
      _ => (wocomSoft, wocomDeep),
    };

void _toast(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

Future<void> _callShop(BuildContext context) async {
  if (!await Phone.instance.dial('8000') && context.mounted) _toast(context, "Your line isn't ready yet. Wait a moment and try again.");
}

Future<void> _callCustomer(BuildContext context, Map<String, dynamic> d) async {
  final code = (d['dial_code'] ?? '').toString();
  // Calls open only once every package is scanned and the order is out for delivery.
  if (d['has_phone'] != false && !RegExp(r'^\d{6}$').hasMatch(code)) {
    final pk = (d['packages'] as List? ?? const []).whereType<Map>();
    final left = pk.where((p) => p['scanned'] != true).length;
    _toast(context, left > 0
        ? 'Scan all packages first ($left of ${pk.length} still to scan). Then you can call the customer.'
        : 'This order is not out for delivery yet. Check with the shop.');
    return;
  }
  if (d['has_phone'] == false) {
    final go = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('No phone number for this customer'),
      content: const Text('Call the shop and they will help you.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Call the shop'))],
    ));
    if (go == true && context.mounted) await _callShop(context);
    return;
  }
  if (!await Phone.instance.dial('*7$code') && context.mounted) _toast(context, "Your line isn't ready yet. Wait a moment and try again.");
}

Future<void> _directions(BuildContext context, Map<String, dynamic> d) async {
  final lat = d['lat'], lng = d['lng'];
  final q = (lat != null && lng != null) ? '$lat,$lng' : [d['address'], d['parish'], 'Jamaica'].where((x) => x != null && x.toString().isNotEmpty).join(', ');
  final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(q)}');
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) _toast(context, 'Could not open Maps.');
}

// ── Deliveries tab ────────────────────────────────────────────────────────────

class DeliveriesScreen extends StatefulWidget {
  const DeliveriesScreen({super.key, required this.onScan});
  final VoidCallback onScan;
  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends State<DeliveriesScreen> with WidgetsBindingObserver {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GfDriver.instance.refresh();
    _poll = Timer.periodic(const Duration(minutes: 2), (_) => GfDriver.instance.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) GfDriver.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([GfDriver.instance, Phone.instance]),
      builder: (context, _) {
        final g = GfDriver.instance;
        final list = g.deliveries;
        final open = list.where((d) => !const {'delivered', 'returned_to_shop'}.contains(d['status'])).length;
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('My deliveries', style: TextStyle(fontWeight: FontWeight.w900)),
              Text('${list.length} today · $open to go${g.pending > 0 ? ' · ${g.pending} waiting to send' : ''}', style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
            ]),
            actions: [
              IconButton(tooltip: 'Call the shop', icon: const Icon(Icons.storefront_outlined), onPressed: () => _callShop(context)),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: g.refresh),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(onPressed: widget.onScan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan package')),
          body: RefreshIndicator(
            onRefresh: g.refresh,
            child: list.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Icon(g.loading ? Icons.hourglass_empty : Icons.local_shipping_outlined, size: 56, color: wocomMuted),
                    const SizedBox(height: 12),
                    Center(child: Text(g.loading ? 'Loading your deliveries…' : (g.error ?? 'No deliveries yet. Scan a package label to start.'), textAlign: TextAlign.center, style: const TextStyle(color: wocomMuted))),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: list.length + (g.error != null ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      if (g.error != null && i == 0) {
                        return Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(12)),
                            child: Text('Showing the last saved list. ${g.error}', style: const TextStyle(color: _amber)));
                      }
                      final d = list[i - (g.error != null ? 1 : 0)];
                      return _DeliveryCard(d: d, index: i + 1 - (g.error != null ? 1 : 0));
                    },
                  ),
          ),
        );
      },
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({required this.d, required this.index});
  final Map<String, dynamic> d;
  final int index;

  @override
  Widget build(BuildContext context) {
    final status = (d['status'] ?? '').toString();
    final (bg, fg) = _tone(status);
    final pk = (d['packages'] as List? ?? const []);
    final scanned = pk.where((p) => p is Map && p['scanned'] == true).length;
    final done = const {'delivered', 'returned_to_shop'}.contains(status);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeliveryScreen(deliveryId: d['delivery_id'].toString()))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 14, backgroundColor: done ? const Color(0xFFDCFCE7) : wocomSoft, child: Text('$index', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: done ? _green : wocomDeep))),
              const SizedBox(width: 10),
              Expanded(child: Text((d['recipient_name'] ?? 'Recipient').toString(), style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
                  child: Text((d['status_label'] ?? status).toString() + (d['_pending'] == true ? ' ⋯' : ''), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: fg))),
            ]),
            const SizedBox(height: 6),
            Text([d['address'], d['parish']].where((x) => x != null && x.toString().isNotEmpty).join(', '), style: const TextStyle(height: 1.3)),
            if ((d['landmark'] ?? '').toString().isNotEmpty) Text('${d['landmark']}', style: const TextStyle(color: wocomMuted, fontSize: 13)),
            const SizedBox(height: 4),
            Text([
              if ((d['window_label'] ?? '').toString().isNotEmpty) '${d['window_label']}',
              'Order ${d['order_no'] ?? ''}',
              if (pk.isNotEmpty) '$scanned of ${pk.length} packages',
            ].join('  ·  '), style: const TextStyle(color: wocomMuted, fontSize: 12.5)),
            if (!done) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: _green), onPressed: () => _callCustomer(context, d), icon: const Icon(Icons.call), label: const Text('Call'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: () => _directions(context, d), icon: const Icon(Icons.directions), label: const Text('Directions'))),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

// ── one delivery ─────────────────────────────────────────────────────────────

class DeliveryScreen extends StatelessWidget {
  const DeliveryScreen({super.key, required this.deliveryId});
  final String deliveryId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GfDriver.instance,
      builder: (context, _) {
        final d = GfDriver.instance.deliveries.firstWhere((x) => x['delivery_id'].toString() == deliveryId, orElse: () => const {});
        if (d.isEmpty) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This delivery is no longer in your list.')));
        final status = (d['status'] ?? '').toString();
        final canFinish = const {'out_for_delivery', 'not_delivered', 'delivery_failed', 'rescheduled'}.contains(status) && d['_pending'] != true;
        final pk = (d['packages'] as List? ?? const []).whereType<Map>().toList();
        return Scaffold(
          appBar: AppBar(title: Text('Order ${d['order_no'] ?? ''}')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text((d['recipient_name'] ?? '').toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text([d['address'], d['parish']].where((x) => x != null && x.toString().isNotEmpty).join(', '), style: const TextStyle(fontSize: 15.5, height: 1.35)),
            if ((d['landmark'] ?? '').toString().isNotEmpty) Text('${d['landmark']}', style: const TextStyle(color: wocomMuted)),
            if ((d['window_label'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Deliver: ${d['window_label']}', style: const TextStyle(fontWeight: FontWeight.w700))),
            if ((d['notes'] ?? '').toString().isNotEmpty)
              Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFFFEF9C3), borderRadius: BorderRadius.circular(12)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.sticky_note_2_outlined, size: 20, color: _amber), const SizedBox(width: 8), Expanded(child: Text('${d['notes']}', style: const TextStyle(height: 1.35)))])),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: _green, minimumSize: const Size.fromHeight(50)), onPressed: () => _callCustomer(context, d), icon: const Icon(Icons.call), label: const Text('Call customer'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)), onPressed: () => _directions(context, d), icon: const Icon(Icons.directions), label: const Text('Directions'))),
            ]),
            const SizedBox(height: 18),
            const Text('PACKAGES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1, color: wocomMuted)),
            for (final p in pk)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(p['scanned'] == true ? Icons.check_circle : Icons.radio_button_unchecked, color: p['scanned'] == true ? _green : wocomMuted),
                title: Text('Package ${p['label'] ?? ''}'),
                trailing: p['scanned'] == true && status != 'out_for_delivery' && status != 'delivered'
                    ? TextButton(onPressed: () async {
                        try { await GfDriver.instance.undoScan(p['package_id'].toString()); } on ApiException catch (e) { if (context.mounted) _toast(context, e.message); }
                      }, child: const Text('Undo scan'))
                    : null,
              ),
            if ((d['attempt_count'] as num? ?? 0) > 0)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('Attempts: ${d['attempt_count']}${d['last_attempt'] != null ? ' · last: ${d['last_attempt'] is Map ? (d['last_attempt']['label'] ?? d['last_attempt']['reason'] ?? '') : d['last_attempt']}' : ''}', style: const TextStyle(color: wocomMuted))),
            const SizedBox(height: 20),
            if (canFinish) ...[
              FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), backgroundColor: _green), onPressed: () => _delivered(context, d), icon: const Icon(Icons.task_alt), label: const Text('Delivered', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900))),
              const SizedBox(height: 8),
              OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), foregroundColor: _red), onPressed: () => _notDelivered(context, d), icon: const Icon(Icons.block), label: const Text('Not delivered')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _rescheduled(context, d), child: const Text('Rescheduled'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: () => _returned(context, d), child: const Text('Returned to shop'))),
              ]),
            ] else if (status == 'assigned' || status == 'ready_for_dispatch')
              const Text('Scan every package of this order to start the delivery.', style: TextStyle(color: wocomMuted)),
          ]),
        );
      },
    );
  }

  Future<void> _delivered(BuildContext context, Map<String, dynamic> d) async {
    final r = await Navigator.of(context).push<_Proof>(MaterialPageRoute(builder: (_) => _ProofScreen(d: d), fullscreenDialog: true));
    if (r == null) return;
    await GfDriver.instance.report(deliveryId, {'status': 'delivered', 'recipient_name': r.receivedBy}, photoPath: r.photo, signaturePath: r.signature);
    if (context.mounted) { _toast(context, 'Marked delivered.'); Navigator.of(context).pop(); }
  }

  Future<void> _notDelivered(BuildContext context, Map<String, dynamic> d) async {
    final reasons = GfDriver.instance.reasons;
    String? reason;
    final note = TextEditingController();
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (c) => StatefulBuilder(builder: (c, set) => Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Why wasn\'t it delivered?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in reasons.entries) ChoiceChip(label: Text(e.value), selected: reason == e.key, onSelected: (_) => set(() => reason = e.key)),
        ]),
        const SizedBox(height: 10),
        TextField(controller: note, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: reason == 'other' ? 'What happened? (needed)' : 'Note (optional)')),
        const SizedBox(height: 12),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: _red, minimumSize: const Size.fromHeight(50)),
            onPressed: reason == null || (reason == 'other' && note.text.trim().isEmpty) ? null : () => Navigator.pop(c, true), child: const Text('Save: not delivered')),
      ]),
    )));
    if (ok != true || reason == null) return;
    await GfDriver.instance.report(deliveryId, {'status': 'not_delivered', 'reason': reason, if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
    if (context.mounted) _toast(context, 'Saved. The order goes back to the shop.');
  }

  Future<void> _rescheduled(BuildContext context, Map<String, dynamic> d) async {
    final now = DateTime.now();
    final date = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 60)), initialDate: now.add(const Duration(days: 1)), helpText: 'New delivery date (optional)');
    final note = await _askNote(context, 'Rescheduled — note (optional)');
    if (note == null) return;
    await GfDriver.instance.report(deliveryId, {
      'status': 'rescheduled',
      if (date != null) 'reschedule_date': '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      if (note.isNotEmpty) 'note': note,
    });
    if (context.mounted) _toast(context, 'Saved as rescheduled.');
  }

  Future<void> _returned(BuildContext context, Map<String, dynamic> d) async {
    final note = await _askNote(context, 'Returned to shop — note (optional)');
    if (note == null) return;
    await GfDriver.instance.report(deliveryId, {'status': 'returned_to_shop', if (note.isNotEmpty) 'note': note});
    if (context.mounted) _toast(context, 'Saved as returned to shop.');
  }

  Future<String?> _askNote(BuildContext context, String title) {
    final c = TextEditingController();
    return showDialog<String>(context: context, builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, minLines: 1, maxLines: 4, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Save'))],
    ));
  }
}

// ── proof of delivery ────────────────────────────────────────────────────────

class _Proof {
  _Proof(this.photo, this.receivedBy, this.signature);
  final String photo;
  final String receivedBy;
  final String? signature;
}

class _ProofScreen extends StatefulWidget {
  const _ProofScreen({required this.d});
  final Map<String, dynamic> d;
  @override
  State<_ProofScreen> createState() => _ProofScreenState();
}

class _ProofScreenState extends State<_ProofScreen> {
  String? _photo;
  // Pre-filled with the recipient on the order; the driver can clear it and type who took it.
  late final _name = TextEditingController(text: (widget.d['recipient_name'] ?? '').toString());
  final _sig = GlobalKey<_SignaturePadState>();
  bool _signing = false; // page scrolling is paused while a finger is on the signature box

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 70);
    if (x != null) setState(() => _photo = x.path);
  }

  Future<void> _save() async {
    String? sig;
    if (_sig.currentState?.hasInk == true) sig = await _sig.currentState!.toPng();
    if (mounted) Navigator.pop(context, _Proof(_photo!, _name.text.trim(), sig));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _photo != null && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Proof of delivery')),
      // Save stays on screen at the bottom, above the keyboard and the phone's buttons.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.of(context).viewInsets.bottom),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), backgroundColor: _green),
            onPressed: ready ? _save : null,
            child: Text(ready ? 'Save: delivered' : (_photo == null ? 'Take the photo to save' : 'Enter who received it'),
                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900)),
          ),
        ),
      ),
      body: ListView(
        physics: _signing ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          Text('Delivering to ${widget.d['recipient_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          InkWell(
            onTap: _takePhoto,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 170,
              decoration: BoxDecoration(color: wocomSoft, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomTint)),
              clipBehavior: Clip.antiAlias,
              child: _photo == null
                  ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.photo_camera, size: 40, color: wocomDeep), SizedBox(height: 6), Text('Tap to take a photo of the delivered package (needed)', textAlign: TextAlign.center)])
                  : Stack(fit: StackFit.expand, children: [
                      Image.file(File(_photo!), fit: BoxFit.cover),
                      Positioned(right: 8, bottom: 8, child: FilledButton.tonalIcon(onPressed: _takePhoto, icon: const Icon(Icons.refresh, size: 18), label: const Text('Retake'))),
                    ]),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Received by (needed)',
              suffixIcon: _name.text.isEmpty ? null : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: () => setState(_name.clear)),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Expanded(child: Text('Signature (optional)', style: TextStyle(fontWeight: FontWeight.w800))),
            TextButton.icon(onPressed: () => _sig.currentState?.clear(), icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Clear')),
          ]),
          _SignaturePad(key: _sig, onSigning: (on) { if (on != _signing) setState(() => _signing = on); }),
          const SizedBox(height: 6),
          const Text('Sign inside the box with a finger.', style: TextStyle(fontSize: 12.5, color: wocomMuted)),
        ],
      ),
    );
  }
}

class _SignaturePad extends StatefulWidget {
  const _SignaturePad({super.key, required this.onSigning});
  final ValueChanged<bool> onSigning;
  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final List<List<Offset>> _strokes = [];
  Size _size = const Size(300, 200);
  bool get hasInk => _strokes.any((s) => s.length > 1);
  void clear() => setState(_strokes.clear);

  Future<String> toPng() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & _size, Paint()..color = Colors.white);
    _SigPainter(_strokes).paint(canvas, _size);
    final img = await rec.endRecording().toImage(_size.width.ceil(), _size.height.ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('${(await getTemporaryDirectory()).path}/sig-${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(bytes!.buffer.asUint8List());
    return f.path;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, 200);
      return Container(
        height: 200,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: wocomTint, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        // Raw pointer events (not drag gestures), and the page stops scrolling while the finger is
        // down, so up/down strokes draw instead of moving the page.
        child: RawGestureDetector(
          // Claim the touch at once so the page's scroll never takes a signature stroke.
          gestures: {EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(() => EagerGestureRecognizer(), (_) {})},
          child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) { widget.onSigning(true); setState(() => _strokes.add([e.localPosition])); },
          onPointerMove: (e) { if (_strokes.isNotEmpty) setState(() => _strokes.last.add(e.localPosition)); },
          onPointerUp: (_) => widget.onSigning(false),
          onPointerCancel: (_) => widget.onSigning(false),
          child: CustomPaint(painter: _SigPainter(_strokes), size: Size.infinite),
        ),
        ),
      );
    });
  }
}

class _SigPainter extends CustomPainter {
  _SigPainter(this.strokes);
  final List<List<Offset>> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black..strokeWidth = 2.6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final o in s.skip(1)) { path.lineTo(o.dx, o.dy); }
      canvas.drawPath(path, p);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ── Scan tab ─────────────────────────────────────────────────────────────────

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.active});
  final bool active;
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  ({bool ok, String text})? _result;

  @override
  void didUpdateWidget(covariant ScanScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _controller.start();
    if (!widget.active && old.active) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onCode(String raw) async {
    if (_busy || !raw.startsWith('GFPKG:')) return;
    if (raw == _last && DateTime.now().difference(_lastAt) < const Duration(seconds: 4)) return;
    _last = raw;
    _lastAt = DateTime.now();
    setState(() => _busy = true);
    try {
      final r = await GfDriver.instance.scan(raw);
      final done = r['order_complete'] == true;
      setState(() => _result = (ok: true, text: 'Order ${r['order_no'] ?? ''} · package ${r['label'] ?? ''} is yours.${done ? '\nAll packages scanned: out for delivery.' : ''}'));
    } on ApiException catch (e) {
      final who = e.data['assigned_to'];
      final text = switch (e.code) {
        'assigned_elsewhere' => 'This package is with ${who is Map ? (who['name'] ?? 'another driver') : (who ?? 'another driver')}. Ask the shop to reassign it.',
        'not_ready' => 'This order isn\'t ready for delivery yet. Check with the shop.',
        'unknown_label' => 'This label wasn\'t recognised.',
        _ => e.message,
      };
      setState(() => _result = (ok: false, text: text));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan package')),
      body: Column(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(controller: _controller, onDetect: (c) {
              for (final b in c.barcodes) {
                final v = b.rawValue ?? '';
                if (v.isNotEmpty) { _onCode(v); return; }
              }
            }),
            Center(child: Container(width: 240, height: 240, decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)))),
            if (_busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
          ]),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: _result == null ? Colors.white : (_result!.ok ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2)),
          child: Text(_result?.text ?? 'Point the camera at the QR code on the package label.',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: _result == null ? wocomInk : (_result!.ok ? _green : _red))),
        ),
      ]),
    );
  }
}

// ── Me tab: shift, line, sign out ────────────────────────────────────────────

class DriverMeScreen extends StatelessWidget {
  const DriverMeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([GfDriver.instance, Phone.instance, Session.instance]),
      builder: (context, _) {
        final g = GfDriver.instance;
        final p = Phone.instance;
        final u = Session.instance.user ?? const {};
        return Scaffold(
          appBar: AppBar(title: Text(Brand.name)),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text((g.driver?['name'] ?? u['name'] ?? '').toString(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            Text('Extension ${g.driver?['extension'] ?? p.extension} · line ${p.statusText}', style: const TextStyle(color: wocomMuted)),
            const SizedBox(height: 16),
            Card(
              child: SwitchListTile(
                value: g.onShift,
                title: const Text('On shift', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(g.shiftProblem ?? (g.onShift ? 'The shop can see your location while you are on shift.' : 'Go on shift when you start delivering.')),
                onChanged: (v) async {
                  try { await g.setShift(v); } on ApiException catch (e) { if (context.mounted) _toast(context, e.message); }
                },
              ),
            ),
            if (g.pending > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${g.pending} update(s) waiting to be sent. They go as soon as you have signal.', style: const TextStyle(color: _amber))),
            if (g.lastRejected != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Last update was refused by the shop system: ${g.lastRejected}', style: const TextStyle(color: _red))),
            const SizedBox(height: 16),
            ListTile(leading: const Icon(Icons.storefront_outlined), title: const Text('Call the shop'), onTap: () => _callShop(context)),
            ListTile(leading: const Icon(Icons.local_police_outlined, color: _red), title: const Text('Emergency: Police 119'), onTap: () => Phone.instance.dial('119')),
            ListTile(leading: const Icon(Icons.local_hospital_outlined, color: _red), title: const Text('Emergency: Fire & Ambulance 110'), onTap: () => Phone.instance.dial('110')),
            const Divider(),
            ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () async {
              await g.signOut();
              await Session.instance.signOut();
            }),
          ]),
        );
      },
    );
  }
}
