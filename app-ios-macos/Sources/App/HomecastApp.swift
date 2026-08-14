import SwiftUI
import WebKit
import HomeKit
import UIKit
import UniformTypeIdentifiers
import Network

// MARK: - Host info

/// Machine metadata the web layer can't read for itself.
///
/// Injected onto `window` at document start and forwarded to the cloud on the
/// relay's WebSocket handshake. Until this existed a relay was anonymous to the
/// server beyond its generated `device_id`, so the admin panel couldn't tell a
/// stale build or an old macOS from a current one.
///
/// Values are sanitised because they get interpolated into a JS string literal.
enum HostInfo {
    /// e.g. "macOS 15.3.1". `operatingSystemVersionString` returns the noisier
    /// "Version 15.3.1 (Build 24D70)", so build it from the components.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let name: String
        #if targetEnvironment(macCatalyst)
        name = "macOS"
        #else
        name = UIDevice.current.systemName
        #endif
        let patch = v.patchVersion > 0 ? ".\(v.patchVersion)" : ""
        return jsSafe("\(name) \(v.majorVersion).\(v.minorVersion)\(patch)")
    }

    /// Hardware identifier — "Macmini9,1" on Catalyst, "iPhone15,2" on iOS.
    /// `hw.model` is the Mac's real model; on iOS it reports the same string
    /// `uname` would, which is what we want.
    static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return jsSafe(String(cString: bytes))
    }

    /// The machine's name without the Bonjour `.local` suffix — matches how
    /// LocalHTTPServer derives its advertised service name.
    static var hostName: String {
        jsSafe(ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: ""))
    }

    /// Strip anything that would break out of (or corrupt) a JS string literal.
    private static func jsSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Config

enum AppConfig {
    /// Whether to show the main window when the app launches.
    /// Set to `true` for testing, `false` for production (menu bar only on launch).
    static let showWindowOnLaunch = true

    /// Whether the app is currently configured for the staging environment.
    static var isStaging: Bool {
        UserDefaults.standard.bool(forKey: "com.homecast.stagingMode")
    }

    /// Whether the app is in Community mode (fully local, no cloud).
    static var isCommunity: Bool {
        UserDefaults.standard.bool(forKey: "com.homecast.communityMode")
    }

    /// Whether the user has selected a mode (Community or Cloud).
    static var modeSelected: Bool {
        UserDefaults.standard.bool(forKey: "com.homecast.modeSelected")
    }

    /// The port the local HTTP server is running on (set at runtime).
    static var localServerPort: UInt16 = 5656

