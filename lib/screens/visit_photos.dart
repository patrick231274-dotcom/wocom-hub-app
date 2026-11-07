import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';

import '../services/api.dart';
import '../services/photo_queue.dart';
import '../services/techhub.dart';
import '../theme.dart';

/// Image from Tech Hub (Bearer auth, cached on disk).
class AuthImage extends StatelessWidget {
  const AuthImage(this.url, {super.key, this.fit = BoxFit.cover});
  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => FutureBuilder<File?>(
        future: AuthImageCache.get(url),
        builder: (_, s) {
          if (s.data != null) return Image.file(s.data!, fit: fit, gaplessPlayback: true);
          if (s.connectionState == ConnectionState.done) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54));
          return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
        },
      );
}

/// Thumbnail strip + count + "Add photos" for one survey / visit location.
class VisitPhotos extends StatelessWidget {
  const VisitPhotos({super.key, required this.number, required this.visit, required this.onChanged});
  final String number;
  final Map<String, dynamic> visit;
  final VoidCallback onChanged;

  int get _vid => (visit['id'] as num).toInt();

  @override
  Widget build(BuildContext context) {
    final photos = ((visit['photos'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final count = (visit['photo_count'] as num?)?.toInt() ?? photos.length;
    final canAdd = visit['can_add_photos'] == true;
    return AnimatedBuilder(
      animation: PhotoQueue.instance,
      builder: (context, _) {
        final pending = PhotoQueue.instance.pendingFor(number, _vid);
        if (photos.isEmpty && pending.isEmpty && !canAdd) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.photo_library_outlined, size: 18, color: wocomMuted),
              const SizedBox(width: 6),
              Expanded(child: Text(
                count == 0 && pending.isEmpty ? 'No photos yet' : '$count photo${count == 1 ? '' : 's'}${pending.isNotEmpty ? ' · ${pending.length} uploading' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: wocomMuted),
              )),
              if (canAdd) TextButton.icon(
                onPressed: () => _add(context),
                icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: const Text('Add photos'),
              ),
            ]),
            if (photos.isNotEmpty || pending.isNotEmpty)
              SizedBox(
                height: 76,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (var i = 0; i < photos.length; i++)
                    _thumb(
                      child: Hero(tag: 'vp${photos[i]['id']}', child: AuthImage(photos[i]['url'].toString())),
                      onTap: () async {
                        final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
                          builder: (_) => PhotoViewer(number: number, visitId: _vid, photos: photos, start: i, title: _title()),
                        ));
                        if (changed == true) onChanged();
                      },
                    ),
                  for (final p in pending)
                    _thumb(
                      child: Stack(fit: StackFit.expand, children: [
                        Image.file(File(p['path'].toString()), fit: BoxFit.cover),
                        Container(color: Colors.black38, child: const Center(child: Icon(Icons.cloud_upload_outlined, color: Colors.white))),
                      ]),
                      onTap: () => _pendingMenu(context, p),
                    ),
                ]),
              ),
          ]),
        );
      },
    );
  }

  String _title() {
    final name = (visit['location_name'] ?? '').toString();
    final seq = visit['seq'] != null ? ' ${visit['seq']}' : '';
    return name.isNotEmpty ? name : '${visit['kind'] == 'survey' ? 'Site survey' : 'Visit'}$seq';
  }

  Widget _thumb({required Widget child, required VoidCallback onTap}) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(width: 76, height: 76, color: const Color(0xFFE5E7EB), child: child),
          ),
        ),
      );

  void _pendingMenu(BuildContext context, Map<String, dynamic> p) {
    showModalBottomSheet(context: context, builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const ListTile(leading: Icon(Icons.cloud_upload_outlined), title: Text('Waiting to upload'), subtitle: Text('It will send by itself when there is signal.')),
      ListTile(leading: const Icon(Icons.refresh), title: const Text('Try now'), onTap: () { Navigator.pop(c); PhotoQueue.instance.kick(); }),
      ListTile(leading: const Icon(Icons.delete_outline, color: Colors.red), title: const Text("Don't upload this photo"), onTap: () { Navigator.pop(c); PhotoQueue.instance.remove(p); }),
    ])));
  }

  Future<void> _add(BuildContext context) async {
    final src = await showModalBottomSheet<ImageSource>(context: context, builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo'), onTap: () => Navigator.pop(c, ImageSource.camera)),
      ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(c, ImageSource.gallery)),
    ])));
    if (src == null) return;
    final picker = ImagePicker();
    List<XFile> files = [];
    try {
      if (src == ImageSource.camera) {
        final f = await picker.pickImage(source: ImageSource.camera, maxWidth: 2000, maxHeight: 2000, imageQuality: 80);
        if (f != null) files = [f];
      } else {
        files = await picker.pickMultiImage(maxWidth: 2000, maxHeight: 2000, imageQuality: 80, limit: 20);
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open the camera or gallery.")));
      return;
    }
    if (files.isEmpty || !context.mounted) return;
    final caption = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('${files.length} photo${files.length == 1 ? '' : 's'} · ${_title()}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 70, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final f in files) Padding(padding: const EdgeInsets.only(right: 6), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(f.path), width: 70, height: 70, fit: BoxFit.cover))),
        ])),
        const SizedBox(height: 10),
        TextField(controller: caption, maxLength: 300, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Caption (optional)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Upload')),
      ],
    ));
    if (ok != true) return;
    for (final f in files) {
      await PhotoQueue.instance.add(number, _vid, f.path, caption.text);
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploading ${files.length} photo${files.length == 1 ? '' : 's'}. No signal? They send by themselves later.')));
  }
}

