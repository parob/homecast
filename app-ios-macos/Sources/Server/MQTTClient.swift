import Foundation
import Network

/// Lightweight MQTT 3.1.1 client using NWConnection (QoS 0 only).
/// Connects to an external MQTT broker and handles publish/subscribe.
/// No external dependencies — uses Apple's Network framework.
class MQTTClient {

    struct BrokerConfig {
        let host: String
        let port: UInt16
        let username: String?
        let password: String?
        let useTLS: Bool
        let clientId: String
        let topicPrefix: String  // e.g. "homecast"
    }

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // MARK: - Properties

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.homecast.mqtt", qos: .userInitiated)
    private var config: BrokerConfig?
    private(set) var state: ConnectionState = .disconnected

    /// Callbacks
    var onMessage: ((String, Data) -> Void)?  // topic, payload
    var onStateChange: ((ConnectionState) -> Void)?

    /// Reconnection
    private var reconnectAttempt = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var shouldReconnect = false

    /// Keep-alive
    private var keepAliveTimer: DispatchSourceTimer?
    private let keepAliveInterval: UInt16 = 60

    /// Packet ID for SUBSCRIBE (incremented per use)
    private var nextPacketId: UInt16 = 1

    /// Last Will and Testament
    var willTopic: String?
    var willMessage: Data?
    var willRetain: Bool = false

    /// Buffer for partial TCP reads
    private var readBuffer = Data()

    // MARK: - Lifecycle

    func connect(config: BrokerConfig) {
        self.config = config
        self.shouldReconnect = true
        self.reconnectAttempt = 0
        doConnect()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTimer?.cancel()
        reconnectTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
        updateState(.disconnected)
    }

    // MARK: - Publish & Subscribe

