import Foundation
import SwiftUI
import Security

/// Manages authentication credentials and auth state.
/// The actual WebSocket connection is now handled by the WebView relay.
@MainActor
class ConnectionManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var serverURL: String = ""
    @Published private(set) var savedEmail: String = ""
    @Published private(set) var authToken: String?

    // MARK: - Keychain Keys

    private let keychainService = "cloud.homecast.app"
    private let serverURLKey = "serverURL"
    private let emailKey = "email"
    private let tokenKey = "authToken"

    // MARK: - Initialization

    init() {
        // Load saved credentials
        loadCredentials()
        if authToken != nil && !serverURL.isEmpty {
            isAuthenticated = true
        }
    }

    // MARK: - Authentication

    /// Authenticate using a token received from the web app
    func authenticateWithToken(_ token: String) async throws {
        print("[ConnectionManager] Authenticating with token from web")

        // Use environment-appropriate server URL
        self.serverURL = AppConfig.isStaging ? "https://staging.api.homecast.cloud" : "https://api.homecast.cloud"
        self.authToken = token
        self.isAuthenticated = true

        saveCredentials()
    }

    func signOut() {
        print("[ConnectionManager] Signing out")
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

        // Delete any existing item first
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data

        let status = SecItemAdd(newItem as CFDictionary, nil)
        if status == errSecSuccess {
            print("[Keychain] Saved \(key) successfully")
        } else {
            print("[Keychain] Failed to save \(key): \(status)")
        }
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            print("[Keychain] Loaded \(key) successfully")
            return String(data: data, encoding: .utf8)
        } else {
            print("[Keychain] Failed to load \(key): \(status)")
            return nil
        }
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        print("[Keychain] Deleted \(key): \(status)")
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
