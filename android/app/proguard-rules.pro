# R8 keep rules for release builds (Play flagged low DEX obfuscation, Nov 2026).
# Plugins that ship consumer rules (flutter_webrtc, flutter_callkit_incoming, mobile_scanner, file_picker,
# jni) bring their own; the rules below cover the ones that don't.

# Flutter engine + deferred-components references to Play Core, which we don't ship.
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.google.android.play.core.**

# Our own Android code (MainActivity, services, receivers named in the manifest / called over channels).
-keep class com.wocom.** { *; }

# flutter_local_notifications stores scheduled notifications with Gson (reflection).
-keep class com.dexterous.** { *; }
-keepattributes Signature, *Annotation*, InnerClasses, EnclosingMethod
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# WebRTC JNI (also in the plugin's rules; kept here in case the plugin's rules change).
-keep class org.webrtc.** { *; }

# Firebase Messaging background service + plugin entry points.
-keep class io.flutter.plugins.firebase.** { *; }

# Plugins without consumer rules that are reached from native code or by name.
-keep class com.ryanheise.** { *; }
-keep class com.baseflow.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.llfbandit.record.** { *; }
-keep class co.quis.flutter_contacts.** { *; }
-keep class de.julianassmann.flutter_background.** { *; }
-keep class com.crazecoder.openfile.** { *; }
-keep class dev.fluttercommunity.plus.** { *; }
-keep class io.inway.ringtone.** { *; }