    func publish(topic: String, payload: Data, retain: Bool = false) {
        guard case .connected = state, let connection = connection else { return }

        let packet = buildPublishPacket(topic: topic, payload: payload, retain: retain)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[MQTTClient] Publish error: %@", error.localizedDescription)
            }
        })
    }

    func publish(topic: String, string: String, retain: Bool = false) {
        publish(topic: topic, payload: Data(string.utf8), retain: retain)
    }

    func subscribe(topic: String) {
        guard case .connected = state, let connection = connection else { return }

        let packetId = nextPacketId
        nextPacketId &+= 1

        let packet = buildSubscribePacket(topic: topic, packetId: packetId)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[MQTTClient] Subscribe error: %@", error.localizedDescription)
            }
        })
    }

    func unsubscribe(topic: String) {
        guard case .connected = state, let connection = connection else { return }

        let packetId = nextPacketId
        nextPacketId &+= 1

        let packet = buildUnsubscribePacket(topic: topic, packetId: packetId)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[MQTTClient] Unsubscribe error: %@", error.localizedDescription)
            }
        })
    }

    // MARK: - Connection

    private func doConnect() {
        guard let config = config else { return }
        updateState(.connecting)

        let params = NWParameters.tcp
        if config.useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            params.defaultProtocolStack.applicationProtocols.insert(tlsOptions, at: 0)
        }

        let host = NWEndpoint.Host(config.host)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            updateState(.error("Invalid port: \(config.port)"))
            return
        }
        connection = NWConnection(host: host, port: port, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handleConnectionState(state)
            }
        }

        connection?.start(queue: queue)
    }

    private func handleConnectionState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            NSLog("[MQTTClient] TCP connected to %@:%d", config?.host ?? "", config?.port ?? 0)
            sendConnectPacket()
        case .failed(let error):
            NSLog("[MQTTClient] Connection failed: %@", error.localizedDescription)
            updateState(.error(error.localizedDescription))
            scheduleReconnect()
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - MQTT Packet Sending

    private func sendConnectPacket() {
        guard let config = config, let connection = connection else { return }

        let packet = buildConnectPacket(
            clientId: config.clientId,
            username: config.username,
            password: config.password,
            keepAlive: keepAliveInterval,
            willTopic: willTopic,
            willMessage: willMessage,
            willRetain: willRetain
        )

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[MQTTClient] CONNECT send error: %@", error.localizedDescription)
                self?.updateState(.error(error.localizedDescription))
                self?.scheduleReconnect()
            } else {
                self?.startReading()
            }
        })
    }

    // MARK: - Reading

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            self?.queue.async {
                if let data = content {
                    self?.readBuffer.append(data)
                    self?.processReadBuffer()
                }
                if isComplete || error != nil {
                    if let error = error {
                        NSLog("[MQTTClient] Read error: %@", error.localizedDescription)
                    }
                    self?.handleDisconnect()
                    return
                }
                self?.startReading()
            }
        }
    }

    private func processReadBuffer() {
        while readBuffer.count >= 2 {
            // Parse fixed header: packet type + remaining length
            guard let (totalLength, headerSize) = decodeRemainingLength(from: readBuffer, offset: 1) else {
                break  // Need more data for length encoding
            }

            let packetSize = headerSize + totalLength
            guard readBuffer.count >= packetSize else {
                break  // Need more data for full packet
            }

            let packetData = readBuffer.prefix(packetSize)
            readBuffer.removeFirst(packetSize)
            handlePacket(Data(packetData))
        }
    }

    // MARK: - Packet Handling

    private func handlePacket(_ data: Data) {
        guard !data.isEmpty else { return }

        let packetType = data[0] >> 4

        switch packetType {
        case 2:  // CONNACK
            handleConnack(data)
        case 3:  // PUBLISH
            handlePublish(data)
        case 9:  // SUBACK
            break  // QoS 0 only, no action needed
        case 11: // UNSUBACK
            break
        case 13: // PINGRESP
            break
        default:
            break
        }
    }

    private func handleConnack(_ data: Data) {
        guard data.count >= 4 else { return }
        let returnCode = data[3]

        if returnCode == 0 {
            NSLog("[MQTTClient] Connected to broker")
            reconnectAttempt = 0
            updateState(.connected)
            startKeepAlive()
        } else {
            let reason: String
            switch returnCode {
            case 1: reason = "Unacceptable protocol version"
            case 2: reason = "Client ID rejected"
            case 3: reason = "Server unavailable"
            case 4: reason = "Bad username or password"
            case 5: reason = "Not authorized"
            default: reason = "Unknown error (\(returnCode))"
            }
            NSLog("[MQTTClient] CONNACK rejected: %@", reason)
            updateState(.error(reason))
            // Don't reconnect on auth errors
            if returnCode >= 4 {
                shouldReconnect = false
            }
            connection?.cancel()
        }
    }

    private func handlePublish(_ data: Data) {
        guard data.count >= 4 else { return }

        // Parse variable header: topic length + topic
        let topicLenHigh = Int(data[2])
        let topicLenLow = Int(data[3])
        let topicLen = (topicLenHigh << 8) | topicLenLow
        let topicStart = 4
        let topicEnd = topicStart + topicLen

        guard data.count >= topicEnd else { return }

        guard let topic = String(data: data[topicStart..<topicEnd], encoding: .utf8) else { return }

        // QoS 0: no packet ID, payload starts right after topic
        let payloadStart = topicEnd
        let payload = data.count > payloadStart ? Data(data[payloadStart...]) : Data()

        onMessage?(topic, payload)
    }

    // MARK: - Keep-alive

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Int(keepAliveInterval)),
                       repeating: .seconds(Int(keepAliveInterval)))
        timer.setEventHandler { [weak self] in
            self?.sendPingreq()
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func sendPingreq() {
        // PINGREQ: 0xC0 0x00
        let packet = Data([0xC0, 0x00])
        connection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[MQTTClient] PINGREQ error: %@", error.localizedDescription)
            }
        })
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
        updateState(.disconnected)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        reconnectTimer?.cancel()
        reconnectAttempt += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s max
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        NSLog("[MQTTClient] Reconnecting in %.0fs (attempt %d)", delay, reconnectAttempt)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delay * 1000)))
        timer.setEventHandler { [weak self] in
            self?.doConnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func updateState(_ newState: ConnectionState) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChange?(self.state)
        }
    }

    var statusDescription: String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let msg): return "error: \(msg)"
        }
    }

    // MARK: - MQTT 3.1.1 Packet Builders

    private func buildConnectPacket(
        clientId: String,
        username: String?,
        password: String?,
        keepAlive: UInt16,
        willTopic: String?,
        willMessage: Data?,
        willRetain: Bool
    ) -> Data {
        // Variable header
        var variableHeader = Data()

        // Protocol Name: "MQTT"
        variableHeader.appendMQTTString("MQTT")
        // Protocol Level: 4 (MQTT 3.1.1)
        variableHeader.append(4)

        // Connect Flags
        var flags: UInt8 = 0x02  // Clean Session
        if let _ = willTopic, let _ = willMessage {
            flags |= 0x04  // Will Flag
            if willRetain { flags |= 0x20 }  // Will Retain
        }
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variableHeader.append(flags)

        // Keep Alive
        variableHeader.append(UInt8(keepAlive >> 8))
        variableHeader.append(UInt8(keepAlive & 0xFF))

        // Payload
        var payload = Data()
        payload.appendMQTTString(clientId)
        if let willTopic = willTopic {
            payload.appendMQTTString(willTopic)
            if let willMessage = willMessage {
                payload.append(UInt8(willMessage.count >> 8))
                payload.append(UInt8(willMessage.count & 0xFF))
                payload.append(willMessage)
            } else {
                payload.append(contentsOf: [0x00, 0x00])
            }
        }
        if let username = username {
            payload.appendMQTTString(username)
        }
        if let password = password {
            payload.appendMQTTString(password)
        }

        // Fixed header
        var packet = Data()
        packet.append(0x10)  // CONNECT packet type
        packet.appendMQTTRemainingLength(variableHeader.count + payload.count)
        packet.append(variableHeader)
        packet.append(payload)

        return packet
    }

    private func buildPublishPacket(topic: String, payload: Data, retain: Bool) -> Data {
        var variableHeader = Data()
        variableHeader.appendMQTTString(topic)
        // QoS 0: no packet identifier

        var packet = Data()
        var firstByte: UInt8 = 0x30  // PUBLISH
        if retain { firstByte |= 0x01 }
        packet.append(firstByte)
        packet.appendMQTTRemainingLength(variableHeader.count + payload.count)
        packet.append(variableHeader)
        packet.append(payload)

        return packet
    }

    private func buildSubscribePacket(topic: String, packetId: UInt16) -> Data {
        var variableHeader = Data()
        variableHeader.append(UInt8(packetId >> 8))
        variableHeader.append(UInt8(packetId & 0xFF))

        var payload = Data()
        payload.appendMQTTString(topic)
        payload.append(0x00)  // QoS 0

        var packet = Data()
        packet.append(0x82)  // SUBSCRIBE with QoS 1 fixed header flag
        packet.appendMQTTRemainingLength(variableHeader.count + payload.count)
        packet.append(variableHeader)
        packet.append(payload)

        return packet
    }

    private func buildUnsubscribePacket(topic: String, packetId: UInt16) -> Data {
        var variableHeader = Data()
        variableHeader.append(UInt8(packetId >> 8))
        variableHeader.append(UInt8(packetId & 0xFF))

        var payload = Data()
        payload.appendMQTTString(topic)

        var packet = Data()
        packet.append(0xA2)  // UNSUBSCRIBE
        packet.appendMQTTRemainingLength(variableHeader.count + payload.count)
        packet.append(variableHeader)
        packet.append(payload)

        return packet
    }

    // MARK: - Remaining Length Decoder

    /// Decode MQTT remaining length (variable-length encoding).
    /// Returns (decoded length, total bytes consumed including first byte of fixed header)
    private func decodeRemainingLength(from data: Data, offset: Int) -> (Int, Int)? {
        var multiplier = 1
        var value = 0
        var index = offset

        repeat {
            guard index < data.count else { return nil }
            let byte = data[index]
            value += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            index += 1
            if byte & 0x80 == 0 {
                return (value, index)
            }
        } while multiplier <= 128 * 128 * 128

        return nil
    }
}

// MARK: - Data Extensions for MQTT Encoding

private extension Data {
    mutating func appendMQTTString(_ string: String) {
        let utf8 = Data(string.utf8)
        self.append(UInt8(utf8.count >> 8))
        self.append(UInt8(utf8.count & 0xFF))
        self.append(utf8)
    }

    mutating func appendMQTTRemainingLength(_ length: Int) {
        var value = length
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 {
                byte |= 0x80
            }
            self.append(byte)
        } while value > 0
    }
}
