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
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        Group {
            if connectionManager.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Login View

struct LoginView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var serverURL: String = "https://api.homecast.cloud"
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Logo
                Image(systemName: "house.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("HomeCast")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Sign in to connect your HomeKit devices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Login Form
                VStack(spacing: 16) {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)

                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(action: login) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canLogin || isLoading)
                }
                .frame(maxWidth: 320)

                Spacer()
            }
            .padding()
        }
        .onAppear {
            if !connectionManager.serverURL.isEmpty {
                serverURL = connectionManager.serverURL
            }
            if !connectionManager.savedEmail.isEmpty {
                email = connectionManager.savedEmail
            }
        }
    }

    private var canLogin: Bool {
        !serverURL.isEmpty && !email.isEmpty && !password.isEmpty
    }

    private func login() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await connectionManager.authenticate(
                    serverURL: serverURL,
                    email: email,
                    password: password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
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
            // Header
            headerView

            // WebView
            WebViewContainer(url: URL(string: "https://homecast.cloud")!)
        }
        .background(Color(UIColor.systemBackground))
        .sheet(isPresented: $showingLogs) {
            LogsSheet(logManager: logManager)
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            // App icon
            Image(systemName: "house.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            Text("HomeCast")
                .font(.headline)

            Divider()
                .frame(height: 20)

            // Status indicators
            statusIndicators

            Spacer()

            // Account
            accountSection

            // Logs button
            Button(action: { showingLogs = true }) {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("View activity logs")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
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

// MARK: - WebView

struct WebViewContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Logs Sheet

struct LogsSheet: View {
    @ObservedObject var logManager: LogManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Activity Log")
                    .font(.headline)

                Spacer()

                if !logManager.logs.isEmpty {
                    Button("Clear") {
                        logManager.clear()
                    }
                    .font(.caption)
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

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
        .frame(width: 600, height: 400)
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
