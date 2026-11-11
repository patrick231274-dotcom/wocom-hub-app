import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import '../brand.dart';
import '../theme.dart';
import '../services/call_context.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../screens/home_screen.dart';
import 'api.dart';
import 'app_update.dart';
import 'device_health.dart';
import 'dial_plan.dart';
import 'diag.dart';
import '../widgets/diag_consent.dart';
import 'hub.dart';
import 'native_call.dart';
import 'phone.dart';
import 'session.dart';
import 'techhub.dart';

/// Push notifications through Firebase: wake-ups for incoming calls (shown as Android's own
/// call screen even when the app is closed) and notifications for chat and missed calls.
/// Name of the main app's port (see main.dart): background pushes reach the live app through it.
const kMainPortName = 'wocom_main';

/// Hand a call push to the running app, if it is running. True when it was delivered.
bool forwardToApp(String kind, String callId, [String caller = '']) {
  final port = IsolateNameServer.lookupPortByName(kMainPortName);
  if (port == null) return false;
  port.send([kind, callId, caller]);
  return true;
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final _local = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Notification tapped: idle-ticket warnings open the "update the client" dialog.
  static void _onTap(String? payload) {
    if (payload != null && payload.startsWith('idle:')) TechHub.instance.idleEvent.value = '${payload.substring(5)}|${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> init() async {
    if (_ready) return;
    try {
      // iPhone: Firebase config passed here instead of a bundled GoogleService-Info.plist
      // (project wocom-hub, iOS app com.wocom.app). Android reads google-services.json.
      if (Platform.isIOS && Brand.firebaseIosAppId.isEmpty) {
        throw StateError('no Firebase iOS app registered for ' + Brand.iosBundleId);
      } else if (Platform.isIOS) {
        await Firebase.initializeApp(options: FirebaseOptions(
          apiKey: 'AIzaSyDLXVPgpgWV8HIRZkju2LGQKcrXxqiF9G4',
          appId: Brand.firebaseIosAppId,
          messagingSenderId: '935090189192',
          projectId: 'wocom-hub',
          storageBucket: 'wocom-hub.firebasestorage.app',
          iosBundleId: Brand.iosBundleId,
        ));
      } else {
        await Firebase.initializeApp();
      }
      FirebaseMessaging.onBackgroundMessage(wocomBackgroundMessage);
      await _local.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_wocom'), iOS: DarwinInitializationSettings()),
        onDidReceiveNotificationResponse: (r) => _onTap(r.payload),
      );
      try {
        final launch = await _local.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true) _onTap(launch!.notificationResponse?.payload);
      } catch (_) {}
      await _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(
            const AndroidNotificationChannel('wocom_messages', 'Messages', description: 'Chat messages, missed calls and voicemail', importance: Importance.high),
          );
      await FirebaseMessaging.instance.requestPermission();
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.instance.onTokenRefresh.listen((t) { _register(t); TechHub.instance.registerPushToken(t); });
      _ready = true;
      // Employee App: Tech Hub sends its own ticket alerts, so it needs this phone's token too.
      if (Brand.isEmployee) {
        final t = await FirebaseMessaging.instance.getToken();
        if (t != null) TechHub.instance.registerPushToken(t);
      }
    } catch (e) {
      debugPrint('push init: $e');
    }
  }

  /// Send this phone's token to WOCOM (after sign-in and whenever it changes).
  Future<void> registerToken() async {
    String? t;
    try {
      t = await FirebaseMessaging.instance.getToken();
    } catch (e) {
      Diag.log('push', 'no Firebase token: $e');
    }
    await _register(t);
  }

  /// Firebase token (chat/alerts) and, on iPhone, the PushKit VoIP token (calls) are sent
  /// independently: either one alone is still worth registering.
  Future<void> _register(String? token) async {
    if (!Session.instance.signedIn) return;
    final body = <String, dynamic>{};
    if (token != null && token.isNotEmpty) body['fcm_token'] = token;
    if (Platform.isIOS) {
      try {
        final voip = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
        if (voip != null && voip.toString().isNotEmpty) body['apns_voip_token'] = voip.toString();
      } catch (e) {
        Diag.log('push', 'no VoIP token: $e');
      }
    }
    if (body.isEmpty) { Diag.log('push', 'no push token to register yet'); return; }
    Diag.log('push', 'registering ${body.keys.join('+')}');
    try {
      await Session.instance.api.post('device/push-tokens', body);
    } on ApiException catch (e) {
      debugPrint('push token register: ${e.message}');
    }
  }

  /// A push arriving while the app is open. Calls are already handled by the live line; chat
  /// gets a notification only if the app is not showing that conversation (kept simple: always).
  Future<void> _onForeground(RemoteMessage m) async {
    if (m.data['type'] == 'call_context') { await CallContext.save(Map<String, dynamic>.from(m.data)); await refreshRingerWithContext(Map<String, dynamic>.from(m.data)); return; }
    if (m.data['type'] == 'call_summary') CallContext.instance.setSummary(Map<String, dynamic>.from(m.data));
    final type = m.data['type'];
    Diag.log('push', 'foreground message type=$type');
    if (type == 'incoming_call') {
      // The server is waiting for a fresh registration before it rings us: send one now.
      Phone.instance.pushIncoming((m.data['call_uuid'] ?? '').toString(), (m.data['caller_name'] ?? '').toString().isNotEmpty ? m.data['caller_name'].toString() : prettyNumber((m.data['caller_number'] ?? '').toString()));
      return;
    }
    if (type == 'call_cancel') {
      // The call went away before it reached us: stop the ringing screen.
      Diag.log('push', 'call cancelled by the server');
      if (Phone.instance.call == null) {
        Phone.instance.pushCancelled((m.data['call_uuid'] ?? '').toString());
        Phone.instance.autoAnswerPending = false;
        await NativeCall.instance.end();
      }
      return;
    }
    if (type == 'update') {
      // A new version shipped: offer it now rather than at the next check.
      final ctx = HomeScreen.scaffoldKey.currentContext;
      if (ctx != null && Phone.instance.call == null) await AppUpdate.instance.check(ctx, force: true);
      return;
    }
    if (type == 'wake_test') {
      // Silent self-test: answer it so WOCOM knows this phone can be woken.
      await DeviceHealth.ack((m.data['nonce'] ?? '').toString(), 'open');
      return;
    }
    if (type == 'diag') {
      // WOCOM support asked for this phone's log: send only if the user agrees.
      Diag.log('diag', 'upload requested by WOCOM: asking the user');
      await DiagConsent.mark();
      final ctx = HomeScreen.scaffoldKey.currentContext;
      if (ctx != null && ctx.mounted && Phone.instance.call == null) await DiagConsent.askIfRequested(ctx);
      return;
    }
    if (type == 'token_revoked') { await TechHub.instance.revoked(); return; }
    await showMessageNotification(_local, m);
    if (TechHub.pushTypes.contains(type)) TechHub.instance.changes.value++;
    if ((type == 'chat' && m.data.containsKey('from_name')) || type == 'chat_unclaimed') { TechHub.instance.chatEvent.value = '${m.data['conversation_id']}@${DateTime.now().millisecondsSinceEpoch}'; TechHub.instance.conversations().catchError((_) => <Map<String, dynamic>>[]); }
    if (type == 'chat') Hub.instance.refreshChats();
    if (type == 'door_request' || type == 'door_decision') TechHub.instance.doorEvent.value++;
    if (type == 'ticket_idle' && (m.data['ticket_number'] ?? '').toString().isNotEmpty) TechHub.instance.idleEvent.value = '${m.data['ticket_number']}|${m.data['close_at'] ?? ''}|${DateTime.now().millisecondsSinceEpoch}';
    if (type == 'leave_request' || type == 'leave_decided') TechHub.instance.leaveEvent.value = '$type@${DateTime.now().millisecondsSinceEpoch}';
    if (type == 'announcement') { TechHub.instance.announcementsEvent.value++; TechHub.instance.refreshMe().catchError((_) {}); }
    if (type == 'task') Hub.instance.tasksEvent.value++;
  }
}

