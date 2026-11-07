import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart';
import 'techhub.dart';

import '../brand.dart';

import 'api.dart';
import 'dial_plan.dart';
import 'diag.dart';
import 'emergency.dart';
import 'names.dart';
import 'native_call.dart';
import 'quick_dials.dart';
import 'session.dart';

enum LineStatus { offline, connecting, ready, failed }

/// The phone line: registers the user's extension over the Hub's secure WebSocket
/// (the same connection the Hub webphone uses) and runs calls with WebRTC, so audio
/// is always encrypted (DTLS-SRTP).
class Phone extends ChangeNotifier implements SipUaHelperListener {
  Phone._();
  static final Phone instance = Phone._();

  final SIPUAHelper _ua = SIPUAHelper();
  LineStatus status = LineStatus.offline;
  String statusText = 'Not connected';
  String extension = '';
  Call? call;
  CallStateEnum? callState;
  DateTime? connectedAt;
  bool muted = false;
  bool speaker = false;
  /// Where call audio is going now (earpiece | speaker | bluetooth | wired) and what's possible.
  String audioRoute = 'earpiece';
  List<String> audioRoutes = const [];
  String? bluetoothName;
  bool held = false;
  final List<RecentCall> recents = [];

  /// Fired when a call arrives, so the app can open the call screen.
  VoidCallback? onIncoming;

  /// Answer was tapped on Android's call screen before the SIP invite reached us (app was asleep):
  /// pick up as soon as it arrives.
  bool _autoAnswerPending = false;
  Timer? _autoAnswerTimeout;
  /// Why a push-woken call never reached this phone ("Answered on another phone" …); shown briefly on the call screen.
  String? endedNote;
  String? _pendingCallId;
  /// Who is calling, from the push / Android's call screen, while we wait for the call itself.
  String? pendingCaller;

  /// The server says the call is gone (answered elsewhere or the caller hung up) before it reached us.
  void pushCancelled(String callId) {
    if (call != null) return;
    if (_pendingCallId != null && callId.isNotEmpty && _pendingCallId != callId) return;
    if (_autoAnswerPending) {
      Diag.log('call', 'cancelled before it reached this phone ($callId)');
      endedNote = 'Answered on another phone, or the caller hung up';
      autoAnswerPending = false;
    }
    _pendingCallId = null;
  }

  /// A push says a call is on its way (app was in the background): get the line registered now,
  /// before Answer is tapped, so the server can hand us the call while it is still ringing.
  void pushIncoming(String callId, [String caller = '']) {
    _pendingCallId = callId;
    if (caller.isNotEmpty) pendingCaller = caller;
    endedNote = null;
    Diag.log('call', 'push: call $callId on its way, registering');
    refreshRegistration();
  }
  /// Set when Answer was tapped on Android's call screen before the call reached the app
  /// (woken by push): the next incoming call is answered at once. Cleared after 30 s.
  bool get autoAnswerPending => _autoAnswerPending;
  set autoAnswerPending(bool v) {
    _autoAnswerPending = v;
    _autoAnswerTimeout?.cancel();
    if (v) {
      endedNote = null;
      Diag.log('call', 'answer tapped before the call arrived: waiting for it');
      _autoAnswerTimeout = Timer(const Duration(seconds: 20), () {
        if (_autoAnswerPending) {
          Diag.log('call', 'the call never arrived (20 s)');
          endedNote = "The call didn't reach this phone. It may have been answered elsewhere.";
          _autoAnswerPending = false;
          notifyListeners();
        }
      });
    }
    notifyListeners();
  }
  VoidCallback? onAutoAnswered;

  Timer? _regProbe;

  /// Ask listeners to look again (e.g. the app came to the front during a call).
  void poke() => notifyListeners();

  static const _android = MethodChannel('wocom/app');
  void _tellAndroidInCall(bool v) {
    _android.invokeMethod('inCall', v).catchError((_) => null);
  }

  /// A call is on its way and the server waits for a fresh registration. Re-register on the
  /// live connection first (a quarter of a second, no socket churn); if the connection slept
  /// and gives no answer within 1.5 s, open a new one.
  void refreshRegistration() {
    if (status == LineStatus.ready && !_restarting) {
      Diag.log('reg', 'refresh on the live connection');
      _regProbe?.cancel();
      _regProbe = Timer(const Duration(milliseconds: 1500), () {
        Diag.log('reg', 'no answer to the refresh in 1.5 s: the connection is dead');
        restart('refresh unanswered');
      });
      try { _ua.register(); } catch (e) { restart('refresh failed: $e'); }
      return;
    }
    restart('call on its way');
  }

