package com.buildwithanshul.reeltunes

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Kotlin -> Dart command pipe for the media session.
 *
 * [PlaybackService] owns the MediaSessionCompat and the notification; Dart owns
 * the actual player. Every button press on the lock screen, in the shade, on a
 * headset or over Bluetooth lands here and is forwarded to the one
 * MethodChannel the Flutter side listens on.
 *
 * Invocation hops to the main looper because Flutter's channel must be used
 * from the platform thread, and media session callbacks arrive on a binder
 * thread.
 */
object PlaybackLink {
    const val CHANNEL = "com.buildwithanshul.reeltunes/playback"

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
    }

    fun detach() {
        channel = null
    }

    fun send(command: String) {
        invoke(command, null)
    }

    fun sendSeek(positionMs: Long) {
        invoke("seek", positionMs)
    }

    private fun invoke(method: String, argument: Any?) {
        main.post {
            try {
                channel?.invokeMethod(method, argument)
            } catch (_: Throwable) {
                // Engine gone: the notification is irrelevant anyway.
            }
        }
    }
}