/// Chat, missed-call and voicemail alerts are data pushes the app draws itself, so they look the
/// same whether the app is open, asleep or closed: WOCOM icon and colour, sender as title, text.
Future<void> showMessageNotification(FlutterLocalNotificationsPlugin local, RemoteMessage m) async {
  if (m.data['type'] == 'token_revoked') return;
  final th = TechHub.alertText(m.data);
  final title = th?.$1 ?? (m.data['title'] ?? m.notification?.title ?? '').toString();
  final body = th?.$2 ?? (m.data['body'] ?? m.notification?.body ?? '').toString();
  if (title.isEmpty && body.isEmpty) return;
  final conv = (m.data['conversation_id'] ?? m.data['ticket_number'] ?? '').toString();
  final payload = m.data['type'] == 'ticket_idle' ? 'idle:${m.data['ticket_number'] ?? ''}|${m.data['close_at'] ?? ''}' : conv;
  await local.show(
    id: conv.isEmpty ? m.hashCode & 0x7fffffff : conv.hashCode & 0x7fffffff, // one notification per conversation
    title: title.isEmpty ? Brand.name : title,
    body: body,
    payload: payload,
    notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails(), android: AndroidNotificationDetails(
      'wocom_messages', 'Messages', channelDescription: 'Chat messages, missed calls and voicemail',
      importance: Importance.high, priority: Priority.high, color: wocomDeep, icon: 'ic_stat_wocom',
      category: AndroidNotificationCategory.message, styleInformation: BigTextStyleInformation(''),
    )),
  );
}

