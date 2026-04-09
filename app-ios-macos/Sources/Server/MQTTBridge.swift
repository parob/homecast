import Foundation
import WebKit

/// Persisted broker configuration (stored in UserDefaults per home).
struct MQTTBrokerConfig: Codable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var useTLS: Bool
    var topicPrefix: String
    var haDiscovery: Bool
    var haDiscoveryPrefix: String
    var enabled: Bool

    /// Runtime-only status (not persisted)
    var status: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, useTLS, topicPrefix, haDiscovery, haDiscoveryPrefix, enabled
    }
}

/// Bridges between MQTT clients and the WKWebView JavaScript context.
/// Supports multiple brokers per home. Publishes HomeKit state changes to MQTT
/// topics and routes incoming MQTT commands to HomeKit via the existing JS bridge.
class MQTTBridge: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?

    /// Active MQTT clients keyed by broker ID
    private var clients: [String: MQTTClient] = [:]

    /// Broker configs keyed by home ID → [BrokerConfig]
    private var brokerConfigs: [String: [MQTTBrokerConfig]] = [:]

    /// Map broker ID → home ID for routing
    private var brokerHomeMap: [String: String] = [:]

    // MARK: - Slug Maps

    private var homeSlugMap: [String: String] = [:]         // slug → homeId
    private var homeSlugs: [String: String] = [:]           // homeId → slug
    private var roomSlugs: [String: (slug: String, homeSlug: String)] = [:]
    private var accessoryMap: [String: String] = [:]        // "homeSlug/roomSlug/accSlug" → accessoryId
    private var reverseAccessoryMap: [String: String] = [:] // accessoryId → "homeSlug/roomSlug/accSlug"
    /// accessoryId → homeId
    private var accessoryHomeMap: [String: String] = [:]

    /// Deduplication
    private var recentPublishes: [String: Date] = [:]
    private let deduplicationWindow: TimeInterval = 0.5

    private var isReady = false
    let discovery = MQTTDiscovery()

    private static let userDefaultsKey = "mqtt_brokers"

    // MARK: - Lifecycle

    override init() {
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        NSLog("[MQTTBridge] Attached to WebView")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.buildSlugMap()
        }
    }

    // MARK: - Broker Management

    /// Load saved brokers from UserDefaults and connect all enabled ones.
    func loadAndConnectSavedBrokers() {
        guard let data = UserDefaults.standard.data(forKey: MQTTBridge.userDefaultsKey),
              let configs = try? JSONDecoder().decode([String: [MQTTBrokerConfig]].self, from: data) else {
            NSLog("[MQTTBridge] No saved MQTT brokers found")
            return
        }
        brokerConfigs = configs

        var brokerCount = 0
        for (homeId, brokers) in configs {
            for broker in brokers where broker.enabled {
                connectBroker(broker, forHome: homeId)
                brokerCount += 1
            }
        }
        NSLog("[MQTTBridge] Loaded %d brokers from UserDefaults", brokerCount)
    }

    /// Save current broker configs to UserDefaults.
    private func saveBrokers() {
        if let data = try? JSONEncoder().encode(brokerConfigs) {
            UserDefaults.standard.set(data, forKey: MQTTBridge.userDefaultsKey)
        }
    }

    /// Add a new broker for a home, save, and connect.
    func addBroker(_ config: MQTTBrokerConfig, forHome homeId: String) -> MQTTBrokerConfig {
        var brokers = brokerConfigs[homeId] ?? []
        brokers.append(config)
        brokerConfigs[homeId] = brokers
        saveBrokers()

        if config.enabled {
            connectBroker(config, forHome: homeId)
        }

        NSLog("[MQTTBridge] Added broker '%@' for home %@", config.name, homeId)
        return config
    }

    /// Remove a broker by ID from a home.
    func removeBroker(id: String, forHome homeId: String) {
        // Disconnect
        clients[id]?.disconnect()
        clients.removeValue(forKey: id)
        brokerHomeMap.removeValue(forKey: id)

        // Remove from config
        brokerConfigs[homeId]?.removeAll { $0.id == id }
        if brokerConfigs[homeId]?.isEmpty == true {
            brokerConfigs.removeValue(forKey: homeId)
        }
        saveBrokers()
        NSLog("[MQTTBridge] Removed broker %@ from home %@", id, homeId)
    }

    /// Update an existing broker's config.
    func updateBroker(id: String, forHome homeId: String, updates: [String: Any]) {
        guard var brokers = brokerConfigs[homeId],
              let index = brokers.firstIndex(where: { $0.id == id }) else { return }

        var config = brokers[index]
        if let name = updates["name"] as? String { config.name = name }
        if let host = updates["host"] as? String { config.host = host }
        if let port = updates["port"] as? Int { config.port = UInt16(port) }
        if let username = updates["username"] as? String { config.username = username.isEmpty ? nil : username }
        if let password = updates["password"] as? String { config.password = password.isEmpty ? nil : password }
        if let useTLS = updates["useTLS"] as? Bool { config.useTLS = useTLS }
        if let topicPrefix = updates["topicPrefix"] as? String { config.topicPrefix = topicPrefix }
        if let haDiscovery = updates["haDiscovery"] as? Bool { config.haDiscovery = haDiscovery }
        if let haDiscoveryPrefix = updates["haDiscoveryPrefix"] as? String { config.haDiscoveryPrefix = haDiscoveryPrefix }
        if let enabled = updates["enabled"] as? Bool { config.enabled = enabled }

        brokers[index] = config
        brokerConfigs[homeId] = brokers
        saveBrokers()

        // Reconnect with new config
        clients[id]?.disconnect()
        clients.removeValue(forKey: id)
        if config.enabled {
            connectBroker(config, forHome: homeId)
        }
    }

    /// Get all broker configs with live status.
    func getBrokers() -> [String: [[String: Any]]] {
        var result: [String: [[String: Any]]] = [:]
        for (homeId, brokers) in brokerConfigs {
            result[homeId] = brokers.map { broker in
                var dict: [String: Any] = [
                    "id": broker.id,
                    "name": broker.name,
                    "host": broker.host,
                    "port": broker.port,
                    "useTLS": broker.useTLS,
                    "topicPrefix": broker.topicPrefix,
                    "haDiscovery": broker.haDiscovery,
                    "haDiscoveryPrefix": broker.haDiscoveryPrefix,
                    "enabled": broker.enabled,
                    "status": clients[broker.id]?.statusDescription ?? "disconnected",
                ]
                if let username = broker.username { dict["username"] = username }
                // Don't expose password
                dict["hasPassword"] = broker.password != nil
                return dict
            }
        }
        return result
    }

    /// Test a broker connection (connect, wait for CONNACK, disconnect).
    func testConnection(host: String, port: UInt16, username: String?, password: String?, useTLS: Bool, completion: @escaping (Bool, String?) -> Void) {
        let client = MQTTClient()
        let config = MQTTClient.BrokerConfig(
            host: host,
            port: port,
            username: username,
            password: password,
            useTLS: useTLS,
            clientId: "homecast-test-\(UUID().uuidString.prefix(4))",
            topicPrefix: "homecast"
        )

        var completed = false
        client.onStateChange = { state in
            guard !completed else { return }
            switch state {
            case .connected:
                completed = true
                client.disconnect()
                completion(true, nil)
            case .error(let msg):
                completed = true
                client.disconnect()
                completion(false, msg)
            default:
                break
            }
        }

        client.connect(config: config)

        // Timeout after 10s
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !completed else { return }
            completed = true
            client.disconnect()
            completion(false, "Connection timed out")
        }
    }

    // MARK: - Client Connection

    private func connectBroker(_ config: MQTTBrokerConfig, forHome homeId: String) {
        let client = MQTTClient()
        let homeSlug = homeSlugs[homeId] ?? homeId

        let clientConfig = MQTTClient.BrokerConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            useTLS: config.useTLS,
            clientId: "homecast-\(ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: ""))-\(String(config.id.prefix(4)))",
            topicPrefix: config.topicPrefix
        )

        // LWT
        client.willTopic = "\(config.topicPrefix)/\(homeSlug)/status"
        client.willMessage = Data("offline".utf8)
        client.willRetain = true

        client.onMessage = { [weak self] topic, payload in
            self?.handleIncomingMessage(topic: topic, payload: payload, brokerId: config.id)
        }

        client.onStateChange = { [weak self] state in
            if case .connected = state {
                self?.onBrokerConnected(brokerId: config.id)
            }
        }

        clients[config.id] = client
        brokerHomeMap[config.id] = homeId
        client.connect(config: clientConfig)
    }

    // MARK: - Broker Connected

    private func onBrokerConnected(brokerId: String) {
        guard let client = clients[brokerId],
              let homeId = brokerHomeMap[brokerId],
              let config = brokerConfigs[homeId]?.first(where: { $0.id == brokerId }) else { return }

        let prefix = config.topicPrefix
        // Subscribe to command topics for this home's slug
        if let homeSlug = homeSlugs[homeId] {
            client.subscribe(topic: "\(prefix)/\(homeSlug)/+/+/set")
            client.subscribe(topic: "\(prefix)/\(homeSlug)/scene/+/execute")
        }
        NSLog("[MQTTBridge] Broker '%@' connected, subscribed to commands", config.name)

        if isReady {
            publishFullStateForHome(homeId: homeId, client: client, config: config)
            if config.haDiscovery {
                publishHADiscoveryForHome(homeId: homeId, client: client, config: config)
            }
        }
    }

    // MARK: - Slug Map Building

    func buildSlugMap() {
        guard let webView = webView else { return }

        let js = """
        (async function() {
            try {
                const homes = await window.homekit.call('homes.list', {});
                const result = [];
                for (const home of homes) {
                    const rooms = await window.homekit.call('rooms.list', { homeId: home[0] });
                    const accessories = await window.homekit.call('accessories.list', { homeId: home[0], includeValues: true });
                    result.push({
                        id: home[0], name: home[1],
                        rooms: rooms.map(r => ({ id: r[0], name: r[1] })),
                        accessories: accessories
                    });
                }
                return JSON.stringify(result);
            } catch (e) {
                return JSON.stringify({ error: e.message || String(e) });
            }
        })();
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { [weak self] result, error in
                guard let self = self else { return }
                if let error = error {
                    NSLog("[MQTTBridge] Failed to query HomeKit: %@", error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.buildSlugMap() }
                    return
                }
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let homes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    NSLog("[MQTTBridge] Failed to parse HomeKit response")
                    return
                }
                self.processSlugMap(homes: homes)
            }
        }
    }

    private func processSlugMap(homes: [[String: Any]]) {
        homeSlugMap.removeAll()
        homeSlugs.removeAll()
        roomSlugs.removeAll()
        accessoryMap.removeAll()
        reverseAccessoryMap.removeAll()
        accessoryHomeMap.removeAll()

        for home in homes {
            guard let homeId = home["id"] as? String,
                  let homeName = home["name"] as? String else { continue }

            let homeSlug = makeSlug(name: homeName, id: homeId)
            homeSlugMap[homeSlug] = homeId
            homeSlugs[homeId] = homeSlug

            if let rooms = home["rooms"] as? [[String: Any]] {
                for room in rooms {
                    guard let roomId = room["id"] as? String,
                          let roomName = room["name"] as? String else { continue }
                    let roomSlug = makeSlug(name: roomName, id: roomId)
                    roomSlugs[roomId] = (slug: roomSlug, homeSlug: homeSlug)
                }
            }

            if let accessories = home["accessories"] as? [[String: Any]] {
                for accessory in accessories {
                    guard let accId = accessory["id"] as? String,
                          let accName = accessory["name"] as? String,
                          let roomId = accessory["roomId"] as? String,
                          let roomInfo = roomSlugs[roomId] else { continue }

                    let accSlug = makeSlug(name: accName, id: accId)
                    let path = "\(homeSlug)/\(roomInfo.slug)/\(accSlug)"
                    accessoryMap[path] = accId
                    reverseAccessoryMap[accId] = path
                    accessoryHomeMap[accId] = homeId
                }
            }
        }

        isReady = true
        NSLog("[MQTTBridge] Slug map built: %d homes, %d accessories", homeSlugMap.count, accessoryMap.count)

        // Publish state for all connected brokers
        for (brokerId, client) in clients {
            guard case .connected = client.state,
                  let homeId = brokerHomeMap[brokerId],
                  let config = brokerConfigs[homeId]?.first(where: { $0.id == brokerId }) else { continue }
            publishFullStateForHome(homeId: homeId, client: client, config: config)
            if config.haDiscovery {
                publishHADiscoveryForHome(homeId: homeId, client: client, config: config)
            }
        }
    }

    // MARK: - Slug Generation

    func makeSlug(name: String, id: String) -> String {
        let base = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
        let hex = id.replacingOccurrences(of: "-", with: "")
        let suffix = String(hex.prefix(4)).lowercased()
        return "\(base)-\(suffix)"
    }

    // MARK: - Outbound: HomeKit → MQTT (fan out to all brokers for the home)

    func handleBroadcast(type: String, payload: [String: Any]) {
        guard isReady else { return }

        switch type {
        case "characteristic_update":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let charType = payload["characteristicType"] as? String else { return }

            let dedupKey = "\(accessoryId):\(charType)"
            if let recent = recentPublishes[dedupKey], Date().timeIntervalSince(recent) < deduplicationWindow {
                return
            }

            guard let path = reverseAccessoryMap[accessoryId],
                  let homeId = accessoryHomeMap[accessoryId],
                  let simpleName = CharacteristicMapper.simpleNameForType(charType) else { return }

            let state: [String: Any] = [simpleName: payload["value"] ?? NSNull()]
            guard let data = try? JSONSerialization.data(withJSONObject: state),
                  let json = String(data: data, encoding: .utf8) else { return }

            forEachClient(forHome: homeId) { client, config in
                client.publish(topic: "\(config.topicPrefix)/\(path)", string: json, retain: true)
            }

        case "reachability_update":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let isReachable = payload["isReachable"] as? Bool,
                  let path = reverseAccessoryMap[accessoryId],
                  let homeId = accessoryHomeMap[accessoryId] else { return }

            forEachClient(forHome: homeId) { client, config in
                client.publish(topic: "\(config.topicPrefix)/\(path)/availability",
                               string: isReachable ? "online" : "offline", retain: true)
            }

        case "homes_updated":
            buildSlugMap()

        default:
            break
        }
    }

    /// Execute a closure for each connected client serving a specific home.
    private func forEachClient(forHome homeId: String, _ action: (MQTTClient, MQTTBrokerConfig) -> Void) {
        guard let brokers = brokerConfigs[homeId] else { return }
        for broker in brokers where broker.enabled {
            guard let client = clients[broker.id], case .connected = client.state else { continue }
            action(client, broker)
        }
    }

    // MARK: - Publish Full State (per home, per client)

    private func publishFullStateForHome(homeId: String, client: MQTTClient, config: MQTTBrokerConfig) {
        guard let webView = webView, let homeSlug = homeSlugs[homeId] else { return }

        client.publish(topic: "\(config.topicPrefix)/\(homeSlug)/status", string: "online", retain: true)

        let js = """
        (async function() {
            try {
                const accessories = await window.homekit.call('accessories.list', { homeId: '\(homeId)', includeValues: true });
                return JSON.stringify(accessories);
            } catch (e) {
                return JSON.stringify({ error: e.message || String(e) });
            }
        })();
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self,
                      let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let accessories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

                for accessory in accessories {
                    self.publishAccessoryState(accessory, client: client, config: config)
                }
                NSLog("[MQTTBridge] Published state for %d accessories to '%@'", accessories.count, config.name)
            }
        }
    }

    private func publishAccessoryState(_ accessory: [String: Any], client: MQTTClient, config: MQTTBrokerConfig) {
        guard let accId = accessory["id"] as? String,
              let path = reverseAccessoryMap[accId] else { return }

        var state: [String: Any] = [:]
        let isReachable = accessory["isReachable"] as? Bool ?? false

        if let services = accessory["services"] as? [[String: Any]] {
            for service in services {
                if let chars = service["characteristics"] as? [[String: Any]] {
                    for char in chars {
                        guard let charType = char["characteristicType"] as? String,
                              let simpleName = CharacteristicMapper.simpleNameForType(charType) else { continue }
                        state[simpleName] = char["value"] ?? NSNull()
                    }
                }
            }
        }

        if !state.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            client.publish(topic: "\(config.topicPrefix)/\(path)", string: json, retain: true)
        }

        client.publish(topic: "\(config.topicPrefix)/\(path)/availability",
                       string: isReachable ? "online" : "offline", retain: true)
    }

    // MARK: - HA Discovery (per home, per client)

    private func publishHADiscoveryForHome(homeId: String, client: MQTTClient, config: MQTTBrokerConfig) {
        guard let webView = webView else { return }

        let js = """
        (async function() {
            try {
                const accessories = await window.homekit.call('accessories.list', { homeId: '\(homeId)', includeValues: true });
                return JSON.stringify(accessories);
            } catch (e) {
                return JSON.stringify({ error: e.message || String(e) });
            }
        })();
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self,
                      let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let accessories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

                var configCount = 0
                for accessory in accessories {
                    guard let accId = accessory["id"] as? String,
                          let path = self.reverseAccessoryMap[accId] else { continue }

                    let configs = self.discovery.generateConfigs(
                        accessory: accessory,
                        topicPrefix: config.topicPrefix,
                        topicPath: path,
                        discoveryPrefix: config.haDiscoveryPrefix
                    )

                    for (topic, payload) in configs {
                        client.publish(topic: topic, payload: payload, retain: true)
                        configCount += 1
                    }
                }
                NSLog("[MQTTBridge] Published %d HA discovery configs to '%@'", configCount, config.name)
            }
        }
    }

    // MARK: - Inbound: MQTT → HomeKit

    private func handleIncomingMessage(topic: String, payload: Data, brokerId: String) {
        guard let homeId = brokerHomeMap[brokerId],
              let config = brokerConfigs[homeId]?.first(where: { $0.id == brokerId }) else { return }

        let prefix = config.topicPrefix
        let parts = topic.components(separatedBy: "/")

        // {prefix}/{home}/{room}/{accessory}/set
        if parts.count == 5 && parts[0] == prefix && parts[4] == "set" {
            handleSetCommand(topicParts: parts, payload: payload)
        }
        // {prefix}/{home}/scene/{scene}/execute
        else if parts.count == 5 && parts[0] == prefix && parts[2] == "scene" && parts[4] == "execute" {
            handleSceneCommand(topicParts: parts)
        }
    }

    private func handleSetCommand(topicParts: [String], payload: Data) {
        let path = "\(topicParts[1])/\(topicParts[2])/\(topicParts[3])"
        guard let accessoryId = accessoryMap[path] else {
            NSLog("[MQTTBridge] Unknown accessory path: %@", path)
            return
        }

        guard let updates = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            NSLog("[MQTTBridge] Invalid set payload")
            return
        }

        for (simpleName, value) in updates {
            guard let charType = CharacteristicMapper.typeForSimpleName(simpleName) else {
                NSLog("[MQTTBridge] Unknown characteristic: %@", simpleName)
                continue
            }

            let dedupKey = "\(accessoryId):\(charType)"
            recentPublishes[dedupKey] = Date()

            sendHomeKitCommand(
                action: "characteristic.set",
                payload: [
                    "accessoryId": accessoryId,
                    "characteristicType": charType,
                    "value": value
                ]
            )
        }
    }

    private func handleSceneCommand(topicParts: [String]) {
        let homeSlug = topicParts[1]
        let sceneSlug = topicParts[3]

        guard let homeId = homeSlugMap[homeSlug] else {
            NSLog("[MQTTBridge] Unknown home slug: %@", homeSlug)
            return
        }

        let js = """
        (async function() {
            const scenes = await window.homekit.call('scenes.list', { homeId: '\(homeId)' });
            return JSON.stringify(scenes);
        })();
        """

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self,
                      let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let scenes = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return }

                for scene in scenes {
                    guard scene.count >= 2,
                          let sceneId = scene[0] as? String,
                          let sceneName = scene[1] as? String else { continue }

                    let slug = self.makeSlug(name: sceneName, id: sceneId)
                    if slug == sceneSlug {
                        self.sendHomeKitCommand(action: "scene.execute", payload: ["sceneId": sceneId])
                        return
                    }
                }
                NSLog("[MQTTBridge] Scene not found: %@", sceneSlug)
            }
        }
    }

    // MARK: - JS Bridge Communication

    private func sendHomeKitCommand(action: String, payload: [String: Any]) {
        guard let webView = webView else { return }

        let clientId = "mqtt_\(UUID().uuidString.prefix(8))"
        let message: [String: Any] = [
            "id": clientId,
            "type": "request",
            "action": action,
            "payload": payload
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let messageJson = String(data: data, encoding: .utf8) else { return }

        let escaped = messageJson
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let js = "window.__localserver_request && window.__localserver_request('\(clientId)', '\(escaped)');"

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    NSLog("[MQTTBridge] JS eval error: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // No-op — command responses flow through LocalNetworkBridge
    }

    // MARK: - Status

    var statusDescription: String {
        let connected = clients.values.filter { if case .connected = $0.state { return true }; return false }.count
        let total = clients.count
        if total == 0 { return "no brokers" }
        return "\(connected)/\(total) connected"
    }
}
