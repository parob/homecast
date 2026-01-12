import Foundation

/// WebSocket client for communicating with the relay server
/// Implements the HomeCast Protocol (see PROTOCOL.md)
class WebSocketClient {
    private let url: URL
    private let token: String
    private let homeKitManager: HomeKitManager
    private let logManager = LogManager.shared

    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var reconnectAttempts = 0
    private var pingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    // Refresh connection every 5 minutes to avoid server timeout (600s)
    private let connectionRefreshInterval: UInt64 = 5 * 60 * 1_000_000_000  // 5 minutes in nanoseconds

    // Callbacks
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onAuthError: (() -> Void)?
    var onWebClientsListeningChanged: ((Bool) -> Void)?
    var onPingHealthChanged: ((Int) -> Void)?  // Reports consecutive ping failures (0 = healthy)
    var onRefreshNeeded: (() -> Void)?  // Called when connection should be refreshed

    init(url: URL, token: String, homeKitManager: HomeKitManager) {
        self.url = url
        self.token = token
        self.homeKitManager = homeKitManager
    }

    // MARK: - Connection

    func connect() async throws {
        await MainActor.run {
            logManager.log("Connecting to \(url.host ?? "server")...", category: .websocket)
        }

        // Token and device_id are passed via query params in the URL
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnected = true
        reconnectAttempts = 0
        consecutivePingFailures = 0
        onConnect?()

        await MainActor.run {
            logManager.log("Connected successfully", category: .websocket)
        }

        // Start listening for messages
        startListening()

        // Start ping task
        startPingTask()

        // Start refresh timer (reconnect before server timeout)
        startRefreshTask()
    }

    func disconnect() {
        isConnected = false
        pingTask?.cancel()
        refreshTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        Task { @MainActor in
            logManager.log("Disconnected", category: .websocket)
        }
    }

    /// Send a characteristic update event to the server
    func sendCharacteristicUpdate(accessoryId: String, characteristicType: String, value: Any) {
        guard isConnected else { return }

        print("[WebSocket] 📤 Event: characteristic.updated (accessory=\(accessoryId.prefix(8))..., type=\(characteristicType), value=\(value))")

        let event = ProtocolMessage(
            id: UUID().uuidString,
            type: .event,
            action: "characteristic.updated",
            payload: [
                "accessoryId": .string(accessoryId),
                "characteristicType": .string(characteristicType),
                "value": jsonValue(from: value)
            ]
        )

        Task {
            do {
                try await send(event)
            } catch {
                print("[WebSocket] ❌ Failed to send characteristic update: \(error)")
            }
        }
    }

    // MARK: - Message Handling

