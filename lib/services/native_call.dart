import '../brand.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'dial_plan.dart';
import 'diag.dart';
import 'phone.dart';
import 'push_service.dart';

/// Android's own incoming-call screen (Answer / Decline, shown over the lock screen) for calls
/// that arrive while the app is in the background, plus the small "ready for calls" service
/// that keeps the app's connection alive when it is not on screen.
class NativeCall {
  NativeCall._();
  static final NativeCall instance = NativeCall._();

  StreamSubscription<CallEvent?>? _events;
  String? _shownId;

  /// Called when the person taps Answer on the native screen.
  VoidCallback? onAccept;

  /// Called when the person taps Decline.
  VoidCallback? onDecline;

  Future<void> init() async {
    _events ??= FlutterCallkitIncoming.onEvent.listen((e) {
      if (e is! CallEventActionCallToggleHold) Diag.log('native', e.runtimeType.toString());
      switch (e) {
        case CallEventActionCallAccept():
          onAccept?.call();
        case CallEventActionCallDecline():
        case CallEventActionCallTimeout():
          onDecline?.call();
        case CallEventActionCallEnded():
          _shownId = null;
        case CallEventActionCallIncoming(:final callKitParams) when Platform.isIOS:
          // iPhone: the VoIP push put up the ringer natively; connect the line so the call lands.
          _shownId = callKitParams.id;
          Phone.instance.pushIncoming(callKitParams.id ?? '', callKitParams.nameCaller ?? '');
        case CallEventActionDidUpdateDevicePushTokenVoip() when Platform.isIOS:
          PushService.instance.registerToken();
        default:
          break;
      }
    });
    // Started because Answer was tapped on Android's call screen: that accept happened before
    // this engine existed, so read it back instead of waiting for an event that already fired.
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final c in calls) {
        final m = c is Map ? c : (c as dynamic).toJson();
        if (Platform.isIOS && m['isAccepted'] != true) {
          // iPhone woken by a VoIP push: the ringer is up but the line isn't connected yet.
          _shownId = m['id']?.toString();
          Phone.instance.pushIncoming((m['id'] ?? '').toString(), (m['nameCaller'] ?? '').toString());
          continue;
        }
        if (m['isAccepted'] == true) {
          Diag.log('native', 'call already accepted before start');
          final who = (m['nameCaller'] ?? '').toString();
          if (who.isNotEmpty) Phone.instance.pendingCaller = who;
          _shownId = m['id']?.toString();
          onAccept?.call();
          break;
        }
      }
    } catch (e) {
      Diag.log('native', 'activeCalls: $e');
    }
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({'rationaleMessagePermission': '${Brand.name} needs to show incoming calls.', 'postNotificationMessageRequired': 'Allow notifications so calls can ring.'});
      if (!await FlutterCallkitIncoming.canUseFullScreenIntent()) await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (e) {
      debugPrint('callkit permissions: $e');
    }
  }

  Future<void> showIncoming({required String id, required String name, required String number}) async {
    // The push already put up Android's ringer for this call (app was in the background and its
    // line registered before Answer was tapped): keep that one instead of ringing twice.
    try {
      for (final c in await FlutterCallkitIncoming.activeCalls()) {
        final m = c is Map ? c : (c as dynamic).toJson();
        if (m['isAccepted'] == true) continue;
        final cid = (m['id'] ?? '').toString();
        if (cid.isNotEmpty && cid != id) {
          Diag.log('native', 'call arrived while the push ringer is up: using it');
          _shownId = cid;
          return;
        }
      }
    } catch (_) {}
    _shownId = id;
    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: id,
      nameCaller: name.isEmpty ? prettyNumber(number) : name,
      appName: Brand.name,
      handle: name.isEmpty ? 'Incoming call' : prettyNumber(number),
      type: 0,
      duration: 45000,
      missedCallNotification: const NotificationParams(showNotification: true, isShowCallback: true, subtitle: 'Missed call', callbackText: 'Call back'),
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        isShowCallID: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: Brand.darkHex,
        actionColor: '#16A34A',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Incoming calls',
        missedCallNotificationChannelName: 'Missed calls',
        isShowFullLockedScreen: true,
        isImportant: true,
        textAccept: 'Answer',
        textDecline: 'Decline',
      ),
    ));
  }

  /// An outgoing call: register it with Android as an ongoing call. That runs the plugin's
  /// foreground service with microphone rights, so the mic keeps working once the screen locks
  /// (without it Android silences a background app's microphone and the far end hears nothing).
  Future<void> startOutgoing({required String id, required String name, required String number}) async {
    _shownId = id;
    try {
      await FlutterCallkitIncoming.startCall(CallKitParams(
        id: id,
        nameCaller: name.isEmpty ? prettyNumber(number) : name,
        appName: Brand.name,
        handle: name.isEmpty ? 'Outgoing call' : prettyNumber(number),
        type: 0,
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          isShowCallID: true,
          backgroundColor: Brand.darkHex,
          actionColor: '#16A34A',
          textColor: '#FFFFFF',
          incomingCallNotificationChannelName: 'Incoming calls',
          missedCallNotificationChannelName: 'Missed calls',
        ),
      ));
    } catch (e) {
      Diag.log('native', 'startCall: $e');
    }
  }

  /// Speaker on/off for the call Android knows about (a Telecom-registered call ignores the
  /// plain speakerphone switch, so the route has to go through the call itself).
  Future<void> setSpeaker(bool on) => setRoute(on ? 'speaker' : 'auto');

  /// speaker | bluetooth | wired | earpiece | auto (headset if connected, else earpiece).
  /// True when Android's call (Telecom) took it; false = no Telecom call, route via WebRTC.
  Future<bool> setRoute(String route) async {
    final id = _shownId;
    if (id == null) return false;
    try {
      final took = await FlutterCallkitIncoming.setAudioRoute(id, route);
      Diag.log('native', 'audio route $route telecom=$took');
      return took;
    } catch (e) {
      Diag.log('native', 'setAudioRoute: $e');
      return false;
    }
  }

  /// {current, available, bluetooth_name} for the Telecom call, or null.
  Future<Map<String, dynamic>?> routes() async {
    final id = _shownId;
    if (id == null) return null;
    try { return await FlutterCallkitIncoming.getAudioRoutes(id); } catch (_) { return null; }
  }

  /// Our own screen answered or the call ended: take the native screen down.
  Future<void> connected() async {
    final id = _shownId;
    if (id != null) {
      try { await FlutterCallkitIncoming.setCallConnected(id); } catch (_) {}
    }
  }

  Future<void> end() async {
    final id = _shownId;
    _shownId = null;
    try {
      if (id != null) {
        await FlutterCallkitIncoming.endCall(id);
        await FlutterCallkitIncoming.hideCallkitIncoming(CallKitParams(id: id));
      }
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  // --- keep the connection alive in the background --------------------------------------

  Future<void> keepAlive() async {
    try {
      final ok = await FlutterBackground.initialize(androidConfig: const FlutterBackgroundAndroidConfig(
        notificationTitle: Brand.name,
        notificationText: 'Ready for calls',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: 'ic_stat_wocom', defType: 'drawable'),
        enableWifiLock: true,
        showBadge: false,
      ));
      if (ok && !FlutterBackground.isBackgroundExecutionEnabled) await FlutterBackground.enableBackgroundExecution();
    } catch (e) {
      debugPrint('background service: $e');
    }
  }

  Future<void> release() async {
    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
  }
}
