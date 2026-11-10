package com.buildwithanshul.reeltunes

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * AlarmManager forgets alarms on reboot and the app is not started until the
 * user opens it, so restore the saved subscription reminders here.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> ReminderScheduler.rescheduleSaved(context)
        }
    }
}
