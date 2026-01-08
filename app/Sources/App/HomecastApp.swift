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
    static let showInfoButton = Notification.Name("showInfoButton")
    static let hideInfoButton = Notification.Name("hideInfoButton")
}

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
            }
        }
    }
}

// MARK: - Root View

struct RootView: View {
    var body: some View {
        ContentView()
            .frame(minWidth: 960, minHeight: 600)
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
        VStack(spacing: 0) {
            // Header - pinned to top, stretches full width
            headerView

            // WebView - fills remaining space
            WebViewContainer(url: URL(string: "https://homecast.cloud/login")!, authToken: connectionManager.authToken, connectionManager: connectionManager)
        }
        .edgesIgnoringSafeArea(.all)
        .overlay {
            if showingLogs {
                ZStack {
                    // Dimmed background
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showingLogs = false
                        }

                    // Logs panel
                    LogsSheet(logManager: logManager, connectionManager: connectionManager, dismiss: {
                        showingLogs = false
                    })
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }
        }
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async {
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

        // Suppress autofill/suggestions to avoid WebKit warnings during focus changes
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs
        }

        // Add message handler for native bridge
        config.userContentController.add(context.coordinator, name: "homecast")

        // Only inject token at document start if we have one
        // Don't clear localStorage - let it persist naturally across reloads
        if let token = authToken {
            let tokenScript = "localStorage.setItem('homekit-token', '\(token)'); console.log('[Homecast] Token pre-injected');"
            let script = WKUserScript(
                source: tokenScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        // Use a reasonable initial frame to avoid CoreGraphics NaN errors
        let webView = FocusableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.authToken = authToken
        context.coordinator.webView = webView

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
        private var hasInjectedToken = false
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
        }

        @objc private func handleReload() {
            print("[WebView] Reloading page (Cmd+R)")
            webView?.reloadFromOrigin()
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
                        self.hasInjectedToken = true
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
            default:
                print("[WebView] Unknown action: \(action)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Ensure WebView has keyboard focus
            DispatchQueue.main.async {
                webView.becomeFirstResponder()
            }

            // Fallback: inject auth token after page loads and trigger re-check
            guard let token = authToken, !hasInjectedToken else { return }

            let js = """
            localStorage.setItem('homekit-token', '\(token)');
            console.log('[Homecast] Auth token injected');
            window.dispatchEvent(new StorageEvent('storage', { key: 'homekit-token', newValue: '\(token)' }));
            """

            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("[WebView] Failed to inject token: \(error.localizedDescription)")
                } else {
                    print("[WebView] Auth token injected into localStorage")
                    self.hasInjectedToken = true
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

struct LogsSheet: View {
    @ObservedObject var logManager: LogManager
    @ObservedObject var connectionManager: ConnectionManager
    var dismiss: () -> Void
    @State private var showingSignOutConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact header with inline status
            HStack(spacing: 8) {
                // Connection indicator
                Circle()
                    .fill(connectionManager.isConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(connectionManager.isConnected ? "Connected" : "Offline")
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
                if connectionManager.isAuthenticated {
                    Button("Sign Out") {
                        showingSignOutConfirm = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                if !logManager.logs.isEmpty {
                    Button("Clear") {
                        logManager.clear()
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
            .padding(.vertical, 10)
            .background(.bar)

            Divider().opacity(0.5)

            // Log entries
            if logManager.logs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No activity yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logManager.logs.reversed()) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 600, height: 400)
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
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

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

            // Timestamp (right-aligned, subtle)
            Text(entry.timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(Color.clear)
        .contentShape(Rectangle())
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
