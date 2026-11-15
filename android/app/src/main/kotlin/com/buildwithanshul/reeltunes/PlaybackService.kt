package com.buildwithanshul.reeltunes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.LruCache
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * One MediaSessionCompat plus one MediaStyle notification: the shade player,
 * the lock-screen player, the Bluetooth/headset controls.
 *
 * Dart (lib/media_notification.dart) owns playback and pushes state here; this
 * service only renders that state and forwards button presses back through
 * [PlaybackLink]. It deliberately does not touch audio itself, so a service
 * hiccup can never stop the music.
 */
class PlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "com.buildwithanshul.reeltunes.playback"
        private const val CHANNEL_NAME = "ReelTunes playback"
        private const val CHANNEL_DESC =
            "Playback controls on the lock screen and in the notification shade"
        private const val NOTIFICATION_ID = 4711

        const val ACTION_UPDATE = "com.buildwithanshul.reeltunes.action.UPDATE"
        const val ACTION_CLEAR = "com.buildwithanshul.reeltunes.action.CLEAR"
        const val ACTION_PLAY = "com.buildwithanshul.reeltunes.action.PLAY"
        const val ACTION_PAUSE = "com.buildwithanshul.reeltunes.action.PAUSE"
        const val ACTION_NEXT = "com.buildwithanshul.reeltunes.action.NEXT"
        const val ACTION_PREVIOUS = "com.buildwithanshul.reeltunes.action.PREVIOUS"
        const val ACTION_STOP = "com.buildwithanshul.reeltunes.action.STOP"

        /** Pushes a state snapshot. Starts the service if needed. */
        fun push(context: Context, state: Bundle) {
            val intent = Intent(context, PlaybackService::class.java)
                .setAction(ACTION_UPDATE)
                .putExtras(state)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (_: Throwable) {
                // Android 12+ rejects a foreground start from the background.
                // Playback carries on; the next in-app change retries.
            }
        }

        fun clear(context: Context) {
            try {
                context.startService(
                    Intent(context, PlaybackService::class.java)
                        .setAction(ACTION_CLEAR)
                )
            } catch (_: Throwable) {
                // Service already gone.
            }
        }
    }

    private lateinit var session: MediaSessionCompat
    private val artCache = LruCache<String, Bitmap>(8)

    private var title: String = ""
    private var artist: String = ""
    private var album: String = ""
    private var cover: Int = 0
    private var playing: Boolean = false
    private var position: Long = 0
    private var duration: Long = 0
    private var hasNext: Boolean = true
    private var hasPrevious: Boolean = true

    override fun onCreate() {
        super.onCreate()
        createChannel()
        session = MediaSessionCompat(this, "ReelTunes").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = PlaybackLink.send("play")
                override fun onPause() = PlaybackLink.send("pause")
                override fun onSkipToNext() = PlaybackLink.send("next")
                override fun onSkipToPrevious() = PlaybackLink.send("previous")
                override fun onStop() = PlaybackLink.send("stop")
                override fun onSeekTo(pos: Long) = PlaybackLink.sendSeek(pos)
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CLEAR -> {
                shutdown()
                return START_NOT_STICKY
            }
            ACTION_PLAY -> {
                PlaybackLink.send("play")
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                PlaybackLink.send("pause")
                return START_NOT_STICKY
            }
            ACTION_NEXT -> {
                PlaybackLink.send("next")
                return START_NOT_STICKY
            }
            ACTION_PREVIOUS -> {
                PlaybackLink.send("previous")
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                PlaybackLink.send("stop")
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                readState(intent.extras)
                // Nothing to show means the track list was emptied; a blank
                // MediaStyle card would just stick around forever.
                if (title.isEmpty()) {
                    shutdown()
                    return START_NOT_STICKY
                }
                render()
            }
            else -> {
                // Restarted by the system with nothing to show: go away.
                if (title.isEmpty()) {
                    shutdown()
                    return START_NOT_STICKY
                }
                render()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try {
            session.isActive = false
            session.release()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    private fun readState(bundle: Bundle?) {        val b = bundle ?: return
        title = b.getString("title") ?: ""
        artist = b.getString("artist") ?: ""
        album = b.getString("album") ?: ""
        cover = b.getInt("cover", 0)
        playing = b.getBoolean("playing", false)
        position = b.getLong("position", 0)
        duration = b.getLong("duration", 0)
        hasNext = b.getBoolean("hasNext", true)
        hasPrevious = b.getBoolean("hasPrevious", true)
    }

    private fun render() {
        val state = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_PLAY_PAUSE or
                    PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackStateCompat.ACTION_SEEK_TO or
                    PlaybackStateCompat.ACTION_STOP
            )
            .setState(
                if (playing) PlaybackStateCompat.STATE_PLAYING
                else PlaybackStateCompat.STATE_PAUSED,
                position,
                if (playing) 1f else 0f
            )
            .build()
        session.setPlaybackState(state)

        val art = artwork(cover)
        val meta = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
        if (art != null) {
            meta.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, art)
            meta.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, art)
        }
        session.setMetadata(meta.build())

        val notification = buildNotification(art)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(art: Bitmap?): Notification {
        val toggle = if (playing) {
            NotificationCompat.Action(
                R.drawable.ic_pause,
                "Pause",
                actionIntent(ACTION_PAUSE, 2)
            )
        } else {
            NotificationCompat.Action(
                R.drawable.ic_play,
                "Play",
                actionIntent(ACTION_PLAY, 3)
            )
        }
        val previous = NotificationCompat.Action(
            R.drawable.ic_skip_previous,
            "Previous",
            actionIntent(ACTION_PREVIOUS, 1)
        )
        val next = NotificationCompat.Action(
            R.drawable.ic_skip_next,
            "Next",
            actionIntent(ACTION_NEXT, 4)
        )
        val close = NotificationCompat.Action(
            R.drawable.ic_close,
            "Stop",
            actionIntent(ACTION_STOP, 5)
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(title)
            .setContentText(artist)
            .setSubText("ReelTunes")
            .setLargeIcon(art)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(openAppIntent())
            .setDeleteIntent(actionIntent(ACTION_STOP, 6))
            .setOngoing(playing)
            .addAction(previous)
            .addAction(toggle)
            .addAction(next)
            .addAction(close)

        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(session.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)
        builder.setStyle(style)
        return builder.build()
    }

    private fun actionIntent(action: String, code: Int): PendingIntent {
        val intent = Intent(this, PlaybackService::class.java).setAction(action)
        return PendingIntent.getService(this, code, intent, flags())
    }

    private fun openAppIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(this, 0, intent, flags())
    }

    private fun flags(): Int =
        if (Build.VERSION.SDK_INT >= 23) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    /** Decodes the same abstract cover the in-app lists use. */
    private fun artwork(index: Int): Bitmap? {
        val key = "cover_%02d".format(index)
        artCache.get(key)?.let { return it }
        return try {
            assets.open("flutter_assets/assets/covers/$key.webp").use {
                BitmapFactory.decodeStream(it)
            }?.also { artCache.put(key, it) }
        } catch (_: Throwable) {
            null
        }
    }

    private fun shutdown() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
        }
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(NOTIFICATION_ID)
        } catch (_: Throwable) {
        }
        try {
            session.isActive = false
        } catch (_: Throwable) {
        }
        title = ""
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = CHANNEL_DESC
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }
}
