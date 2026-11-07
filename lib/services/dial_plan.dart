/// Turns whatever a person typed or saved into what the phone system expects.
///
///   876 960 1004, (876) 960-1004, 876-960-1004, +1 876 960 1004  →  18769601004
///   960 1004 (7 digits, Jamaica)                                  →  18769601004
///   305 878 8092                                                  →  13058788092
///   +44 20 7946 0958                                              →  011442079460958
///   2000, 8000, *97, #, 1900 (extensions and feature codes)       →  unchanged
String normalizeDialString(String raw, {String defaultAreaCode = '876'}) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  // Feature codes and anything with * or # are dialled exactly as typed.
  if (s.startsWith('*') || s.startsWith('#') || s.contains('*') || s.contains('#')) {
    return s.replaceAll(RegExp(r'[^0-9*#+]'), '');
  }
  final plus = s.startsWith('+');
  final digits = s.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return '';

  if (plus) {
    // International, written with +: North America keeps its 1, everywhere else gets 011.
    return digits.startsWith('1') ? digits : '011$digits';
  }
  if (digits.length <= 6) return digits;                    // extension or short code
  if (digits.length == 7) return '1$defaultAreaCode$digits'; // local number without area code
  if (digits.length == 10) return '1$digits';                // area code + number
  if (digits.length == 11 && digits.startsWith('1')) return digits;
  if (digits.startsWith('011')) return digits;               // already international
  return digits;
}

/// Why a typed number can't be dialled, or null when it can. Catches the common slips before
/// the carrier rejects them: 8 or 9 digits (a number missing digits), or an over-long one.
String? dialProblem(String raw) {
  final s = raw.trim();
  if (s.contains('*') || s.contains('#') || s.startsWith('+')) return null;
  final digits = s.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return 'Enter a number first.';
  if (digits.length == 8 || digits.length == 9) return "That isn't a complete number. Local numbers are 7 digits, or 10 with the area code.";
  if (digits.length == 11 && !digits.startsWith('1')) return 'An 11-digit number must start with 1. For overseas, dial 011 then the country code.';
  if (digits.length > 11 && !digits.startsWith('011')) return 'For overseas numbers dial 011, then the country code and number.';
  if (digits.length > 18) return "That's too many digits.";
  return null;
}

/// "18769067240" → "(876) 906-7240"; short extensions are left as they are.
String prettyNumber(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  final digits = d.startsWith('+') ? d.substring(1) : d;
  if (digits.length == 11 && digits.startsWith('1')) return '(${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
  if (digits.length == 10) return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
  if (digits.length == 7) return '${digits.substring(0, 3)}-${digits.substring(3)}';
  return raw;
}
