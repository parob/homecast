import Compression
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
    /// Bonjour service name. Lazy on purpose: `ProcessInfo.hostName` performs a
    /// blocking reverse-DNS resolution that has taken ~20s on a phone, and both
    /// callers construct this server on the main thread. Only `.network`
    /// exposure advertises, so a loopback server on iOS must never pay for it.
    private lazy var serviceName: String = ProcessInfo.processInfo.hostName
        .replacingOccurrences(of: ".local", with: "")

    /// Stable id for this relay, minted once and kept in UserDefaults.
    /// Clients key "the relay I paired with" on this rather than on the name,
    /// which changes when the Mac is renamed or picks up a new DHCP lease.
    private let instanceId: String

    /// Whether the relay requires a login. Lives in the web app's IndexedDB,
    /// so it arrives over the bridge rather than being read here; nil until it
    /// has reported once.
    private var advertisedAuthEnabled: Bool?

    /// Ports to try, in order. They stride by two because the WebSocket
    /// listener binds HTTP+1 — a contiguous ladder would hand the next HTTP
    /// attempt the port the WebSocket listener just took.
    private let portCandidates: [UInt16] = [5656, 5658, 5660, 5662, 5664]
    private var candidateIndex = 0
    /// Fences listener callbacks, so a listener cancelled by a newer start()
    /// cannot advance the current attempt.
    private var bindGeneration = 0
    /// Fences callbacks *within* one ladder run. Every attempt shares a
    /// generation, so without this a late failure from the listener we just
    /// abandoned would advance the ladder a second time and silently skip a
    /// candidate port.
    private var attemptToken = 0

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

    /// How far the server is reachable.
    ///
    /// The two callers want opposite things, and the difference is a security
    /// boundary rather than a preference — `/rest/*` controls HomeKit.
    enum Exposure {
        /// Reachable from the LAN and advertised over Bonjour. The Mac in
        /// Community mode: serving browsers, Home Assistant and the iOS app is
        /// the entire point of that mode.
        case network

        /// Loopback only, no Bonjour, no WebSocket listener. iOS uses this
        /// purely to host the bundled web app at a stable origin that can be
        /// named in WKAppBoundDomains. Nothing off-device may reach it: a
        /// phone has no external clients, and binding its HomeKit control
        /// endpoints to Wi-Fi would be a straight security regression.
        /// Staying off Bonjour also avoids triggering the iOS Local Network
        /// permission prompt, which we'd have no way to justify.
        case loopback
    }

    let exposure: Exposure

    init(exposure: Exposure = .network) {
        self.exposure = exposure

        // Resolve bundled web app path
        if let path = Bundle.main.path(forResource: "web-dist", ofType: nil) {
            self.webDistPath = path
        } else {
            print("[LocalHTTPServer] Warning: web-dist not found in bundle")
            self.webDistPath = nil
        }

        // `serviceName` stays lazy — ProcessInfo.hostName performs a blocking
        // reverse-DNS resolve, and only a network-exposed server ever needs it.
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "com.homecast.relayInstanceId") {
            self.instanceId = existing
        } else {
            let minted = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(8)
                .lowercased()
            defaults.set(minted, forKey: "com.homecast.relayInstanceId")
            self.instanceId = minted
        }
    }

    /// Callback fired when the server is ready (port bound).
    var onReady: (() -> Void)?

    /// Start the server on the first free candidate port.
    func start() {
        guard !isRunning else { return }
        bindGeneration &+= 1
        candidateIndex = 0
        attemptBind(generation: bindGeneration)
    }

    /// Try `portCandidates[candidateIndex]`, falling through to the next on failure.
    ///
    /// This is a callback ladder rather than a loop because a busy port does not
    /// throw: `NWListener` accepts it and then reports `.failed` asynchronously.
    /// The old loop returned as soon as `start()` was called, so the fallback
    /// range never ran and a busy 5656 left no server and no advertisement.
    private func attemptBind(generation: Int) {
        guard generation == bindGeneration else { return }
        guard candidateIndex < portCandidates.count else {
            NSLog("[LocalHTTPServer] Failed to bind any port in %@", "\(portCandidates)")
            return
        }
        let candidatePort = portCandidates[candidateIndex]
        attemptToken &+= 1
        let token = attemptToken

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if exposure == .loopback {
            params.requiredInterfaceType = .loopback
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidatePort)!)
        } catch {
            print("[LocalHTTPServer] Port \(candidatePort) unavailable: \(error)")
            advance(from: generation)
            return
        }

        // Only a network-exposed server advertises. A loopback server has no
        // external clients to be found by, and staying off Bonjour is what
        // keeps iOS from raising a Local Network prompt we could not justify.
        // Published without `ws` for now — the WebSocket port isn't known until
        // its own listener is ready, which re-publishes with it.
        if exposure == .network {
            listener.service = makeService()
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self,
                  generation == self.bindGeneration,
                  token == self.attemptToken else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.port = candidatePort
                NSLog("[LocalHTTPServer] Listening on port %d", candidatePort)
                DispatchQueue.main.async {
                    // webBaseURL is built from this. Without the sync it stayed
                    // at 5656 while the listener had fallen through, and the
                    // WebView would load nothing at all.
                    AppConfig.localServerPort = candidatePort
                    self.onReady?()
                }
            case .failed(let error):
                NSLog("[LocalHTTPServer] Port %d failed: %@", candidatePort, error.localizedDescription)
                guard !self.isRunning else {
                    // Already serving — this is a later collapse, not a bind
                    // failure. Wake-from-sleep restarts us; don't re-ladder.
                    self.isRunning = false
                    return
                }
                self.teardownPair()
                self.advance(from: generation)
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
        // A loopback server exists only to serve the app's own UI; the
        // WebSocket listener is for external clients, which by definition
        // cannot reach it.
        if exposure == .network {
            startWSListener(httpPort: candidatePort, generation: generation, token: token)
        }
    }

    private func advance(from generation: Int) {
        guard generation == bindGeneration else { return }
        candidateIndex += 1
        attemptBind(generation: generation)
    }

    private func teardownPair() {
        listener?.cancel()
        listener = nil
        wsListener?.cancel()
        wsListener = nil
        isRunning = false
        port = 0
        wsPort = 0
    }

    /// Start the WebSocket listener on HTTP port + 1.
    ///
    /// HTTP and WS bind as a pair: if WS can't come up, the HTTP listener it
    /// belongs to is torn down and the ladder moves on, rather than leaving a
    /// server that serves pages but can never push an update.
    private func startWSListener(httpPort: UInt16, generation: Int, token: Int) {
        let wsPortCandidate = httpPort + 1

        let wsParams = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        wsParams.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: wsParams, on: NWEndpoint.Port(rawValue: wsPortCandidate)!)
        } catch {
            NSLog("[LocalHTTPServer] WS port %d unavailable: %@", wsPortCandidate, error.localizedDescription)
            failWSPair(generation: generation, token: token)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self,
                  generation == self.bindGeneration,
                  token == self.attemptToken else { return }
            switch state {
            case .ready:
                self.wsPort = wsPortCandidate
                NSLog("[LocalHTTPServer] WebSocket listening on port %d", wsPortCandidate)
                // Re-publish now that `ws` can be filled in.
                self.listener?.service = self.makeService()
            case .failed(let error):
                NSLog("[LocalHTTPServer] WS listener failed on %d: %@", wsPortCandidate, error.localizedDescription)
                // wsPort is only set once ready, so a non-zero value means this
                // is a later collapse rather than a failure to bind.
                guard self.wsPort == 0 else { return }
                self.failWSPair(generation: generation, token: token)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewWSConnection(connection)
        }

        listener.start(queue: queue)
        self.wsListener = listener
    }

    /// Drop the whole HTTP+WS pair for this candidate and try the next.
    private func failWSPair(generation: Int, token: Int) {
        guard generation == bindGeneration, token == attemptToken else { return }
        teardownPair()
        advance(from: generation)
    }

    // MARK: - Bonjour

    /// The Bonjour advertisement.
    ///
    /// TXT carries what a browsing client cannot otherwise learn: the WebSocket
    /// port (that listener doesn't advertise, and deriving it from the HTTP port
    /// is a guess), a stable id that outlives a rename or a new DHCP lease, and
    /// whether the relay asks for a login at all.
    ///
    /// Not included: the HTTP port, which the SRV record already carries, and a
    /// display name, which is the Bonjour instance name.
    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["id"] = instanceId
        txt["md"] = "community"
        txt["vs"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        // Unknown reads as "no password", so a relay whose web app hasn't
        // reported yet is flagged rather than silently trusted.
        txt["au"] = (advertisedAuthEnabled == true) ? "1" : "0"
        if wsPort != 0 { txt["ws"] = String(wsPort) }
        return NWListener.Service(
            name: serviceName,
            type: "_homecast._tcp",
            domain: nil,
            txtRecord: txt
        )
    }

    /// Re-publish the advertisement when the relay's auth setting changes.
    /// Called from the web app over the `localServer` bridge.
    func updateAdvertisement(authEnabled: Bool) {
        queue.async { [weak self] in
            guard let self = self, self.advertisedAuthEnabled != authEnabled else { return }
            self.advertisedAuthEnabled = authEnabled
            guard self.isRunning else { return }
            self.listener?.service = self.makeService()
        }
    }

    /// Raw JSON fragment for `authEnabled`: `null` until the web app reports.
    private var authEnabledJSON: String {
        advertisedAuthEnabled.map { $0 ? "true" : "false" } ?? "null"
    }

    /// Stop the server and disconnect all clients.
    func stop() {
        // Invalidate any in-flight bind ladder, so a listener cancelled here
        // cannot advance to the next candidate after we've been told to stop.
        bindGeneration &+= 1
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
            // Echo back exactly what was asked for. A fixed allow-list is a
            // standing trap: any header the client adds later is refused, the
            // request is never sent, and the only symptom is "Load failed".
            var preflight: [String: String] = [:]
            if let requested = headers["access-control-request-headers"], !requested.isEmpty {
                preflight["Access-Control-Allow-Headers"] = requested
            }
            sendResponse(on: connection, status: 204, headers: preflight, body: nil)
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
            let mqttStatus = bridge?.mqttBridge?.statusDescription
            let mqttJson = mqttStatus != nil ? "\"\(mqttStatus!)\"" : "null"
            let json = """
            {"mode":"community","version":"\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")","port":\(port),"wsPort":\(wsPort),"instanceId":"\(instanceId)","authEnabled":\(authEnabledJSON),"mqtt":\(mqttJson)}
            """
            sendResponse(on: connection, status: 200, contentType: "application/json", body: json)
            return
        }

        // Health check
        if path == "/health" {
            let mqttStatus = bridge?.mqttBridge?.statusDescription
            let mqttJson = mqttStatus != nil ? "\"\(mqttStatus!)\"" : "null"
            let json = """
            {"status":"ok","mode":"community","port":\(port),"wsPort":\(wsPort),"instanceId":"\(instanceId)","authEnabled":\(authEnabledJSON),"wsClients":\(wsClients.count),"bridgeAttached":\(bridge != nil),"mqtt":\(mqttJson)}
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
                bridge.handleGraphQLRequest(clientId: clientId, body: body, authorization: headers["authorization"]) { [weak self] response in
                    NSLog("[LocalHTTPServer] GraphQL %@ response: %@", operationName, String(response.prefix(100)))
                    self?.sendResponse(on: connection, status: 200, contentType: "application/json", body: response)
                }
            } else if exposure == .loopback {
                // No bridge ever attaches on the loopback path — this device
                // hosts its own UI and is not a relay. Queueing would hold the
                // caller open forever, which is precisely what left iOS on an
                // endless spinner. Fail fast so the client can say so.
                sendResponse(on: connection, status: 503, contentType: "application/json", body: """
                {"data":null,"errors":[{"message":"This device is not a relay"}]}
                """)
            } else {
                // Bridge not ready — queue the request until it initializes.
                // Capture the header now; `headers` does not outlive this scope.
                let authorization = headers["authorization"]
                pendingGraphQLRequests.append { [weak self] in
                    guard let self = self, let bridge = self.bridge else {
                        self?.sendResponse(on: connection, status: 503, contentType: "application/json", body: """
                        {"errors":[{"message":"Bridge unavailable"}]}
                        """)
                        return
                    }
                    let clientId = "graphql-\(UUID().uuidString)"
                    bridge.handleGraphQLRequest(clientId: clientId, body: body, authorization: authorization) { [weak self] response in
                        self?.sendResponse(on: connection, status: 200, contentType: "application/json", body: response)
                    }
                }
            }
            return
        }

        // Static file serving
        if method == "GET" {
            let acceptsGzip = (headers["accept-encoding"] ?? "").lowercased().contains("gzip")
            serveStaticFile(path: path, on: connection, acceptsGzip: acceptsGzip)
            return
        }

        sendResponse(on: connection, status: 405, body: "Method Not Allowed")
    }

    // MARK: - Static File Serving

    private func serveStaticFile(path: String, on connection: NWConnection, acceptsGzip: Bool = false) {
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
            serveFile(atPath: filePath, on: connection, acceptsGzip: acceptsGzip)
        } else {
            // SPA fallback: serve index.html for routes without file extensions
            let ext = (sanitized as NSString).pathExtension
            if ext.isEmpty {
                let indexPath = webDistPath + "/index.html"
                if fileManager.fileExists(atPath: indexPath) {
                    serveFile(atPath: indexPath, on: connection, acceptsGzip: acceptsGzip)
                } else {
                    sendResponse(on: connection, status: 404, body: "Not Found")
                }
            } else {
                sendResponse(on: connection, status: 404, body: "Not Found")
            }
        }
    }

    private func serveFile(atPath path: String, on connection: NWConnection, acceptsGzip: Bool = false) {
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

        // Vite content-hashes everything under /assets/, so those URLs are
        // immutable and can be cached hard. Only index.html must stay fresh —
        // it is what points at the current hashes. Previously js was no-cache
        // too, so every launch re-read the whole bundle.
        let isHashedAsset = path.contains("/assets/") && ext != "html"
        let cacheControl: String
        if ext == "html" {
            cacheControl = "no-cache"
        } else if isHashedAsset {
            cacheControl = "public, max-age=31536000, immutable"
        } else {
            cacheControl = "public, max-age=3600"
        }

        // Compress text-ish payloads. The Mac's own WKWebView barely notices
        // (loopback), but every LAN client — the phone or browser this mode
        // exists to serve — was pulling the bundle uncompressed over WiFi.
        // Images/fonts are already compressed, so skip them.
        var contentEncoding: String? = nil
        if acceptsGzip, Self.compressibleExtensions.contains(ext), data.count >= 1024,
           let gzipped = Self.gzip(data) {
            data = gzipped
            contentEncoding = "gzip"
        }

        // Build HTTP response
        var headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Cache-Control: \(cacheControl)",
        ]
        if let contentEncoding = contentEncoding {
            headerLines.append("Content-Encoding: \(contentEncoding)")
            // Caches must not hand a gzipped body to a client that didn't ask.
            headerLines.append("Vary: Accept-Encoding")
        }
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

    // MARK: - gzip

    /// Extensions worth compressing. Everything else on disk (png/jpg/woff2/…)
    /// is already compressed and would only get bigger.
    private static let compressibleExtensions: Set<String> = [
        "html", "js", "css", "json", "svg", "txt", "xml", "map",
    ]

    /// CRC-32 (IEEE), needed for the gzip trailer.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    /// Wrap raw DEFLATE (which is what COMPRESSION_ZLIB emits here) in a gzip
    /// container: 10-byte header, payload, then CRC32 and ISIZE little-endian.
    /// Returns nil if compression fails or doesn't actually save anything.
    private static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let capacity = data.count + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let compressedSize: Int = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard compressedSize > 0 else { return nil }

        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        out.append(destination, count: compressedSize)

        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }

        return out.count < data.count ? out : nil
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

    /// The client sends tracing headers the allow-list did not name —
    /// `x-client-type`, `x-client-timestamp`, `x-trace-id` — and a preflight
    /// that does not allow every requested header is rejected outright, so the
    /// browser never sends the request at all. Reads only carry `content-type`
    /// and were unaffected; every write failed with a bare "Load failed" and
    /// nothing on the wire to explain it.
    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers":
                "Content-Type, Authorization, x-client-type, x-client-timestamp, x-trace-id",
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

        // Merge rather than append both sets. Appending meant a caller that
        // passed CORS headers of its own got them sent twice, and a preflight
        // answering with two Access-Control-Allow-Origin headers is a CORS
        // failure per the Fetch spec — WebKit rejects it outright. curl does
        // not care, so this survived every command-line test while blocking
        // every real cross-origin request from a browser or the iOS app.
        var merged = corsHeaders()
        for (key, value) in headers { merged[key] = value }
        for (key, value) in merged {
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
