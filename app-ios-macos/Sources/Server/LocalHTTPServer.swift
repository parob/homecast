import Foundation
import Network

/// Lightweight HTTP server using NWListener.
/// Serves bundled web app static files and handles API/WebSocket requests.
/// Used in Community mode to make the Mac app fully self-contained.
class LocalHTTPServer {
    /// Singleton for access from the WKWebView Coordinator (avoids UIApplicationDelegateAdaptor proxy issue)
    static var shared: LocalHTTPServer?

    private var listener: NWListener?
    private var wsListener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.homecast.localserver", qos: .userInitiated)

    /// Connected WebSocket clients (for broadcasting)
    private(set) var wsClients: [String: NWConnection] = [:]

    /// Bridge for forwarding WebSocket messages to/from the WKWebView JS context
    weak var bridge: LocalNetworkBridge? {
        didSet {
            // Process any queued GraphQL requests now that the bridge is available
            if bridge != nil {
                // Drain on the server queue where requests were enqueued
                queue.async { [weak self] in
                    guard let self = self else { return }
                    let pending = self.pendingGraphQLRequests
                    self.pendingGraphQLRequests.removeAll()
                    for request in pending {
                        request()
                    }
                }
            }
        }
    }
    /// Queued GraphQL requests waiting for the bridge to initialize
    private var pendingGraphQLRequests: [() -> Void] = []
    private let webDistPath: String?
    private(set) var port: UInt16 = 0
    private(set) var wsPort: UInt16 = 0
    private(set) var isRunning = false

    // Bonjour service name (unique per Mac)
    private let serviceName: String

