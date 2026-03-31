use tauri::webview::PageLoadEvent;

/// Inject platform globals so the web app knows it's running in a native context.
fn inject_platform_globals(webview: &tauri::Webview) {
    let platform = if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "ios") {
        "ios"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    };

    let script = format!(
        r#"
        window.isHomecastApp = true;
        window.isHomecastTauriApp = true;
        window.homecastPlatform = "{}";
        window.isHomecastIOSApp = {};
        window.isHomecastAndroidApp = {};
        window.isHomecastDesktopApp = {};
        "#,
        platform,
        if cfg!(target_os = "ios") { "true" } else { "false" },
        if cfg!(target_os = "android") { "true" } else { "false" },
        if cfg!(any(target_os = "macos", target_os = "windows", target_os = "linux")) {
            "true"
        } else {
            "false"
        },
    );

    let _ = webview.eval(&script);

    // Staging environment persistence: use a cookie with domain=.homecast.cloud
    // so the preference is shared across both origins (unlike localStorage which
    // is per-origin and caused an infinite redirect loop between the two domains).
    // On staging: trust the hostname, sync cookie, stay.
    // On production: redirect to staging only if cookie says 'staging'.
    let _ = webview.eval(r#"
        (function() {
            if (window.__homecast_env_checked) return;
            window.__homecast_env_checked = true;
            try {
                var match = document.cookie.match(/(?:^|;\s*)homecast-env=(\w+)/);
                var env = match ? match[1] : null;
                var host = window.location.hostname;
                if (host.includes('staging')) {
                    document.cookie = 'homecast-env=staging;domain=.homecast.cloud;path=/;max-age=31536000;secure;samesite=lax';
                } else if (env === 'staging') {
                    window.location.href = window.location.href.replace('://homecast.cloud', '://staging.homecast.cloud');
                }
            } catch(e) {}
        })();
    "#);

    // Android-specific injections
    #[cfg(target_os = "android")]
    {
        // Safe area CSS (Android WebView doesn't support env(safe-area-inset-*))
        let _ = webview.eval(r#"
            (function() {
                var id = '__tauri_safe_area';
                if (document.getElementById(id)) return;
                var s = document.createElement('style');
                s.id = id;
                s.textContent = ':root { --safe-area-top: 48px; }';
                document.head.appendChild(s);
            })();
        "#);

    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .on_page_load(|webview, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                inject_platform_globals(&webview);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
