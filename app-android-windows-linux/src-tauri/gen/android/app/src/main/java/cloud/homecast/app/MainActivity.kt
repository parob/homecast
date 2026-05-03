package cloud.homecast.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.view.WindowInsetsController
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging

class MainActivity : TauriActivity() {

    private var webViewRef: WebView? = null
    private val permissionRequest = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.d(TAG, "POST_NOTIFICATIONS granted=$granted")
        evalJs("window.__homecastOnPushPermission && window.__homecastOnPushPermission($granted)")
    }

    override fun onWebViewCreate(webView: WebView) {
        super.onWebViewCreate(webView)
        webViewRef = webView
        instance = this
        webView.addJavascriptInterface(StatusBarBridge(), "HomecastAndroid")
        webView.addJavascriptInterface(PushBridge(), "HomecastAndroidPush")
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        webViewRef = null
        super.onDestroy()
    }

    private fun evalJs(js: String) {
        runOnUiThread { webViewRef?.evaluateJavascript(js, null) }
    }

    inner class StatusBarBridge {
        @JavascriptInterface
        fun setStatusBarDarkIcons(dark: Boolean) {
            runOnUiThread {
                window.insetsController?.setSystemBarsAppearance(
                    if (dark) WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else 0,
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                )
            }
        }
    }

    inner class PushBridge {
        /** Returns the cached FCM token, or null if none yet. */
        @JavascriptInterface
        fun getCachedFcmToken(): String? =
            getSharedPreferences(HomecastFirebaseMessagingService.PREFS, Context.MODE_PRIVATE)
                .getString(HomecastFirebaseMessagingService.KEY_TOKEN, null)

        /** Triggers an FCM token fetch. Result delivered via window.__homecastOnFcmToken. */
        @JavascriptInterface
        fun fetchFcmToken() {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    Log.w(TAG, "FCM token fetch failed", task.exception)
                    evalJs("window.__homecastOnFcmToken && window.__homecastOnFcmToken(null)")
                    return@addOnCompleteListener
                }
                val token = task.result
                getSharedPreferences(HomecastFirebaseMessagingService.PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putString(HomecastFirebaseMessagingService.KEY_TOKEN, token)
                    .apply()
                evalJs("window.__homecastOnFcmToken && window.__homecastOnFcmToken(${jsString(token)})")
            }
        }

        /** Returns true if POST_NOTIFICATIONS is already granted (always true pre-Android 13). */
        @JavascriptInterface
        fun hasNotificationPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
            return ContextCompat.checkSelfPermission(
                this@MainActivity,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }

        /**
         * Prompts for notification permission. Result delivered via
         * window.__homecastOnPushPermission(boolean). On Android <13 the
         * permission is implicit; we resolve immediately.
         */
        @JavascriptInterface
        fun requestNotificationPermission() {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                evalJs("window.__homecastOnPushPermission && window.__homecastOnPushPermission(true)")
                return
            }
            runOnUiThread {
                permissionRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        @JavascriptInterface
        fun deviceModel(): String = "${Build.MANUFACTURER} ${Build.MODEL}"
    }

    companion object {
        private const val TAG = "HomecastMain"

        @Volatile private var instance: MainActivity? = null

        /** Called from the FCM service when a fresh token arrives. */
        fun deliverFcmToken(token: String) {
            instance?.evalJs("window.__homecastOnFcmToken && window.__homecastOnFcmToken(${jsString(token)})")
        }

        /** Called from the FCM service when a foreground message arrives. */
        fun deliverForegroundPush(jsonPayload: String) {
            instance?.evalJs("window.__homecastOnPush && window.__homecastOnPush($jsonPayload)")
        }

        private fun jsString(s: String?): String =
            if (s == null) "null"
            else "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
    }
}
