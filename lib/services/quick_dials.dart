/// Short codes the app understands before a number reaches the phone system, and the names
/// and badges shown for them on the call screen.
///
///   100       → WOCOM office (876 906 7240)
///   119, 911  → Police emergency (Jamaica's 119)
///   110       → Fire & Ambulance
enum QuickDialKind { wocom, police, fire }

class QuickDial {
  const QuickDial({required this.kind, required this.name, required this.dial, required this.emergency});

  final QuickDialKind kind;
  final String name;
  final String dial;       // what actually goes to the phone system
  final bool emergency;

  String get service => kind == QuickDialKind.police ? 'police' : 'fire_ambulance';
}

const _wocomOffice = QuickDial(kind: QuickDialKind.wocom, name: 'WOCOM Limited', dial: '18769067240', emergency: false);
const _police = QuickDial(kind: QuickDialKind.police, name: 'Police Emergency', dial: '119', emergency: true);
const _fire = QuickDial(kind: QuickDialKind.fire, name: 'Fire & Ambulance', dial: '110', emergency: true);

/// What a typed number means, if it is one of ours.
QuickDial? quickDialFor(String typed) {
  final d = typed.replaceAll(RegExp(r'\D'), '');
  return switch (d) {
    '100' => _wocomOffice,
    '119' || '911' => _police,
    '110' => _fire,
    _ => null,
  };
}

/// What a number on a live call represents (either side), so the call screen can show the badge.
QuickDial? quickDialForRemote(String number) {
  final d = number.replaceAll(RegExp(r'\D'), '');
  if (d == '119' || d == '911') return _police;
  if (d == '110') return _fire;
  if (d.endsWith('8769067240') && d.length >= 10) return _wocomOffice;
  return null;
}
