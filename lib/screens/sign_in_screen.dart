import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../brand.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../theme.dart';

/// Activation. The usual path needs no password: the person types the email or mobile number
/// on their profile, picks how to get a code (email, text, or a phone call that reads it out),
/// and enters it. Administrators can still sign in with a password, or scan a QR from the Hub.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.password = false});

  /// Open straight on the password form.
  final bool password;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _Step { identify, channel, code }

class _SignInScreenState extends State<SignInScreen> {
  final _ident = TextEditingController();
  final _code = TextEditingController();
  _Step _step = _Step.identify;
  bool _busy = false;
  String? _error;
  String? _challengeId;
  List<Map<String, dynamic>> _channels = [];
  String? _lookedUp;
  String _sentTo = '';
  String _channel = 'email';
  int _resendsLeft = 0;

  Future<void> _run(Future<void> Function() action) async {
    setState(() { _busy = true; _error = null; });
    try {
      await action();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Look the person up, then send straight away on the channel they tapped.
  Future<void> _startWith(String channel) => _run(() async {
        final id = _ident.text.trim();
        if (id.isEmpty) throw ApiException('empty', 'Enter the email or mobile number on your profile first.', 0);
        if (_challengeId == null || _lookedUp != id) {
          final r = await Session.instance.api.start(id, await Session.deviceInfo());
          _challengeId = r['challenge_id'] as String;
          _lookedUp = id;
          _channels = ((r['channels'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).where((c) => c['channel'] != 'sms').toList();
        }
        if (!_channels.any((c) => c['channel'] == channel)) {
          throw ApiException('no_channel', channel == 'call' ? 'There is no mobile number on your profile, so we can\'t call you. Use email, or ask your administrator to add your number.' : 'That option is not available for this account.', 0);
        }
        await _send(channel);
      });

  Future<void> _send(String channel) => _run(() async {
        final r = await Session.instance.api.sendCode(_challengeId!, channel);
        setState(() {
          _channel = channel;
          _sentTo = (r['sent_to'] ?? '').toString();
          _resendsLeft = (r['resends_left'] ?? 0) as int;
          _code.clear();
          _step = _Step.code;
        });
      });

  Future<void> _verify() => _run(() async {
        final r = await Session.instance.api.verify(_challengeId!, _code.text.trim());
        await Session.instance.signedInWith(r);
      });

  Future<void> _resend() => _run(() async {
        final r = await Session.instance.api.resend(_challengeId!);
        setState(() => _resendsLeft = (r['resends_left'] ?? 0) as int);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_channel == 'call' ? 'Calling you again now.' : 'New code sent.')));
      });

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _QrScanScreen()));
    if (code == null || code.isEmpty) return;
    await _run(() async {
      final r = await Session.instance.api.qr(code, await Session.deviceInfo());
      await Session.instance.signedInWith(r);
    });
  }

  void _restart() => setState(() { _step = _Step.identify; _challengeId = null; _lookedUp = null; _channels = []; _error = null; _code.clear(); });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (title, blurb) = switch (_step) {
      _Step.identify || _Step.channel => ('Activate your phone', 'Enter the email address or mobile number on your profile, then choose how to get your 6-digit code.'),
      _Step.code => ('Enter your code', switch (_channel) {
          'call' => 'We\'re calling $_sentTo now. Listen for the six digits; they are read three times.',
          _ => 'We sent a 6-digit code by email to $_sentTo. It works for 5 minutes.',
        }),
    };
    final stepIndex = _step == _Step.identify ? 0 : 1;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
        const Positioned(left: 0, right: 0, bottom: 0, child: JmWaves(height: 90)),
        SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                  child: Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: wocomLine)),
                      child: IconButton(padding: EdgeInsets.zero, tooltip: 'Back', icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: wocomInk),
                          onPressed: _busy ? null : () => _step == _Step.code ? _restart() : Navigator.of(context).maybePop()),
                    ),
                    const Spacer(),
                    for (var i = 0; i < 2; i++) Container(width: 28, height: 4, margin: const EdgeInsets.only(left: 6), decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: i <= stepIndex ? const Color(0xFF009B3A) : wocomLine)),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 120),
                    child: AutofillGroup(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Align(alignment: Alignment.centerLeft, child: BrandWordmark(fontSize: 22)),
                        const SizedBox(height: 14),
                        Text(title, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, height: 1.1, letterSpacing: -0.5, color: wocomInk)),
                        const SizedBox(height: 10),
                        const Align(alignment: Alignment.centerLeft, child: JmBar(width: 64, thickness: 3)),
                        const SizedBox(height: 8),
                        Text(blurb, style: const TextStyle(fontSize: 15, height: 1.45, color: wocomMuted)),
                        const SizedBox(height: 18),

                        if (_step == _Step.identify || _step == _Step.channel) ...[
                          TextField(
                            controller: _ident,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email, AutofillHints.telephoneNumber],
                            textInputAction: TextInputAction.done,
                            onChanged: (_) { if (_error != null) setState(() => _error = null); },
                            decoration: const InputDecoration(labelText: 'Email or mobile number', prefixIcon: Icon(Icons.person_outline)),
                          ),
                          const SizedBox(height: 14),
                          _ChannelCard(channel: 'email', to: 'the email on your profile', onTap: _busy ? null : () => _startWith('email'), highlight: true),
                          const SizedBox(height: 10),
                          _ChannelCard(channel: 'call', to: 'the mobile on your profile', onTap: _busy ? null : () => _startWith('call')),
                          const SizedBox(height: 10),
                          _ChannelCard(channel: 'qr', to: '', onTap: _busy ? null : _scan),
                          if (_busy) const Padding(padding: EdgeInsets.only(top: 14), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)))),
                        ] else ...[
                          TextField(
                            controller: _code,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 10),
                            onChanged: (v) { if (v.length == 6 && !_busy) _verify(); },
                            decoration: const InputDecoration(counterText: '', hintText: '••••••'),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: _busy ? null : _verify,
                            style: FilledButton.styleFrom(
                              backgroundColor: wocomButton,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(52),
                              shape: const StadiumBorder(),
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Activate'),
                          ),
                          const SizedBox(height: 6),
                          Wrap(alignment: WrapAlignment.center, children: [
                            TextButton(onPressed: _busy || _resendsLeft <= 0 ? null : _resend, child: Text(_resendsLeft > 0 ? (_channel == 'call' ? 'Call me again' : 'Send a new code') : 'No more codes')),
                            TextButton(onPressed: _busy ? null : _restart, child: const Text('Try another way')),
                          ]),
                        ],

                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
                            child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600, height: 1.35)),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The green/gold band at the foot of the activation screen.
