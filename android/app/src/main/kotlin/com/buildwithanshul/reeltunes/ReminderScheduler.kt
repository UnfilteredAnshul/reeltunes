package com.buildwithanshul.reeltunes

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

/**
 * Local subscription reminders.
 *
 * Three alarms per subscription: 3 days before the period ends, 1 day before,
 * and at the exact end / renewal minute. Nothing leaves the device; this only
 * needs AlarmManager + a notification. Exact alarms need the user's permission
 * on Android 12+; without it the alarms still fire, just not to the minute.
 *
 * The schedule is mirrored into SharedPreferences so a reboot or an app update
 * can restore it (alarms themselves do not survive a reboot).
 */
object ReminderScheduler {
    const val CHANNEL_ID = "reeltunes_reminders"
    const val EXTRA_ID = "reminder_id"
    const val EXTRA_TITLE = "reminder_title"
    const val EXTRA_BODY = "reminder_body"
    const val EXTRA_VIBRATE = "reminder_vibrate"

    private const val PREFS = "reeltunes_scheduled_reminders"
    private const val KEY = "items"

    data class Reminder(
        val id: Int,
        val atMs: Long,
        val title: String,
        val body: String,
        val vibrate: Boolean,
    )

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Subscription reminders",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description =
                "Reminders before ReelTunes Pro ends or renews. Created on this device only."
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        val manager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return manager.canScheduleExactAlarms()
    }

    fun requestExactPermission(context: Context) {
        if (Build.VERSION.SDK_INT < 31) return
        try {
            val intent = Intent(
                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:${context.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Exception) {
            // Some OEMs hide this screen; the inexact fallback still works.
        }
    }

    fun replace(context: Context, reminders: List<Reminder>) {
        cancelAll(context)
        val future = reminders.filter { it.atMs > System.currentTimeMillis() }
        save(context, future)
        future.forEach { schedule(context, it) }
    }

    fun cancelAll(context: Context) {
        val manager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        load(context).forEach { reminder ->
            try {
                manager.cancel(pendingIntent(context, reminder.id))
            } catch (_: Exception) {
            }
        }
        save(context, emptyList())
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        REMINDER_IDS.forEach { nm.cancel(it) }
    }

    fun rescheduleSaved(context: Context) {
        val now = System.currentTimeMillis()
        val future = load(context).filter { it.atMs > now }
        save(context, future)
        future.forEach { schedule(context, it) }
    }

    fun removeSaved(context: Context, id: Int) {
        save(context, load(context).filter { it.id != id })
    }

    fun postNow(context: Context, id: Int, title: String, body: String, vibrate: Boolean) {
        ensureChannel(context)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val content = launch?.let {
            PendingIntent.getActivity(
                context,
                id + 90000,
                it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_reminder)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
        if (vibrate) {
            @Suppress("DEPRECATION")
            builder.setDefaults(Notification.DEFAULT_VIBRATE)
        }
        if (content != null) builder.setContentIntent(content)
        manager.notify(id, builder.build())
    }

    private fun schedule(context: Context, reminder: Reminder) {
        if (reminder.atMs <= System.currentTimeMillis()) return
        ensureChannel(context)
        val manager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pendingIntent(context, reminder.id)
        val exact = Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()
        try {
            if (exact) {
                manager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    reminder.atMs,
                    pending
                )
            } else {
                manager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    reminder.atMs,
                    pending
                )
            }
        } catch (_: SecurityException) {
            manager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                reminder.atMs,
                pending
            )
        }
    }

    private fun pendingIntent(context: Context, id: Int): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            putExtra(EXTRA_ID, id)
        }
        // The receiver reads the persisted copy by id, so the pending intent
        // stays small and survives an app update.
        return PendingIntent.getBroadcast(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun save(context: Context, reminders: List<Reminder>) {
        val array = JSONArray()
        reminders.forEach { r ->
            array.put(JSONObject().apply {
                put("id", r.id)
                put("atMs", r.atMs)
                put("title", r.title)
                put("body", r.body)
                put("vibrate", r.vibrate)
            })
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, array.toString())
            .apply()
    }

    private fun load(context: Context): List<Reminder> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { i ->
                val o = array.optJSONObject(i) ?: return@mapNotNull null
                Reminder(
                    id = o.optInt("id"),
                    atMs = o.optLong("atMs"),
                    title = o.optString("title"),
                    body = o.optString("body"),
                    vibrate = o.optBoolean("vibrate", true),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun reminderFor(context: Context, id: Int): Reminder? =
        load(context).firstOrNull { it.id == id }

    private val REMINDER_IDS = listOf(7303, 7301, 7300, 7399)
}
