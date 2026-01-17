import SwiftUI
import WebKit
import HomeKit
import UIKit

// MARK: - Config

enum AppConfig {
    /// Whether to show the main window when the app launches.
    /// Set to `true` for testing, `false` for production (menu bar only on launch).
    static let showWindowOnLaunch = true
}

// Notifications
extension Notification.Name {
    static let reloadWebView = Notification.Name("reloadWebView")
    static let hardRefreshWebView = Notification.Name("hardRefreshWebView")
    static let showInfoButton = Notification.Name("showInfoButton")
    static let hideInfoButton = Notification.Name("hideInfoButton")
    static let showLogsSheet = Notification.Name("showLogsSheet")
}

// MARK: - Shake Gesture Detection (iOS)

#if !targetEnvironment(macCatalyst)
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .showLogsSheet, object: nil)
        }
    }
}
#endif

@main
struct HomecastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.homeKitManager)
                .environmentObject(appDelegate.httpServer)
                .environmentObject(appDelegate.connectionManager)
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
        ContentView()
            .frame(minWidth: 960, minHeight: 600)
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
    @EnvironmentObject var httpServer: SimpleHTTPServer
    @EnvironmentObject var connectionManager: ConnectionManager
    @StateObject private var logManager = LogManager.shared
    @State private var showingLogs = false
    @State private var showInfoButton = false
    @State private var dKeyHeld = false

    var body: some View {
        ZStack(alignment: .top) {
            // WebView - fills entire screen (edge-to-edge)
            WebViewContainer(url: URL(string: "https://homecast.cloud/login")!, authToken: connectionManager.authToken, connectionManager: connectionManager)
                .ignoresSafeArea()

            // Header - overlays on top when 'd' key is held
            if showInfoButton {
                headerView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Logs panel overlay
            if showingLogs {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingLogs = false
                    }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LogsSheet(logManager: logManager, connectionManager: connectionManager, homeKitManager: homeKitManager, dismiss: {
                            showingLogs = false
                        })
                        .shadow(radius: 20)
                        Spacer()
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onChange(of: showingLogs) { isShowing in
            // Hide info button when logs panel opens
            if isShowing {
                showInfoButton = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showInfoButton)) { _ in
            dKeyHeld = true
            withAnimation(.easeInOut(duration: 0.15)) {
                showInfoButton = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hideInfoButton)) { _ in
            dKeyHeld = false
            withAnimation(.easeInOut(duration: 0.15)) {
                showInfoButton = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showLogsSheet)) { _ in
            showingLogs = true
        }
    }

    private var headerView: some View {
        HStack {
            Spacer()

            if showInfoButton {
                Button(action: { showingLogs = true }) {
                    Image(systemName: "info.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(connectionManager.isConnected ? .green : .orange)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusIndicators: some View {
        HStack(spacing: 16) {
            // HomeKit
            HStack(spacing: 6) {
                Circle()
                    .fill(homeKitManager.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("HomeKit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Relay
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionManager.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("Relay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Local Server
            HStack(spacing: 6) {
                Circle()
                    .fill(httpServer.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(":\(String(httpServer.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        HStack(spacing: 8) {
            Text(connectionManager.savedEmail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Sign Out") {
                connectionManager.signOut()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
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

    // Handle Tab key to move between form fields
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
            } else if key.keyCode == .keyboardReturnOrEnter {
                // Enter key - submit form or click button
                let js = """
                (function() {
                    var el = document.activeElement;
                    if (el.tagName === 'BUTTON' || el.type === 'submit') {
                        el.click();
                    } else if (el.form) {
                        el.form.requestSubmit();
                    }
                })();
                """
                evaluateJavaScript(js, completionHandler: nil)
                handled = true
            } else if key.keyCode == .keyboardD {
                // D key - show info button while held
                NotificationCenter.default.post(name: .showInfoButton, object: nil)
                // Inject keydown event to WebView via JavaScript
                let js = "window.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', code: 'KeyD', bubbles: true }));"
                evaluateJavaScript(js, completionHandler: nil)
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardD {
                // D key released - hide info button
                NotificationCenter.default.post(name: .hideInfoButton, object: nil)
                // Inject keyup event to WebView via JavaScript
                let js = "window.dispatchEvent(new KeyboardEvent('keyup', { key: 'd', code: 'KeyD', bubbles: true }));"
                evaluateJavaScript(js, completionHandler: nil)
            }
        }
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - WebView

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    let authToken: String?
    let connectionManager: ConnectionManager

    func makeCoordinator() -> Coordinator {
        Coordinator(connectionManager: connectionManager)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Clear cache on app launch to ensure fresh content after web deploys
        let dataTypes = Set([
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache
        ])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            print("[WebView] Cache cleared on launch")
        }

        // Suppress autofill/suggestions to avoid WebKit warnings during focus changes
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs
        }

        // Add message handler for native bridge
        config.userContentController.add(context.coordinator, name: "homecast")

        // Set platform detection flags for the web app
        #if targetEnvironment(macCatalyst)
        let platformScript = "window.isHomecastApp = true; window.isHomecastMacApp = true; console.log('[Homecast] Mac app detected');"
        #else
        let platformScript = "window.isHomecastApp = true; window.isHomecastIOSApp = true; console.log('[Homecast] iOS app detected');"
        #endif
        config.userContentController.addUserScript(WKUserScript(
            source: platformScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

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

        // iOS-specific config must be set before creating webView
        #if !targetEnvironment(macCatalyst)
        // Disable text selection on iOS to prevent long-press selecting text in context menus
        if #available(iOS 14.5, *) {
            config.preferences.isTextInteractionEnabled = false
        } else {
            let selectionScript = WKUserScript(source: """
                document.body.style.webkitTouchCallout='none';
                document.body.style.webkitUserSelect='none';
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            config.userContentController.addUserScript(selectionScript)
        }
        #endif

        // Use a reasonable initial frame to avoid CoreGraphics NaN errors
        let webView = FocusableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.authToken = authToken
        context.coordinator.webView = webView

        #if targetEnvironment(macCatalyst)
        // On Mac, disable content inset adjustment for full-bleed layout
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        // On iOS, set mobile user agent so website renders mobile layout
        let iOSVersion = UIDevice.current.systemVersion
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(iOSVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(iOSVersion) Mobile/15E148 Safari/604.1"
        #endif

        webView.load(URLRequest(url: url))
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
                    // Mac app sign out (from menu, LogsSheet, etc.) - clear localStorage and reload to login
                    let js = """
                    localStorage.removeItem('homekit-token');
                    console.log('[Homecast] Signed out from Mac app');
                    """
                    webView.evaluateJavaScript(js) { [weak webView] _, _ in
                        // Force load login page after clearing token
                        if let url = URL(string: "https://homecast.cloud/login") {
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
        private let connectionManager: ConnectionManager

        // Track whether auth changes were initiated by WebView (vs Mac app)
        var webViewInitiatedLogin = false
        var webViewInitiatedLogout = false

        init(connectionManager: ConnectionManager) {
            self.connectionManager = connectionManager
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
        }

        @objc private func handleReload() {
            print("[WebView] Reloading page (Cmd+R)")
            webView?.reloadFromOrigin()
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
                // Filter to only homecast.cloud records
                let homecastRecords = records.filter { $0.displayName.contains("homecast") }
                if homecastRecords.isEmpty {
                    print("[WebView] No cached data found, reloading anyway")
                } else {
                    print("[WebView] Clearing \(homecastRecords.count) cache records")
                }

                dataStore.removeData(ofTypes: dataTypes, for: homecastRecords) {
                    print("[WebView] Cache cleared, reloading page")
                    DispatchQueue.main.async {
                        if let url = URL(string: "https://homecast.cloud/login") {
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
                Task { @MainActor in
                    connectionManager.signOut()
                }
            case "copy":
                if let text = body["text"] as? String {
                    let textCopy = String(text)
                    Task { @MainActor in
                        UIPasteboard.general.string = textCopy
                    }
                }
            default:
                print("[WebView] Unknown action: \(action)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[WebView] Provisional navigation failed: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("[WebView] Error domain: \(nsError.domain), code: \(nsError.code)")
                if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] {
                    print("[WebView] Failing URL: \(failingURL)")
                }
            }
        }
    }
}

// MARK: - Logs Sheet

enum DebugTab: String, CaseIterable {
    case logs = "Logs"
    case journeys = "Journeys"
    case stats = "Stats"
}

struct LogsSheet: View {
    @ObservedObject var logManager: LogManager
    @ObservedObject var connectionManager: ConnectionManager
    @ObservedObject var homeKitManager: HomeKitManager
    var dismiss: () -> Void
    @State private var showingSignOutConfirm = false
    @State private var selectedTab: DebugTab = .logs
    @State private var selectedCategory: LogCategory? = nil

    private var connectionStatusColor: Color {
        if !connectionManager.isNetworkAvailable {
            return .red
        } else if !connectionManager.isConnected {
            return .orange
        } else if connectionManager.consecutivePingFailures > 0 {
            return .yellow
        } else {
            return .green
        }
    }

    private var connectionStatusText: String {
        if !connectionManager.isNetworkAvailable {
            return "No Network"
        } else if !connectionManager.isConnected {
            return "Offline"
        } else if connectionManager.consecutivePingFailures > 0 {
            return "Connected (ping \(connectionManager.consecutivePingFailures)/2)"
        } else {
            return "Connected"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with status and tabs
            headerView

            Divider().opacity(0.5)

            // Tab content
            switch selectedTab {
            case .logs:
                logsView
            case .journeys:
                journeysView
            case .stats:
                statsView
            }

            Divider().opacity(0.5)

            // Footer
            footerView
        }
        .frame(width: 800, height: 550)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Sign Out", isPresented: $showingSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                connectionManager.signOut()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 8) {
                // Connection indicator
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 6, height: 6)
                Text(connectionStatusText)
                    .font(.caption)
                    .foregroundStyle(.primary)

                Text("·")
                    .foregroundStyle(.tertiary)

                // User info
                if connectionManager.isAuthenticated {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(connectionManager.savedEmail)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("Not logged in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("·")
                    .foregroundStyle(.tertiary)

                // Device name
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(ProcessInfo.processInfo.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                // Actions
                Button("Hard Refresh") {
                    NotificationCenter.default.post(name: .hardRefreshWebView, object: nil)
                    dismiss()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)

                if connectionManager.isAuthenticated {
                    Button("Sign Out") {
                        showingSignOutConfirm = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(DebugTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tabIcon(for: tab))
                                .font(.system(size: 10))
                            Text(tab.rawValue)
                                .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Clear button for current tab
                if selectedTab == .logs && !logManager.logs.isEmpty {
                    Button("Clear") {
                        logManager.clear()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                } else if selectedTab == .journeys && !logManager.journeyLogs.isEmpty {
                    Button("Clear") {
                        logManager.clearJourneys()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func tabIcon(for tab: DebugTab) -> String {
        switch tab {
        case .logs: return "list.bullet.rectangle"
        case .journeys: return "arrow.left.arrow.right"
        case .stats: return "chart.bar"
        }
    }

    // MARK: - Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            // Category filter
            HStack(spacing: 4) {
                Text("Filter:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: { selectedCategory = nil }) {
                    Text("All")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selectedCategory == nil ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedCategory == nil ? .primary : .secondary)

                ForEach(LogCategory.allCases, id: \.self) { category in
                    Button(action: { selectedCategory = category }) {
                        Text(category.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(selectedCategory == category ? categoryColor(category).opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedCategory == category ? categoryColor(category) : .secondary)
                }

                Spacer()

                Text("\(filteredLogs.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))

            // Log entries
            if filteredLogs.isEmpty {
                emptyStateView(icon: "text.alignleft", message: "No activity yet")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLogs.reversed()) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var filteredLogs: [LogEntry] {
        guard let category = selectedCategory else {
            return logManager.logs
        }
        return logManager.logs.filter { $0.category == category }
    }

    // MARK: - Journeys View

    private var journeysView: some View {
        VStack(spacing: 0) {
            // Header explanation
            VStack(alignment: .leading, spacing: 6) {
                Text("Request Journey Tracker")
                    .font(.system(size: 11, weight: .semibold))

                Text("Shows requests received from the server, how they were routed, and our responses. Tap a row to see full details.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("⚡️")
                            .font(.system(size: 10))
                        Text("Direct")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("— same instance")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        Text("🌐")
                            .font(.system(size: 10))
                        Text("Routed")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("— via Pub/Sub")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text("\(groupedJourneys.count) requests")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

            // Journey entries
            if logManager.journeyLogs.isEmpty {
                emptyStateView(icon: "arrow.left.arrow.right", message: "No request journeys yet")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedJourneys.reversed(), id: \.0) { (requestId, entries) in
                            JourneyGroupRow(requestId: requestId, entries: entries)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var groupedJourneys: [(String, [JourneyLogEntry])] {
        var groups: [String: [JourneyLogEntry]] = [:]
        for entry in logManager.journeyLogs {
            groups[entry.requestId, default: []].append(entry)
        }
        return groups.map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { $0.1.first?.timestamp ?? Date.distantPast < $1.1.first?.timestamp ?? Date.distantPast }
    }

    // MARK: - Stats View

    private var statsView: some View {
        let homes = homeKitManager.homes
        let totalAccessories = homes.reduce(0) { $0 + $1.accessories.count }
        let reachableAccessories = homes.reduce(0) { $0 + $1.accessories.filter { $0.isReachable }.count }
        let totalRooms = homes.reduce(0) { $0 + $1.rooms.count }

        // Calculate journey stats
        let journeyStats = calculateJourneyStats()

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // HomeKit Stats
                statsSection(title: "HomeKit", icon: "house.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(homes, id: \.uniqueIdentifier) { home in
                            HStack {
                                Text(home.name)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(home.accessories.count) accessories")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .foregroundStyle(.quaternary)
                                Text("\(home.rooms.count) rooms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        HStack {
                            statItem(label: "Homes", value: "\(homes.count)")
                            statItem(label: "Rooms", value: "\(totalRooms)")
                            statItem(label: "Accessories", value: "\(totalAccessories)")
                            statItem(label: "Online", value: "\(reachableAccessories)")
                        }
                    }
                }

                // Request Stats
                statsSection(title: "Request Performance", icon: "speedometer") {
                    if journeyStats.totalRequests > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                statItem(label: "Total Requests", value: "\(journeyStats.totalRequests)")
                                statItem(label: "Direct", value: "\(journeyStats.directRequests)")
                                statItem(label: "Pub/Sub", value: "\(journeyStats.pubsubRequests)")
                            }

                            Divider()

                            HStack {
                                statItem(label: "Avg Latency", value: "\(journeyStats.avgLatencyMs)ms")
                                statItem(label: "Min", value: "\(journeyStats.minLatencyMs)ms")
                                statItem(label: "Max", value: "\(journeyStats.maxLatencyMs)ms")
                            }

                            if !journeyStats.actionCounts.isEmpty {
                                Divider()

                                Text("By Action")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(journeyStats.actionCounts.sorted { $0.value > $1.value }, id: \.key) { action, count in
                                    HStack {
                                        Text(action)
                                            .font(.system(size: 11, design: .monospaced))
                                        Spacer()
                                        Text("\(count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("No request data yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func statsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            content()
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(8)
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .frame(minWidth: 60, alignment: .leading)
    }

    private struct JourneyStats {
        var totalRequests: Int = 0
        var directRequests: Int = 0
        var pubsubRequests: Int = 0
        var avgLatencyMs: Int = 0
        var minLatencyMs: Int = 0
        var maxLatencyMs: Int = 0
        var actionCounts: [String: Int] = [:]
    }

    private func calculateJourneyStats() -> JourneyStats {
        var stats = JourneyStats()

        // Group by request ID and get response entries
        var seenRequests = Set<String>()
        var latencies: [Int] = []

        for entry in logManager.journeyLogs {
            if !seenRequests.contains(entry.requestId) && entry.phase == .request {
                seenRequests.insert(entry.requestId)
                stats.totalRequests += 1
                if entry.isPubsub {
                    stats.pubsubRequests += 1
                } else {
                    stats.directRequests += 1
                }
                stats.actionCounts[entry.action, default: 0] += 1
            }

            if entry.phase == .response, let duration = entry.durationMs {
                latencies.append(duration)
            }
        }

        if !latencies.isEmpty {
            stats.avgLatencyMs = latencies.reduce(0, +) / latencies.count
            stats.minLatencyMs = latencies.min() ?? 0
            stats.maxLatencyMs = latencies.max() ?? 0
        }

        return stats
    }

    private func emptyStateView(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func categoryColor(_ category: LogCategory) -> Color {
        switch category {
        case .general: return .secondary
        case .websocket: return .blue
        case .homekit: return .orange
        case .auth: return .purple
        }
    }

    private var footerView: some View {
        let homes = homeKitManager.homes
        let totalAccessories = homes.reduce(0) { $0 + $1.accessories.count }
        let reachableAccessories = homes.reduce(0) { $0 + $1.accessories.filter { $0.isReachable }.count }
        let totalRooms = homes.reduce(0) { $0 + $1.rooms.count }
        let homeIds = homes.map { String($0.uniqueIdentifier.uuidString.prefix(8)) }.joined(separator: ", ")

        return HStack(spacing: 4) {
            Text("Homes:")
                .foregroundStyle(.secondary)
            Text("\(homes.count)")
                .foregroundStyle(.primary)

            Text("·")
                .foregroundStyle(.quaternary)

            Text("Accessories:")
                .foregroundStyle(.secondary)
            Text("\(totalAccessories)")
                .foregroundStyle(.primary)
            Text("(\(reachableAccessories) online)")
                .foregroundStyle(.tertiary)

            Text("·")
                .foregroundStyle(.quaternary)

            Text("Rooms:")
                .foregroundStyle(.secondary)
            Text("\(totalRooms)")
                .foregroundStyle(.primary)

            Text("·")
                .foregroundStyle(.quaternary)

            Text("IDs:")
                .foregroundStyle(.secondary)
            Text(homeIds.isEmpty ? "—" : homeIds)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Journey Group Row

struct JourneyGroupRow: View {
    let requestId: String
    let entries: [JourneyLogEntry]
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        let requestEntry = entries.first { $0.phase == .request }
        let responseEntry = entries.first { $0.phase == .response }
        let isPubsub = requestEntry?.isPubsub ?? false
        let route = requestEntry?.route ?? "unknown"
        let action = requestEntry?.action ?? "unknown"
        let duration = responseEntry?.durationMs
        let isError = responseEntry?.details?.hasPrefix("error") ?? false
        let isSuccess = responseEntry != nil && !isError
        let isPending = responseEntry == nil

        VStack(alignment: .leading, spacing: 0) {
            // Main row - tap to expand
            HStack(spacing: 8) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                    HStack(spacing: 8) {
                        // Expand indicator
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)

                        // Status icon
                        if isPending {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else if isSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }

                        // Action name
                        Text(action)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)

                        // Route badge
                        HStack(spacing: 3) {
                            Text(isPubsub ? "🌐" : "⚡️")
                                .font(.system(size: 9))
                            Text(isPubsub ? "routed" : "direct")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isPubsub ? Color.purple.opacity(0.15) : Color.green.opacity(0.15))
                        .cornerRadius(4)
                        .foregroundStyle(isPubsub ? .purple : .green)

                        Spacer()

                        // Duration badge
                        if let duration = duration {
                            Text("\(duration)ms")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(durationColor(duration).opacity(0.15))
                                .cornerRadius(4)
                                .foregroundStyle(durationColor(duration))
                        } else if isPending {
                            Text("pending...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Copy button (visible on hover)
                if isHovered {
                    Button(action: { copyJourneyToClipboard(requestEntry: requestEntry, responseEntry: responseEntry, route: route, action: action, duration: duration, isPubsub: isPubsub) }) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(showCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                // Timestamp
                Text(requestEntry?.timeString ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isHovered ? Color(uiColor: .secondarySystemBackground).opacity(0.5) : Color.clear)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.horizontal, 12)

                    // Request info section
                    detailSection(title: "📥 REQUEST RECEIVED", color: .blue) {
                        VStack(alignment: .leading, spacing: 4) {
                            detailRow(label: "Action", value: action)
                            detailRow(label: "Request ID", value: requestId)
                            detailRow(label: "Received at", value: requestEntry?.timeString ?? "—")
                            if let details = requestEntry?.details, !details.isEmpty {
                                detailRow(label: "Parameters", value: details)
                            }
                        }
                    }

                    // Routing info section
                    let sourceInst = requestEntry?.sourceInstance ?? "unknown"
                    let targetInst = requestEntry?.targetInstance ?? "unknown"
                    let isSameInstance = requestEntry?.isSameInstance ?? false

                    detailSection(title: isPubsub ? "🌐 ROUTED VIA PUB/SUB" : "⚡️ DIRECT CONNECTION", color: isPubsub ? .purple : .green) {
                        VStack(alignment: .leading, spacing: 4) {
                            if isPubsub {
                                Text("This request was forwarded from another Cloud Run instance via Google Pub/Sub because the web client that initiated it is connected to a different instance than this Mac app.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 4)
                            } else {
                                Text("This request came directly from a web client connected to the same Cloud Run instance as this Mac app.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 4)
                            }

                            // Instance IDs
                            detailRow(label: "Source instance", value: "\(sourceInst)\(isSameInstance ? " (web client here)" : "")")
                            detailRow(label: "Target instance", value: "\(targetInst)\(isSameInstance ? " (mac app here)" : "")")

                            if isSameInstance {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                    Text("Same instance — no network hop required")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                }
                                .padding(.top, 4)
                            } else if isPubsub {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.swap")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.purple)
                                    Text("Cross-instance — routed via Pub/Sub")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.purple)
                                }
                                .padding(.top, 4)
                            }

                            // Visual journey
                            Divider().padding(.vertical, 4)

                            HStack(spacing: 4) {
                                // Source
                                VStack(spacing: 2) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.blue)
                                    Text("Web Client")
                                        .font(.system(size: 8))
                                    Text(shortInstanceId(sourceInst))
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 70)

                                // Arrow 1
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)

                                // Server/Pub/Sub
                                VStack(spacing: 2) {
                                    Image(systemName: isPubsub ? "cloud" : "server.rack")
                                        .font(.system(size: 14))
                                        .foregroundStyle(isPubsub ? .purple : .gray)
                                    Text(isPubsub ? "Pub/Sub" : "Server")
                                        .font(.system(size: 8))
                                }
                                .frame(width: 70)

                                // Arrow 2
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)

                                // Target
                                VStack(spacing: 2) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.green)
                                    Text("Mac App")
                                        .font(.system(size: 8))
                                    Text(shortInstanceId(targetInst))
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 70)

                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }

                    // Response info section
                    if let responseEntry = responseEntry {
                        detailSection(title: isError ? "❌ RESPONSE SENT (ERROR)" : "✅ RESPONSE SENT (SUCCESS)", color: isError ? .red : .green) {
                            VStack(alignment: .leading, spacing: 4) {
                                if isSuccess {
                                    Text("We successfully processed this request and sent a response back to the server.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.bottom, 4)
                                } else {
                                    Text("We encountered an error processing this request.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.bottom, 4)
                                }

                                detailRow(label: "Status", value: isError ? "Error" : "Success")
                                detailRow(label: "Responded at", value: responseEntry.timeString)
                                if let duration = duration {
                                    detailRow(label: "Processing time", value: "\(duration)ms\(durationDescription(duration))")
                                }

                                // Response data details
                                if let responseData = responseEntry.responseData {
                                    Divider().padding(.vertical, 4)

                                    if responseData.isSuccess {
                                        if let summary = responseData.payloadSummary {
                                            detailRow(label: "Response", value: summary)
                                        }
                                        if let itemCount = responseData.itemCount {
                                            detailRow(label: "Items returned", value: "\(itemCount)")
                                        }
                                        if let size = responseData.payloadSize {
                                            detailRow(label: "Payload size", value: formatBytes(size))
                                        }
                                    } else {
                                        if let errorCode = responseData.errorCode {
                                            detailRow(label: "Error code", value: errorCode)
                                        }
                                        if let errorMessage = responseData.errorMessage {
                                            detailRow(label: "Error message", value: errorMessage)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        detailSection(title: "⏳ AWAITING RESPONSE", color: .orange) {
                            Text("This request is still being processed. A response has not been sent yet.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Timeline visualization
                    detailSection(title: "📊 TIMELINE", color: .secondary) {
                        HStack(spacing: 0) {
                            // Request received
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 8, height: 8)
                                Text("Received")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }

                            // Line
                            Rectangle()
                                .fill(responseEntry != nil ? (isError ? Color.red : Color.green) : Color.orange)
                                .frame(height: 2)

                            // Processing
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(responseEntry != nil ? (isError ? Color.red : Color.green) : Color.orange)
                                    .frame(width: 8, height: 8)
                                if let duration = duration {
                                    Text("\(duration)ms")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(durationColor(duration))
                                } else {
                                    Text("...")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.orange)
                                }
                            }

                            // Line
                            Rectangle()
                                .fill(responseEntry != nil ? (isError ? Color.red : Color.green) : Color.gray.opacity(0.3))
                                .frame(height: 2)

                            // Response sent
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(responseEntry != nil ? (isError ? Color.red : Color.green) : Color.gray.opacity(0.3))
                                    .frame(width: 8, height: 8)
                                Text(responseEntry != nil ? (isError ? "Error" : "Sent") : "Pending")
                                    .font(.system(size: 8))
                                    .foregroundStyle(responseEntry != nil ? .secondary : .tertiary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 12)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
            }
        }
        .background(Color.clear)
    }

    private func detailSection<Content: View>(title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 12)

            content()
                .padding(.horizontal, 20)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func durationColor(_ ms: Int) -> Color {
        if ms < 100 { return .green }
        if ms < 300 { return .blue }
        if ms < 500 { return .orange }
        return .red
    }

    private func durationDescription(_ ms: Int) -> String {
        if ms < 100 { return " (fast)" }
        if ms < 300 { return " (normal)" }
        if ms < 500 { return " (slow)" }
        return " (very slow)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        } else {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.2f MB", mb)
        }
    }

    private func shortInstanceId(_ id: String) -> String {
        if id == "local" || id == "unknown" { return id }
        // Cloud Run instance IDs are like "homecast-xyz-abc123"
        // Show a meaningful truncation
        if id.count > 20 {
            return String(id.suffix(12))
        }
        return id
    }

    private func copyJourneyToClipboard(
        requestEntry: JourneyLogEntry?,
        responseEntry: JourneyLogEntry?,
        route: String,
        action: String,
        duration: Int?,
        isPubsub: Bool
    ) {
        var lines: [String] = []

        lines.append("═══════════════════════════════════════════════════════")
        lines.append("REQUEST JOURNEY: \(action)")
        lines.append("═══════════════════════════════════════════════════════")
        lines.append("")

        // Request info
        lines.append("📥 REQUEST RECEIVED")
        lines.append("   Request ID:    \(requestId)")
        lines.append("   Action:        \(action)")
        lines.append("   Received at:   \(requestEntry?.timeString ?? "—")")
        if let details = requestEntry?.details, !details.isEmpty {
            lines.append("   Parameters:    \(details)")
        }
        lines.append("")

        // Routing info
        let sourceInst = requestEntry?.sourceInstance ?? "unknown"
        let targetInst = requestEntry?.targetInstance ?? "unknown"
        let isSameInstance = requestEntry?.isSameInstance ?? false

        if isPubsub {
            lines.append("🌐 ROUTED VIA PUB/SUB")
            lines.append("   This request was forwarded from another Cloud Run instance")
            lines.append("   via Google Pub/Sub.")
        } else {
            lines.append("⚡️ DIRECT CONNECTION")
            lines.append("   This request came directly from a web client on the same")
            lines.append("   Cloud Run instance.")
        }
        lines.append("   Source instance: \(sourceInst)")
        lines.append("   Target instance: \(targetInst)")
        lines.append("   Same instance:   \(isSameInstance ? "Yes" : "No")")
        lines.append("   Route path:      \(route)")
        lines.append("")

        // Response info
        if let responseEntry = responseEntry {
            let isError = responseEntry.details?.hasPrefix("error") ?? false
            if isError {
                lines.append("❌ RESPONSE SENT (ERROR)")
            } else {
                lines.append("✅ RESPONSE SENT (SUCCESS)")
            }
            lines.append("   Status:        \(isError ? "Error" : "Success")")
            lines.append("   Responded at:  \(responseEntry.timeString)")
            if let duration = duration {
                lines.append("   Processing:    \(duration)ms\(durationDescription(duration))")
            }

            if let responseData = responseEntry.responseData {
                if responseData.isSuccess {
                    if let summary = responseData.payloadSummary {
                        lines.append("   Response:      \(summary)")
                    }
                    if let itemCount = responseData.itemCount {
                        lines.append("   Items:         \(itemCount)")
                    }
                    if let size = responseData.payloadSize {
                        lines.append("   Payload size:  \(formatBytes(size))")
                    }
                } else {
                    if let errorCode = responseData.errorCode {
                        lines.append("   Error code:    \(errorCode)")
                    }
                    if let errorMessage = responseData.errorMessage {
                        lines.append("   Error message: \(errorMessage)")
                    }
                }
            }
        } else {
            lines.append("⏳ AWAITING RESPONSE")
            lines.append("   This request is still being processed.")
        }

        lines.append("")
        lines.append("═══════════════════════════════════════════════════════")

        let text = lines.joined(separator: "\n")
        UIPasteboard.general.string = text

        withAnimation {
            showCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopied = false
            }
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 6) {
            // Direction + Category (combined, left-aligned)
            HStack(spacing: 3) {
                if let direction = entry.direction {
                    Text(direction == .incoming ? "←" : "→")
                        .foregroundStyle(direction == .incoming ? .blue : .orange)
                } else {
                    Text("·")
                        .foregroundStyle(.quaternary)
                }

                Text(entry.category.rawValue)
                    .foregroundStyle(categoryColor(entry.category))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .frame(width: 44, alignment: .leading)

            // Message (fills space)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Copy button (visible on hover)
            if isHovered {
                Button(action: copyToClipboard) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(showCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            // Timestamp (right-aligned, subtle)
            Text(entry.timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(isHovered ? Color(uiColor: .secondarySystemBackground) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    private func copyToClipboard() {
        let dirStr = entry.direction.map { $0 == .incoming ? "←" : "→" } ?? "•"
        let text = "[\(entry.timeString)] [\(entry.category.rawValue)] \(dirStr) \(entry.message)"
        UIPasteboard.general.string = text

        withAnimation {
            showCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopied = false
            }
        }
    }

    private func categoryColor(_ category: LogCategory) -> Color {
        switch category {
        case .general: return .secondary
        case .websocket: return .blue
        case .homekit: return .orange
        case .auth: return .purple
        }
    }
}