/// Runs in the background (app closed or asleep): a call wake-up shows Android's call screen at
/// once; the app then connects its line so the call lands when Answer is tapped.
@pragma('vm:entry-point')
Future<void> wocomBackgroundMessage(RemoteMessage m) async {
  try { await Diag.instance.init(tag: 'push'); } catch (_) {}
  Diag.log('push', 'background message type=${m.data['type']} from ${m.data['caller_number'] ?? ''}');
  if (m.data['type'] == 'call_context') {
    await CallContext.save(Map<String, dynamic>.from(m.data));
    await refreshRingerWithContext(Map<String, dynamic>.from(m.data));
    // (0.28.1) No separate notification: it competed with the full-screen ringer. The ringer itself now carries the details.
    return;
  }
  if (m.data['type'] == 'call_cancel') {
    Diag.log('push', 'call cancelled by the server (app asleep)');
    if (forwardToApp('call_cancel', (m.data['call_uuid'] ?? '').toString())) Diag.log('push', 'cancel passed to the running app');
    try {
      // Only take down THIS call's ringing screen, and only while it is still ringing: a cancel can
      // also arrive after the call was answered (the PBX sends one when a call ends), and a queue
      // cancel must never end a different call the person is on with the screen locked.
      final id = (m.data['call_uuid'] ?? '').toString();
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final c in calls) {
        final mm = c is Map ? c : (c as dynamic).toJson();
        final cid = (mm['id'] ?? '').toString();
        if (mm['isAccepted'] == true) continue;
        if (id.isEmpty || cid == id || calls.length == 1) {
          await FlutterCallkitIncoming.endCall(cid);
          await FlutterCallkitIncoming.hideCallkitIncoming(CallKitParams(id: cid));
        }
      }
    } catch (e) {
      Diag.log('push', 'cancel failed: $e');
    }
    await Diag.instance.flush();
    return;
  }
  if (m.data['type'] == 'update') {
    // A version shipped while the app was asleep: say so, and offer it the moment the app opens.
    await AppUpdate.markPending();
    try {
      final local = FlutterLocalNotificationsPlugin();
      await local.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_wocom'), iOS: DarwinInitializationSettings()));
      final v = (m.data['version'] ?? '').toString();
      await local.show(
        id: 7001,
        title: 'Update available',
        body: '${Brand.name}${v.isEmpty ? '' : ' v$v'} is ready. Tap to update.',
        notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails(), android: AndroidNotificationDetails('wocom_messages', 'Messages', importance: Importance.high, priority: Priority.high, color: wocomDeep)),
      );
      Diag.log('update', 'shipped notice shown (v$v)');
    } catch (e) {
      Diag.log('update', 'notice failed: $e');
    }
    await Diag.instance.flush();
    return;
  }
  if (m.data['type'] == 'wake_test') {
    // The silent self-test reached a sleeping app: that is exactly what an incoming call needs.
    await DeviceHealth.ack((m.data['nonce'] ?? '').toString(), 'asleep');
    await Diag.instance.flush();
    return;
  }
  if (m.data['type'] == 'diag') {
    try {
      // Asleep: never upload silently. Remember it; the user is asked next time the app opens.
      Diag.log('diag', 'upload requested by WOCOM (app asleep): will ask the user');
      await DiagConsent.mark();
    } catch (e) {
      Diag.log('diag', 'upload failed: $e');
    }
    await Diag.instance.flush();
    return;
  }
  if (m.data['type'] != 'incoming_call') {
    // Chat, missed call, voicemail: draw the alert ourselves (same look as when the app is open).
    try {
      final local = FlutterLocalNotificationsPlugin();
      await local.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_wocom'), iOS: DarwinInitializationSettings()));
      await showMessageNotification(local, m);
      Diag.log('push', 'alert shown: ${m.data['type']}');
    } catch (e) {
      Diag.log('push', 'alert failed: $e');
    }
    await Diag.instance.flush();
    return;
  }
  final name = (m.data['caller_name'] ?? '').toString();
  final number = (m.data['caller_number'] ?? '').toString();
  final id = (m.data['call_uuid'] ?? '').toString().isNotEmpty ? m.data['call_uuid'].toString() : DateTime.now().millisecondsSinceEpoch.toString();
  // App still running in the background: register its line now, while the call is still ringing.
  Diag.log('push', forwardToApp('incoming_call', id, name.isNotEmpty ? name : prettyNumber(number)) ? 'passed to the running app: registering now' : 'app not running: line connects when Answer is tapped');
  // WE App: if Tech Hub's "who's calling" already arrived, put it straight into the ringer.
  final ctx = Brand.isEmployee ? await CallContext.stored(number) : null;
  final (ringName, ringHandle) = ctx != null ? CallContext.ringerText(ctx, number) : (name.isEmpty ? prettyNumber(number) : name, name.isEmpty ? 'Incoming call' : prettyNumber(number));
  await showRinger(id, ringName, ringHandle);
  Diag.log('push', 'native call screen shown');
  await Diag.instance.flush();
}


