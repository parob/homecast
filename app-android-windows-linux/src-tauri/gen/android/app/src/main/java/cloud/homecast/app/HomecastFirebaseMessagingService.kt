package cloud.homecast.app

import android.content.Context
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * Receives FCM tokens and incoming messages.
 *
 * - When the app is foregrounded, [onMessageReceived] forwards the payload
 *   to the WebView via [MainActivity.deliverForegroundPush].
 * - When the app is backgrounded, FCM draws a system-tray notification
 *   directly from the message's `notification` block; we don't need to do
 *   anything here for that case (Android handles it).
 *
 * The latest FCM token is cached in SharedPreferences so the WebView can
 * read it back via the [MainActivity.HomecastAndroidPush] JS bridge after
 * a cold start.
 */
class HomecastFirebaseMessagingService : FirebaseMessagingService() {

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
        MainActivity.deliverForegroundPush(payload.toString())
    }

    companion object {
        private const val TAG = "HomecastFCM"
        const val PREFS = "homecast_push"
        const val KEY_TOKEN = "fcm_token"
    }
}
