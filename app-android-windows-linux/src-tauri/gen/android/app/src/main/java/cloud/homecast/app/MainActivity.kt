package cloud.homecast.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.view.WindowInsetsController
import org.json.JSONObject
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging

class MainActivity : TauriActivity() {

    private var webViewRef: WebView? = null
    @Volatile private var homeUrl: String? = null
    /** Notification payload waiting for the web app to come up and collect it. */
    @Volatile private var pendingPushOpen: String? = null
    private val permissionRequest = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.d(TAG, "POST_NOTIFICATIONS granted=$granted")
        evalJs("window.__homecastOnPushPermission && window.__homecastOnPushPermission($granted)")
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        HomecastNotifications.ensureChannel(this)
        // Cold start from a notification tap: the WebView doesn't exist yet and
        // React is nowhere near mounted, so stash the payload for the web app to
        // collect via consumePendingPushOpen() once it is ready.
        capturePushOpen(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // launchMode is singleTask, so a tap while the app is already running
        // arrives here rather than through onCreate.
        setIntent(intent)
        capturePushOpen(intent)
        pendingPushOpen?.let { payload ->
            evalJs("window.__homecastOnPushOpen && window.__homecastOnPushOpen($payload)")
            pendingPushOpen = null
        }
    }

    /** Pull the notification's data payload off the launch intent, if any. */
    private fun capturePushOpen(intent: android.content.Intent?) {
        val extras = intent?.extras ?: return
        val json = JSONObject()
        for (key in extras.keySet()) {
            // FCM's own plumbing rides along on the same extras; it is noise to
            // the web app and must not be mistaken for automation payload.
            if (key.startsWith("google.") || key.startsWith("gcm.") ||
                key == "from" || key == "collapse_key" || key == "message_type"
            ) continue
            val value = extras.get(key)
            if (value is String) json.put(key, value)
        }
        if (json.length() > 0) pendingPushOpen = json.toString()
    }

    override fun onWebViewCreate(webView: WebView) {
        super.onWebViewCreate(webView)
        webViewRef = webView
        instance = this
        webView.addJavascriptInterface(StatusBarBridge(), "HomecastAndroid")
        webView.addJavascriptInterface(PushBridge(), "HomecastAndroidPush")
        installBackPressHandler()
    }

    private fun installBackPressHandler() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val wv = webViewRef
                val home = homeUrl
                if (wv == null || home == null) {
                    finish(); return
                }
                val current = wv.url
                if (current != null && sameOrigin(current, home)) {
                    // Already on the picker — back exits the app.
                    finish(); return
                }
                val history = wv.copyBackForwardList()
                val idx = history.currentIndex
                // If the previous history entry is the picker, going back would
                // trigger the IIFE redirect again — load home with ?reset=1 so
                // the selector renders and the saved mode is cleared.
                if (idx > 0 && sameOrigin(history.getItemAtIndex(idx - 1).url, home)) {
                    runOnUiThread { wv.loadUrl(homeUrlWithReset(home)) }
                    return
                }
                if (wv.canGoBack()) {
                    runOnUiThread { wv.goBack() }
                    return
                }
                finish()
            }
        })
    }

    private fun sameOrigin(a: String, b: String): Boolean = try {
        val ua = Uri.parse(a)
        val ub = Uri.parse(b)
        ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port
    } catch (_: Throwable) { false }

    private fun homeUrlWithReset(home: String): String {
        val sep = if (home.contains("?")) "&" else "?"
        // Strip any existing fragment so the IIFE sees a clean ?reset=1
        val base = home.substringBefore('#')
        return "$base${sep}reset=1"
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

        @JavascriptInterface
        fun setHomeUrl(url: String) {
            if (homeUrl == null) homeUrl = url
        }

        @JavascriptInterface
        fun resetMode() {
            val home = homeUrl ?: return
            val target = homeUrlWithReset(home)
            runOnUiThread { webViewRef?.loadUrl(target) }
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

        /**
         * The payload of the notification this launch came from, or null.
         *
         * Read-and-clear, and a pull rather than a push, because a cold start
         * races the WebView and the React mount — the same reason
         * getCachedFcmToken() exists.
         */
        @JavascriptInterface
        fun consumePendingPushOpen(): String? {
            val payload = pendingPushOpen
            pendingPushOpen = null
            return payload
        }
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
