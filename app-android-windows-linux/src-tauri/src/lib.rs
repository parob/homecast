use tauri::webview::PageLoadEvent;

/// Relay discovery on desktop.
///
/// Android has its own path — the system `NsdManager`, reached through a
/// Kotlin `@JavascriptInterface` bridge — because it needs no multicast lock
/// and no extra manifest permissions, which a raw-socket mDNS implementation
/// like this one would. iOS never runs the Tauri shell at all.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod discovery {
    use serde_json::json;
    use std::time::Duration;
    use tauri::Emitter;

    const SERVICE_TYPE: &str = "_homecast._tcp.local.";

    /// Whether this webview is still showing the bundled picker, which Tauri
    /// serves over the asset protocol rather than from a real host.
    fn is_picker(window: &tauri::WebviewWindow) -> bool {
        match window.url() {
            Ok(url) => {
                let host = url.host_str().unwrap_or("");
                url.scheme() == "tauri" || host == "tauri.localhost" || host == "localhost"
            }
            Err(_) => false,
        }
    }

    /// Browse for relays, emitting `relay-found` as each one resolves.
    ///
    /// Runs for a bounded window rather than forever: the picker is a
    /// short-lived screen, and a browse left running would outlive it.
    #[tauri::command]
    pub fn discover_relays(window: tauri::WebviewWindow) -> Result<(), String> {
        // Only the bundled picker may scan the network. Tauri already refuses
        // IPC from origins outside a capability's `remote.urls`, but stating
        // it here means a relay page — or the cloud web app, which *is*
        // allowlisted — can never enumerate the user's LAN. Same posture as
        // the Android bridge's origin gate.
        if !is_picker(&window) {
            return Err("discovery is only available on the mode picker".into());
        }

        let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
        let receiver = daemon.browse(SERVICE_TYPE).map_err(|e| e.to_string())?;

        std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(30);
            while std::time::Instant::now() < deadline {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                let event = match receiver.recv_timeout(remaining) {
                    Ok(event) => event,
                    Err(_) => break,
                };
                match event {
                    mdns_sd::ServiceEvent::ServiceResolved(info) => {
                        // The web app navigates to this, so it must be an
                        // address rather than a .local name — and specifically
                        // an IPv4 one: a bare IPv6 literal needs brackets to
                        // be a legal URL host, and the first address offered
                        // is often the link-local v6.
                        let Some(address) = info
                            .get_addresses()
                            .iter()
                            .find(|addr| addr.is_ipv4())
                        else {
                            continue;
                        };
                        let name = info.get_fullname().split('.').next().unwrap_or("").to_string();
                        let txt = |key: &str| {
                            info.get_property_val_str(key).map(|v| v.to_string())
                        };
                        let payload = json!({
                            "id": txt("id").unwrap_or_else(|| name.clone()),
                            "name": name,
                            "host": address.to_string(),
                            "port": info.get_port(),
                            "wsPort": txt("ws").and_then(|v| v.parse::<u16>().ok()),
                            "version": txt("vs"),
                            "auth": txt("au").map(|v| v == "1"),
                            "v": txt("v").and_then(|v| v.parse::<u32>().ok()),
                        });
                        let _ = window.emit("relay-found", payload);
                    }
                    mdns_sd::ServiceEvent::ServiceRemoved(_, fullname) => {
                        let name = fullname.split('.').next().unwrap_or("").to_string();
                        let _ = window.emit("relay-lost", name);
                    }
                    _ => {}
                }
            }
            let _ = daemon.shutdown();
        });

        Ok(())
    }
}

#[cfg(target_os = "android")]
const PLATFORM_FLAGS_JS: &str = "\
    window.isHomecastTauriApp = true;\
    window.homecastPlatform = \"android\";\
    window.isHomecastIOSApp = false;\
    window.isHomecastAndroidApp = true;\
    window.isHomecastDesktopApp = false;";

