package com.wocom.wocom_app

/** Shared with the task watcher: never end the process while a call is up. */
object AppState {
    @Volatile var inCall: Boolean = false
}
