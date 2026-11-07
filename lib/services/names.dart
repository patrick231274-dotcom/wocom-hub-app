import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Phone;
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';
import 'hub.dart';
import 'session.dart';

/// Turns a number into a name the user recognises: a colleague's extension, a company directory
/// entry, or a contact on this phone. Used for incoming calls and the Recents list, so the caller
/// ID name passes through even when the phone system only sends a number.
class Names {
  Names._();
  static final Names instance = Names._();

  final Map<String, String> _directory = {}; // digits → name
  final Map<String, String> _phone = {};     // digits → name
  bool _loaded = false;

  static String _digits(String n) => n.replaceAll(RegExp(r'\D'), '');

  /// Last 7 digits are enough to match "876 960 1004", "18769601004" and "960-1004".
  static String _key(String digits) => digits.length > 7 ? digits.substring(digits.length - 7) : digits;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final r = await Session.instance.api.get('directory');
      for (final c in (r['contacts'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(c as Map);
        for (final p in (m['phones'] as List? ?? const [])) {
          final d = _digits((p as Map)['number'].toString());
          if (d.length >= 7) _directory[_key(d)] = m['name'] as String;
        }
      }
    } on ApiException {
      _loaded = false; // try again next time
    } catch (_) {}
    try {
      if (await Permission.contacts.isGranted) {
        for (final c in await FlutterContacts.getAll(properties: {ContactProperty.name, ContactProperty.phone})) {
          final name = (c.displayName ?? '').trim();
          if (name.isEmpty) continue;
          for (final p in c.phones) {
            final d = _digits(p.number);
            if (d.length >= 7) _phone[_key(d)] = name;
          }
        }
      }
    } catch (e) {
      debugPrint('phone contacts: $e');
    }
    // Keep the location permission warm too (emergency calls use it).
    try { await Geolocator.checkPermission(); } catch (_) {}
  }

  /// A name for this number, or null when nothing is known.
  String? lookup(String number) {
    final d = _digits(number);
    if (d.isEmpty) return null;
    if (d.length <= 6) {
      for (final p in Hub.instance.people) {
        if (p['extension'] == d) return p['name'] as String?;
      }
      return null;
    }
    final k = _key(d);
    return _directory[k] ?? _phone[k];
  }
}
