package cloud.homecast.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/**
 * The notification channel Homecast posts on.
 *
 * Android 8+ silently drops any notification posted to a channel that has not
 * been declared, so this has to run before the first push can arrive — which is
 * why it is called from both [MainActivity.onCreate] and
 * [HomecastFirebaseMessagingService.onCreate]: the messaging service can run in
 * a process where the activity never started. Creating a channel twice is a
 * no-op, so calling it from both costs nothing.
 *
 * The id must match `default_notification_channel_id` in AndroidManifest.xml and
 * the `channel_id` the cloud server sets on its AndroidConfig.
 */
object HomecastNotifications {
    const val CHANNEL_ID = "homecast_default"

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Home alerts",
            // Automation alerts are the reason someone installed this — a door
            // left open or a leak detected should be able to interrupt.
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Notifications from your Homecast automations"
        }
        ctx.getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }
}
