import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';

import 'screens/call_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/employee_home.dart';
import 'services/techhub.dart';
import 'services/text_zoom.dart';
import 'screens/welcome_screen.dart';
import 'services/api.dart';
import 'services/diag.dart';
import 'services/hub.dart';
import 'services/native_call.dart';
import 'services/push_service.dart';
import 'services/phone.dart';
import 'services/session.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diag.instance.init();
  Diag.captureErrors();
  Diag.log('app', 'process start');
  try {
    final pkg = await PackageInfo.fromPlatform();
    PushApi.appVersion = '${pkg.version}+${pkg.buildNumber}';
  } catch (_) {}
  // No orientation lock: on large and folding screens Android boxes locked apps in and leaves
  // the rest of the screen black. Edge-to-edge so the header runs under the status bar.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light));
  Session.instance.load();
  if (Brand.isEmployee) { TechHub.instance.load(); await TextZoom.instance.load(); }
  Hub.instance.messenger = messengerKey;
  // Incoming calls are shown by Android's own call screen (NativeCall); our screen opens on Answer.
  Phone.instance.onIncoming = () {};
  NativeCall.instance.onAccept = () {
    if (Phone.instance.call != null) {
      Phone.instance.answer();
    } else {
      // Woken by push: the server rings us once it sees a fresh registration. Send one and
      // answer the moment the call lands.
      Phone.instance.autoAnswerPending = true;
      Phone.instance.refreshRegistration();
    }
  };
  Phone.instance.onAutoAnswered = () {};
  // Whenever a live call exists and the call window isn't showing, show it — however the call
  // was answered (our screen, Android's call screen, or a push wake-up).
  Phone.instance.addListener(() {
    final p = Phone.instance;
    final c = p.call;
    if (CallScreen.open) return;
    if (c == null && !p.autoAnswerPending) return;
    if (c != null && p.incoming && !p.connected) return; // still ringing: Android's call screen is showing
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    CallScreen.open = true;
    nav.push(MaterialPageRoute(builder: (_) => const CallScreen(), fullscreenDialog: true));
  });
  // Call pushes are handled in a background isolate while the app is not in front; it forwards
  // them here so the live line registers at once instead of waiting for Answer.
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(kMainPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, kMainPortName);
  port.listen((msg) {
    if (msg is! List || msg.length < 2) return;
    if (msg[0] == 'incoming_call') Phone.instance.pushIncoming(msg[1].toString(), msg.length > 2 ? msg[2].toString() : '');
    if (msg[0] == 'call_cancel') Phone.instance.pushCancelled(msg[1].toString());
  });
  PushService.instance.init();
  NativeCall.instance.onDecline = () => Phone.instance.hangup();
  NativeCall.instance.init();
  runApp(const WocomApp());
}

class WocomApp extends StatelessWidget {
  const WocomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Brand.name,
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      // The approved design is light-only; the phone's dark mode must not restyle it.
      theme: wocomTheme(Brightness.light),
      darkTheme: wocomTheme(Brightness.light),
      themeMode: ThemeMode.light,
      // WE App: two-finger pinch anywhere resizes the text (remembered per phone).
      builder: Brand.isEmployee ? (context, child) => PinchTextZoom(child: child ?? const SizedBox()) : null,
      // WOCOM Employee App: Tech Hub first. Calls on the workspace PBX join as extra tabs once
      // that PBX is connected through the push server.
      home: Brand.isEmployee ? const EmployeeRoot() : AnimatedBuilder(
        animation: Session.instance,
        builder: (context, _) {
          final s = Session.instance;
          if (!s.ready) return const _Splash();
          if (s.signedIn) return const HomeScreen();
          return s.welcomed ? const SignInScreen() : WelcomeScreen(onContinue: () => s.markWelcomed());
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const WocomLogo(height: 52),
            const SizedBox(height: 20),
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Theme.of(context).colorScheme.primary)),
          ]),
        ),
      );
}
