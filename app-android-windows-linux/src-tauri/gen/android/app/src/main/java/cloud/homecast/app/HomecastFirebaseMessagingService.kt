package cloud.homecast.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * Receives FCM tokens and incoming messages.
 *
 * - Backgrounded, FCM draws the tray notification itself from the message's
 *   `notification` block and this class is never called.
 * - Foregrounded, FCM draws nothing and calls [onMessageReceived] instead — so
 *   the notification has to be built here, or an automation firing while the
 *   user happens to have Homecast open produces no alert at all.
 *
 * The latest FCM token is cached in SharedPreferences so the WebView can read it
 * back via the `HomecastAndroidPush` JS bridge after a cold start.
 */
class HomecastFirebaseMessagingService : FirebaseMessagingService() {

    override fun onCreate() {
        super.onCreate()
        // This service can run in a process where MainActivity never started.
        HomecastNotifications.ensureChannel(this)
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "FCM onNewToken: ${token.take(8)}…")
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TOKEN, token)
            .apply()
        MainActivity.deliverFcmToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val title = message.notification?.title ?: message.data["title"]
        val body = message.notification?.body ?: message.data["body"]
        val payload = JSONObject().apply {
            put("title", title ?: JSONObject.NULL)
            put("body", body ?: JSONObject.NULL)
            put("data", JSONObject(message.data as Map<*, *>))
        }
        // Let the web app refresh notification history and react in-page.
        MainActivity.deliverForegroundPush(payload.toString())
        showNotification(title, body, message.data)
    }

    /**
     * Draw the tray notification for the foreground case, carrying the same data
     * extras FCM would have attached, so a tap routes identically either way
     * (see MainActivity.capturePushOpen).
     */
    private fun showNotification(title: String?, body: String?, data: Map<String, String>) {
        if (title == null && body == null) return

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            for ((key, value) in data) putExtra(key, value)
        }
        val pending = PendingIntent.getActivity(
            this,
            // Distinct request codes so a second alert doesn't overwrite the
            // first one's extras.
            (System.currentTimeMillis() and 0xfffffff).toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, HomecastNotifications.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_homecast)
            .setColor(ContextCompat.getColor(this, R.color.homecast_notification))
            .setContentTitle(title ?: "Homecast")
            .apply { body?.let { setContentText(it); setStyle(NotificationCompat.BigTextStyle().bigText(it)) } }
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        try {
            NotificationManagerCompat.from(this)
                .notify((System.currentTimeMillis() and 0xfffffff).toInt(), notification)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS revoked between the push and here.
            Log.w(TAG, "Cannot post notification", e)
        }
    }

    companion object {
        private const val TAG = "HomecastFCM"
        const val PREFS = "homecast_push"
        const val KEY_TOKEN = "fcm_token"
    }
}