    /// Saved relay address for iOS community mode (e.g. "192.168.1.50:5656")
    static var relayAddress: String? {
        get { UserDefaults.standard.string(forKey: "com.homecast.relayAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "com.homecast.relayAddress") }
    }

    /// Base URL for the web app (changes based on mode).
    static var webBaseURL: String {
        if isCommunity {
            #if targetEnvironment(macCatalyst)
            return "http://localhost:\(localServerPort)"
            #else
            // iOS: connect to the user's Mac relay
            if let addr = relayAddress {
                return "http://\(addr)"
            }
            return "http://localhost:\(localServerPort)" // fallback
            #endif
        }
        return isStaging ? "https://staging.homecast.cloud" : "https://homecast.cloud"
    }

    /// Base URL for the cloud API. Nil in Community mode (no cloud endpoint).
    /// Used by LogShipper to post Mac-side logs to /internal/logs.
    static var apiBaseURL: URL? {
        if isCommunity { return nil }
        return URL(string: isStaging ? "https://staging.api.homecast.cloud" : "https://api.homecast.cloud")
    }
}

// Notifications
extension Notification.Name {
    static let reloadWebView = Notification.Name("reloadWebView")
    static let hardRefreshWebView = Notification.Name("hardRefreshWebView")
    static let environmentDidChange = Notification.Name("environmentDidChange")
    static let relayStatusDidChange = Notification.Name("relayStatusDidChange")
    static let localServerDidStart = Notification.Name("localServerDidStart")
}

@main
struct HomecastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.homeKitManager)
                .environmentObject(appDelegate.connectionManager)
                .environmentObject(appDelegate.homeKitBridge)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Sign Out") {
                    appDelegate.connectionManager.signOut()
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
                .disabled(!appDelegate.connectionManager.isAuthenticated)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Page") {
                    NotificationCenter.default.post(name: .reloadWebView, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Hard Refresh (Clear Cache)") {
                    NotificationCenter.default.post(name: .hardRefreshWebView, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Root View

struct RootView: View {
    var body: some View {
        #if targetEnvironment(macCatalyst)
        // No minimum here: the window's own sizeRestrictions (AppDelegate,
        // 480x400) are the floor. Asking for a taller minimum than the window
        // allows made SwiftUI centre the overflow, so between 400 and 600pt of
        // window height the top of the page — header, menus — was clipped off.
        ContentView()
            .ignoresSafeArea()
        #else
        ContentView()
            .ignoresSafeArea()
        #endif
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var homeKitManager: HomeKitManager
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var homeKitBridge: HomeKitBridge
    @State private var showModeSelector = !AppConfig.modeSelected
    @State private var showRelayConnect = false
    @State private var webViewId = UUID()

    private var webViewURL: URL {
        return URL(string: "\(AppConfig.webBaseURL)/login")!
    }

    var body: some View {
        if showModeSelector {
            ModeSelector(onSelect: { mode in
                let isCommunity = mode == .community
                UserDefaults.standard.set(true, forKey: "com.homecast.modeSelected")
                UserDefaults.standard.set(isCommunity, forKey: "com.homecast.communityMode")
                webViewId = UUID()
                if isCommunity {
                    #if targetEnvironment(macCatalyst)
                    LocalHTTPServer.shared?.stop()
                    LocalHTTPServer.shared = nil
                    let server = LocalHTTPServer()
                    server.onReady = {
                        showModeSelector = false
                    }
                    server.start()
                    LocalHTTPServer.shared = server
                    return
                    #else
                    // iOS: show native relay address input
                    showRelayConnect = true
                    showModeSelector = false
                    return
                    #endif
                }
                showModeSelector = false
            })
        } else if showRelayConnect {
            RelayConnector(onConnect: { address in
                AppConfig.relayAddress = address
                webViewId = UUID()
                showRelayConnect = false
            }, onBack: {
                UserDefaults.standard.set(false, forKey: "com.homecast.modeSelected")
                UserDefaults.standard.set(false, forKey: "com.homecast.communityMode")
                showRelayConnect = false
                showModeSelector = true
            })
        } else {
            WebViewContainer(url: webViewURL, authToken: AppConfig.isCommunity ? nil : connectionManager.authToken, connectionManager: connectionManager, homeKitBridge: homeKitBridge)
                .ignoresSafeArea()
                .id(webViewId)
                .onReceive(NotificationCenter.default.publisher(for: .environmentDidChange)) { _ in
                    if !AppConfig.modeSelected {
                        showModeSelector = true
                    } else {
                        webViewId = UUID()
                    }
                }
        }
    }
}

// MARK: - Mode Selector

enum HomecastMode {
    case community
    case cloud
}

struct ModeSelector: View {
    let onSelect: (HomecastMode) -> Void
    @State private var isStarting = false

    private var logoImage: UIImage? {
        // Load from bundled web-dist (always available)
        if let path = Bundle.main.path(forResource: "web-dist/icon-192", ofType: "png"),
           let image = UIImage(contentsOfFile: path) {
            return image
        }
        // Fallback: try app icon
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            return UIImage(named: name)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Logo + title + buttons as one centered group
            VStack(spacing: 20) {
                VStack(spacing: 16) {
                    if let img = logoImage {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .cornerRadius(14)
                    }

                    Text("Welcome to Homecast")
                        .font(.system(size: 24, weight: .semibold))

                    Text("Choose how you'd like to connect your devices.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 12) {
                // Homecast Cloud
                Button(action: { onSelect(.cloud) }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Homecast Cloud")
                                .font(.system(size: 15, weight: .medium))
                            Text("Remote access, cloud sync, and sharing")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isStarting)

                // Community (local server) — dark card mirroring website pricing style
                Button(action: {
                    isStarting = true
                    onSelect(.community)
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Community")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                            #if targetEnvironment(macCatalyst)
                            Text("Runs entirely on this Mac — no cloud needed")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                            #else
                            Text("Connect to a Mac running the Homecast relay")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                            #endif
                        }
                        Spacer()
                        if isStarting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .padding(14)
                    .background(Color(hue: 222/360, saturation: 0.47, brightness: 0.08))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color(hue: 217/360, saturation: 0.32, brightness: 0.17).opacity(0.8), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isStarting)

                }
                .frame(maxWidth: 300)
            }

            Spacer(minLength: 0)

            Text("You can log out and swap between modes at any time.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Relay Connector (iOS only)

struct RelayConnector: View {
    let onConnect: (String) -> Void
    let onBack: () -> Void

    @State private var address = "http://localhost:5656"
    @State private var isConnecting = false
    @State private var error = ""

    private var logoImage: UIImage? {
        if let path = Bundle.main.path(forResource: "web-dist/icon-192", ofType: "png"),
           let image = UIImage(contentsOfFile: path) {
            return image
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                VStack(spacing: 16) {
                    if let img = logoImage {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .cornerRadius(14)
                    }

                    Text("Connect to Relay")
                        .font(.system(size: 24, weight: .semibold))

                    Text("Enter the address of your Homecast relay running on your Mac.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("http://192.168.1.50:5656", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isConnecting)

                    if !error.isEmpty {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: connect) {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 4)
                            }
                            Text(isConnecting ? "Connecting..." : "Connect")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(isConnecting)

                    Button(action: onBack) {
                        Text("Back")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting)
                }
                .frame(maxWidth: 300)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func connect() {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Enter a relay address"
            return
        }
        isConnecting = true
        error = ""

        // Normalize URL
        var url = address.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://\(url)"
        }

        // Extract host:port
        guard let parsed = URL(string: url), let host = parsed.host else {
            error = "Invalid URL"
            isConnecting = false
            return
        }
        let port = parsed.port ?? 5656
        let addr = "\(host):\(port)"

        // Validate relay
        guard let healthURL = URL(string: "http://\(addr)/health") else {
            error = "Invalid address"
            isConnecting = false
            return
        }

        let task = URLSession.shared.dataTask(with: healthURL) { data, response, err in
            DispatchQueue.main.async {
                self.isConnecting = false
                if let err = err {
                    self.error = "Could not connect: \(err.localizedDescription)"
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["status"] as? String == "ok" else {
                    self.error = "Not a Homecast relay"
                    return
                }
                onConnect(addr)
            }
        }
        task.resume()
    }
}

// MARK: - Focusable WebView

/// Custom WKWebView that properly handles keyboard input on Mac Catalyst
class FocusableWebView: WKWebView {
    override var canBecomeFirstResponder: Bool { true }

    #if targetEnvironment(macCatalyst)
    // On Mac, override safe area insets for full-bleed content
    override var safeAreaInsets: UIEdgeInsets { .zero }
    #endif
    // On iOS, keep real safe area insets so CSS env(safe-area-inset-*) works

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }
    }

    /// Handle Tab key to move between form fields.
    ///
    /// Return is deliberately **not** handled here. Swallowing a key means
    /// WebKit never sees it, so the page gets no `keydown` at all — and the web
    /// app is full of fields that finish on Enter (a virtual accessory's text
    /// value, search boxes, dialogs). Those worked in a browser and did nothing
    /// in this app, which is exactly the shape of a key that never arrived.
    ///
    /// Nothing is lost by letting it through: WebKit already clicks a focused
    /// button on Return and already submits a field's form, which is all the
    /// interception did, and it does it after the page has had its say.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if key.keyCode == .keyboardTab {
                // Tab key - move to next/previous focusable element
                // Blur first to dismiss any autofill popups and avoid WebKit warnings
                let shift = key.modifierFlags.contains(.shift)
                let js = """
                (function() {
                    var focusable = Array.from(document.querySelectorAll('input:not([disabled]), button:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'));
                    var current = document.activeElement;
                    var idx = focusable.indexOf(current);
                    var next = \(shift ? "idx - 1" : "idx + 1");
                    if (next < 0) next = focusable.length - 1;
                    if (next >= focusable.length) next = 0;
                    if (current) current.blur();
                    if (focusable[next]) setTimeout(function() { focusable[next].focus(); }, 0);
                })();
                """
                evaluateJavaScript(js, completionHandler: nil)
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - WebView

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    let authToken: String?
    let connectionManager: ConnectionManager
    let homeKitBridge: HomeKitBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(connectionManager: connectionManager, homeKitBridge: homeKitBridge)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // The initial page load bypasses local cache (reloadIgnoringLocalCacheData)
        // so the HTML is always fresh after app-web deploys. Subresource requests
        // (Vite's content-hashed /assets/*) still use disk cache for fast loads.

        // Suppress autofill/suggestions to avoid WebKit warnings during focus changes
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            #if targetEnvironment(macCatalyst)
            // Use mobile content mode so the viewport matches the actual window width
            // instead of Mac Catalyst's fixed ~960px scaled viewport.
            // This allows the web app to switch to mobile layout at small window sizes.
            prefs.preferredContentMode = .mobile
            #endif
            config.defaultWebpagePreferences = prefs
        }

        // Enable Web Inspector for debugging (remove in production)
        #if DEBUG
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            // isInspectable is set after WebView creation below
        }
        #endif

        // Add message handler for native bridge
        config.userContentController.add(context.coordinator, name: "homecast")

        // Add message handler for Community mode local server bridge
        #if targetEnvironment(macCatalyst)
        if AppConfig.isCommunity {
            config.userContentController.add(context.coordinator.localNetworkBridge, name: "localServer")
        }
        #endif

        // Add message handler for the native cloud-relay WebSocket bridge.
        // Registered in both cloud and community mode — the JS adapter only
        // activates on the cloud-relay socket, and leaving the handler
        // registered means switching modes at runtime doesn't require a
        // separate wiring path.
        #if targetEnvironment(macCatalyst)
        config.userContentController.add(context.coordinator.relayWSBridge, name: "relayWs")
        #endif

        // Set platform detection flags and HomeKit bridge for the web app
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = BuildInfo.gitHash
        // Host metadata for the cloud relay handshake — JS can't read any of
        // this itself. The relay sends it as WebSocket query params so the
        // admin panel can tell which machine and build is serving a home.
        let osVersion = HostInfo.osVersion
        let deviceModel = HostInfo.deviceModel
        let hostName = HostInfo.hostName

        // The JS half of the HomeKit bridge, shared by every platform that has
        // HomeKit. It used to live only in the Catalyst branch; iPhone and iPad
        // need exactly the same object for Local Mode, and keeping one copy is
        // the only way the two stay identical.
        let homeKitBridgeScript = """
        // HomeKit bridge setup
        window.__homekit_callbacks = {};
        window.__homekit_event_handlers = [];

        window.__homekit_callback = function(payload) {
            var callbackId = payload.callbackId;
            var callback = window.__homekit_callbacks[callbackId];
            if (callback) {
                delete window.__homekit_callbacks[callbackId];
                if (payload.success) {
                    callback.resolve(payload.data);
                } else {
                    callback.reject(payload.error);
                }
            }
        };

        window.__homekit_event = function(payload) {
            window.__homekit_event_handlers.forEach(function(handler) {
                try {
                    handler(payload);
                } catch (e) {
                    console.error('[HomeKit Bridge] Event handler error:', e);
                }
            });
        };

        window.homekit = {
            _callbackIdCounter: 0,
            _generateCallbackId: function() {
                return 'hk_' + (++this._callbackIdCounter) + '_' + Date.now();
            },
            call: function(method, payload) {
                var self = this;
                return new Promise(function(resolve, reject) {
                    var callbackId = self._generateCallbackId();
                    window.__homekit_callbacks[callbackId] = { resolve: resolve, reject: reject };
                    webkit.messageHandlers.homecast.postMessage({
                        action: 'homekit',
                        method: method,
                        payload: payload || {},
                        callbackId: callbackId
                    });
                });
            },
            onEvent: function(handler) {
                window.__homekit_event_handlers.push(handler);
                return function() {
                    var idx = window.__homekit_event_handlers.indexOf(handler);
                    if (idx >= 0) window.__homekit_event_handlers.splice(idx, 1);
                };
            }
        };

        console.log('[Homecast] HomeKit bridge ready');
        """

        #if targetEnvironment(macCatalyst)
        let platformScript = """
        window.isHomecastApp = true;
        window.isHomecastMacApp = true;
        // "can BE the relay" — drives relay claim, relay duties, the relay
        // status badge and the Settings relay pane. Mac only, deliberately.
        window.isHomeKitRelayCapable = true;
        // "can serve HomeKit from this device" — the Local Mode capability.
        // Both flags are true here; on iPhone only the second one is.
        window.isHomeKitLocalCapable = true;
        window.homecastAppVersion = "\(appVersion)";
        window.homecastAppBuild = "\(appBuild)";
        window.homecastOSVersion = "\(osVersion)";
        window.homecastDeviceModel = "\(deviceModel)";
        window.homecastHostName = "\(hostName)";
        window.homecastPlatform = "macos";

        console.log('[Homecast] Mac app detected - HomeKit relay capable');

        \(homeKitBridgeScript)

        // ── Native relay WebSocket bridge ────────────────────────────────
        // The web app's ServerWebSocket can use window.NativeRelayWebSocket
        // as a drop-in replacement for `new WebSocket(url)` when
        // window.homecastNativeRelayWs === true.
        window.homecastNativeRelayWs = true;
        window.__relay_ws_sockets = {};
        window.__relay_ws_event = function(payload) {
            try {
                var sock = window.__relay_ws_sockets[payload.socketId];
                if (!sock) return;
                switch (payload.type) {
                    case 'open':
                        sock._onOpen();
                        break;
                    case 'message':
                        sock._onMessage(payload.data);
                        break;
                    case 'error':
                        sock._onError(payload.message);
                        break;
                    case 'close':
                        sock._onClose(payload.code, payload.reason, payload.wasClean);
                        break;
                }
            } catch (e) {
                console.error('[RelayWS] event dispatch failed:', e);
            }
        };
        console.log('[Homecast] Native relay WebSocket bridge ready');
        """
        #else
        let platformScript = """
        window.isHomecastApp = true;
        window.isHomecastIOSApp = true;
        // NOT isHomeKitRelayCapable: an iPhone must never claim relay duty or
        // suppress the genuine relay-offline warning. It can serve its own
        // HomeKit, which is a different and smaller claim.
        window.isHomeKitLocalCapable = true;
        window.homecastAppVersion = "\(appVersion)";
        window.homecastAppBuild = "\(appBuild)";
        window.homecastOSVersion = "\(osVersion)";
        window.homecastDeviceModel = "\(deviceModel)";
        window.homecastHostName = "\(hostName)";
        window.homecastPlatform = "ios";

        console.log('[Homecast] iOS app detected - HomeKit local capable');

        \(homeKitBridgeScript)
        """
        #endif
        config.userContentController.addUserScript(WKUserScript(
            source: platformScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // Native purchase bridge — App Store builds only. Signals the React app
        // to route Plan/Cloud upgrade flows through StoreKit instead of Stripe.
        let purchaseBootstrap = """
        window.isHomecastNativePurchaseAvailable = true;
        console.log('[Homecast] Native purchase bridge available');
        """
        config.userContentController.addUserScript(WKUserScript(
            source: purchaseBootstrap,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // iOS community mode: inject client state so web app knows it's connected to a relay
        #if !targetEnvironment(macCatalyst)
        if AppConfig.isCommunity, let addr = AppConfig.relayAddress {
            let communityScript = """
            window.__HOMECAST_COMMUNITY__ = true;
            localStorage.setItem('cookie-consent', 'granted');
            console.log('[Homecast] iOS community client — relay: \(addr)');
            """
            config.userContentController.addUserScript(WKUserScript(
                source: communityScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        #endif

        // Inject local server bridge globals (Community mode only)
        #if targetEnvironment(macCatalyst)
        if AppConfig.isCommunity {
            let localServerScript = """
            // Local server bridge — receives requests from external WebSocket clients
            // and sends responses/broadcasts back via Swift
            window.__localserver_request = function(clientId, messageJson) {
                try {
                    var msg = JSON.parse(messageJson);
                    if (window.__localserver_handler) {
                        window.__localserver_handler(clientId, msg);
                    } else {
                        console.warn('[LocalServer] No handler registered yet');
                    }
                } catch (e) {
                    console.error('[LocalServer] Failed to parse message:', e);
                }
            };

            window.__localserver_disconnect = function(clientId) {
                if (window.__localserver_disconnect_handler) {
                    window.__localserver_disconnect_handler(clientId);
                }
            };

            // Helper to send a response to a specific client
            window.__localserver_respond = function(clientId, message) {
                webkit.messageHandlers.localServer.postMessage({
                    action: 'response',
                    clientId: clientId,
                    message: typeof message === 'string' ? message : JSON.stringify(message)
                });
            };

            // Helper to broadcast a message to all clients
            window.__localserver_broadcast = function(message) {
                webkit.messageHandlers.localServer.postMessage({
                    action: 'broadcast',
                    message: typeof message === 'string' ? message : JSON.stringify(message)
                });
            };

            // Helper to handle GraphQL requests forwarded from Swift
            window.__localserver_graphql = function(clientId, bodyJson) {
                try {
                    var request = JSON.parse(bodyJson);
                    if (window.__localserver_graphql_handler) {
                        window.__localserver_graphql_handler(clientId, request);
                    } else {
                        // Handler not registered yet — retry until web app finishes loading
                        var retries = 0;
                        var retry = function() {
                            if (window.__localserver_graphql_handler) {
                                window.__localserver_graphql_handler(clientId, request);
                            } else if (retries++ < 20) {
                                setTimeout(retry, 250);
                            } else {
                                webkit.messageHandlers.localServer.postMessage({
                                    action: 'graphqlResponse',
                                    clientId: clientId,
                                    response: JSON.stringify({data: null, errors: [{message: 'Handler not ready after 5s'}]})
                                });
                            }
                        };
                        setTimeout(retry, 250);
                    }
                } catch (e) {
                    webkit.messageHandlers.localServer.postMessage({
                        action: 'graphqlResponse',
                        clientId: clientId,
                        response: JSON.stringify({data: null, errors: [{message: e.message}]})
                    });
                }
            };

            // Helper to handle HTTP requests (REST, MCP, OAuth) forwarded from Swift
            window.__localserver_http = function(clientId, requestJson) {
                try {
                    var request = JSON.parse(requestJson);
                    if (window.__localserver_http_handler) {
                        window.__localserver_http_handler(clientId, request);
                    } else {
                        var retries = 0;
                        var retry = function() {
                            if (window.__localserver_http_handler) {
                                window.__localserver_http_handler(clientId, request);
                            } else if (retries++ < 20) {
                                setTimeout(retry, 250);
                            } else {
                                webkit.messageHandlers.localServer.postMessage({
                                    action: 'httpResponse',
                                    clientId: clientId,
                                    response: JSON.stringify({error: 'HTTP handler not ready after 5s'})
                                });
                            }
                        };
                        setTimeout(retry, 250);
                    }
                } catch (e) {
                    webkit.messageHandlers.localServer.postMessage({
                        action: 'httpResponse',
                        clientId: clientId,
                        response: JSON.stringify({error: e.message})
                    });
                }
            };

            console.log('[Homecast] Local server bridge ready');
            """
            config.userContentController.addUserScript(WKUserScript(
                source: localServerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        #endif

        // Sync auth state with WebView at document start
        if let token = authToken {
            // Logged in - inject token
            let tokenScript = "localStorage.setItem('homekit-token', '\(token)'); console.log('[Homecast] Token pre-injected');"
            let script = WKUserScript(
                source: tokenScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        } else {
            // Not logged in - clear any stale token in WebView
            let clearScript = "localStorage.removeItem('homekit-token'); console.log('[Homecast] Token cleared - not logged in');"
            let script = WKUserScript(
                source: clearScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        // Watch for dark/light background changes and sync the WebView background
        // color so CSS backdrop-blur doesn't pick up white at viewport edges.
        // Observes the root div's class for 'bg-black' (set by MainLayout when
        // there's a dark background image). Runs on Mac AND iOS: on iOS the
        // webview backdrop shows through at the safe areas (landscape notch),
        // and without this it stayed hardcoded black in light mode.
        config.userContentController.addUserScript(WKUserScript(source: """
        (function() {
            var last = null, pending = false;
            function check() {
                var isDark = !!document.querySelector('.bg-black');
                if (isDark !== last) {
                    last = isDark;
                    window.webkit.messageHandlers.homecast.postMessage({ action: 'backgroundDark', isDark: isDark });
                }
            }
            new MutationObserver(function() {
                if (!pending) {
                    pending = true;
                    requestAnimationFrame(function() { pending = false; check(); });
                }
            }).observe(document.body || document.documentElement, {
                childList: true, subtree: true, attributes: true, attributeFilter: ['class']
            });
            check();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // iOS text selection prevention is handled by CSS (html.ios-app in index.css
        // sets user-select:none and -webkit-touch-callout:none). Do NOT use
        // isTextInteractionEnabled=false — it suppresses the CSS :active pseudo-class,
        // preventing touch press feedback on buttons and menu items.

        // Use a reasonable initial frame to avoid CoreGraphics NaN errors
        let webView = FocusableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.authToken = authToken
        context.coordinator.webView = webView
        // Watch for the connected-but-not-executing state; see the watchdog.
        context.coordinator.beginLivenessWatch()

        // Enable Safari Web Inspector for debugging
        #if DEBUG
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        // Attach the HomeKit bridge on every platform that has HomeKit: the Mac
        // uses it to serve as the relay, iPhone/iPad for Local Mode.
        homeKitBridge.attach(webView: webView)

        #if targetEnvironment(macCatalyst)
        // Attach native relay WebSocket bridge
        context.coordinator.relayWSBridge.attach(webView: webView)

        // Attach local network bridge for Community mode (external WebSocket clients)
        // Bridge attachment for Community mode happens in didFinish navigation delegate
        #endif

        // Attach StoreKit purchase bridge (Mac Catalyst + iOS — App Store builds)
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            PurchaseBridge.shared.attach(webView: webView)
        }

        #if targetEnvironment(macCatalyst)
        // Observe WebView frame changes to sync actual window width to JavaScript.
        // Mac Catalyst scales the CSS viewport, so window.innerWidth doesn't match
        // the real window frame. We post the UIKit frame width so the web app can
        // switch to mobile layout at small window sizes.
        context.coordinator.startFrameObserver(for: webView)

        // On Mac, disable content inset adjustment for full-bleed layout
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        // Disable pinch-to-zoom — the web app handles its own layout
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        // Allow the web app to control the background color behind the page
        // via the "backgroundDark" bridge message. Default black since most
        // users have dark backgrounds.
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        #else
        // On iOS, set mobile user agent so website renders mobile layout
        let iOSVersion = UIDevice.current.systemVersion
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(iOSVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(iOSVersion) Mobile/15E148 Safari/604.1"
        // Disable automatic content inset adjustment — CSS env(safe-area-inset-*) handles safe areas
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        // Disable pinch-to-zoom
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        // Transparent background so the web app controls the color
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        #endif

        NSLog("[Homecast] Loading URL: %@", url.absoluteString)
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let oldToken = context.coordinator.authToken

        if oldToken != authToken {
            if let token = authToken {
                // Token appeared - check if this was from WebView login or keychain restore
                if context.coordinator.webViewInitiatedLogin {
                    // WebView initiated - frontend already has token and is navigating
                    print("[WebView] Token synced (WebView-initiated login)")
                    context.coordinator.webViewInitiatedLogin = false
                } else {
                    // Keychain restore - inject token and notify frontend via storage event
                    let js = """
                    localStorage.setItem('homekit-token', '\(token)');
                    console.log('[Homecast] Token restored from keychain');
                    window.dispatchEvent(new StorageEvent('storage', { key: 'homekit-token', newValue: '\(token)' }));
                    """
                    webView.evaluateJavaScript(js, completionHandler: nil)
                    print("[WebView] Token injected from keychain restore")
                }
            } else {
                // Token was cleared (sign out)
                if context.coordinator.webViewInitiatedLogout {
                    // WebView initiated - frontend already cleared and is navigating
                    print("[WebView] Token cleared (WebView-initiated logout)")
                    context.coordinator.webViewInitiatedLogout = false
                } else {
                    // Mac app sign out - clear localStorage and reload to login
                    let js = """
                    localStorage.removeItem('homekit-token');
                    console.log('[Homecast] Signed out from Mac app');
                    """
                    let loginURL = "\(AppConfig.webBaseURL)/login"
                    webView.evaluateJavaScript(js) { [weak webView] _, _ in
                        // Force load login page after clearing token
                        if let url = URL(string: loginURL) {
                            webView?.load(URLRequest(url: url))
                        }
                    }
                    print("[WebView] Loading login page (Mac-initiated sign out)")
                }
            }
        }
        context.coordinator.authToken = authToken
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var authToken: String?
        weak var webView: WKWebView?
        let connectionManager: ConnectionManager
        private let homeKitBridge: HomeKitBridge
        private var reloadTimer: Timer?
        private var networkMonitor: NWPathMonitor?
        private var pendingReloadURL: URL?
        private var isShowingErrorPage = false

        // Community mode: bridge for external WebSocket clients
        let localNetworkBridge = LocalNetworkBridge()

        // Cloud mode: native WebSocket client that replaces the browser
        // WebSocket inside the WKWebView for the api.homecast.cloud relay
        // connection. Gives us real WS ping/pong, NWPathMonitor-driven
        // teardown, and lifecycle events shipped through LogShipper.
        #if targetEnvironment(macCatalyst)
        let relayWSBridge = RelayWebSocketBridge()
        #endif

        // Track whether auth changes were initiated by WebView (vs Mac app)
        var webViewInitiatedLogin = false
        // When true, the "backgroundDark" fallback (black/white) is suppressed
        // because Dashboard is sending the precise "backgroundColor" hex color.
        private var hasExplicitBackgroundColor = false
        var webViewInitiatedLogout = false
        private var frameObservation: NSKeyValueObservation?
        private var lastReportedWidth: Int = 0

        init(connectionManager: ConnectionManager, homeKitBridge: HomeKitBridge) {
            self.connectionManager = connectionManager
            self.homeKitBridge = homeKitBridge
            super.init()

            // Listen for reload notification
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleReload),
                name: .reloadWebView,
                object: nil
            )

            // Listen for hard refresh notification
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHardRefresh),
                name: .hardRefreshWebView,
                object: nil
            )

            // Listen for environment change (staging <-> production)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleEnvironmentChange),
                name: .environmentDidChange,
                object: nil
            )

            // Auto-reload WebView every 24 hours
            self.reloadTimer = Timer.scheduledTimer(
                withTimeInterval: 24 * 60 * 60,
                repeats: true
            ) { [weak self] _ in
                self?.handleAutoReload()
            }
        }

        deinit {
            reloadTimer?.invalidate()
            livenessTimer?.invalidate()
            stallTimer?.invalidate()
            networkMonitor?.cancel()
        }

        private func handleAutoReload() {
            print("[WebView] Auto-reloading (24h timer)")
            DispatchQueue.main.async { [weak self] in
                self?.webView?.reloadFromOrigin()
            }
        }

        /// Observe the WKWebView's bounds and post the actual UIKit width to JavaScript.
        /// Mac Catalyst scales the CSS viewport, so window.innerWidth doesn't reflect
        /// the real frame width. This lets the web app switch to mobile layout.
        func startFrameObserver(for webView: WKWebView) {
            frameObservation = webView.observe(\.bounds, options: [.new, .initial]) { [weak self] wv, _ in
                let width = Int(wv.bounds.width)
                guard width != self?.lastReportedWidth, width > 0 else { return }
                self?.lastReportedWidth = width
                let js = "window.__nativeWidth = \(width); console.log('[Homecast] nativeWidth=' + \(width) + ' innerWidth=' + window.innerWidth); window.dispatchEvent(new Event('nativeResize'))"
                wv.evaluateJavaScript(js, completionHandler: nil)
                print("[Homecast] Frame width: \(width)pt")
            }
        }

        // MARK: - Main-thread stall detector

        /// A main-thread timer fires late by exactly as long as the thread was
        /// blocked. That is the cheapest way to measure the one thing we cannot
        /// see from the server: whether the app's main thread — which is what
        /// hands the WebView each request — was unavailable.
        ///
        /// Recorded here so the next occurrence of the stuck-relay fault arrives
        /// with its cause attached, rather than being inferred from the outside
        /// as it was the first time.
        private static let stallTickSeconds: TimeInterval = 1.0
        /// Lateness worth reporting. Below this is ordinary scheduling jitter.
        private static let stallReportThreshold: TimeInterval = 3.0
        private var stallTimer: Timer?
        private var lastStallTick: Date?
        private(set) var worstStallSeconds: TimeInterval = 0
        private var lastStallAt: Date?
        private var lastStallDuration: TimeInterval = 0
        private var lastStallReportAt = Date.distantPast
        /// At most one stall warning per this interval.
        private static let stallReportIntervalSeconds: TimeInterval = 60

        /// How badly the main thread stalled inside the last liveness window.
        /// Used to tell "the page is stuck" apart from "the main thread was busy",
        /// which look identical from the probe's point of view.
        private func recentStallSeconds() -> TimeInterval {
            guard let at = lastStallAt,
                  Date().timeIntervalSince(at) <= Coordinator.livenessTimeoutSeconds * 2 else { return 0 }
            return lastStallDuration
        }

        private func startStallDetector() {
            lastStallTick = Date()
            stallTimer?.invalidate()
            stallTimer = Timer.scheduledTimer(withTimeInterval: Coordinator.stallTickSeconds,
                                              repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let now = Date()
                defer { self.lastStallTick = now }
                guard let last = self.lastStallTick else { return }

                let late = now.timeIntervalSince(last) - Coordinator.stallTickSeconds
                guard late >= Coordinator.stallReportThreshold else { return }

                self.worstStallSeconds = max(self.worstStallSeconds, late)
                self.lastStallAt = now
                self.lastStallDuration = late

                // Rate limited: a main thread stalling constantly would otherwise
                // ship a warning per second, which costs money and makes the very
                // problem it is reporting worse.
                if now.timeIntervalSince(self.lastStallReportAt) >= Coordinator.stallReportIntervalSeconds {
                    self.lastStallReportAt = now
                    Log.warning("Main thread stalled",
                                category: "watchdog",
                                metadata: ["seconds": String(format: "%.1f", late),
                                           "worstSeconds": String(format: "%.1f", self.worstStallSeconds)])
                }
            }
        }

        // MARK: - WebView liveness watchdog

        /// Seconds without a JS reply before the WebView is considered stuck.
        private static let livenessTimeoutSeconds: TimeInterval = 25
        /// How often to ask.
        private static let livenessIntervalSeconds: TimeInterval = 20
        private var livenessTimer: Timer?
        private var livenessOutstandingSince: Date?
        private var livenessReloads = 0
        /// Reloads in a row before we stop trying. Past this the page is not
        /// coming back and looping only guarantees nothing ever runs.
        private static let maxConsecutiveReloads = 3

        /// A native call outstanding this long means the bridge has stopped
        /// answering, not that a device is slow.
        ///
        /// Comfortably past everything with a real ceiling: Swift bounds a
        /// characteristic write at 10s, the web app bounds any bridge call at
        /// 20s, and the cloud gives up on a request at 30s. Anything still in
        /// flight past 45s is not late, it is gone.
        private static let bridgeWedgeSeconds: TimeInterval = 45
        private var bridgeReloads = 0
        /// Set once we stop reloading for a wedged bridge, so the give-up notice
        /// is logged once rather than every tick.
        private var bridgeGaveUp = false

        /// Consecutive liveness checks skipped because the main thread was
        /// stalled. Deferring is meant to ride out a momentary stall.
        private var stallDeferrals = 0
        private static let maxStallDeferrals = 3

        /// Watch for the state where the relay is connected but not working.
        ///
        /// The relay's cloud WebSocket is handled natively, so the socket stays up
        /// and heartbeats keep flowing regardless of what has gone wrong above it.
        /// The server therefore sees a healthy relay while every request it
        /// forwards times out — observed in production for minutes at a stretch,
        /// with reads and writes failing alike.
        ///
        /// There are two ways to reach that state and they need different tests:
        ///
        /// - **The page stopped executing.** Ask it a question only a running page
        ///   can answer (`evaluateJavaScript`), and reload when it stops answering.
        ///
        /// - **The page is fine but the bridge beneath it stopped answering.** The
        ///   JS probe cannot see this — it comes back instantly, because JavaScript
        ///   is not what broke. The 2026-08-09 occurrence was this one: pure-JS
        ///   actions replied in 32ms for the whole twelve-minute outage while every
        ///   HomeKit-backed action timed out. So also ask `BridgeLoad` how long its
        ///   oldest native call has been outstanding.
        ///
        /// Reloading is the cure for both, and it works remotely too — `app.reload`
        /// cleared the bridge fault twice in production, answering in ~32ms and
        /// restoring service about three seconds later.
        func beginLivenessWatch() {
            startLivenessWatchdog()
            startStallDetector()
        }

        /// Everything we know about why the page might be stuck, for the report.
        private func bridgeAndStallMetadata() -> [String: String] {
            var meta = BridgeLoad.shared.snapshot()
            meta["reloads"] = String(livenessReloads)
            meta["worstMainThreadStallSeconds"] = String(format: "%.1f", worstStallSeconds)
            meta["recentMainThreadStallSeconds"] = String(format: "%.1f", recentStallSeconds())
            return meta
        }

        private func startLivenessWatchdog() {
            livenessTimer?.invalidate()
            livenessTimer = Timer.scheduledTimer(withTimeInterval: Coordinator.livenessIntervalSeconds,
                                                 repeats: true) { [weak self] _ in
                self?.checkWebViewLiveness()
            }
        }

        private func stopLivenessWatchdog() {
            livenessTimer?.invalidate()
            livenessTimer = nil
            livenessOutstandingSince = nil
        }

        private func checkWebViewLiveness() {
            guard let webView = webView else { return }

            // Check the bridge before the page. The page can be executing
            // perfectly while the native bridge underneath it has stopped
            // answering — observed in production, with pure-JS actions replying
            // in 32ms while every HomeKit-backed one timed out for twelve
            // minutes. The JS probe below is blind to that by construction: it
            // asks whether JavaScript runs, and JavaScript was never what broke.
            if let wedged = BridgeLoad.shared.oldestWedgeable(),
               wedged.seconds >= Coordinator.bridgeWedgeSeconds {
                reloadForWedgedBridge(webView, method: wedged.method, seconds: wedged.seconds)
                return
            }
            bridgeReloads = 0
            bridgeGaveUp = false

            // A probe is already outstanding: if it has been too long, the page is
            // stuck. Reload rather than pile up more probes.
            if let since = livenessOutstandingSince {
                if Date().timeIntervalSince(since) >= Coordinator.livenessTimeoutSeconds {
                    livenessOutstandingSince = nil

                    // The probe's completion handler is delivered on the main
                    // thread, so a blocked main thread looks exactly like a stuck
                    // page. Reloading would not fix that — it needs the main
                    // thread too — and would destroy in-flight work for nothing.
                    // Report it and leave the page alone.
                    if recentStallSeconds() >= Coordinator.livenessTimeoutSeconds * 0.5 {
                        stallDeferrals += 1
                        if stallDeferrals <= Coordinator.maxStallDeferrals {
                            Log.warning("WebView probe unanswered, but the main thread was stalled — not reloading (\(stallDeferrals)/\(Coordinator.maxStallDeferrals))",
                                        category: "watchdog",
                                        metadata: bridgeAndStallMetadata())
                            return
                        }

                        // Deferring was meant to ride out a momentary stall. A
                        // main thread that is still stalling several windows
                        // later is not momentary, and holding off indefinitely
                        // leaves the relay dead — the exact outcome the deferral
                        // was there to avoid. Fall through and reload.
                        Log.error("WebView probe unanswered through \(Coordinator.maxStallDeferrals) main-thread stalls — reloading anyway",
                                  category: "watchdog",
                                  metadata: bridgeAndStallMetadata())
                    }

                    // Reloading has not helped: stop rather than loop forever.
                    // A relay reloading every 25s is worse than a stuck one — it
                    // never finishes starting, so no automation ever runs.
                    guard livenessReloads < Coordinator.maxConsecutiveReloads else {
                        Log.error("WebView still unresponsive after \(livenessReloads) reloads — giving up until the app is restarted",
                                  category: "watchdog",
                                  metadata: bridgeAndStallMetadata())
                        stopLivenessWatchdog()
                        return
                    }

                    livenessReloads += 1
                    print("[Watchdog] WebView unresponsive for \(Int(Coordinator.livenessTimeoutSeconds))s — reloading (count: \(livenessReloads))")
                    Log.warning("WebView unresponsive — reloading",
                                category: "watchdog",
                                metadata: bridgeAndStallMetadata())
                    webView.reloadFromOrigin()
                }
                return
            }

            livenessOutstandingSince = Date()
            // Deliberately trivial: this measures whether JS runs at all, not
            // whether the app's own state is healthy.
            webView.evaluateJavaScript("1") { [weak self] _, _ in
                // Any answer at all — value or error — proves JS executed.
                guard let self = self else { return }
                self.livenessOutstandingSince = nil
                // Recovered: only consecutive failures should count towards the cap.
                self.livenessReloads = 0
                self.stallDeferrals = 0
            }
        }

        /// Reload the page because the native bridge stopped answering.
        ///
        /// Reloading is the cure we have evidence for: in the two occurrences on
        /// record the relay started serving again about three seconds after its
        /// page was reloaded, having served nothing for the twelve minutes before.
        private func reloadForWedgedBridge(_ webView: WKWebView, method: String, seconds: TimeInterval) {
            var meta = bridgeAndStallMetadata()
            meta["wedgedMethod"] = method
            meta["wedgedSeconds"] = String(format: "%.1f", seconds)

            // Reloading has not helped: stop rather than loop forever. The
            // watchdog keeps running, so if the bridge frees up on its own the
            // counter resets and this arms again.
            guard bridgeReloads < Coordinator.maxConsecutiveReloads else {
                if !bridgeGaveUp {
                    bridgeGaveUp = true
                    Log.error("HomeKit bridge still wedged after \(bridgeReloads) reloads — giving up until it frees or the app is restarted",
                              category: "watchdog",
                              metadata: meta)
                }
                return
            }

            bridgeReloads += 1
            print("[Watchdog] HomeKit bridge wedged on \(method) for \(Int(seconds))s — reloading (count: \(bridgeReloads))")
            Log.warning("HomeKit bridge wedged — reloading",
                        category: "watchdog",
                        metadata: meta)

            // Before the reload, not after: the calls in flight answer into a
            // page that is about to stop existing, and carrying their age over
            // would make the new page look wedged on arrival.
            BridgeLoad.shared.abandonInFlight()
            // Any probe outstanding against the old page is void. Left set, it
            // would age past the liveness timeout and earn a second reload for
            // a page that has already been replaced.
            livenessOutstandingSince = nil
            webView.reloadFromOrigin()
        }

        @objc private func handleReload() {
            print("[WebView] Reloading page (Cmd+R)")
            if isShowingErrorPage, let url = pendingReloadURL {
                isShowingErrorPage = false
                pendingReloadURL = nil
                stopNetworkMonitor()
                webView?.load(URLRequest(url: url))
            } else {
                webView?.reloadFromOrigin()
            }
        }

        @objc private func handleEnvironmentChange() {
            print("[WebView] Environment changed to \(AppConfig.isStaging ? "staging" : "production"), reloading")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Clear stale auth from the previous environment
                self.webViewInitiatedLogout = true
                self.connectionManager.signOut()
                if let url = URL(string: "\(AppConfig.webBaseURL)/login") {
                    self.webView?.load(URLRequest(url: url))
                }
            }
        }

        @objc private func handleHardRefresh() {
            print("[WebView] Hard refresh - clearing cache")
            guard let webView = webView else { return }

            // Clear all website data (cache, cookies, etc.) for this domain
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
                WKWebsiteDataTypeFetchCache
            ])

            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                let homecastRecords = records.filter { record in
                    record.displayName.contains("homecast")
                }
                if homecastRecords.isEmpty {
                    print("[WebView] No cached data found, reloading anyway")
                } else {
                    print("[WebView] Clearing \(homecastRecords.count) cache records")
                }

                dataStore.removeData(ofTypes: dataTypes, for: homecastRecords) {
                    print("[WebView] Cache cleared, reloading page")
                    DispatchQueue.main.async {
                        if let url = URL(string: "\(AppConfig.webBaseURL)/login") {
                            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
                        }
                    }
                }
            }
        }

        // Handle messages from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "homecast",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else {
                return
            }

            print("[WebView] Received message: \(action)")

            switch action {
            case "login":
                guard let token = body["token"] as? String else {
                    print("[WebView] Login action missing token")
                    return
                }
                print("[WebView] Received login token from web")
                // Mark as WebView-initiated so updateUIView doesn't interfere with frontend navigation
                self.webViewInitiatedLogin = true
                Task { @MainActor in
                    do {
                        try await connectionManager.authenticateWithToken(token)
                        self.authToken = token
                    } catch {
                        print("[WebView] Failed to authenticate with token: \(error)")
                        self.webViewInitiatedLogin = false  // Reset on failure
                    }
                }
            case "logout":
                print("[WebView] Received logout from web")
                // Mark as WebView-initiated so updateUIView doesn't interfere with frontend navigation
                self.webViewInitiatedLogout = true
                // Show "Change install type" button on login page
                Task { @MainActor in
                    connectionManager.signOut()
                }
            case "authSuccess":
                print("[WebView] User authenticated")
            case "resetMode":
                // Reset mode selection — stop server, clean up, show mode selector
                print("[WebView] Reset mode selection")
                LocalHTTPServer.shared?.stop()
                LocalHTTPServer.shared = nil
                // Clear ALL web data (localStorage, cookies, cache) across all origins
                // THEN show mode selector — ensures no stale data when user picks a mode
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                ) {
                    DispatchQueue.main.async {
                        print("[WebView] Web data cleared, showing mode selector")
                        UserDefaults.standard.set(false, forKey: "com.homecast.modeSelected")
                        UserDefaults.standard.set(false, forKey: "com.homecast.communityMode")
                        AppConfig.relayAddress = nil
                        NotificationCenter.default.post(name: .environmentDidChange, object: nil)
                    }
                }
            case "copy":
                if let text = body["text"] as? String {
                    let textCopy = String(text)
                    Task { @MainActor in
                        UIPasteboard.general.string = textCopy
                    }
                }
            case "backgroundDark":
                // Coarse fallback (black/white) — only apply when Dashboard
                // hasn't sent a precise color via "backgroundColor".
                guard !hasExplicitBackgroundColor else { break }
                let isDark = body["isDark"] as? Bool ?? false
                Task { @MainActor in
                    self.webView?.backgroundColor = isDark ? .black : .white
                    self.webView?.scrollView.backgroundColor = isDark ? .black : .white
                }
            case "backgroundColor":
                if let hex = body["color"] as? String {
                    hasExplicitBackgroundColor = true
                    Task { @MainActor in
                        let color = Self.colorFromHex(hex)
                        self.webView?.backgroundColor = color
                        self.webView?.scrollView.backgroundColor = color
                    }
                } else {
                    // Dashboard unmounted — fall back to backgroundDark
                    hasExplicitBackgroundColor = false
                }
            case "openUrl":
                if let urlString = body["url"] as? String,
                   let url = URL(string: urlString) {
                    Task { @MainActor in
                        await UIApplication.shared.open(url)
                    }
                }
            case "homekit":
                // Route HomeKit bridge calls. Available on iPhone/iPad as well
                // as the Mac — an iOS device with Home access serves its own
                // HomeKit in Local Mode.
                let method = body["method"] as? String
                let payload = body["payload"] as? [String: Any]
                let callbackId = body["callbackId"] as? String
                Task { @MainActor in
                    self.homeKitBridge.handle(method: method, payload: payload, callbackId: callbackId)
                }
            case "purchase":
                // Route StoreKit IAP calls (App Store builds)
                let method = body["method"] as? String
                let payload = body["payload"] as? [String: Any]
                let callbackId = body["callbackId"] as? String
                if #available(iOS 15.0, macCatalyst 15.0, *) {
                    Task { @MainActor in
                        PurchaseBridge.shared.handle(method: method, payload: payload, callbackId: callbackId)
                    }
                }
            case "file":
                // Handle file operations
                let method = body["method"] as? String
                let payload = body["payload"] as? [String: Any]
                let callbackId = body["callbackId"] as? String
                Task { @MainActor in
                    self.handleFileOperation(method: method, payload: payload, callbackId: callbackId)
                }
            case "mqtt":
                // Handle MQTT broker management from the web app
                #if targetEnvironment(macCatalyst)
                if let method = body["method"] as? String,
                   let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                   let bridge = appDelegate.mqttBridge {
                    let callbackId = body["callbackId"] as? String ?? ""
                    switch method {
                    case "getBrokers":
                        let brokers = bridge.getBrokers()
                        if let data = try? JSONSerialization.data(withJSONObject: brokers),
                           let json = String(data: data, encoding: .utf8) {
                            sendMQTTCallback(callbackId: callbackId, json: json)
                        }

                    case "addBroker":
                        if let homeId = body["homeId"] as? String,
                           let host = body["host"] as? String {
                            let config = MQTTBrokerConfig(
                                id: UUID().uuidString,
                                name: body["name"] as? String ?? host,
                                host: host,
                                port: UInt16(body["port"] as? Int ?? 1883),
                                username: body["username"] as? String,
                                password: body["password"] as? String,
                                useTLS: body["useTLS"] as? Bool ?? false,
                                topicPrefix: body["topicPrefix"] as? String ?? "homecast",
                                haDiscovery: body["haDiscovery"] as? Bool ?? true,
                                haDiscoveryPrefix: body["haDiscoveryPrefix"] as? String ?? "homeassistant",
                                enabled: true
                            )
                            let added = bridge.addBroker(config, forHome: homeId)
                            if let data = try? JSONEncoder().encode(added),
                               let json = String(data: data, encoding: .utf8) {
                                sendMQTTCallback(callbackId: callbackId, json: json)
                            }
                        }

                    case "removeBroker":
                        if let homeId = body["homeId"] as? String,
                           let brokerId = body["brokerId"] as? String {
                            bridge.removeBroker(id: brokerId, forHome: homeId)
                            let js = "window.__mqtt_callback && window.__mqtt_callback('\(callbackId)', '{\"ok\":true}');"
                            webView?.evaluateJavaScript(js, completionHandler: nil)
                        }

                    case "updateBroker":
                        if let homeId = body["homeId"] as? String,
                           let brokerId = body["brokerId"] as? String,
                           let updates = body["updates"] as? [String: Any] {
                            bridge.updateBroker(id: brokerId, forHome: homeId, updates: updates)
                            let js = "window.__mqtt_callback && window.__mqtt_callback('\(callbackId)', '{\"ok\":true}');"
                            webView?.evaluateJavaScript(js, completionHandler: nil)
                        }

                    case "testConnection":
                        if let host = body["host"] as? String {
                            let port = UInt16(body["port"] as? Int ?? 1883)
                            bridge.testConnection(
                                host: host,
                                port: port,
                                username: body["username"] as? String,
                                password: body["password"] as? String,
                                useTLS: body["useTLS"] as? Bool ?? false
                            ) { [weak self] success, error in
                                var result: [String: Any] = ["success": success]
                                if let error = error { result["error"] = error }
                                if let data = try? JSONSerialization.data(withJSONObject: result),
                                   let json = String(data: data, encoding: .utf8) {
                                    self?.sendMQTTCallback(callbackId: callbackId, json: json)
                                }
                            }
                        }

                    default:
                        break
                    }
                }
                #endif
            case "relayStatus":
                let connectionState = body["connectionState"] as? String ?? "disconnected"
                let relayStatus = body["relayStatus"] as? NSNumber
                NotificationCenter.default.post(
                    name: .relayStatusDidChange,
                    object: nil,
                    userInfo: [
                        "connectionState": connectionState,
                        "relayStatus": relayStatus as Any
                    ]
                )
            case "retry":
                if let url = pendingReloadURL {
                    print("[WebView] Manual retry from error page")
                    isShowingErrorPage = false
                    pendingReloadURL = nil
                    stopNetworkMonitor()
                    webView?.load(URLRequest(url: url))
                }
            default:
                print("[WebView] Unknown action: \(action)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // When the error page HTML finishes loading, didFinish fires.
            // Don't stop the network monitor — we need it to detect restoration.
            if isShowingErrorPage { return }
            stopNetworkMonitor()

            // Attach local network bridge for Community mode (once, on first load)
            #if targetEnvironment(macCatalyst)
            if AppConfig.isCommunity && localNetworkBridge.webView == nil {
                if let server = LocalHTTPServer.shared {
                    // Set MQTT bridge before attaching (attach forwards it to WebView)
                    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                        localNetworkBridge.mqttBridge = appDelegate.mqttBridge
                    }
                    localNetworkBridge.attach(webView: webView, server: server)
                }
            }
            #endif

            // Ensure WebView has keyboard focus (only if not already)
            if !webView.isFirstResponder {
                DispatchQueue.main.async {
                    guard !webView.isFirstResponder else { return }
                    webView.becomeFirstResponder()
                }
            }

            // Always inject auth token after page loads (including reloads)
            guard let token = authToken else { return }

            let js = """
            (function() {
                var currentToken = localStorage.getItem('homekit-token');
                var newToken = '\(token)';
                if (currentToken !== newToken) {
                    localStorage.setItem('homekit-token', newToken);
                    console.log('[Homecast] Auth token injected/updated');
                    window.dispatchEvent(new StorageEvent('storage', { key: 'homekit-token', newValue: newToken }));
                } else {
                    console.log('[Homecast] Auth token already set');
                }
            })();
            """

            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("[WebView] Failed to inject token: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebView] Navigation failed: \(error.localizedDescription)")
            if let url = webView.url {
                print("[WebView] Failed URL: \(url)")
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WKWebView's content process was terminated by the OS (memory pressure, etc.)
            // The WebView shows a blank white screen until we reload.
            print("[WebView] Content process terminated, reloading...")
            if let url = webView.url {
                webView.load(URLRequest(url: url))
            } else {
                let baseURL = URL(string: "\(AppConfig.webBaseURL)/portal")!
                webView.load(URLRequest(url: baseURL))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            print("[WebView] Provisional navigation failed: \(nsError.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")

            let networkErrorCodes: Set<Int> = [
                NSURLErrorNotConnectedToInternet,   // -1009
                NSURLErrorNetworkConnectionLost,     // -1005
                NSURLErrorCannotFindHost,            // -1003
                NSURLErrorCannotConnectToHost,       // -1004
                NSURLErrorTimedOut,                  // -1001
                NSURLErrorDNSLookupFailed,           // -1006
                NSURLErrorSecureConnectionFailed,    // -1200
            ]

            if nsError.domain == NSURLErrorDomain && networkErrorCodes.contains(nsError.code) {
                let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                pendingReloadURL = URL(string: failingURL ?? "\(AppConfig.webBaseURL)/login")
                isShowingErrorPage = true
                loadErrorPage(in: webView)
                startNetworkMonitor()
            }
        }

        private func loadErrorPage(in webView: WKWebView) {
            #if targetEnvironment(macCatalyst)
            let hintHTML = "<p class=\"hint\">or press &#8984;R to retry</p>"
            #else
            let hintHTML = "<button class=\"retry-btn\" onclick=\"webkit.messageHandlers.homecast.postMessage({action:'retry'})\">Tap to Retry</button>"
            #endif

            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              * { margin: 0; padding: 0; box-sizing: border-box; }
              body {
                background: #000; color: #fff;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                display: flex; align-items: center; justify-content: center;
                height: 100vh; text-align: center;
                -webkit-user-select: none;
              }
              .container { max-width: 360px; padding: 24px; }
              .icon { font-size: 48px; margin-bottom: 16px; opacity: 0.7; }
              h1 { font-size: 20px; font-weight: 600; margin-bottom: 8px; }
              p { font-size: 14px; color: rgba(255,255,255,0.5); line-height: 1.5; }
              .spinner {
                margin: 24px auto 0; width: 20px; height: 20px;
                border: 2px solid rgba(255,255,255,0.15);
                border-top-color: rgba(255,255,255,0.5);
                border-radius: 50%;
                animation: spin 0.8s linear infinite;
              }
              .hint { margin-top: 16px; font-size: 12px; color: rgba(255,255,255,0.3); }
              .retry-btn {
                margin-top: 20px; padding: 12px 32px;
                background: rgba(255,255,255,0.12); color: rgba(255,255,255,0.7);
                border: 1px solid rgba(255,255,255,0.2); border-radius: 10px;
                font-size: 15px; font-weight: 500;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                -webkit-tap-highlight-color: transparent;
              }
              .retry-btn:active { background: rgba(255,255,255,0.2); }
              @keyframes spin { to { transform: rotate(360deg); } }
            </style>
            </head>
            <body>
              <div class="container">
                <div class="icon">&#127760;</div>
                <h1>No Internet Connection</h1>
                <p>Homecast will reconnect automatically when your connection is restored.</p>
                <div class="spinner"></div>
                \(hintHTML)
              </div>
            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        private func startNetworkMonitor() {
            stopNetworkMonitor()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied, let self = self else { return }
                // Small delay — NWPathMonitor can report .satisfied when WiFi
                // associates but before the internet route is actually usable.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let url = self.pendingReloadURL, let webView = self.webView else { return }
                    print("[WebView] Network restored, reloading \(url)")
                    self.isShowingErrorPage = false
                    self.pendingReloadURL = nil
                    self.stopNetworkMonitor()
                    webView.load(URLRequest(url: url))
                }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            networkMonitor = monitor
            print("[WebView] Network monitor started, waiting for connectivity")
        }

        private func stopNetworkMonitor() {
            networkMonitor?.cancel()
            networkMonitor = nil
        }

        // MARK: - File Operations

        private func handleFileOperation(method: String?, payload: [String: Any]?, callbackId: String?) {
            guard let method = method, let callbackId = callbackId else {
                print("[WebView] File operation missing method or callbackId")
                return
            }

            print("[WebView] File operation: \(method)")

            switch method {
            case "select":
                #if targetEnvironment(macCatalyst)
                selectFileWithNSOpenPanel(payload: payload, callbackId: callbackId)
                #else
                // iOS - use UIDocumentPickerViewController
                selectFileWithDocumentPicker(payload: payload, callbackId: callbackId)
                #endif
            default:
                sendFileCallback(callbackId: callbackId, error: "Unknown file method: \(method)")
            }
        }

        #if targetEnvironment(macCatalyst)
        private func selectFileWithNSOpenPanel(payload: [String: Any]?, callbackId: String) {
            // Get allowed file types from payload
            let accept = payload?["accept"] as? [String] ?? ["public.image"]
            let maxSizeBytes = payload?["maxSize"] as? Int ?? (10 * 1024 * 1024) // Default 10MB

            // Use AppKit via dynamic loading for NSOpenPanel
            guard let nsOpenPanelClass = NSClassFromString("NSOpenPanel") as? NSObject.Type else {
                sendFileCallback(callbackId: callbackId, error: "NSOpenPanel not available")
                return
            }

            let panel = nsOpenPanelClass.perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject
            guard let openPanel = panel else {
                sendFileCallback(callbackId: callbackId, error: "Failed to create open panel")
                return
            }

            // Configure panel
            openPanel.perform(NSSelectorFromString("setCanChooseFiles:"), with: true)
            openPanel.perform(NSSelectorFromString("setCanChooseDirectories:"), with: false)
            openPanel.perform(NSSelectorFromString("setAllowsMultipleSelection:"), with: false)
            openPanel.perform(NSSelectorFromString("setMessage:"), with: "Select a file")

            // Set allowed content types
            if #available(macCatalyst 14.0, *) {
                var contentTypes: [UTType] = []
                for mimeType in accept {
                    if mimeType == "image/*" || mimeType == "public.image" {
                        contentTypes.append(UTType.image)
                    } else if mimeType == "image/jpeg" {
                        contentTypes.append(UTType.jpeg)
                    } else if mimeType == "image/png" {
                        contentTypes.append(UTType.png)
                    } else if mimeType == "image/webp" {
                        contentTypes.append(UTType.webP)
                    } else if let utType = UTType(mimeType: mimeType) {
                        contentTypes.append(utType)
                    }
                }
                if !contentTypes.isEmpty {
                    openPanel.setValue(contentTypes, forKey: "allowedContentTypes")
                }
            }

            // Show panel
            let runModalSelector = NSSelectorFromString("runModal")
            let result = openPanel.perform(runModalSelector)
            let modalResult = Int(bitPattern: result?.toOpaque())

            // NSModalResponseOK = 1
            if modalResult == 1 {
                // Get selected URL
                let urlsSelector = NSSelectorFromString("URLs")
                guard let urls = openPanel.perform(urlsSelector)?.takeUnretainedValue() as? [URL],
                      let selectedURL = urls.first else {
                    sendFileCallback(callbackId: callbackId, error: "No file selected")
                    return
                }

                processSelectedFile(url: selectedURL, maxSizeBytes: maxSizeBytes, callbackId: callbackId)
            } else {
                // User cancelled
                sendFileCallback(callbackId: callbackId, error: "cancelled")
            }
        }
        #endif

        private func selectFileWithDocumentPicker(payload: [String: Any]?, callbackId: String) {
            // iOS implementation using UIDocumentPickerViewController
            // For now, return an error - can be implemented if needed
            sendFileCallback(callbackId: callbackId, error: "File picker not implemented on iOS")
        }

        private func processSelectedFile(url: URL, maxSizeBytes: Int, callbackId: String) {
            do {
                // Check file size
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int ?? 0

                if fileSize > maxSizeBytes {
                    let maxMB = maxSizeBytes / (1024 * 1024)
                    sendFileCallback(callbackId: callbackId, error: "File too large. Maximum size is \(maxMB)MB")
                    return
                }

                // Read file data
                let data = try Data(contentsOf: url)
                let base64String = data.base64EncodedString()

                // Determine MIME type
                let mimeType: String
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg":
                    mimeType = "image/jpeg"
                case "png":
                    mimeType = "image/png"
                case "webp":
                    mimeType = "image/webp"
                case "gif":
                    mimeType = "image/gif"
                case "heic":
                    mimeType = "image/heic"
                case "pdf":
                    mimeType = "application/pdf"
                default:
                    mimeType = "application/octet-stream"
                }

                // Send success callback with file data
                let result: [String: Any] = [
                    "name": url.lastPathComponent,
                    "size": fileSize,
                    "type": mimeType,
                    "data": "data:\(mimeType);base64,\(base64String)"
                ]
                sendFileCallback(callbackId: callbackId, result: result)

            } catch {
                sendFileCallback(callbackId: callbackId, error: "Failed to read file: \(error.localizedDescription)")
            }
        }

        /// Invoke `window.__mqtt_callback(callbackId, json)` with the JSON string safely
        /// embedded as a JS single-quoted string literal.
        private func sendMQTTCallback(callbackId: String, json: String) {
            let escaped = json
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let js = "window.__mqtt_callback && window.__mqtt_callback('\(callbackId)', '\(escaped)');"
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        private func sendFileCallback(callbackId: String, result: [String: Any]? = nil, error: String? = nil) {
            guard let webView = webView else { return }

            var response: [String: Any] = ["callbackId": callbackId]
            if let result = result {
                response["result"] = result
            }
            if let error = error {
                response["error"] = error
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: response),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("[WebView] Failed to serialize file callback response")
                return
            }

            let js = "window.__file_callback && window.__file_callback(\(jsonString));"
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("[WebView] File callback failed: \(error.localizedDescription)")
                }
            }
        }

        /// Parse a hex color string (#rrggbb) to UIColor.
        static func colorFromHex(_ hex: String) -> UIColor {
            var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if h.hasPrefix("#") { h.removeFirst() }
            guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return .black }
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
