import Foundation
import SwiftUI
import Combine

/// Manages authentication and WebSocket connection to the relay server
@MainActor
class ConnectionManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var serverURL: String = ""
    @Published private(set) var savedEmail: String = ""

    // MARK: - Dependencies

    let homeKitManager: HomeKitManager
    private var webSocketClient: WebSocketClient?
    private var authToken: String?

    // MARK: - Keychain Keys

    private let keychainService = "com.homekitmcp.app"
    private let serverURLKey = "serverURL"
    private let emailKey = "email"
    private let tokenKey = "authToken"

    // MARK: - Computed Properties

    var statusIcon: String {
        if isConnected {
            return "checkmark.circle.fill"
        } else if isAuthenticated {
            return "arrow.triangle.2.circlepath"
        } else {
            return "xmark.circle"
        }
    }

    var statusColor: Color {
        if isConnected {
            return .green
        } else if isAuthenticated {
            return .orange
        } else {
            return .gray
        }
    }

    var statusText: String {
        if isConnected {
            return "Connected"
        } else if isAuthenticated {
            return "Connecting..."
        } else {
            return "Not connected"
        }
    }

    // MARK: - Initialization

    init(homeKitManager: HomeKitManager) {
        self.homeKitManager = homeKitManager
    }

    // MARK: - Authentication

    func authenticate(serverURL: String, email: String, password: String) async throws {
        // Normalize URL
        var normalizedURL = serverURL
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }
        if normalizedURL.hasSuffix("/") {
            normalizedURL.removeLast()
        }

        // Call login API
        let loginURL = URL(string: "\(normalizedURL)/auth/login")!
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorData = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ConnectionError.serverError(errorData.message)
            }
            throw ConnectionError.authenticationFailed
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)

        // Save credentials
        self.serverURL = normalizedURL
        self.savedEmail = email
        self.authToken = authResponse.token
        self.isAuthenticated = true

        saveCredentials()

        // Connect WebSocket
        try await connect()
    }

    func restoreSession() async {
        loadCredentials()

        guard !serverURL.isEmpty, authToken != nil else {
            return
        }

        isAuthenticated = true

        // Try to connect
        do {
            try await connect()
        } catch {
            print("[ConnectionManager] Failed to restore session: \(error)")
            // Don't clear credentials - user can retry
        }
    }

    // MARK: - WebSocket Connection

    private func connect() async throws {
        guard let token = authToken else {
            throw ConnectionError.notAuthenticated
        }

        // Build WebSocket URL
        var wsURL = serverURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        wsURL += "/ws"

        guard let url = URL(string: wsURL) else {
            throw ConnectionError.invalidURL
        }

        // Wait for HomeKit to be ready
        await homeKitManager.waitForReady()

        // Create and connect WebSocket
        webSocketClient = WebSocketClient(
            url: url,
            token: token,
            homeKitManager: homeKitManager
        )

        webSocketClient?.onConnect = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
            }
        }

        webSocketClient?.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.isConnected = false
                if let error = error {
                    print("[ConnectionManager] Disconnected: \(error)")
                }
            }
        }

        try await webSocketClient?.connect()
    }

    func disconnect() {
        webSocketClient?.disconnect()
        webSocketClient = nil
        isConnected = false
    }

    func signOut() {
        disconnect()
        isAuthenticated = false
        authToken = nil
        clearCredentials()
    }

    // MARK: - Credential Storage

    private func saveCredentials() {
        UserDefaults.standard.set(serverURL, forKey: serverURLKey)
        UserDefaults.standard.set(savedEmail, forKey: emailKey)

        if let token = authToken {
            saveToKeychain(key: tokenKey, value: token)
        }
    }

    private func loadCredentials() {
        serverURL = UserDefaults.standard.string(forKey: serverURLKey) ?? ""
        savedEmail = UserDefaults.standard.string(forKey: emailKey) ?? ""
        authToken = loadFromKeychain(key: tokenKey)
    }

    private func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        deleteFromKeychain(key: tokenKey)
        serverURL = ""
        savedEmail = ""
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        SecItemAdd(newItem as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Error Types

enum ConnectionError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notAuthenticated
    case authenticationFailed
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .notAuthenticated:
            return "Not authenticated"
        case .authenticationFailed:
            return "Authentication failed"
        case .serverError(let message):
            return message
        }
    }
}

// MARK: - Response Types

struct AuthResponse: Codable {
    let token: String
    let user: UserInfo?
}

struct UserInfo: Codable {
    let id: String
    let email: String
}

struct ErrorResponse: Codable {
    let message: String
}