class _Band extends CustomClipper<Path> {
  const _Band({this.offset = 0});
  final double offset;

  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, size.height * 0.45 + offset * 0.3)
    ..lineTo(size.width, offset * 0.2)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(covariant _Band old) => old.offset != offset;
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel, required this.to, required this.onTap, this.highlight = false});
  final String channel;
  final String to;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final (icon, title, sub) = switch (channel) {
      'sms' => (Icons.sms_outlined, 'Text message', 'A code by SMS to $to'),
      'call' => (Icons.phone_in_talk_outlined, 'Call me with the code', 'We call $to and read the PIN aloud'),
      'qr' => (Icons.qr_code_scanner, 'Scan a QR setup code', 'Shown by your administrator in the Hub'),
      _ => (Icons.mail_outline, 'Email me the code', 'Sent to $to'),
    };
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: highlight ? wocomSoft : Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: highlight ? wocomDeep : wocomLine, width: highlight ? 2 : 1)),
          child: Row(children: [
            Container(width: 46, height: 46, decoration: BoxDecoration(color: highlight ? wocomDeep : (channel == 'qr' ? const Color(0xFFE7F6EC) : wocomSoft), shape: BoxShape.circle), child: Icon(icon, color: highlight ? Colors.white : (channel == 'qr' ? const Color(0xFF008F3A) : wocomDeep))),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: wocomInk)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
            ])),
            if (highlight) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)), child: const Text('Fastest', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF008F3A)))) else const Icon(Icons.chevron_right, color: Color(0xFFB8B1C6)),
          ]),
        ),
      ),
    );
  }
}

/// Camera QR scanner, with a fallback to typing the code shown under the QR.
class _QrScanScreen extends StatefulWidget {
  const _QrScanScreen();

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  DateTime _lastWrongQr = DateTime(2000);

  void _finish(String code) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(code.trim().toUpperCase());
  }

  /// Accepts "wocom://activate?code=WA-…&host=…" or a bare "WA-…" code.
  String? _codeFrom(String raw) {
    final m = RegExp(r'(WA-[A-Z0-9]{10})', caseSensitive: false).firstMatch(raw);
    return m?.group(1);
  }

  Future<void> _typeCode() async {
    final ctrl = TextEditingController(text: 'WA-');
    final code = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Enter the code'),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(hintText: 'WA-XXXXXXXXXX')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Sign in')),
        ],
      ),
    );
    if (code != null && code.trim().length >= 13) _finish(code);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Scan QR code')),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            for (final b in capture.barcodes) {
              final code = _codeFrom(b.rawValue ?? '');
              if (code != null) return _finish(code);
            }
            // A QR, but not ours (e.g. the older mobile app's code): say so, at most every few seconds.
            if (capture.barcodes.isNotEmpty && DateTime.now().difference(_lastWrongQr).inSeconds > 4) {
              _lastWrongQr = DateTime.now();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                duration: Duration(seconds: 6),
                content: Text('This QR code is for a different app. In the WOCOM Hub, open the extension and use the "${Brand.name} app" tab to get the right code.'),
              ));
            }
          },
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Column(children: [
            const Text('Point the camera at the QR code on the WOCOM Hub.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 14),
            TextButton(onPressed: _typeCode, style: TextButton.styleFrom(foregroundColor: Colors.white), child: const Text('Type the code instead')),
          ]),
        ),
      ]),
    );
  }
}
