import SwiftUI
import WebKit
import HomeKit
import UIKit

@main
struct HomeCastApp: App {
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
        }
    }
}

// MARK: - Root View

struct RootView: View {
    var body: some View {
        ContentView()
            .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var homeKitManager: HomeKitManager
    @EnvironmentObject var httpServer: SimpleHTTPServer
    @EnvironmentObject var connectionManager: ConnectionManager
    @StateObject private var logManager = LogManager.shared
    @State private var showingLogs = false

    var body: some View {
        VStack(spacing: 0) {
            // Header - pinned to top, stretches full width
            headerView

            // WebView - fills remaining space
            WebViewContainer(url: URL(string: "https://homecast.cloud/login")!, authToken: connectionManager.authToken, connectionManager: connectionManager)
        }
        .edgesIgnoringSafeArea(.all)
        .sheet(isPresented: $showingLogs) {
            LogsSheet(logManager: logManager, connectionManager: connectionManager)
        }
    }

    private var headerView: some View {
        HStack {
            Spacer()

            Circle()
                .fill(connectionManager.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Button(action: { showingLogs = true }) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
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

        // Inject auth token BEFORE page loads if available
        if let token = authToken {
            let script = WKUserScript(
                source: "localStorage.setItem('homekit-token', '\(token)'); console.log('[HomeCast] Token pre-injected');",
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
        // If auth token was cleared (sign out), reload to login page
        if context.coordinator.authToken != nil && authToken == nil {
            // Clear localStorage and reload to login
            let js = """
            localStorage.removeItem('homekit-token');
            window.location.href = '/login';
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        context.coordinator.authToken = authToken
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var authToken: String?
        weak var webView: WKWebView?
        private var hasInjectedToken = false
        private let connectionManager: ConnectionManager

        init(connectionManager: ConnectionManager) {
            self.connectionManager = connectionManager
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
                Task { @MainActor in
                    do {
                        try await connectionManager.authenticateWithToken(token)
                        self.authToken = token
                        self.hasInjectedToken = true
                    } catch {
                        print("[WebView] Failed to authenticate with token: \(error)")
                    }
                }
            case "logout":
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
            console.log('[HomeCast] Auth token injected');
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
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("HomeCast")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Status section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Status")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                }

                HStack(spacing: 16) {
                    // Connection status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionManager.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(connectionManager.isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                    }

                    // Login status
                    HStack(spacing: 6) {
                        Image(systemName: connectionManager.isAuthenticated ? "person.fill.checkmark" : "person.slash")
                            .font(.caption)
                        Text(connectionManager.isAuthenticated ? connectionManager.savedEmail : "Not logged in")
                            .font(.caption)
                    }
                }

                // Device name
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption)
                    Text(ProcessInfo.processInfo.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Sign out button
                if connectionManager.isAuthenticated {
                    Button(role: .destructive) {
                        connectionManager.signOut()
                        dismiss()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))

            Divider()

            // Log header
            HStack {
                Text("Activity Log")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                if !logManager.logs.isEmpty {
                    Button("Clear") {
                        logManager.clear()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            if logManager.logs.isEmpty {
                VStack {
                    Spacer()
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logManager.logs.reversed()) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.timeString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if let direction = entry.direction {
                Text(direction == .incoming ? "←" : "→")
                    .font(.caption)
                    .foregroundStyle(direction == .incoming ? .blue : .orange)
            } else {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.category.rawValue)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(categoryColor(entry.category).opacity(0.2))
                .cornerRadius(3)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func categoryColor(_ category: LogCategory) -> Color {
        switch category {
        case .general: return .gray
        case .websocket: return .blue
        case .homekit: return .orange
        case .auth: return .purple
        }
    }
}
