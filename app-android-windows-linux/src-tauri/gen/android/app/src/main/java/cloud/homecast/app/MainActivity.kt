package cloud.homecast.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.view.WindowInsetsController
import org.json.JSONObject
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import java.net.Inet4Address
import java.net.InetAddress

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
        webView.addJavascriptInterface(DiscoveryBridge(), "HomecastDiscovery")
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
        discoveryWanted = false
        stopNsd()
        webViewRef = null
        super.onDestroy()
    }

    override fun onPause() {
        super.onPause()
        // An mDNS subscription left running in the background costs battery
        // for results nobody is looking at.
        if (discoveryWanted) stopNsd()
    }

    override fun onResume() {
        super.onResume()
        if (discoveryWanted) runOnUiThread { if (isPickerOrigin()) startNsd() }
    }

    // MARK: - Relay discovery (mDNS)

    private val nsdManager: NsdManager by lazy {
        getSystemService(Context.NSD_SERVICE) as NsdManager
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    @Volatile private var discoveryWanted = false

    /** Pre-34 resolve state. resolveService serialises, so this queue is required. */
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val resolveRetries = HashMap<String, Int>()

    /** API 34+ per-service callbacks, keyed by service name. */
    private val infoCallbacks = HashMap<String, Any>()

    /**
     * A JavascriptInterface is attached to the WebView, so every page it loads
     * can call it — including the relay's own web app, which is a remote
     * origin and after remote access may not even be on this network. Without
     * this gate a hostile or compromised relay could enumerate the user's LAN.
     */
    private fun isPickerOrigin(): Boolean {
        val current = webViewRef?.url ?: return false
        val home = homeUrl ?: return false
        return sameOrigin(current, home)
    }

    private fun startNsd() {
        if (discoveryListener != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                emitDiscoveryState("searching")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceType.trim('.') != SERVICE_TYPE.trim('.')) return
                enqueueResolve(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                evalJs(
                    "window.__homecastOnRelayLost && " +
                        "window.__homecastOnRelayLost(${jsString(info.serviceName)})"
                )
            }

            override fun onDiscoveryStopped(serviceType: String) {
                emitDiscoveryState("stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "NSD discovery failed to start: $errorCode")
                discoveryListener = null
                emitDiscoveryState("unavailable")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                discoveryListener = null
            }
        }
        discoveryListener = listener
        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (t: Throwable) {
            Log.w(TAG, "NSD unavailable", t)
            discoveryListener = null
            emitDiscoveryState("unavailable")
        }
    }

    private fun stopNsd() {
        discoveryListener?.let {
            try { nsdManager.stopServiceDiscovery(it) } catch (_: Throwable) {}
        }
        discoveryListener = null
        if (Build.VERSION.SDK_INT >= 34) unregisterInfoCallbacks()
        infoCallbacks.clear()
        synchronized(resolveQueue) {
            resolveQueue.clear()
            resolving = false
        }
        resolveRetries.clear()
    }

    private fun enqueueResolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) {
            watchService(info)
            return
        }
        synchronized(resolveQueue) { resolveQueue.addLast(info) }
        pumpResolve()
    }

    /**
     * One resolve in flight at a time.
     *
     * Before API 34 `resolveService` is serialised inside the framework and
     * answers any concurrent call with FAILURE_ALREADY_ACTIVE, so firing one
     * per discovered service loses all but the first.
     */
    @Suppress("DEPRECATION")
    private fun pumpResolve() {
        val next: NsdServiceInfo
        synchronized(resolveQueue) {
            if (resolving) return
            next = resolveQueue.removeFirstOrNull() ?: return
            resolving = true
        }
        nsdManager.resolveService(next, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                synchronized(resolveQueue) { resolving = false }
                emitRelay(resolved)
                pumpResolve()
            }

            override fun onResolveFailed(failed: NsdServiceInfo, errorCode: Int) {
                synchronized(resolveQueue) { resolving = false }
                if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE) {
                    val key = failed.serviceName
                    val tries = (resolveRetries[key] ?: 0) + 1
                    if (tries <= 3) {
                        resolveRetries[key] = tries
                        mainHandler.postDelayed({ enqueueResolve(failed) }, 250L * tries)
                    }
                } else {
                    Log.w(TAG, "NSD resolve failed for ${failed.serviceName}: $errorCode")
                }
                pumpResolve()
            }
        })
    }

    /** API 34+: a live subscription, so TXT changes arrive without re-resolving. */
    @RequiresApi(34)
    private fun watchService(info: NsdServiceInfo) {
        val key = info.serviceName
        if (infoCallbacks.containsKey(key)) return
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                Log.w(TAG, "NSD info callback failed for $key: $errorCode")
                infoCallbacks.remove(key)
            }

            override fun onServiceUpdated(updated: NsdServiceInfo) = emitRelay(updated)

            override fun onServiceLost() {
                evalJs(
                    "window.__homecastOnRelayLost && " +
                        "window.__homecastOnRelayLost(${jsString(key)})"
                )
            }

            override fun onServiceInfoCallbackUnregistered() {
                infoCallbacks.remove(key)
            }
        }
        infoCallbacks[key] = callback
        try {
            nsdManager.registerServiceInfoCallback(info, mainExecutor, callback)
        } catch (t: Throwable) {
            Log.w(TAG, "NSD info callback registration threw for $key", t)
            infoCallbacks.remove(key)
        }
    }

    @RequiresApi(34)
    private fun unregisterInfoCallbacks() {
        infoCallbacks.values.forEach { cb ->
            if (cb is NsdManager.ServiceInfoCallback) {
                try { nsdManager.unregisterServiceInfoCallback(cb) } catch (_: Throwable) {}
            }
        }
    }

    private fun emitRelay(info: NsdServiceInfo) {
        val address = pickIpv4(info) ?: return
        val attributes = info.attributes ?: emptyMap<String, ByteArray?>()
        fun txt(key: String): String? = attributes[key]?.let { String(it, Charsets.UTF_8) }

        val json = JSONObject()
        // The relay's stable id, so a Mac that changed address is the same row.
        json.put("id", txt("id") ?: info.serviceName)
        json.put("name", info.serviceName)
        json.put("host", address)
        json.put("port", info.port)
        txt("ws")?.toIntOrNull()?.let { json.put("wsPort", it) }
        txt("vs")?.let { json.put("version", it) }
        txt("au")?.let { json.put("auth", it == "1") }
        txt("v")?.toIntOrNull()?.let { json.put("v", it) }

        evalJs("window.__homecastOnRelayFound && window.__homecastOnRelayFound($json)")
    }

    /**
     * Always a numeric IPv4 address.
     *
     * Android's platform resolver has no mDNS — only NsdManager does, and only
     * internally — so a `.local` name handed to the WebView would never
     * resolve. (iOS can use the name; Android cannot.)
     */
    @Suppress("DEPRECATION")
    private fun pickIpv4(info: NsdServiceInfo): String? {
        val candidates: List<InetAddress> =
            if (Build.VERSION.SDK_INT >= 34) info.hostAddresses
            else listOfNotNull(info.host)
        return candidates.filterIsInstance<Inet4Address>().firstOrNull()?.hostAddress
    }

    private fun emitDiscoveryState(state: String) {
        evalJs(
            "window.__homecastOnDiscoveryState && " +
                "window.__homecastOnDiscoveryState(${jsString(state)})"
        )
    }

    inner class DiscoveryBridge {
        /** Begin looking for relays. No-op anywhere but the mode picker. */
        @JavascriptInterface
        fun startDiscovery() {
            runOnUiThread {
                if (!isPickerOrigin()) return@runOnUiThread
                discoveryWanted = true
                startNsd()
            }
        }

        @JavascriptInterface
        fun stopDiscovery() {
            runOnUiThread {
                discoveryWanted = false
                stopNsd()
            }
        }
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

        /** What the Mac relay advertises itself as. */
        private const val SERVICE_TYPE = "_homecast._tcp"

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
