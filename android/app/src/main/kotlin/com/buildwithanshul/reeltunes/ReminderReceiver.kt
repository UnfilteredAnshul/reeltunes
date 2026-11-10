package com.buildwithanshul.reeltunes

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Fires at 3 days, 1 day and the exact subscription end / renewal minute. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(ReminderScheduler.EXTRA_ID, 0)
        if (id == 0) return
        val reminder = ReminderScheduler.reminderFor(context, id)
        if (reminder != null) {
            ReminderScheduler.postNow(
                context,
                reminder.id,
                reminder.title,
                reminder.body,
                reminder.vibrate
            )
            ReminderScheduler.removeSaved(context, id)
        }
        // Always release the goAsync-style reference; nothing async here.
    }
}