    private func startListening() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            while self.isConnected {
                do {
                    let message = try await self.receive()
                    await self.handleMessage(message)
                } catch {
                    if self.isConnected {
                        await MainActor.run {
                            self.logManager.log("Receive error: \(error.localizedDescription)", category: .websocket)
                        }
                        self.handleDisconnect(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: ProtocolMessage) async {
        switch message.type {
        case .request:
            await MainActor.run {
                logManager.log("← Request: \(message.action ?? "unknown")", category: .websocket, direction: .incoming)
            }
            await handleRequest(message)
        case .ping:
            await MainActor.run {
                logManager.log("← Ping", category: .websocket, direction: .incoming)
            }
            // Respond to heartbeat
            try? await send(ProtocolMessage.pong())

            // Check if ping includes listener status (for timeout reset)
            if let listening = message.payload?["webClientsListening"]?.boolValue {
                onWebClientsListeningChanged?(listening)
            }
        case .config:
            await handleConfig(message)
        case .response, .pong, .event:
            // Not expected from server
            break
        }
    }

    private func handleConfig(_ message: ProtocolMessage) async {
        guard let action = message.action else { return }

        if action == "listeners_changed" {
            let listening = message.payload?["webClientsListening"]?.boolValue ?? false
            print("[WebSocket] 📥 Config: listeners_changed → webClientsListening=\(listening)")
            await MainActor.run {
                logManager.log("← Config: webClientsListening=\(listening)", category: .websocket, direction: .incoming)
            }
            onWebClientsListeningChanged?(listening)
        }
    }

    private func handleRequest(_ message: ProtocolMessage) async {
        let requestId = message.id ?? UUID().uuidString

        guard let action = message.action else {
            await sendError(id: requestId, code: "INVALID_REQUEST", message: "Missing action")
            return
        }

        // Log request details
        let payloadSummary = formatPayloadSummary(message.payload)
        print("[WebSocket] 📥 Request: \(action)\(payloadSummary)")

        do {
            let result = try await executeAction(action: action, payload: message.payload)
            let response = ProtocolMessage(
                id: requestId,
                type: .response,
                action: action,
                payload: result
            )
            try await send(response)
            print("[WebSocket] 📤 Response: \(action) ✅")
        } catch let error as HomeKitError {
            print("[WebSocket] 📤 Response: \(action) ❌ \(error.localizedDescription)")
            await sendError(id: requestId, code: error.code, message: error.localizedDescription)
        } catch {
            print("[WebSocket] 📤 Response: \(action) ❌ \(error.localizedDescription)")
            await sendError(id: requestId, code: "INTERNAL_ERROR", message: error.localizedDescription)
        }
    }

    private func formatPayloadSummary(_ payload: [String: JSONValue]?) -> String {
        guard let payload = payload else { return "" }

        var parts: [String] = []
        if let accessoryId = payload["accessoryId"]?.stringValue {
            parts.append("accessory=\(accessoryId.prefix(8))...")
        }
        if let charType = payload["characteristicType"]?.stringValue {
            parts.append("type=\(charType)")
        }
        if let value = payload["value"] {
            parts.append("value=\(value)")
        }
        if let homeId = payload["homeId"]?.stringValue {
            parts.append("home=\(homeId.prefix(8))...")
        }

        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private func sendError(id: String?, code: String, message: String) async {
        let response = ProtocolMessage(
            id: id,
            type: .response,
            action: nil,
            payload: nil,
            error: ProtocolError(code: code, message: message)
        )
        try? await send(response)
    }

    // MARK: - Action Execution

    private func executeAction(action: String, payload: [String: JSONValue]?) async throws -> [String: JSONValue] {
        switch action {

        // MARK: Homes
        case "homes.list":
            let homes = await MainActor.run { homeKitManager.listHomes() }
            return ["homes": .array(homes.map { homeToJSON($0) })]

        // MARK: Rooms
        case "rooms.list":
            guard let homeId = payload?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let rooms = try await MainActor.run { try homeKitManager.listRooms(homeId: homeId) }
            return [
                "homeId": .string(homeId),
                "rooms": .array(rooms.map { $0.toJSON() })
            ]

        // MARK: Zones
        case "zones.list":
            guard let homeId = payload?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let zones = try await MainActor.run { try homeKitManager.listZones(homeId: homeId) }
            return [
                "homeId": .string(homeId),
                "zones": .array(zones.map { $0.toJSON() })
            ]

        // MARK: Service Groups
        case "serviceGroups.list":
            guard let homeId = payload?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let groups = try await MainActor.run { try homeKitManager.listServiceGroups(homeId: homeId) }
            return [
                "homeId": .string(homeId),
                "serviceGroups": .array(groups.map { $0.toJSON() })
            ]

        case "serviceGroup.set":
            guard let groupId = payload?["groupId"]?.stringValue,
                  let characteristicType = payload?["characteristicType"]?.stringValue,
                  let value = payload?["value"] else {
                throw HomeKitError.invalidRequest("Missing groupId, characteristicType, or value")
            }
            let homeId = payload?["homeId"]?.stringValue
            print("[HomeKit] 🎯 serviceGroup.set: group=\(groupId.prefix(8))..., type=\(characteristicType), value=\(value)")

            let successCount = try await homeKitManager.setServiceGroupCharacteristic(
                homeId: homeId,
                groupId: groupId,
                characteristicType: characteristicType,
                value: value.toAny()
            )
            print("[HomeKit] ✅ serviceGroup.set result: affectedCount=\(successCount)")

            // Send update event for each affected accessory
            // (The individual accessory delegates should fire, but we send a group notification too)

            return [
                "success": .bool(successCount > 0),
                "groupId": .string(groupId),
                "characteristicType": .string(characteristicType),
                "value": value,
                "affectedCount": .int(successCount)
            ]

        // MARK: Accessories
        case "accessories.list":
            let startTime = CFAbsoluteTimeGetCurrent()
            let homeId = payload?["homeId"]?.stringValue
            let roomId = payload?["roomId"]?.stringValue

            let fetchStart = CFAbsoluteTimeGetCurrent()
            let accessories = try await MainActor.run {
                try homeKitManager.listAccessories(homeId: homeId, roomId: roomId, includeValues: true)
            }
            let fetchTime = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000

            let convertStart = CFAbsoluteTimeGetCurrent()
            let jsonAccessories = accessories.map { $0.toJSON() }
            let convertTime = (CFAbsoluteTimeGetCurrent() - convertStart) * 1000

            let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            await MainActor.run {
                logManager.log("accessories.list: \(accessories.count) items - fetch: \(Int(fetchTime))ms, convert: \(Int(convertTime))ms, total: \(Int(totalTime))ms", category: .homekit)
            }

            return ["accessories": .array(jsonAccessories)]

        case "accessory.get":
            guard let accessoryId = payload?["accessoryId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing accessoryId")
            }
            // Refresh characteristic values from device before returning
            try await homeKitManager.refreshAccessoryValues(id: accessoryId)
            let accessory = try await MainActor.run { try homeKitManager.getAccessory(id: accessoryId) }
            return ["accessory": accessory.toJSON()]

        // MARK: Characteristics
        case "characteristic.get":
            guard let accessoryId = payload?["accessoryId"]?.stringValue,
                  let characteristicType = payload?["characteristicType"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing accessoryId or characteristicType")
            }
            let value = try await homeKitManager.readCharacteristic(
                accessoryId: accessoryId,
                characteristicType: characteristicType
            )
            return [
                "accessoryId": .string(accessoryId),
                "characteristicType": .string(characteristicType),
                "value": jsonValue(from: value)
            ]

        case "characteristic.set":
            guard let accessoryId = payload?["accessoryId"]?.stringValue,
                  let characteristicType = payload?["characteristicType"]?.stringValue,
                  let value = payload?["value"] else {
                throw HomeKitError.invalidRequest("Missing accessoryId, characteristicType, or value")
            }
            print("[HomeKit] 🎯 characteristic.set: accessory=\(accessoryId.prefix(8))..., type=\(characteristicType), value=\(value)")

            let result = try await homeKitManager.setCharacteristic(
                accessoryId: accessoryId,
                characteristicType: characteristicType,
                value: value.toAny()
            )
            print("[HomeKit] ✅ characteristic.set result: success=\(result.success), newValue=\(result.newValue ?? "nil")")

            // Send update event to server so other web clients get notified
            // (HMAccessoryDelegate doesn't fire for changes made by our own app)
            if result.success {
                sendCharacteristicUpdate(
                    accessoryId: accessoryId,
                    characteristicType: characteristicType,
                    value: value.toAny()
                )
            }

            return [
                "success": .bool(result.success),
                "accessoryId": .string(accessoryId),
                "characteristicType": .string(characteristicType),
                "value": value
            ]

        // MARK: Scenes
        case "scenes.list":
            guard let homeId = payload?["homeId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing homeId")
            }
            let scenes = try await MainActor.run { try homeKitManager.listScenes(homeId: homeId) }
            return [
                "homeId": .string(homeId),
                "scenes": .array(scenes.map { $0.toJSON() })
            ]

        case "scene.execute":
            guard let sceneId = payload?["sceneId"]?.stringValue else {
                throw HomeKitError.invalidRequest("Missing sceneId")
            }
            let result = try await homeKitManager.executeScene(sceneId: sceneId)
            return [
                "success": .bool(result.success),
                "sceneId": .string(sceneId)
            ]

        // MARK: Simplified State API
        case "state.set":
            guard let stateValue = payload?["state"]?.objectValue else {
                throw HomeKitError.invalidRequest("Missing state object")
            }
            let homeId = payload?["homeId"]?.stringValue

            // Convert JSONValue to [String: [String: [String: Any]]]
            var state: [String: [String: [String: Any]]] = [:]
            for (roomKey, roomValue) in stateValue {
                guard let accessories = roomValue.objectValue else { continue }
                var roomState: [String: [String: Any]] = [:]
                for (accKey, accValue) in accessories {
                    guard let props = accValue.objectValue else { continue }
                    var propDict: [String: Any] = [:]
                    for (propKey, propValue) in props {
                        propDict[propKey] = propValue.toAny()
                    }
                    roomState[accKey] = propDict
                }
                state[roomKey] = roomState
            }

            print("[HomeKit] 🎯 state.set: \(state)")
            let result = try await homeKitManager.setState(state: state, homeId: homeId)
            print("[HomeKit] ✅ state.set result: ok=\(result.ok), failed=\(result.failed)")

            return [
                "ok": .int(result.ok),
                "failed": .array(result.failed.map { .string($0) })
            ]

        default:
            throw HomeKitError.invalidRequest("Unknown action: \(action)")
        }
    }

    // MARK: - Helpers

    /// Sanitize a name to match server convention (spaces to underscores, lowercase)
    private func sanitizeName(_ name: String) -> String {
        return name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            .lowercased()
    }

    private func homeToJSON(_ home: HomeModel) -> JSONValue {
        return .object([
            "id": .string(home.id),
            "name": .string(home.name),
            "isPrimary": .bool(home.isPrimary),
            "roomCount": .int(home.roomCount),
            "accessoryCount": .int(home.accessoryCount)
        ])
    }

    private func jsonValue(from any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            } else if n.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                return .int(n.intValue)
            } else {
                return .double(n.doubleValue)
            }
        case is NSNull: return .null
        default: return .string(String(describing: any))
        }
    }

    // MARK: - Low-level Send/Receive

    private func send(_ message: ProtocolMessage) async throws {
        // Encode on background thread to avoid blocking UI
        let (data, encodeTime) = try await Task.detached(priority: .userInitiated) {
            let encodeStart = CFAbsoluteTimeGetCurrent()
            let data = try JSONEncoder().encode(message)
            let encodeTime = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
            return (data, encodeTime)
        }.value

        let string = String(data: data, encoding: .utf8)!
        let sizeKB = data.count / 1024

        let sendStart = CFAbsoluteTimeGetCurrent()
        try await webSocketTask?.send(.string(string))
        let sendTime = (CFAbsoluteTimeGetCurrent() - sendStart) * 1000

        await MainActor.run {
            let desc: String
            switch message.type {
            case .pong:
                desc = "Pong"
            case .response:
                if let error = message.error {
                    desc = "Response: error - \(error.code): \(error.message)"
                } else {
                    desc = "Response: \(message.action ?? "unknown") (\(sizeKB)KB, encode: \(Int(encodeTime))ms, send: \(Int(sendTime))ms)"
                }
            default:
                desc = message.type.rawValue
            }
            logManager.log("→ \(desc)", category: .websocket, direction: .outgoing)
        }
    }

    private func receive() async throws -> ProtocolMessage {
        guard let task = webSocketTask else {
            throw WebSocketError.notConnected
        }

        let result = try await task.receive()

        // Decode on background thread to avoid blocking UI
        return try await Task.detached(priority: .userInitiated) {
            switch result {
            case .string(let text):
                guard let data = text.data(using: .utf8) else {
                    throw WebSocketError.invalidMessage
                }
                return try JSONDecoder().decode(ProtocolMessage.self, from: data)

            case .data(let data):
                return try JSONDecoder().decode(ProtocolMessage.self, from: data)

            @unknown default:
                throw WebSocketError.invalidMessage
            }
        }.value
    }

    // MARK: - Keep-alive

    private var consecutivePingFailures = 0
    private let maxPingFailures = 2

    private func startPingTask() {
        pingTask = Task {
            while isConnected {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if isConnected {
                    webSocketTask?.sendPing { [weak self] error in
                        guard let self = self else { return }
                        let previousFailures = self.consecutivePingFailures
                        if let error = error {
                            print("[WebSocket] ⚠️ Ping failed: \(error)")
                            self.consecutivePingFailures += 1
                            // Notify about health change
                            if self.consecutivePingFailures != previousFailures {
                                self.onPingHealthChanged?(self.consecutivePingFailures)
                            }
                            if self.consecutivePingFailures >= self.maxPingFailures {
                                print("[WebSocket] ❌ Too many ping failures (\(self.consecutivePingFailures)), forcing reconnect")
                                Task { @MainActor in
                                    self.logManager.log("Connection stale - forcing reconnect", category: .websocket)
                                }
                                self.handleDisconnect(error: error)
                            }
                        } else {
                            self.consecutivePingFailures = 0
                            // Notify about health restored
                            if previousFailures > 0 {
                                self.onPingHealthChanged?(0)
                            }
                        }
                    }
                }
            }
        }
    }

    private func startRefreshTask() {
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: connectionRefreshInterval)
            if isConnected {
                print("[WebSocket] 🔄 Connection refresh interval reached (5 min) - triggering reconnect")
                Task { @MainActor in
                    logManager.log("Refreshing connection (5 min interval)", category: .websocket)
                }
                onRefreshNeeded?()
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        isConnected = false
        pingTask?.cancel()
        refreshTask?.cancel()
        onDisconnect?(error)

        Task { @MainActor in
            if let error = error {
                logManager.log("Connection lost: \(error.localizedDescription)", category: .websocket)
            } else {
                logManager.log("Connection lost", category: .websocket)
            }
        }

        // Always attempt reconnection - don't give up on network failures
        reconnectAttempts += 1

        // Exponential backoff with cap at 30 seconds
        let delay = min(Double(reconnectAttempts) * 2.0, 30.0)

        Task { @MainActor in
            logManager.log("Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts))", category: .websocket)
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            do {
                try await connect()
            } catch {
                print("[WebSocket] Reconnect attempt \(reconnectAttempts) failed: \(error)")
                // If connect() throws, handleDisconnect will be called again from the receive loop
                // or we need to trigger it manually for connection failures
                self.handleDisconnect(error: error)
            }
        }
    }
}

