package cloud.homecast.app

import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.view.WindowInsetsController

class MainActivity : TauriActivity() {
    override fun onWebViewCreate(webView: WebView) {
        super.onWebViewCreate(webView)
        webView.addJavascriptInterface(StatusBarBridge(), "HomecastAndroid")
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
}