  StreamSubscription<List<ConnectivityResult>>? _net;
  String _lastNet = '';
  bool _reconnectAfterCall = false;
  bool _restarting = false;
  Timer? _restartDebounce;

  /// Wi-Fi ↔ mobile data: restart the line once the network actually changes (not on the
  /// initial report, and not when the same network is reported again).
  void watchNetwork() {
    _net ??= Connectivity().onConnectivityChanged.listen((results) {
      final now = (results.toList()..sort((a, b) => a.name.compareTo(b.name))).map((r) => r.name).join(',');
      final was = _lastNet;
      _lastNet = now;
      Diag.log('net', 'connectivity $was -> $now');
      if (was.isEmpty || was == now) return;
      if (results.contains(ConnectivityResult.none) && results.length == 1) {
        _set(LineStatus.connecting, 'No network…');
        return;
      }
      if (call == null) {
        restart('network changed');
      } else {
        _reconnectAfterCall = true; // keep the call; re-register when it ends
      }
    });
  }

  Completer<void>? _oldClosed;

  /// Stop and start the line, once however many things ask for it. The old connection is
  /// closed completely before the new one opens, so the two never overlap on the server.
  void restart(String reason) {
    Diag.log('line', 'restart requested: $reason');
    _restartDebounce?.cancel();
    _restartDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (_restarting) return;
      _restarting = true;
      try {
        _recover?.cancel();
        _regProbe?.cancel();
        final hadLine = status != LineStatus.offline;
        status = LineStatus.offline;
        if (hadLine) {
          _oldClosed = Completer<void>();
          try { _ua.stop(); } catch (_) {}
          await _oldClosed!.future.timeout(const Duration(milliseconds: 2500), onTimeout: () => Diag.log('line', 'old connection did not close in 2.5 s; going on'));
          _oldClosed = null;
        }
        await connect();
      } finally {
        _restarting = false;
      }
    });
  }

  Future<void> connect() async {
    if (status == LineStatus.connecting || status == LineStatus.ready) return;
    _set(LineStatus.connecting, 'Connecting…');
    Diag.log('line', 'connect');
    Map<String, dynamic> sip;
    try {
      // WE App: the office extension on the workspace PBX, handed out by the push server.
      sip = ((Brand.isEmployee ? await TechHub.instance.callingConfig() : await Session.instance.api.callingConfig())['sip']) as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.signedOut && !Brand.isEmployee) await Session.instance.forceSignedOut();
      _set(LineStatus.failed, e.message);
      return;
    }
    extension = sip['extension'].toString();
    final deviceUuid = await Session.instance.deviceUuid();
    final settings = UaSettings()
      // Stable per phone: the registration's Call-ID (via instanceId, see the vendored sip_ua)
      // and contact. A second copy of the app or a reconnect then REPLACES this phone's
      // registration on the switch rather than adding one, so only the newest copy is rung.
      ..instanceId = deviceUuid
      ..contact_uri = 'sip:w${deviceUuid.substring(0, 8)}@wocom.invalid${Brand.isEmployee ? ';transport=ws' : ''}'
      ..webSocketUrl = sip['wss_uri'] as String
      ..uri = 'sip:${sip['extension']}@${sip['domain']}'
      ..authorizationUser = sip['extension'].toString()
      ..password = sip['password'] as String
      ..displayName = sip['display_name'] as String
      ..userAgent = 'WOCOM App'
      ..register = true
      ..register_expires = 120
      ..dtmfMode = DtmfMode.RFC2833
      ..iceGatheringTimeout = 300
      ..transportType = TransportType.WS
      ..iceServers = ((sip['ice_servers'] as List?) ?? const []).map((e) => Map<String, String>.from(e as Map)).toList();
    settings.webSocketSettings.allowBadCertificate = false;
    _ua.removeSipUaHelperListener(this);
    _ua.addSipUaHelperListener(this);
    try {
      await _ua.start(settings);
      Diag.log('line', 'start returned');
    } catch (e) {
      Diag.log('line', 'start failed: $e');
      _set(LineStatus.failed, "Couldn't connect your extension.");
    }
    _stall?.cancel();
    _stall = Timer(const Duration(seconds: 12), () {
      if (status == LineStatus.connecting || status == LineStatus.failed) restart('connect stalled for 12 s');
    });
  }

  void disconnect() {
    _ua.stop();
    _set(LineStatus.offline, 'Not connected');
  }

  /// The number is cleaned up first (see dial_plan.dart), so "(876) 960-1004" dials 18769601004.
  Future<bool> dial(String number) async {
    final quick = quickDialFor(number);
    final target = quick?.dial ?? normalizeDialString(number);
    if (target.isEmpty || status != LineStatus.ready) return false;
    Diag.log('call', 'dial $target');
    final ok = await _ua.call(target, voiceOnly: true);
    Diag.log('call', 'dial accepted by library: $ok');
    if (ok) Future.delayed(const Duration(milliseconds: 300), () { if (call != null && !incoming) _watchDial(call!.id ?? ''); });
    // Emergency: send the phone's position in the background; the call is never held up.
    if (ok && quick != null && quick.emergency) unawaited(Emergency.report(quick));
    return ok;
  }

  /// Which quick-dial the current call is with (WOCOM office, police, fire), if any.
  QuickDial? get remoteQuickDial => call == null ? null : quickDialForRemote(remoteNumber);

  // Ringtone + vibration for an incoming call while the app is open. (Ringing when the phone is
  // locked or the app is closed needs push notifications, which come with Firebase.)
  final _ringer = FlutterRingtonePlayer();
  Timer? _vibrate;
  bool _ringing = false;

  void _stopRinging() {
    if (!_ringing) return;
    _ringing = false;
    _ringer.stop();
    _vibrate?.cancel();
  }

  void answer() {
    final c = call;
    if (c == null) return;
    c.answer(_ua.buildCallOptions(true));
  }

  void hangup() {
    final c = call;
    if (c == null) return;
    try {
      c.hangup({'status_code': 603});
    } catch (_) {
      _endCall();
    }
  }

  void toggleMute() {
    final c = call;
    if (c == null) return;
    muted ? c.unmute(true, false) : c.mute(true, false);
  }

  void toggleHold() {
    final c = call;
    if (c == null) return;
    held ? c.unhold() : c.hold();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await applyAudioRoute();
    notifyListeners();
  }

  /// From the in-call audio picker.
  Future<void> chooseRoute(String route) async {
    speaker = route == 'speaker';
    await applyAudioRoute(route);
    notifyListeners();
  }

  Future<void> refreshRoutes() async {
    final r = await NativeCall.instance.routes();
    if (r != null) {
      audioRoute = (r['current'] ?? 'earpiece').toString();
      audioRoutes = ((r['available'] as List?) ?? const []).map((e) => e.toString()).toList();
      bluetoothName = r['bluetooth_name']?.toString();
    } else {
      try {
        final outs = (await navigator.mediaDevices.enumerateDevices()).where((d) => d.kind == 'audiooutput').map((d) => d.deviceId).toList();
        audioRoutes = outs.map((o) => o == 'wired-headset' ? 'wired' : o).toList();
      } catch (_) {}
      audioRoute = speaker ? 'speaker' : (audioRoutes.contains('bluetooth') ? 'bluetooth' : 'earpiece');
    }
    Diag.log('audio', 'route $audioRoute of $audioRoutes');
    notifyListeners();
  }

  /// Speaker when chosen; otherwise a Bluetooth headset if one is connected, then a wired
  /// headset, then the earpiece. (setSpeakerphoneOn(false) alone takes whichever of these
  /// Android lists first, which is often the earpiece, so calls answered on a headset
  /// jumped back to the phone.)
  Future<void> applyAudioRoute([String? want]) async {
    want ??= speaker ? 'speaker' : 'auto';
    // A call Android knows about (Telecom) must be routed through Android's call, or
    // Android puts it back on the earpiece.
    final took = await NativeCall.instance.setRoute(want);
    Future.delayed(const Duration(milliseconds: 700), refreshRoutes);
    if (took) return;
    if (want == 'speaker') { await Helper.setSpeakerphoneOn(true); return; }
    if (want == 'earpiece') { await Helper.setSpeakerphoneOn(false); return; }
    try {
      final outs = (await navigator.mediaDevices.enumerateDevices()).where((d) => d.kind == 'audiooutput').map((d) => d.deviceId).toList();
      final pick = outs.contains('bluetooth') ? 'bluetooth' : (outs.contains('wired-headset') ? 'wired-headset' : null);
      Diag.log('audio', 'outputs $outs -> ${pick ?? 'earpiece'}');
      if (pick != null) { await Helper.selectAudioOutput(pick); return; }
    } catch (e) {
      Diag.log('audio', 'route: $e');
    }
    await Helper.setSpeakerphoneOn(false);
  }

  void sendTone(String digit) => call?.sendDTMF(digit);

  /// Blind transfer of the current call (SIP REFER). The number is cleaned up like a dial.
  bool transfer(String number) {
    final c = call;
    final target = normalizeDialString(number);
    if (c == null || target.isEmpty) return false;
    try {
      c.refer(target);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get incoming => call != null && call!.direction.toString().toLowerCase().contains('incoming');
  bool get connected => callState == CallStateEnum.CONFIRMED || callState == CallStateEnum.ACCEPTED ||
      callState == CallStateEnum.HOLD || callState == CallStateEnum.UNHOLD || callState == CallStateEnum.MUTED ||
      callState == CallStateEnum.UNMUTED || callState == CallStateEnum.STREAM;
  String get remoteNumber => call?.remote_identity ?? '';
  /// The caller's display name from the network, unless it is just a number or a generic
  /// "Extension 2000" label; then '' so callers fall back to the directory/team lookup.
  String get remoteName {
    final n = (call?.remote_display_name ?? '').trim();
    if (RegExp(r'^(extension|ext\.?)?\s*[0-9+ ()\-]*$', caseSensitive: false).hasMatch(n)) return '';
    return n;
  }

  // --- SipUaHelperListener ---------------------------------------------------

  @override
  void registrationStateChanged(RegistrationState state) {
    Diag.log('reg', '${state.state} ${state.cause ?? ''}');
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        _regProbe?.cancel();
        _regProbe = null;
        _stall?.cancel();
        _set(LineStatus.ready, 'Ready · Ext $extension');
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _set(LineStatus.failed, "Couldn't register your extension. Check your connection.");
        break;
      case RegistrationStateEnum.UNREGISTERED:
        if (status != LineStatus.offline) _set(LineStatus.connecting, 'Reconnecting…');
        break;
      default:
        break;
    }
  }

  Timer? _recover;
  Timer? _stall;

  @override
  void transportStateChanged(TransportState state) {
    Diag.log('transport', '${state.state} ${state.cause ?? ''}');
    if (state.state == TransportStateEnum.DISCONNECTED) {
      if (_oldClosed != null && !_oldClosed!.isCompleted) _oldClosed!.complete();
      if (_restarting || status == LineStatus.offline) return; // we closed it on purpose
      _set(LineStatus.connecting, 'Reconnecting…');
      // The library retries on its own; if the line is still down after 10 s, restart it ourselves.
      _recover?.cancel();
      _recover = Timer(const Duration(seconds: 10), () { if (status == LineStatus.connecting) restart('still down after 10 s'); });
    } else if (state.state == TransportStateEnum.CONNECTED) {
      _recover?.cancel();
    }
  }

  /// A dial that gets no answer from the phone system (no ringing, no progress) within 15 s
  /// means the line is dead even though it looked ready: end it and reconnect.
  Timer? _dialWatch;
  void _watchDial(String id) {
    _dialWatch?.cancel();
    _dialWatch = Timer(const Duration(seconds: 15), () {
      final c = call;
      if (c != null && c.id == id && !incoming && callState == CallStateEnum.CALL_INITIATION) {
        Diag.log('call', 'no progress within 15 s: giving up and restarting the line');
        try { c.hangup({'status_code': 487}); } catch (_) {}
        _endCall();
        _set(LineStatus.connecting, 'Lost the connection. Reconnecting…');
        restart('dead dial');
      }
    });
  }

  @override
  void callStateChanged(Call c, CallState state) {
    final s = state.state;
    Diag.log('call', '${s.name} ${c.direction} ${c.remote_identity ?? ''}${state.cause != null ? ' cause=${state.cause!.cause} ${state.cause!.status_code ?? ''} ${state.cause!.reason_phrase ?? ''}' : ''}');
    if (s == CallStateEnum.CALL_INITIATION) {
      if (call != null && call!.id != c.id) {
        // Already on a call: decline the second one as busy.
        c.hangup({'status_code': 486});
        return;
      }
      call = c;
      callState = s;
      muted = false;
      held = false;
      connectedAt = null;
      notifyListeners();
      if (incoming) {
        _pendingCallId = null;
        pendingCaller = null;
        endedNote = null;
        if (autoAnswerPending) {
          autoAnswerPending = false;
          answer();
          onAutoAnswered?.call();
          return;
        }
        // Android's own incoming-call screen rings, vibrates and works on the lock screen.
        final name = RegExp(r'^[0-9+ ()\-]*$').hasMatch(remoteName) ? (Names.instance.lookup(remoteNumber) ?? remoteNumber) : remoteName;
        NativeCall.instance.showIncoming(id: c.id ?? DateTime.now().millisecondsSinceEpoch.toString(), name: name, number: remoteNumber);
        onIncoming?.call();
      } else {
        // Keep the microphone alive if the screen locks during the call (see NativeCall).
        NativeCall.instance.startOutgoing(id: c.id ?? DateTime.now().millisecondsSinceEpoch.toString(), name: Names.instance.lookup(remoteNumber) ?? '', number: remoteNumber);
      }
      return;
    }
    if (call == null || call!.id != c.id) return;
    if (s == CallStateEnum.PROGRESS || s == CallStateEnum.ACCEPTED || s == CallStateEnum.CONFIRMED) _dialWatch?.cancel();
    switch (s) {
      case CallStateEnum.MUTED:
        muted = true;
        break;
      case CallStateEnum.UNMUTED:
        muted = false;
        break;
      case CallStateEnum.HOLD:
        held = true;
        break;
      case CallStateEnum.UNHOLD:
        held = false;
        break;
      case CallStateEnum.CONFIRMED:
      case CallStateEnum.ACCEPTED:
        _stopRinging();
        NativeCall.instance.connected();
        if (connectedAt == null) {
          // Audio just started: force the route we show (earpiece unless Speaker is on).
          Future.delayed(const Duration(milliseconds: 600), () { if (call != null) applyAudioRoute(); });
        }
        connectedAt ??= DateTime.now();
        break;
      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        _endCall();
        return;
      default:
        break;
    }
    callState = s;
    if (s == CallStateEnum.CALL_INITIATION) _tellAndroidInCall(true);
    notifyListeners();
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}

  void _endCall() {
    _stopRinging();
    NativeCall.instance.end();
    _dialWatch?.cancel();
    // Always back to the earpiece, so the next call never starts on speaker.
    speaker = false;
    Helper.setSpeakerphoneOn(false);
    if (_reconnectAfterCall) {
      _reconnectAfterCall = false;
      Future.delayed(const Duration(seconds: 1), () => restart('network changed during the call'));
    }
    final c = call;
    if (c != null) {
      recents.insert(0, RecentCall(
        number: remoteNumber,
        name: remoteName,
        incoming: incoming,
        answered: connectedAt != null,
        at: DateTime.now(),
        seconds: connectedAt == null ? 0 : DateTime.now().difference(connectedAt!).inSeconds,
      ));
      if (recents.length > 50) recents.removeLast();
    }
    call = null;
    callState = null;
    _tellAndroidInCall(false);
    connectedAt = null;
    muted = false;
    held = false;
    speaker = false;
    notifyListeners();
  }

  void _set(LineStatus s, String text) {
    if (s != status || text != statusText) Diag.log('line', '${s.name}: $text');
    if (s == LineStatus.ready) _readyAt = DateTime.now();
    if (s == LineStatus.connecting && status == LineStatus.ready) {
      // Hold the "ready" look through the grace period; re-draw when it runs out if still reconnecting.
      _graceTimer?.cancel();
      _graceTimer = Timer(_grace + const Duration(seconds: 1), notifyListeners);
    }
    status = s;
    statusText = text;
    notifyListeners();
  }

  DateTime? _readyAt;
  Timer? _graceTimer;
  static const _grace = Duration(seconds: 90);

  /// What the screens show. A line that was registered and is re-registering (a network blip, a
  /// socket refresh mid-call) keeps reading "Ready" for [_grace]; only a longer outage, a failure
  /// or a deliberate disconnect shows as not ready. The real [status] still drives reconnects.
  LineStatus get shownStatus {
    if (status == LineStatus.connecting && _readyAt != null && DateTime.now().difference(_readyAt!) < _grace) return LineStatus.ready;
    return status;
  }

  String get shownStatusText => shownStatus == LineStatus.ready ? 'Ready · Ext $extension' : statusText;
}

class RecentCall {
  RecentCall({required this.number, required this.name, required this.incoming, required this.answered, required this.at, required this.seconds});

  final String number;
  final String name;
  final bool incoming;
  final bool answered;
  final DateTime at;
  final int seconds;
}