    // MIME type mapping
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "webp": "image/webp",
        "webm": "video/webm",
        "mp4": "video/mp4",
        "txt": "text/plain; charset=utf-8",
        "xml": "application/xml",
        "map": "application/json",
    ]

    init() {
        // Resolve bundled web app path
        if let path = Bundle.main.path(forResource: "web-dist", ofType: nil) {
            self.webDistPath = path
        } else {
            print("[LocalHTTPServer] Warning: web-dist not found in bundle")
            self.webDistPath = nil
        }

        // Use hostname for unique Bonjour service name
        self.serviceName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
    }

    /// Callback fired when the server is ready (port bound).
    var onReady: (() -> Void)?

    /// Start the server, trying ports 5656-5660.
    func start() {
        guard !isRunning else { return }

        for candidatePort in UInt16(5656)...UInt16(5660) {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true

                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidatePort)!)
                listener.service = NWListener.Service(
                    name: serviceName,
                    type: "_homecast._tcp"
                )

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.port = candidatePort
                        NSLog("[LocalHTTPServer] Listening on port %d", candidatePort)
                        DispatchQueue.main.async { self?.onReady?() }
                    case .failed(let error):
                        print("[LocalHTTPServer] Listener failed: \(error)")
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleNewConnection(connection)
                }

                listener.start(queue: queue)
                self.listener = listener
                startWSListener(httpPort: candidatePort)
                return // Success — stop trying ports
            } catch {
                print("[LocalHTTPServer] Port \(candidatePort) unavailable: \(error)")
                continue
            }
        }

        print("[LocalHTTPServer] Failed to bind any port in range 5656-5660")
    }

    /// Start WebSocket listener on port HTTP+1 using NWProtocolWebSocket.
    private func startWSListener(httpPort: UInt16) {
        let wsPortCandidate = httpPort + 1

        let wsParams = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        wsParams.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: wsParams, on: NWEndpoint.Port(rawValue: wsPortCandidate)!)

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.wsPort = wsPortCandidate
                    NSLog("[LocalHTTPServer] WebSocket listening on port %d", wsPortCandidate)
                case .failed(let error):
                    NSLog("[LocalHTTPServer] WS listener failed: %@", error.localizedDescription)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewWSConnection(connection)
            }

            listener.start(queue: queue)
            self.wsListener = listener
        } catch {
            NSLog("[LocalHTTPServer] Failed to start WS listener on port %d: %@", wsPortCandidate, error.localizedDescription)
        }
    }

    /// Stop the server and disconnect all clients.
    func stop() {
        listener?.cancel()
        listener = nil
        wsListener?.cancel()
        wsListener = nil
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        for (_, connection) in wsClients {
            connection.cancel()
        }
        wsClients.removeAll()
        isRunning = false
        port = 0
        wsPort = 0
        print("[LocalHTTPServer] Stopped")
    }

    /// Restart the server (e.g., after wake from sleep).
    func restart() {
        stop()
        start()
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        // Read up to 64KB for the HTTP request (headers + body)
        // Safari/WKWebView may split headers and body across TCP segments,
        // so we check Content-Length and read more if the body is incomplete.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    print("[LocalHTTPServer] Receive error: \(error)")
                }
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendResponse(on: connection, status: 400, body: "Bad Request")
                return
            }

            // Check if the full body has arrived
            let contentLength = self.parseContentLength(from: requestString)
            if contentLength > 0, let headerEnd = requestString.range(of: "\r\n\r\n") {
                let receivedBody = requestString[headerEnd.upperBound...]
                let receivedBytes = receivedBody.utf8.count
                if receivedBytes < contentLength {
                    // Body incomplete — read the remaining bytes
                    let remaining = contentLength - receivedBytes
                    connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { moreData, _, _, _ in
                        if let moreData = moreData, let moreString = String(data: moreData, encoding: .utf8) {
                            self.handleHTTPRequest(requestString + moreString, rawData: data + moreData, on: connection)
                        } else {
                            // Couldn't read more — proceed with what we have
                            self.handleHTTPRequest(requestString, rawData: data, on: connection)
                        }
                    }
                    return
                }
            }

            self.handleHTTPRequest(requestString, rawData: data, on: connection)
        }
    }

    private func parseContentLength(from request: String) -> Int {
        for line in request.components(separatedBy: "\r\n") {
            if line.isEmpty { break } // End of headers
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    // MARK: - HTTP Request Parsing & Routing

    private func handleHTTPRequest(_ request: String, rawData: Data, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(on: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(on: connection, status: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Handle CORS preflight
        if method == "OPTIONS" {
            sendResponse(on: connection, status: 204, headers: corsHeaders(), body: nil)
            return
        }

        // WebSocket upgrade — redirect to WS port
        if headers["upgrade"]?.lowercased() == "websocket" {
            // External clients should connect to the WS port directly
            sendResponse(on: connection, status: 400, body: "Use ws://host:\(wsPort)/ws for WebSocket")
            return
        }

        // Community mode config — web app fetches this on startup to detect mode
        if path == "/config.json" {
            let json = """
            {"mode":"community","version":"\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")","port":\(port),"wsPort":\(wsPort)}
            """
            sendResponse(on: connection, status: 200, contentType: "application/json", body: json)
            return
        }

        // Health check
        if path == "/health" {
            let json = """
            {"status":"ok","mode":"community","port":\(port),"wsPort":\(wsPort),"wsClients":\(wsClients.count),"bridgeAttached":\(bridge != nil)}
            """
            sendResponse(on: connection, status: 200, contentType: "application/json", body: json)
            return
        }

        // REST, MCP, OAuth endpoints — forward to JS bridge
        if path.hasPrefix("/rest/") || path == "/mcp" || path.hasPrefix("/oauth/") || path.hasPrefix("/.well-known/") || path == "/register" {
            let body = extractBody(from: request)
            if let bridge = bridge {
                let clientId = "http-\(UUID().uuidString)"
                // Build request info as JSON using JSONSerialization for safe encoding
                var info: [String: Any] = [
                    "method": method,
                    "path": rawPath,
                ]
                if !body.isEmpty { info["body"] = body }
                info["authorization"] = headers["authorization"] ?? ""
                let requestJson = (try? JSONSerialization.data(withJSONObject: info))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                bridge.handleHTTPRequest(clientId: clientId, body: requestJson) { [weak self] response in
                    if let data = response.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // _serveSPA: JS says this is a frontend route — serve index.html
                        if json["_serveSPA"] as? Bool == true {
                            self?.serveStaticFile(path: "/index.html", on: connection)
                            return
                        }
                        // _status/_headers overrides from JS (used by OAuth redirects)
                        if let status = json["_status"] as? Int {
                            let extraHeaders = json["_headers"] as? [String: String] ?? [:]
                            let body = json["_body"] as? String ?? ""
                            let ct = status == 302 ? "text/plain" : "application/json"
                            self?.sendResponse(on: connection, status: status, contentType: ct, headers: extraHeaders, body: body)
                            return
                        }
                    }
                    self?.sendResponse(on: connection, status: 200, contentType: "application/json", body: response)
                }
            } else {
                sendResponse(on: connection, status: 503, contentType: "application/json", body: "{\"error\":\"Bridge not ready\"}")
            }
            return
        }

        // GraphQL endpoint — forward to JS bridge if available, otherwise queue
        if method == "POST" && (path == "/" || path == "/graphql") {
            let body = extractBody(from: request)
            let operationName = extractOperationName(from: body) ?? "unknown"
            NSLog("[LocalHTTPServer] GraphQL %@ — bridge: %@, body length: %d", operationName, bridge != nil ? "ready" : "nil", body.count)
            if let bridge = bridge {
                let clientId = "graphql-\(UUID().uuidString)"
                bridge.handleGraphQLRequest(clientId: clientId, body: body) { [weak self] response in
                    NSLog("[LocalHTTPServer] GraphQL %@ response: %@", operationName, String(response.prefix(100)))
                    self?.sendResponse(on: connection, status: 200, contentType: "application/json", body: response)
                }
            } else {
                // Bridge not ready — queue the request until it initializes
                pendingGraphQLRequests.append { [weak self] in
                    guard let self = self, let bridge = self.bridge else {
                        self?.sendResponse(on: connection, status: 503, contentType: "application/json", body: """
                        {"errors":[{"message":"Bridge unavailable"}]}
                        """)
                        return
                    }
                    let clientId = "graphql-\(UUID().uuidString)"
                    bridge.handleGraphQLRequest(clientId: clientId, body: body) { [weak self] response in
                        self?.sendResponse(on: connection, status: 200, contentType: "application/json", body: response)
                    }
                }
            }
            return
        }

        // Static file serving
        if method == "GET" {
            serveStaticFile(path: path, on: connection)
            return
        }

        sendResponse(on: connection, status: 405, body: "Method Not Allowed")
    }

    // MARK: - Static File Serving

    private func serveStaticFile(path: String, on connection: NWConnection) {
        guard let webDistPath = webDistPath else {
            sendResponse(on: connection, status: 503, body: "Web app not bundled")
            return
        }

        // Sanitize path to prevent directory traversal
        let sanitized = path
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let filePath: String
        if sanitized.isEmpty {
            filePath = webDistPath + "/index.html"
        } else {
            filePath = webDistPath + "/" + sanitized
        }

        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: filePath) {
            // Serve the file
            serveFile(atPath: filePath, on: connection)
        } else {
            // SPA fallback: serve index.html for routes without file extensions
            let ext = (sanitized as NSString).pathExtension
            if ext.isEmpty {
                let indexPath = webDistPath + "/index.html"
                if fileManager.fileExists(atPath: indexPath) {
                    serveFile(atPath: indexPath, on: connection)
                } else {
                    sendResponse(on: connection, status: 404, body: "Not Found")
                }
            } else {
                sendResponse(on: connection, status: 404, body: "Not Found")
            }
        }
    }

    private func serveFile(atPath path: String, on connection: NWConnection) {
        guard var data = FileManager.default.contents(atPath: path) else {
            sendResponse(on: connection, status: 500, body: "Internal Server Error")
            return
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let contentType = Self.mimeTypes[ext] ?? "application/octet-stream"

        // Inject Community mode flag into index.html so the web app detects
        // Community mode regardless of hostname (works with tunnels like Cloudflare)
        if ext == "html", var html = String(data: data, encoding: .utf8) {
            let injection = "<script>window.__HOMECAST_COMMUNITY__=true</script>"
            if let range = html.range(of: "</head>") {
                html.insert(contentsOf: injection, at: range.lowerBound)
                data = html.data(using: .utf8) ?? data
            }
        }

        // Build HTTP response
        var headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Cache-Control: \(ext == "html" || ext == "js" ? "no-cache" : "public, max-age=3600")",
        ]
        headerLines.append(contentsOf: corsHeaders().map { "\($0.key): \($0.value)" })
        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")

        let headerString = headerLines.joined(separator: "\r\n")
        var responseData = headerString.data(using: .utf8)!
        responseData.append(data)

        connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                print("[LocalHTTPServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }

    // MARK: - WebSocket (NWProtocolWebSocket)

    private func handleNewWSConnection(_ connection: NWConnection) {
        let clientId = UUID().uuidString

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.wsClients[clientId] = connection
                NSLog("[LocalHTTPServer] WS client connected: %@ (total: %d)", clientId, self?.wsClients.count ?? 0)

                // Send initial config (mirrors cloud server behavior)
                let config = """
                {"type":"broadcast","action":"config","payload":{"webClientCount":0,"webhookCount":0,"subscriptionCount":0,"accessoryLimit":null}}
                """
                self?.sendWSMessage(config, on: connection)

                // Start reading messages
                self?.receiveWSMessage(clientId: clientId, on: connection)

            case .failed, .cancelled:
                self?.removeWSClient(clientId)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveWSMessage(clientId: String, on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[LocalHTTPServer] WS receive error: %@", error.localizedDescription)
                self.removeWSClient(clientId)
                return
            }

            // Check if this is a close frame
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if metadata.opcode == .close {
                    NSLog("[LocalHTTPServer] WS client sent close frame: %@", clientId)
                    self.removeWSClient(clientId)
                    return
                }
            }

            if let data = data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                self.bridge?.handleExternalMessage(clientId: clientId, message: text)
            }

            // Continue reading next message
            self.receiveWSMessage(clientId: clientId, on: connection)
        }
    }

    func sendWSMessage(_ text: String, on connection: NWConnection) {
        let data = text.data(using: .utf8)!
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[LocalHTTPServer] WS send error: %@", error.localizedDescription)
            }
        })
    }

    /// Broadcast a message to ALL connected WebSocket clients.
    func broadcastToWSClients(_ text: String) {
        for (_, connection) in wsClients {
            sendWSMessage(text, on: connection)
        }
    }

    private func removeWSClient(_ clientId: String) {
        if let connection = wsClients.removeValue(forKey: clientId) {
            connection.cancel()
        }
        NSLog("[LocalHTTPServer] WS client removed: %@ (remaining: %d)", clientId, wsClients.count)
        bridge?.handleClientDisconnected(clientId: clientId)
    }

    /// Send a WebSocket message to a specific client (used by bridge for responses).
    func sendToWSClient(clientId: String, message: String) {
        guard let connection = wsClients[clientId] else { return }
        sendWSMessage(message, on: connection)
    }

    // MARK: - GraphQL Stub Responses

    private func extractBody(from request: String) -> String {
        // HTTP body comes after the blank line (\r\n\r\n)
        guard let range = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[range.upperBound...])
    }

    private func extractOperationName(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["operationName"] as? String else {
            return nil
        }
        return name
    }

    private func stubGraphQLResponse(for operationName: String?) -> String {
        switch operationName {
        case "GetMe":
            return """
            {"data":{"me":{"id":"community-local","email":"local@homecast","name":null,"isAdmin":true,"accountType":"standard","stagingAccess":false,"createdAt":"\(ISO8601DateFormatter().string(from: Date()))","lastLoginAt":"\(ISO8601DateFormatter().string(from: Date()))","__typename":"User"}}}
            """
        case "GetSettings":
            return """
            {"data":{"settings":{"data":"{}","__typename":"UserSettings"}}}
            """
        case "GetAccount":
            return """
            {"data":{"account":{"accountType":"standard","accessoryLimit":null,"adsenseAdsEnabled":false,"smartDealsEnabled":false,"hasSubscription":true,"cloudSignupsAvailable":0,"__typename":"Account"}}}
            """
        case "GetCollections":
            return """
            {"data":{"collections":[]}}
            """
        case "GetCachedHomes":
            return """
            {"data":{"cachedHomes":[]}}
            """
        case "GetStoredEntities":
            return """
            {"data":{"storedEntities":[]}}
            """
        case "GetRoomGroups":
            return """
            {"data":{"roomGroups":[]}}
            """
        case "GetSessions":
            return """
            {"data":{"sessions":[]}}
            """
        case "GetPendingInvitations":
            return """
            {"data":{"pendingInvitations":[]}}
            """
        case "IsOnboarded":
            // If the server is running, the relay is ready. Auth status comes from
            // the JS bridge (when available), but stub assumes disabled for quick responses.
            return """
            {"data":{"isOnboarded":true,"relayReady":true,"authEnabled":false}}
            """
        case "GetVersion":
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return """
            {"data":{"version":"\(version)","deployedAt":"\(ISO8601DateFormatter().string(from: Date()))"}}
            """
        case "GetMySharedHomes":
            return """
            {"data":{"mySharedHomes":[]}}
            """
        case "GetHcAutomations":
            return """
            {"data":{"hcAutomations":[]}}
            """
        case "GetActiveDeals":
            return """
            {"data":{"activeDeals":[]}}
            """
        case "GetWebhooks":
            return """
            {"data":{"webhooks":[]}}
            """
        case "GetAccessTokens":
            return """
            {"data":{"accessTokens":[]}}
            """
        case "GetAuthorizedApps":
            return """
            {"data":{"authorizedApps":[]}}
            """
        case "GetConnectionDebugInfo":
            return """
            {"data":{"connectionDebugInfo":{"serverInstanceId":"community-local","pubsubEnabled":false,"pubsubSlot":null,"__typename":"ConnectionDebugInfo"}}}
            """
        case "GetMyEnrollments":
            return """
            {"data":{"myEnrollments":[]}}
            """
        case "GetBackgroundPresets":
            return """
            {"data":{"backgroundPresets":[]}}
            """
        case "GetUserBackgrounds":
            return """
            {"data":{"userBackgrounds":[]}}
            """
        default:
            // For any unknown query, return empty data (no error)
            // This prevents the app from getting stuck on loading
            print("[LocalHTTPServer] Unknown GraphQL operation: \(operationName ?? "nil")")
            return """
            {"data":{}}
            """
        }
    }

    // MARK: - Response Helpers

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
        ]
    }

    private func sendResponse(on connection: NWConnection, status: Int, contentType: String = "text/plain", headers: [String: String] = [:], body: String?) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 204: statusText = "No Content"
        case 302: statusText = "Found"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        case 501: statusText = "Not Implemented"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }

        let bodyData = body?.data(using: .utf8)
        var headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
        ]

        if let bodyData = bodyData {
            headerLines.append("Content-Type: \(contentType)")
            headerLines.append("Content-Length: \(bodyData.count)")
        }

        for (key, value) in corsHeaders() {
            headerLines.append("\(key): \(value)")
        }
        for (key, value) in headers {
            headerLines.append("\(key): \(value)")
        }

        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")

        var responseData = headerLines.joined(separator: "\r\n").data(using: .utf8)!
        if let bodyData = bodyData {
            responseData.append(bodyData)
        }

        connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                print("[LocalHTTPServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }
}