/// The native full-screen ringer (lock screen). Re-showing it with the same id replaces the text.
Future<void> showRinger(String id, String nameCaller, String handle) => FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
    id: id,
    nameCaller: nameCaller,
    appName: Brand.name,
    handle: handle,
    type: 0,
    duration: 45000,
    extra: {'from_push': true},
    missedCallNotification: const NotificationParams(showNotification: true, isShowCallback: true, subtitle: 'Missed call', callbackText: 'Call back'),
    ios: NativeCall.iosAudio,
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

/// Tech Hub's caller details arrived while the native ringer is up: redraw it with them.
Future<void> refreshRingerWithContext(Map<String, dynamic> ctx) async {
  try {
    final calls = await FlutterCallkitIncoming.activeCalls();
    for (final c in calls) {
      final mm = c is Map ? c : (c as dynamic).toJson();
      if (mm['isAccepted'] == true) continue;
      final id = (mm['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final num = (mm['handle'] ?? '').toString();
      final (n, h) = CallContext.ringerText(ctx, num);
      await FlutterCallkitIncoming.hideCallkitIncoming(CallKitParams(id: id));
      await showRinger(id, n, h);
      Diag.log('push', 'ringer updated with caller details');
      break;
    }
  } catch (e) {
    Diag.log('push', 'ringer update failed: $e');
  }
}
