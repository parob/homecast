import Foundation
import Security
import WebKit

/// Bridges between external WebSocket clients (via LocalHTTPServer) and the
/// WKWebView's JavaScript context. Messages from external clients are forwarded
/// to JS for processing (HomeKit actions, GraphQL), and responses/broadcasts
/// from JS are sent back to the appropriate client(s).
class LocalNetworkBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var server: LocalHTTPServer?

    /// MQTT bridge — receives broadcast events for publishing to MQTT topics
    var mqttBridge: MQTTBridge?

    /// Attach to a WKWebView — called after the WebView is created.
    func attach(webView: WKWebView, server: LocalHTTPServer) {
        self.webView = webView
        self.server = server
        server.bridge = self
        NSLog("[LocalNetworkBridge] Attached to WebView and server")

        // Attach MQTT bridge to the same WebView
        mqttBridge?.attach(webView: webView)
    }

    // MARK: - External Client → JS

    /// Called by LocalHTTPServer when a WebSocket message arrives from an external client.
    func handleExternalMessage(clientId: String, message: String) {
        guard let webView = webView else {
            NSLog("[LocalNetworkBridge] No WebView attached — dropping message from %@", clientId)
            return
        }

        // Escape the message for safe injection into JavaScript
        let escapedClientId = clientId.replacingOccurrences(of: "'", with: "\\'")
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let js = "window.__localserver_request && window.__localserver_request('\(escapedClientId)', '\(escapedMessage)');"

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    NSLog("[LocalNetworkBridge] JS eval error: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Called when an external WebSocket client disconnects.
    func handleClientDisconnected(clientId: String) {
        guard let webView = webView else { return }

        let escapedClientId = clientId.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__localserver_disconnect && window.__localserver_disconnect('\(escapedClientId)');"

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - HTTP Request Forwarding (REST, MCP, OAuth)

    private var httpCallbacks: [String: (String) -> Void] = [:]

    func handleHTTPRequest(clientId: String, body: String, completion: @escaping (String) -> Void) {
        let escapedClientId = clientId.replacingOccurrences(of: "'", with: "\\'")
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let js = "window.__localserver_http && window.__localserver_http('\(escapedClientId)', '\(escapedBody)');"

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else {
                completion("{\"error\":\"Bridge not ready\"}")
                return
            }

            self.httpCallbacks[clientId] = completion

            webView.evaluateJavaScript(js) { [weak self] _, error in
                if let error = error {
                    if let callback = self?.httpCallbacks.removeValue(forKey: clientId) {
                        callback("{\"error\":\"JS eval error: \(error.localizedDescription)\"}")
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if let callback = self?.httpCallbacks.removeValue(forKey: clientId) {
                    callback("{\"error\":\"Timeout\"}")
                }
            }
        }
    }

    // MARK: - GraphQL Forwarding

    /// Pending GraphQL request callbacks (keyed by request ID)
    private var graphqlCallbacks: [String: (String) -> Void] = [:]

    /// Forward a GraphQL POST body to JS for processing.
    /// All callback dictionary access is serialized on the main queue to prevent thread safety issues.
    func handleGraphQLRequest(clientId: String, body: String, completion: @escaping (String) -> Void) {
        let escapedClientId = clientId.replacingOccurrences(of: "'", with: "\\'")
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let js = "window.__localserver_graphql && window.__localserver_graphql('\(escapedClientId)', '\(escapedBody)');"

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else {
                completion("{\"data\":null,\"errors\":[{\"message\":\"Bridge not ready\"}]}")
                return
            }

            self.graphqlCallbacks[clientId] = completion

            webView.evaluateJavaScript(js) { [weak self] _, error in
                if let error = error {
                    NSLog("[LocalNetworkBridge] GraphQL JS eval error: %@", error.localizedDescription)
                    if let callback = self?.graphqlCallbacks.removeValue(forKey: clientId) {
                        callback("{\"data\":null,\"errors\":[{\"message\":\"JS eval error\"}]}")
                    }
                }
            }

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if let callback = self?.graphqlCallbacks.removeValue(forKey: clientId) {
                    callback("{\"data\":null,\"errors\":[{\"message\":\"Timeout\"}]}")
                }
            }
        }
    }

    // MARK: - JS → External Client (WKScriptMessageHandler)

    /// Receives messages from JavaScript via webkit.messageHandlers.localServer.postMessage()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "localServer",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        switch action {
        case "response":
            // Send response to a specific client
            guard let clientId = body["clientId"] as? String,
                  let message = body["message"] as? String else { return }
            server?.sendToWSClient(clientId: clientId, message: message)

        case "broadcast":
            // Broadcast to all connected WebSocket clients
            guard let message = body["message"] as? String else { return }
            server?.broadcastToWSClients(message)

            // Forward to MQTT bridge for publishing to MQTT topics
            if let mqttBridge = mqttBridge,
               let msgData = message.data(using: .utf8),
               let msgJson = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
               let broadcastType = msgJson["type"] as? String {
                mqttBridge.handleBroadcast(type: broadcastType, payload: msgJson)
            }

        case "graphqlResponse":
            guard let clientId = body["clientId"] as? String,
                  let response = body["response"] as? String else { return }
            if let callback = graphqlCallbacks.removeValue(forKey: clientId) {
                callback(response)
            }

        case "httpResponse":
            guard let clientId = body["clientId"] as? String,
                  let response = body["response"] as? String else { return }
            if let callback = httpCallbacks.removeValue(forKey: clientId) {
                callback(response)
            }

        case "advertise":
            // Whether the relay requires a login lives in the web app's
            // IndexedDB, so Bonjour can only learn it by being told.
            guard let authEnabled = body["authEnabled"] as? Bool else { return }
            server?.updateAdvertisement(authEnabled: authEnabled)

        case "jwtKey":
            guard let requestId = body["requestId"] as? String else { return }
            if body["rotate"] as? Bool == true { Self.deleteJWTSigningKey() }
            let key = Self.jwtSigningKey()?.base64EncodedString()
            deliverJWTKey(requestId: requestId, base64: key)

        default:
            NSLog("[LocalNetworkBridge] Unknown action from JS: %@", action)
        }
    }

    // MARK: - JWT signing key (Keychain)

    /// The relay's JWT signing key, minted on first use and kept in the
    /// Keychain.
    ///
    /// It used to be generated per launch and held in memory, which meant
    /// every restart of the Mac app silently signed out every client on the
    /// network. Keeping it here restores restart-survival while leaving the
    /// raw bytes under the OS's protection rather than in IndexedDB — which is
    /// the trade the local-auth module was written to wait for.
    private static let jwtKeychainService = "cloud.homecast.relay"
    private static let jwtKeychainAccount = "jwt-signing-key"

    private static func jwtKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: jwtKeychainService,
            kSecAttrAccount as String: jwtKeychainAccount,
        ]
    }

    static func jwtSigningKey() -> Data? {
        var query = jwtKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return data
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            NSLog("[LocalNetworkBridge] Could not generate a JWT signing key")
            return nil
        }
        let data = Data(bytes)

        var add = jwtKeychainQuery()
        add[kSecValueData as String] = data
        // The relay serves the network from launch, including before anyone
        // has unlocked the Mac since boot.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            NSLog("[LocalNetworkBridge] Keychain add failed: %d", Int(status))
            return nil
        }
        return data
    }

    /// Drop the key so the next request mints a fresh one. Used when the web
    /// app deliberately invalidates every outstanding token.
    static func deleteJWTSigningKey() {
        SecItemDelete(jwtKeychainQuery() as CFDictionary)
    }

    private func deliverJWTKey(requestId: String, base64: String?) {
        let value = base64.map { "'\($0)'" } ?? "null"
        let js = "window.__homecast_jwt_key && window.__homecast_jwt_key('\(requestId)', \(value))"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
