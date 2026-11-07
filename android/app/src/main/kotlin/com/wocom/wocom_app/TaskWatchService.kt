package com.wocom.wocom_app

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.Process

/**
 * When the person swipes WOCOM HUB away, Android removes the task but can leave the Flutter
 * engine alive for a while. A later tap or an Answer on the call screen would then start a
 * second engine beside it (one holding the line, one drawing the screen). Ending the process
 * here, when no call is up, makes every next start a single clean copy, woken by push.
 */
class TaskWatchService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (!AppState.inCall) {
            stopSelf()
            Process.killProcess(Process.myPid())
        }
    }
}
