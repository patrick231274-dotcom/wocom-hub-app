package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * WOCOM: call audio routing for calls that are NOT hosted in Android Telecom (no self-managed Connection).
 * Android 12+: AudioManager communication device (the supported way to reach Bluetooth SCO / LE headsets).
 * Older: MODE_IN_COMMUNICATION + Bluetooth SCO / speakerphone.
 * Routes: earpiece | speaker | wired | bluetooth | auto (Bluetooth, else wired, else earpiece).
 */
object CommAudio {
    private const val TAG = "CommAudio"

    private fun am(ctx: Context?): AudioManager? = ctx?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private fun kind(t: Int): String? = when (t) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && (t == AudioDeviceInfo.TYPE_BLE_HEADSET || t == AudioDeviceInfo.TYPE_BLE_SPEAKER)) "bluetooth" else null
    }

    private fun btOutput(a: AudioManager): AudioDeviceInfo? =
        a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }

    private fun hasWired(a: AudioManager): Boolean = a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET || it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
    }

    /** {current, available, bluetooth_name} like the Telecom version, or null when nothing can be read. */
    fun routes(ctx: Context?): Map<String, Any?>? {
        val a = am(ctx) ?: return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devs = a.availableCommunicationDevices
                val avail = devs.mapNotNull { kind(it.type) }.distinct()
                val cur = a.communicationDevice
                val bt = devs.firstOrNull { kind(it.type) == "bluetooth" }
                mapOf("current" to (cur?.let { kind(it.type) } ?: "earpiece"), "available" to avail,
                    "bluetooth_name" to bt?.productName?.toString())
            } else {
                val avail = mutableListOf("earpiece")
                if (hasWired(a)) avail.add("wired")
                val bt = btOutput(a)
                if (bt != null) avail.add("bluetooth")
                avail.add("speaker")
                @Suppress("DEPRECATION")
                val cur = when { a.isSpeakerphoneOn -> "speaker"; a.isBluetoothScoOn -> "bluetooth"; hasWired(a) -> "wired"; else -> "earpiece" }
                mapOf("current" to cur, "available" to avail, "bluetooth_name" to bt?.productName?.toString())
            }
        } catch (e: Exception) {
            Log.w(TAG, "routes: $e"); null
        }
    }

    /** True when the route was applied here. */
    fun setRoute(ctx: Context?, want: String): Boolean {
        val a = am(ctx) ?: return false
        return try {
            a.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devs = a.availableCommunicationDevices
                fun find(k: String) = devs.firstOrNull { kind(it.type) == k }
                val dev = when (want) {
                    "auto" -> find("bluetooth") ?: find("wired") ?: find("earpiece")
                    else -> find(want)
                }
                if (dev == null) { a.clearCommunicationDevice(); false } else a.setCommunicationDevice(dev)
            } else {
                @Suppress("DEPRECATION")
                run {
                    val route = if (want == "auto") (if (btOutput(a) != null) "bluetooth" else "earpiece") else want
                    if (route == "bluetooth") {
                        a.isSpeakerphoneOn = false
                        a.startBluetoothSco(); a.isBluetoothScoOn = true
                    } else {
                        if (a.isBluetoothScoOn) { a.isBluetoothScoOn = false; a.stopBluetoothSco() }
                        a.isSpeakerphoneOn = route == "speaker"
                    }
                }
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "setRoute($want): $e"); false
        }
    }

    /** Call over: give the audio back. */
    fun reset(ctx: Context?) {
        val a = am(ctx) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) a.clearCommunicationDevice()
            else @Suppress("DEPRECATION") { if (a.isBluetoothScoOn) { a.isBluetoothScoOn = false; a.stopBluetoothSco() } }
        } catch (_: Exception) {}
    }
}
