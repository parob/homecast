import Foundation
import WebKit

/// Bridges between MQTT clients and the WKWebView JavaScript context.
/// Publishes HomeKit state changes to MQTT topics and routes incoming
/// MQTT commands to HomeKit via the existing JS bridge.
class MQTTBridge: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?
    let mqttClient: MQTTClient

    /// Slug mappings: slug path → HomeKit ID and reverse
    private var homeSlugMap: [String: String] = [:]         // slug → homeId
    private var homeSlugs: [String: String] = [:]           // homeId → slug
    private var roomSlugs: [String: (slug: String, homeSlug: String)] = [:]  // roomId → (slug, homeSlug)
    private var accessoryMap: [String: String] = [:]        // "homeSlug/room/roomSlug/accSlug" → accessoryId
    private var reverseAccessoryMap: [String: String] = [:] // accessoryId → "homeSlug/room/roomSlug/accSlug"

    /// Pending MQTT command callbacks (keyed by synthetic client ID)
    private var pendingCallbacks: [String: (Data?) -> Void] = [:]

    /// Deduplication: recently published characteristic updates (accessoryId+type → timestamp)
    private var recentPublishes: [String: Date] = [:]
    private let deduplicationWindow: TimeInterval = 0.5

    /// Whether slug map has been built
    private var isReady = false

    /// Topic prefix (configurable, default "homecast")
    var topicPrefix = "homecast"

    /// HA Discovery
    var haDiscoveryEnabled = true
    var haDiscoveryPrefix = "homeassistant"
    let discovery = MQTTDiscovery()

    // MARK: - Lifecycle

    init(mqttClient: MQTTClient) {
        self.mqttClient = mqttClient
        super.init()
        mqttClient.onMessage = { [weak self] topic, payload in
            self?.handleIncomingMessage(topic: topic, payload: payload)
        }
        mqttClient.onStateChange = { [weak self] state in
            if case .connected = state {
                self?.onBrokerConnected()
            }
        }
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        NSLog("[MQTTBridge] Attached to WebView")

        // Build slug map once the web app is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.buildSlugMap()
        }
    }

    // MARK: - Broker Connected

    private func onBrokerConnected() {
        // Subscribe to command topics
        mqttClient.subscribe(topic: "\(topicPrefix)/+/room/+/+/set")
        mqttClient.subscribe(topic: "\(topicPrefix)/+/scene/+/execute")
        NSLog("[MQTTBridge] Subscribed to command topics")

        // Publish full state if slug map is ready
        if isReady {
            publishFullState()
            if haDiscoveryEnabled {
                publishHADiscovery()
            }
        }
    }

    // MARK: - Slug Map Building

    /// Build slug ↔ HomeKit ID mappings by querying HomeKit via JS bridge.
    func buildSlugMap() {
        guard let webView = webView else { return }

        // Request homes list
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
                    // Retry after 5s
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

        for home in homes {
            guard let homeId = home["id"] as? String,
                  let homeName = home["name"] as? String else { continue }

            let homeSlug = makeSlug(name: homeName, id: homeId)
            homeSlugMap[homeSlug] = homeId
            homeSlugs[homeId] = homeSlug

            // Map rooms
            if let rooms = home["rooms"] as? [[String: Any]] {
                for room in rooms {
                    guard let roomId = room["id"] as? String,
                          let roomName = room["name"] as? String else { continue }
                    let roomSlug = makeSlug(name: roomName, id: roomId)
                    roomSlugs[roomId] = (slug: roomSlug, homeSlug: homeSlug)
                }
            }

            // Map accessories
            if let accessories = home["accessories"] as? [[String: Any]] {
                for accessory in accessories {
                    guard let accId = accessory["id"] as? String,
                          let accName = accessory["name"] as? String,
                          let roomId = accessory["roomId"] as? String,
                          let roomInfo = roomSlugs[roomId] else { continue }

                    let accSlug = makeSlug(name: accName, id: accId)
                    let path = "\(homeSlug)/room/\(roomInfo.slug)/\(accSlug)"
                    accessoryMap[path] = accId
                    reverseAccessoryMap[accId] = path
                }
            }
        }

        isReady = true
        NSLog("[MQTTBridge] Slug map built: %d homes, %d accessories", homeSlugMap.count, accessoryMap.count)

        // Publish state now that we have mappings
        if case .connected = mqttClient.state {
            publishFullState()
            if haDiscoveryEnabled {
                publishHADiscovery()
            }
        }
    }

    // MARK: - Slug Generation

    /// Generate a stable slug: "name-xxxx" where xxxx is first 4 hex chars of the UUID.
    func makeSlug(name: String, id: String) -> String {
        let base = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()

        // First 4 hex characters of the UUID (strip hyphens)
        let hex = id.replacingOccurrences(of: "-", with: "")
        let suffix = String(hex.prefix(4)).lowercased()

        return "\(base)-\(suffix)"
    }

    // MARK: - Outbound: HomeKit → MQTT

    /// Called by LocalNetworkBridge when a broadcast event occurs.
    func handleBroadcast(type: String, payload: [String: Any]) {
        guard isReady else { return }

        switch type {
        case "characteristic_update":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let charType = payload["characteristicType"] as? String else { return }

            // Dedup: skip if we recently published this from an MQTT command
            let dedupKey = "\(accessoryId):\(charType)"
            if let recent = recentPublishes[dedupKey], Date().timeIntervalSince(recent) < deduplicationWindow {
                return
            }

            publishCharacteristicUpdate(accessoryId: accessoryId, charType: charType, value: payload["value"])

        case "reachability_update":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let isReachable = payload["isReachable"] as? Bool else { return }
            publishAvailability(accessoryId: accessoryId, isReachable: isReachable)

        case "homes_updated":
            // Rebuild slug map when home structure changes
            buildSlugMap()

        default:
            break
        }
    }

    private func publishCharacteristicUpdate(accessoryId: String, charType: String, value: Any?) {
        guard let path = reverseAccessoryMap[accessoryId] else { return }
        let topic = "\(topicPrefix)/\(path)/state"

        // Build partial state update — just the changed characteristic
        let simpleName = CharacteristicMapper.simpleNameForType(charType)
        guard let simpleName = simpleName else { return }

        var state: [String: Any] = [simpleName: value ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            mqttClient.publish(topic: topic, string: json, retain: true)
        }
    }

    private func publishAvailability(accessoryId: String, isReachable: Bool) {
        guard let path = reverseAccessoryMap[accessoryId] else { return }
        let topic = "\(topicPrefix)/\(path)/availability"
        mqttClient.publish(topic: topic, string: isReachable ? "online" : "offline", retain: true)
    }

    /// Publish full state for all accessories (on connect or slug map rebuild).
    private func publishFullState() {
        guard let webView = webView else { return }

        // Publish relay status
        mqttClient.publish(topic: "\(topicPrefix)/status", string: "online", retain: true)

        // Query all accessories with values
        let js = """
        (async function() {
            try {
                const homes = await window.homekit.call('homes.list', {});
                const allAccessories = [];
                for (const home of homes) {
                    const accessories = await window.homekit.call('accessories.list', { homeId: home[0], includeValues: true });
                    allAccessories.push(...accessories);
                }
                return JSON.stringify(allAccessories);
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
                    self.publishAccessoryState(accessory)
                }
                NSLog("[MQTTBridge] Published full state for %d accessories", accessories.count)
            }
        }
    }

    private func publishAccessoryState(_ accessory: [String: Any]) {
        guard let accId = accessory["id"] as? String,
              let path = reverseAccessoryMap[accId] else { return }

        // Build state object from all characteristics
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
            mqttClient.publish(topic: "\(topicPrefix)/\(path)/state", string: json, retain: true)
        }

        mqttClient.publish(
            topic: "\(topicPrefix)/\(path)/availability",
            string: isReachable ? "online" : "offline",
            retain: true
        )
    }

    // MARK: - Inbound: MQTT → HomeKit

    private func handleIncomingMessage(topic: String, payload: Data) {
        let parts = topic.components(separatedBy: "/")

        // homecast/{home}/room/{room}/{accessory}/set
        if parts.count == 6 && parts[0] == topicPrefix && parts[2] == "room" && parts[5] == "set" {
            handleSetCommand(topicParts: parts, payload: payload)
        }
        // homecast/{home}/scene/{scene}/execute
        else if parts.count == 5 && parts[0] == topicPrefix && parts[2] == "scene" && parts[4] == "execute" {
            handleSceneCommand(topicParts: parts)
        }
    }

    private func handleSetCommand(topicParts: [String], payload: Data) {
        let path = "\(topicParts[1])/room/\(topicParts[3])/\(topicParts[4])"
        guard let accessoryId = accessoryMap[path] else {
            NSLog("[MQTTBridge] Unknown accessory path: %@", path)
            return
        }

        guard let updates = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            NSLog("[MQTTBridge] Invalid set payload")
            return
        }

        // Convert simple names back to HomeKit characteristic types and send each
        for (simpleName, value) in updates {
            guard let charType = CharacteristicMapper.typeForSimpleName(simpleName) else {
                NSLog("[MQTTBridge] Unknown characteristic: %@", simpleName)
                continue
            }

            // Mark as recently published to prevent echo
            let dedupKey = "\(accessoryId):\(charType)"
            recentPublishes[dedupKey] = Date()

            // Route through the JS bridge (same path as WebSocket commands)
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

        // Query scenes to find matching slug
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

    /// Send a HomeKit command via the JS bridge (same path as WebSocket clients).
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

    // MARK: - HA Discovery

    private func publishHADiscovery() {
        guard let webView = webView else { return }

        let js = """
        (async function() {
            try {
                const homes = await window.homekit.call('homes.list', {});
                const result = [];
                for (const home of homes) {
                    const accessories = await window.homekit.call('accessories.list', { homeId: home[0], includeValues: true });
                    result.push({ homeId: home[0], homeName: home[1], accessories: accessories });
                }
                return JSON.stringify(result);
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
                      let homes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

                var configCount = 0
                for home in homes {
                    guard let accessories = home["accessories"] as? [[String: Any]] else { continue }
                    for accessory in accessories {
                        guard let accId = accessory["id"] as? String,
                              let path = self.reverseAccessoryMap[accId] else { continue }

                        let configs = self.discovery.generateConfigs(
                            accessory: accessory,
                            topicPrefix: self.topicPrefix,
                            topicPath: path,
                            discoveryPrefix: self.haDiscoveryPrefix
                        )

                        for (topic, payload) in configs {
                            self.mqttClient.publish(topic: topic, payload: payload, retain: true)
                            configCount += 1
                        }
                    }
                }
                NSLog("[MQTTBridge] Published %d HA discovery configs", configCount)
            }
        }
    }

    // MARK: - Discovery metadata

    func publishDiscoveryMetadata() {
        // Publish discovery topic with home/room/accessory structure
        var homes: [[String: Any]] = []
        for (homeSlug, homeId) in homeSlugMap {
            var rooms: [[String: Any]] = []
            for (roomId, roomInfo) in roomSlugs where roomInfo.homeSlug == homeSlug {
                var accessories: [[String: Any]] = []
                for (accPath, accId) in accessoryMap {
                    if accPath.hasPrefix("\(homeSlug)/room/\(roomInfo.slug)/") {
                        let accSlug = accPath.components(separatedBy: "/").last ?? ""
                        accessories.append(["slug": accSlug, "id": accId])
                    }
                }
                rooms.append(["slug": roomInfo.slug, "id": roomId, "accessories": accessories])
            }
            homes.append(["slug": homeSlug, "id": homeId, "rooms": rooms])
        }

        if let data = try? JSONSerialization.data(withJSONObject: homes),
           let json = String(data: data, encoding: .utf8) {
            mqttClient.publish(topic: "\(topicPrefix)/discovery", string: json, retain: true)
        }
    }

    // MARK: - WKScriptMessageHandler (for MQTT command responses)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // MQTTBridge uses the localServer handler for responses — this is a no-op.
        // Command responses flow through LocalNetworkBridge's existing response path.
    }

    // MARK: - Status

    var isConnected: Bool {
        if case .connected = mqttClient.state { return true }
        return false
    }

    var statusDescription: String {
        switch mqttClient.state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let msg): return "error: \(msg)"
        }
    }
}
