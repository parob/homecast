import Foundation
import WebKit

/// Bridges between external WebSocket clients (via LocalHTTPServer) and the
/// WKWebView's JavaScript context. Messages from external clients are forwarded
/// to JS for processing (HomeKit actions, GraphQL), and responses/broadcasts
/// from JS are sent back to the appropriate client(s).
class LocalNetworkBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var server: LocalHTTPServer?

    /// Attach to a WKWebView — called after the WebView is created.
    func attach(webView: WKWebView, server: LocalHTTPServer) {
        self.webView = webView
        self.server = server
        server.bridge = self
        NSLog("[LocalNetworkBridge] Attached to WebView and server")
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

        default:
            NSLog("[LocalNetworkBridge] Unknown action from JS: %@", action)
        }
    }
}