#[cfg(target_os = "ios")]
const PLATFORM_FLAGS_JS: &str = "\
    window.isHomecastTauriApp = true;\
    window.homecastPlatform = \"ios\";\
    window.isHomecastIOSApp = true;\
    window.isHomecastAndroidApp = false;\
    window.isHomecastDesktopApp = false;";

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
const PLATFORM_FLAGS_JS: &str = {
    #[cfg(target_os = "macos")]
    { "\
        window.isHomecastTauriApp = true;\
        window.homecastPlatform = \"macos\";\
        window.isHomecastIOSApp = false;\
        window.isHomecastAndroidApp = false;\
        window.isHomecastDesktopApp = true;" }
    #[cfg(target_os = "windows")]
    { "\
        window.isHomecastTauriApp = true;\
        window.homecastPlatform = \"windows\";\
        window.isHomecastIOSApp = false;\
        window.isHomecastAndroidApp = false;\
        window.isHomecastDesktopApp = true;" }
    #[cfg(target_os = "linux")]
    { "\
        window.isHomecastTauriApp = true;\
        window.homecastPlatform = \"linux\";\
        window.isHomecastIOSApp = false;\
        window.isHomecastAndroidApp = false;\
        window.isHomecastDesktopApp = true;" }
};

/// Inject the small set of synchronous platform flags React needs before its
/// first render. Runs on PageLoadEvent::Started so flags like
/// `window.isHomecastAndroidApp` are visible to module-level code and the
/// initial useState/useEffect on mount. Safe to call again on Finished.
fn inject_platform_flags(webview: &tauri::Webview) {
    let _ = webview.eval(PLATFORM_FLAGS_JS);
    #[cfg(target_os = "android")]
    {
        let _ = webview.eval(ANDROID_SAFE_AREA_JS);
    }
}

/// Heavier post-load injections: community/staging detection. Runs on Finished.
/// NOTE: do NOT set window.isHomecastApp here. The cloud web app uses
/// that flag as a proxy for "Apple App Store build" (anti-steering copy,
/// Apple subscription disclosure, repo-link instead of Sponsor link).
/// The Mac/iOS native WKWebView host injects it; Tauri (Android, Windows,
/// Linux) is not an App Store build and must not impersonate one.
fn inject_platform_globals(webview: &tauri::Webview) {
    inject_platform_flags(webview);

    // Community mode detection: inject flag when not on homecast.cloud
    let _ = webview.eval(r#"
        (function() {
            var host = window.location.hostname;
            if (host !== 'homecast.cloud' && host !== 'staging.homecast.cloud') {
                window.__HOMECAST_COMMUNITY__ = true;
            }
        })();
    "#);

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

}

#[cfg(target_os = "android")]
const ANDROID_SAFE_AREA_JS: &str = r#"
(function() {
    try {
        var STYLE_ID = '__homecast_safe_area_style';
        var VALUE = '48px';
        function ensureStyle() {
            if (document.getElementById(STYLE_ID)) return;
            var s = document.createElement('style');
            s.id = STYLE_ID;
            s.textContent = ':root { --safe-area-top: ' + VALUE + ' !important; }';
            (document.head || document.documentElement).appendChild(s);
        }
        function ensureInline() {
            try {
                var el = document.documentElement;
                var cur = el.style.getPropertyValue('--safe-area-top');
                var prio = el.style.getPropertyPriority('--safe-area-top');
                if (cur === VALUE && prio === 'important') return;
                el.style.setProperty('--safe-area-top', VALUE, 'important');
            } catch(e) {}
        }
        ensureInline();
        ensureStyle();
        if (window.__homecastSafeAreaObserver) return;
        var reapply = function() { ensureInline(); ensureStyle(); };
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', reapply, { once: true });
        }
        try {
            var obs = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                    var m = mutations[i];
                    if (m.type === 'attributes' && m.target === document.documentElement) {
                        ensureInline();
                    }
                    if (m.type === 'childList' && !document.getElementById(STYLE_ID)) {
                        ensureStyle();
                    }
                }
            });
            obs.observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
            if (document.head) {
                obs.observe(document.head, { childList: true });
            }
            window.__homecastSafeAreaObserver = obs;
        } catch(e) {}
    } catch(e) {}
})();
"#;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default().plugin(tauri_plugin_opener::init());

    // Desktop only — on Android the Kotlin bridge does this instead.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let builder = builder.invoke_handler(tauri::generate_handler![discovery::discover_relays]);

    builder
        .on_page_load(|webview, payload| {
            match payload.event() {
                // Set safe-area-top BEFORE first paint so content positioned
                // with calc(... + var(--safe-area-top)) doesn't flash at 0px.
                PageLoadEvent::Started => {
                    inject_platform_flags(&webview);
                }
                PageLoadEvent::Finished => {
                    inject_platform_globals(&webview);
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
