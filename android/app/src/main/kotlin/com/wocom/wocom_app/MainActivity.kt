package com.wocom.wocom_app

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Watches for the app being swiped away (see TaskWatchService).
        try { startService(Intent(this, TaskWatchService::class.java)) } catch (_: Exception) {}
    }

    private fun declares(perm: String): Boolean = try {
        @Suppress("DEPRECATION")
        packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.GET_PERMISSIONS).requestedPermissions?.contains(perm) == true
    } catch (_: Exception) { false }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wocom/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "inCall" -> { AppState.inCall = call.arguments as? Boolean ?: false; result.success(null) }
                "health" -> result.success(health())
                "requestBatteryUnrestricted" -> result.success(
                    (declares("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS")
                        && open(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))))
                        || open(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
                "openNotificationSettings" -> result.success(
                    open(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)))
                "openFullScreenSettings" -> result.success(
                    Build.VERSION.SDK_INT >= 34 && open(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))))
                "openAutoStart" -> result.success(openAutoStart())
                "openAppInfo" -> result.success(open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))))
                "installApk" -> result.success(installApk(call.arguments as? String ?: ""))
                else -> result.notImplemented()
            }
        }
    }

    /** What can stop a push from waking this phone for a call. */
    private fun health(): Map<String, Any?> {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        return mapOf(
            "battery_unrestricted" to pm.isIgnoringBatteryOptimizations(packageName),
            "power_save" to pm.isPowerSaveMode,
            "notifications" to nm.areNotificationsEnabled(),
            "full_screen" to (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()),
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "autostart_hint" to autoStartTargets().isNotEmpty(),
        )
    }

    private fun open(i: Intent): Boolean = try {
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i); true
    } catch (_: Exception) { false }

    /** Makers whose own "auto-start" / background manager also has to allow the app. */
    private fun autoStartTargets(): List<ComponentName> {
        val m = Build.MANUFACTURER.lowercase()
        val b = Build.BRAND.lowercase()
        fun c(p: String, a: String) = ComponentName(p, a)
        return when {
            m.contains("xiaomi") || b.contains("redmi") || b.contains("poco") -> listOf(
                c("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"))
            m.contains("huawei") || m.contains("honor") -> listOf(
                c("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                c("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"),
                c("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
            m.contains("oppo") || m.contains("realme") || b.contains("realme") || m.contains("oneplus") -> listOf(
                c("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                c("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                c("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
                c("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"))
            m.contains("vivo") || b.contains("iqoo") -> listOf(
                c("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                c("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"))
            m.contains("samsung") -> listOf(
                c("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
                c("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
            m.contains("asus") -> listOf(
                c("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"),
                c("com.asus.mobilemanager", "com.asus.mobilemanager.powersaver.PowerSaverSettings"))
            m.contains("tecno") || m.contains("infinix") || m.contains("itel") -> listOf(
                c("com.transsion.phonemanager", "com.itel.autobootmanager.activity.AutoBootMgrActivity"))
            m.contains("letv") -> listOf(c("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"))
            m.contains("hmd") || m.contains("nokia") -> listOf(
                c("com.evenwell.powersaving.g3", "com.evenwell.powersaving.g3.exception.PowerSaverExceptionActivity"))
            else -> emptyList()
        }
    }

    /** Hand a downloaded APK to Android's installer. "ok" | "needs_permission" | "failed". */
    private fun installApk(path: String): String {
        val f = File(path)
        if (!f.exists()) return "failed"
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            open(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "needs_permission"
        }
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.wocomfiles", f)
            val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i); "ok"
        } catch (_: Exception) { "failed" }
    }

    private fun openAutoStart(): Boolean {
        for (t in autoStartTargets()) {
            if (open(Intent().setComponent(t))) return true
        }
        return false
    }
}