/// Full-screen swipe viewer for one location's photos.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.number, required this.visitId, required this.photos, required this.start, required this.title, this.canDelete = true});
  final String number;
  final int visitId;
  final bool canDelete;
  final List<Map<String, dynamic>> photos;
  final int start;
  final String title;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _page = PageController(initialPage: widget.start);
  late final List<Map<String, dynamic>> _photos = [...widget.photos];
  late int _i = widget.start;
  bool _changed = false, _busy = false;

  String _when(dynamic v) {
    var d = DateTime.tryParse((v ?? '').toString());
    if (d == null) return '';
    if (d.isUtc) d = d.toLocal();
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year} · ${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  bool _canRemove(Map p) {
    if (!widget.canDelete) return false;
    final me = '${TechHub.instance.engineer?['id'] ?? ''}';
    return TechHub.instance.isLead || (me.isNotEmpty && '${p['added_by_id'] ?? ''}' == me);
  }

  Future<void> _remove() async {
    final p = _photos[_i];
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Remove this photo?'),
      content: const Text('It will be removed from the ticket for everyone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(c, true), child: const Text('Remove'))],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await TechHub.instance.visitPhotoDelete(widget.number, widget.visitId, (p['id'] as num).toInt());
      _changed = true;
      if (!mounted) return;
      if (_photos.length == 1) { Navigator.pop(context, true); return; }
      setState(() { _photos.removeAt(_i); if (_i >= _photos.length) _i = _photos.length - 1; });
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _photos[_i];
    final caption = (p['caption'] ?? '').toString();
    final who = (p['added_by'] ?? '').toString();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) { if (!did) Navigator.pop(context, _changed); },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black, foregroundColor: Colors.white,
          title: Text('${widget.title} · ${_i + 1} of ${_photos.length}', style: const TextStyle(fontSize: 16)),
          actions: [if (_canRemove(p)) IconButton(tooltip: 'Remove photo', onPressed: _busy ? null : _remove, icon: const Icon(Icons.delete_outline))],
        ),
        body: Column(children: [
          Expanded(child: PageView.builder(
            controller: _page,
            itemCount: _photos.length,
            onPageChanged: (i) => setState(() => _i = i),
            itemBuilder: (_, i) => InteractiveViewer(
              maxScale: 5,
              child: Hero(tag: 'vp${_photos[i]['id']}', child: AuthImage(_photos[i]['url'].toString(), fit: BoxFit.contain)),
            ),
          )),
          SafeArea(top: false, child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (caption.isNotEmpty) Text(caption, style: const TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 4),
              Text([if (who.isNotEmpty) who, _when(p['added_at'])].where((s) => s.isNotEmpty).join(' · '), style: const TextStyle(color: Colors.white60)),
            ]),
          )),
        ]),
      ),
    );
  }
}

// ── whole-ticket photos & files (no remove: they are part of the ticket record) ──

bool isImageAttachment(Map a) => a['is_image'] == true || (a['mime'] ?? '').toString().startsWith('image/');

void openTicketPhotos(BuildContext context, String number, List<Map<String, dynamic>> images, int start) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PhotoViewer(number: number, visitId: 0, photos: images, start: start, title: number, canDelete: false),
  ));
}

Future<void> openTicketFile(BuildContext context, Map a) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Opening…'), duration: Duration(seconds: 1)));
  final f = await AuthImageCache.get(a['url'].toString());
  if (f == null) { messenger.showSnackBar(const SnackBar(content: Text("Couldn't download that file."))); return; }
  // Give the cached copy its real name so the right app opens it.
  final name = (a['name'] ?? a['filename'] ?? 'file').toString().replaceAll(RegExp(r'[\\/]'), '_');
  final named = File('${f.parent.path}/${f.uri.pathSegments.last}_$name');
  if (!await named.exists()) await f.copy(named.path);
  final r = await OpenFilex.open(named.path, type: (a['mime'] ?? '').toString().isEmpty ? null : a['mime'].toString());
  if (r.type != ResultType.done) messenger.showSnackBar(SnackBar(content: Text('No app on this phone can open ${a['name'] ?? 'this file'}.')));
}

/// "Photos & files" body for ticket.attachments[] (also used inline on history entries).
class TicketAttachments extends StatelessWidget {
  const TicketAttachments({super.key, required this.number, required this.items, this.size = 84});
  final String number;
  final List<Map<String, dynamic>> items;
  final double size;

  @override
  Widget build(BuildContext context) {
    final images = items.where(isImageAttachment).toList();
    final files = items.where((a) => !isImageAttachment(a)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (images.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < images.length; i++)
          GestureDetector(
            onTap: () => openTicketPhotos(context, number, images, i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(width: size, height: size, color: const Color(0xFFE5E7EB), child: AuthImage(images[i]['url'].toString())),
            ),
          ),
      ]),
      if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: 8),
      for (final a in files)
        InkWell(
          onTap: () => openTicketFile(context, a),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon((a['mime'] ?? '').toString().contains('pdf') ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined, color: wocomMuted),
              const SizedBox(width: 8),
              Expanded(child: Text((a['name'] ?? a['filename'] ?? 'File').toString(), style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              if (a['size'] is num) Text(_size((a['size'] as num).toInt()), style: const TextStyle(color: wocomMuted, fontSize: 12)),
              const SizedBox(width: 6),
              const Icon(Icons.open_in_new, size: 16, color: wocomMuted),
            ]),
          ),
        ),
    ]);
  }

  static String _size(int b) => b >= 1048576 ? '${(b / 1048576).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';
}
