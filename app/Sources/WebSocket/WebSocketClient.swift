import Foundation

/// WebSocket client for communicating with the relay server
class WebSocketClient {
    private let url: URL
    private let token: String
    private let homeKitManager: HomeKitManager

    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var pingTask: Task<Void, Never>?

    // Callbacks
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(url: URL, token: String, homeKitManager: HomeKitManager) {
        self.url = url
        self.token = token
        self.homeKitManager = homeKitManager
    }

    // MARK: - Connection

    func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        // Send auth message
        let authMessage = WebSocketMessage(
            type: .auth,
            payload: ["token": .string(token)]
        )
        try await send(authMessage)

        // Wait for connected confirmation
        let response = try await receive()
        guard response.type == .connected else {
            throw WebSocketError.authenticationFailed
        }

        isConnected = true
        reconnectAttempts = 0
        onConnect?()

        // Start listening for messages
        startListening()

        // Start ping task
        startPingTask()
    }

    func disconnect() {
        isConnected = false
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Message Handling

    private func startListening() {
        Task {
            while isConnected {
                do {
                    let message = try await receive()
                    await handleMessage(message)
                } catch {
                    if isConnected {
                        print("[WebSocket] Receive error: \(error)")
                        handleDisconnect(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: WebSocketMessage) async {
        switch message.type {
        case .ping:
            // Respond with pong
            try? await send(WebSocketMessage(type: .pong))

        case .request:
            // Handle HomeKit request from server
            await handleRequest(message)

        case .connected, .pong, .response, .error, .auth:
            // These are outgoing or handled elsewhere
            break
        }
    }

    private func handleRequest(_ message: WebSocketMessage) async {
        guard let requestId = message.payload?["requestId"]?.stringValue,
              let action = message.payload?["action"]?.stringValue else {
            return
        }

        do {
            let result = try await executeHomeKitAction(action: action, params: message.payload)
            let response = WebSocketMessage(
                type: .response,
                payload: [
                    "requestId": .string(requestId),
                    "success": .bool(true),
                    "data": result
                ]
            )
            try await send(response)
        } catch {
            let errorResponse = WebSocketMessage(
                type: .response,
                payload: [
                    "requestId": .string(requestId),
                    "success": .bool(false),
                    "error": .string(error.localizedDescription)
                ]
            )
            try? await send(errorResponse)
        }
    }

    private func executeHomeKitAction(action: String, params: [String: JSONValue]?) async throws -> JSONValue {
        switch action {
        case "listHomes":
            let homes = await MainActor.run { homeKitManager.listHomes() }
            return .array(homes.map { $0.toJSON() })

        case "listRooms":
            guard let homeId = params?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let rooms = try await MainActor.run { try homeKitManager.listRooms(homeId: homeId) }
            return .array(rooms.map { $0.toJSON() })

        case "listAccessories":
            let homeId = params?["homeId"]?.stringValue
            let roomId = params?["roomId"]?.stringValue
            let accessories = try await MainActor.run {
                try homeKitManager.listAccessories(homeId: homeId, roomId: roomId)
            }
            return .array(accessories.map { $0.toJSON() })

        case "getAccessory":
            guard let accessoryId = params?["accessoryId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing accessoryId")
            }
            let accessory = try await MainActor.run { try homeKitManager.getAccessory(id: accessoryId) }
            return accessory.toJSON()

        case "controlAccessory":
            guard let accessoryId = params?["accessoryId"]?.stringValue,
                  let characteristic = params?["characteristic"]?.stringValue,
                  let value = params?["value"] else {
                throw HomeKitError.invalidRequest("Missing required parameters")
            }
            let result = try await homeKitManager.setCharacteristic(
                accessoryId: accessoryId,
                characteristicType: characteristic,
                value: value.toAny()
            )
            return result.toJSON()

        case "listScenes":
            guard let homeId = params?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let scenes = try await MainActor.run { try homeKitManager.listScenes(homeId: homeId) }
            return .array(scenes.map { $0.toJSON() })

        case "executeScene":
            guard let sceneId = params?["sceneId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing sceneId")
            }
            let result = try await homeKitManager.executeScene(sceneId: sceneId)
            return result.toJSON()

        default:
            throw HomeKitError.invalidRequest("Unknown action: \(action)")
        }
    }

    // MARK: - Low-level Send/Receive

    private func send(_ message: WebSocketMessage) async throws {
        let data = try JSONEncoder().encode(message)
        let string = String(data: data, encoding: .utf8)!
        try await webSocketTask?.send(.string(string))
    }

    private func receive() async throws -> WebSocketMessage {
        guard let task = webSocketTask else {
            throw WebSocketError.notConnected
        }

        let result = try await task.receive()

        switch result {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw WebSocketError.invalidMessage
            }
            return try JSONDecoder().decode(WebSocketMessage.self, from: data)

        case .data(let data):
            return try JSONDecoder().decode(WebSocketMessage.self, from: data)

        @unknown default:
            throw WebSocketError.invalidMessage
        }
    }

    // MARK: - Keep-alive

    private func startPingTask() {
        pingTask = Task {
            while isConnected {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if isConnected {
                    webSocketTask?.sendPing { error in
                        if let error = error {
                            print("[WebSocket] Ping failed: \(error)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        isConnected = false
        pingTask?.cancel()
        onDisconnect?(error)

        // Attempt reconnection
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = Double(reconnectAttempts) * 2.0 // Exponential backoff

            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                do {
                    try await connect()
                } catch {
                    print("[WebSocket] Reconnect attempt \(reconnectAttempts) failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Message Types

struct WebSocketMessage: Codable {
    let type: MessageType
    var payload: [String: JSONValue]?

    enum MessageType: String, Codable {
        case auth
        case connected
        case ping
        case pong
        case request
        case response
        case error
    }
}

// MARK: - JSON Value

enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConnected
    case authenticationFailed
    case invalidMessage
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .authenticationFailed: return "WebSocket authentication failed"
        case .invalidMessage: return "Invalid message received"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        }
    }
}