// MARK: - Protocol Message

struct ProtocolMessage: Codable {
    let id: String?  // Optional for ping/pong messages
    let type: MessageType
    let action: String?
    var payload: [String: JSONValue]?
    var error: ProtocolError?

    enum MessageType: String, Codable {
        case request   // Server → App
        case response  // App → Server
        case ping      // Server → App (heartbeat)
        case pong      // App → Server (heartbeat response)
        case event     // App → Server (push notification)
        case config    // Server → App (configuration change)
    }

    // Convenience init for pong
    static func pong() -> ProtocolMessage {
        ProtocolMessage(id: nil, type: .pong, action: nil, payload: nil, error: nil)
    }

    // Init for responses
    init(id: String?, type: MessageType, action: String?, payload: [String: JSONValue]? = nil, error: ProtocolError? = nil) {
        self.id = id
        self.type = type
        self.action = action
        self.payload = payload
        self.error = error
    }
}

struct ProtocolError: Codable {
    let code: String
    let message: String
}

// MARK: - JSON Value

enum JSONValue: Codable, Equatable {
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

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
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

        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
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

// MARK: - HomeKitError Extension

extension HomeKitError {
    var code: String {
        switch self {
        case .homeNotFound: return "HOME_NOT_FOUND"
        case .roomNotFound: return "ROOM_NOT_FOUND"
        case .accessoryNotFound: return "ACCESSORY_NOT_FOUND"
        case .sceneNotFound: return "SCENE_NOT_FOUND"
        case .characteristicNotFound: return "CHARACTERISTIC_NOT_FOUND"
        case .characteristicNotWritable: return "CHARACTERISTIC_NOT_WRITABLE"
        case .invalidId, .invalidRequest: return "INVALID_REQUEST"
        case .readFailed, .writeFailed, .sceneExecutionFailed: return "HOMEKIT_ERROR"
        }
    }
}
