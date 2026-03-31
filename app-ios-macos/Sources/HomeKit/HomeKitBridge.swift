import Foundation
import WebKit

#if !targetEnvironment(macCatalyst)
/// Dummy bridge for iOS - does nothing since HomeKit relay is Mac-only
@MainActor
class HomeKitBridge: NSObject, ObservableObject {
    func attach(webView: WKWebView) {}
    func detach() {}
    func handle(method: String?, payload: [String: Any]?, callbackId: String?) {}
}
#else

import HomeKit
import ServiceManagement

/// Bridge exposing HomeKit operations to JavaScript in the WebView.
/// Handles all PROTOCOL.md actions via the webkit message handler system.
@MainActor
class HomeKitBridge: NSObject, ObservableObject, HomeKitManagerDelegate {
    private let homeKitManager: HomeKitManager

    /// WebView for sending events back to JavaScript.
    /// Public read access for AppDelegate to use for menu bar control via JS injection.
    public private(set) weak var webView: WKWebView?

    /// Pending callbacks waiting for async responses
    private var pendingCallbacks: [String: String] = [:]

    /// In-memory relay log buffer (capped to prevent unbounded growth)
    private var relayLogBuffer: [[String: Any]] = []
    private static let maxRelayLogs = 500

    /// Timestamp formatter for relay logs (HH:mm:ss.SSS)
    private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(homeKitManager: HomeKitManager) {
        self.homeKitManager = homeKitManager
        super.init()
        homeKitManager.delegate = self
    }

    /// Attach the WebView for sending events back to JavaScript
    func attach(webView: WKWebView) {
        self.webView = webView
        print("[HomeKitBridge] Attached to WebView")
    }

    /// Detach the WebView
    func detach() {
        self.webView = nil
        print("[HomeKitBridge] Detached from WebView")
    }

    // MARK: - Handle JS Calls

    /// Handle a method call from JavaScript
    /// - Parameters:
    ///   - method: The method name (e.g., "homes.list", "characteristic.set")
    ///   - payload: The payload dictionary
    ///   - callbackId: The callback ID to send the response back
    func handle(method: String?, payload: [String: Any]?, callbackId: String?) {
        guard let method = method, let callbackId = callbackId else {
            print("[HomeKitBridge] Invalid method call - missing method or callbackId")
            return
        }

        print("[HomeKitBridge] Handling method: \(method), callbackId: \(callbackId)")

        let isDebugMethod = method.hasPrefix("debug.")

        Task { @MainActor in
            if !isDebugMethod {
                self.recordRelayLog(method: method, direction: "REQ", payload: payload)
            }

            let startTime = CFAbsoluteTimeGetCurrent()

            do {
                let result = try await self.executeMethod(method, payload: payload ?? [:])

                if !isDebugMethod {
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    self.recordRelayLog(method: method, direction: "RESP", result: result, durationMs: durationMs)
                }

                self.sendSuccess(callbackId: callbackId, result: result)
            } catch {
                if !isDebugMethod {
                    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    self.recordRelayLog(method: method, direction: "RESP", error: error.localizedDescription, durationMs: durationMs)
                }

                self.sendError(callbackId: callbackId, error: error)
            }
        }
    }

    /// Format payload for log display (truncated if too long)
    private func formatPayloadForLog(_ payload: [String: Any]?) -> String? {
        guard let payload = payload, !payload.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        if string.count > 200 {
            return String(string.prefix(200)) + "..."
        }
        return string
    }

    /// Format result for log display (truncated if too long)
    private func formatResultForLog(_ result: Any) -> String? {
        let sanitized = sanitizeForJSON(result)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: result)
        }
        if string.count > 200 {
            return String(string.prefix(200)) + "..."
        }
        return string
    }

    /// Convert a value to a JSON-safe type (handles Data, NSNumber edge cases, etc.)
    private func toJSONSafe(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            // Convert Data to base64 string
            return data.base64EncodedString()
        case let number as NSNumber:
            // NSNumber can represent bools, ints, or doubles
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            } else if number.doubleValue == Double(number.intValue) {
                return number.intValue
            } else {
                return number.doubleValue
            }
        case let array as [Any]:
            return array.map { toJSONSafe($0) }
        case let dict as [String: Any]:
            return dict.mapValues { toJSONSafe($0) }
        default:
            return value
        }
    }

    /// Recursively sanitize a value for JSON serialization
    private func sanitizeForJSON(_ value: Any) -> Any {
        return toJSONSafe(value)
    }

    // MARK: - Method Execution

    private func executeMethod(_ method: String, payload: [String: Any]) async throws -> Any {
        switch method {
        // Home operations
        case "homes.list":
            return try await listHomes()

        // Room operations
        case "rooms.list":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await listRooms(homeId: homeId)

        // Zone operations
        case "zones.list":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await listZones(homeId: homeId)

        // Service group operations
        case "serviceGroups.list":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await listServiceGroups(homeId: homeId)

        case "serviceGroup.set":
            let homeId = payload["homeId"] as? String
            guard let groupId = payload["groupId"] as? String,
                  let characteristicType = payload["characteristicType"] as? String else {
                throw HomeKitBridgeError.missingParameter("groupId or characteristicType")
            }
            guard let value = payload["value"] else {
                throw HomeKitBridgeError.missingParameter("value")
            }
            return try await setServiceGroupCharacteristic(
                homeId: homeId,
                groupId: groupId,
                characteristicType: characteristicType,
                value: value
            )

        // Accessory operations
        case "accessories.list":
            let homeId = payload["homeId"] as? String
            let roomId = payload["roomId"] as? String
            let includeValues = payload["includeValues"] as? Bool ?? true
            return try await listAccessories(homeId: homeId, roomId: roomId, includeValues: includeValues)

        case "accessory.get":
            guard let accessoryId = payload["accessoryId"] as? String else {
                throw HomeKitBridgeError.missingParameter("accessoryId")
            }
            return try await getAccessory(accessoryId: accessoryId)

        case "accessory.refresh":
            guard let accessoryId = payload["accessoryId"] as? String else {
                throw HomeKitBridgeError.missingParameter("accessoryId")
            }
            return try await refreshAccessory(accessoryId: accessoryId)

        // Characteristic operations
        case "characteristic.get":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let characteristicType = payload["characteristicType"] as? String else {
                throw HomeKitBridgeError.missingParameter("accessoryId or characteristicType")
            }
            return try await getCharacteristic(accessoryId: accessoryId, characteristicType: characteristicType)

        case "characteristic.set":
            guard let accessoryId = payload["accessoryId"] as? String,
                  let characteristicType = payload["characteristicType"] as? String else {
                throw HomeKitBridgeError.missingParameter("accessoryId or characteristicType")
            }
            guard let value = payload["value"] else {
                throw HomeKitBridgeError.missingParameter("value")
            }
            return try await setCharacteristic(accessoryId: accessoryId, characteristicType: characteristicType, value: value)

        // Scene operations
        case "scenes.list":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await listScenes(homeId: homeId)

        case "scene.execute":
            guard let sceneId = payload["sceneId"] as? String else {
                throw HomeKitBridgeError.missingParameter("sceneId")
            }
            return try await executeScene(sceneId: sceneId)

        // Automation operations
        case "automations.list":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await listAutomations(homeId: homeId)

        case "automation.get":
            guard let automationId = payload["automationId"] as? String else {
                throw HomeKitBridgeError.missingParameter("automationId")
            }
            return try await getAutomation(automationId: automationId)

        case "automation.create":
            guard let homeId = payload["homeId"] as? String else {
                throw HomeKitBridgeError.missingParameter("homeId")
            }
            return try await createAutomation(homeId: homeId, params: payload)

        case "automation.update":
            guard let automationId = payload["automationId"] as? String else {
                throw HomeKitBridgeError.missingParameter("automationId")
            }
            return try await updateAutomation(automationId: automationId, params: payload)

        case "automation.delete":
            guard let automationId = payload["automationId"] as? String else {
                throw HomeKitBridgeError.missingParameter("automationId")
            }
            return try await deleteAutomation(automationId: automationId)

        case "automation.enable":
            guard let automationId = payload["automationId"] as? String else {
                throw HomeKitBridgeError.missingParameter("automationId")
            }
            return try await setAutomationEnabled(automationId: automationId, enabled: true)

        case "automation.disable":
            guard let automationId = payload["automationId"] as? String else {
                throw HomeKitBridgeError.missingParameter("automationId")
            }
            return try await setAutomationEnabled(automationId: automationId, enabled: false)

        // State operations (bulk)
        case "state.set":
            guard let state = payload["state"] as? [String: [String: [String: Any]]] else {
                throw HomeKitBridgeError.missingParameter("state")
            }
            let homeId = payload["homeId"] as? String
            return try await setState(state: state, homeId: homeId)

        // Observation operations
        case "observe.start":
            return startObserving()

        case "observe.stop":
            return stopObserving()

        case "observe.reset":
            return resetObservationTimeout()

        // Debug operations
        case "debug.getRelayLogs":
            return getRelayLogs()

        case "debug.getWebViewLogs":
            return getWebViewLogs()

        case "debug.getStats":
            return try await getStats()

        case "debug.clearRelayLogs":
            return clearRelayLogs()

        case "debug.clearWebViewLogs":
            return clearWebViewLogs()

        // Settings operations
        case "settings.getLaunchAtLogin":
            return getLaunchAtLogin()

        case "settings.setLaunchAtLogin":
            guard let enabled = payload["enabled"] as? Bool else {
                throw HomeKitBridgeError.missingParameter("enabled")
            }
            return setLaunchAtLogin(enabled: enabled)

        case "settings.getEnvironment":
            return getEnvironment()

        case "settings.setEnvironment":
            guard let environment = payload["environment"] as? String else {
                throw HomeKitBridgeError.missingParameter("environment")
            }
            return setEnvironment(environment: environment)

        default:
            throw HomeKitBridgeError.unknownMethod(method)
        }
    }

    // MARK: - HomeKit Operations

    private func listHomes() async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let homes = homeKitManager.listHomes()
        return homes.map { home in
            [
                "id": home.id,
                "name": home.name,
                "isPrimary": home.isPrimary,
                "roomCount": home.roomCount,
                "accessoryCount": home.accessoryCount
            ]
        }
    }

    private func listRooms(homeId: String) async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let rooms = try homeKitManager.listRooms(homeId: homeId)
        return rooms.map { room in
            [
                "id": room.id,
                "name": room.name,
                "accessoryCount": room.accessoryCount
            ]
        }
    }

    private func listZones(homeId: String) async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let zones = try homeKitManager.listZones(homeId: homeId)
        return zones.map { zone in
            [
                "id": zone.id,
                "name": zone.name,
                "roomIds": zone.roomIds
            ]
        }
    }

    private func listServiceGroups(homeId: String) async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let groups = try homeKitManager.listServiceGroups(homeId: homeId)
        return groups.map { group in
            [
                "id": group.id,
                "name": group.name,
                "serviceIds": group.serviceIds,
                "accessoryIds": group.accessoryIds
            ]
        }
    }

    private func setServiceGroupCharacteristic(
        homeId: String?,
        groupId: String,
        characteristicType: String,
        value: Any
    ) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let successCount = try await homeKitManager.setServiceGroupCharacteristic(
            homeId: homeId,
            groupId: groupId,
            characteristicType: characteristicType,
            value: value
        )
        return [
            "success": true,
            "groupId": groupId,
            "successCount": successCount
        ]
    }

    private func listAccessories(homeId: String?, roomId: String?, includeValues: Bool) async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let accessories = try homeKitManager.listAccessories(homeId: homeId, roomId: roomId, includeValues: includeValues)
        return accessories.map { accessory in
            var dict: [String: Any] = [
                "id": accessory.id,
                "name": accessory.name,
                "category": accessory.category,
                "isReachable": accessory.isReachable,
                "services": accessory.services.map { service in
                    [
                        "id": service.id,
                        "name": service.name,
                        "serviceType": service.serviceType,
                        "characteristics": service.characteristics.map { char in
                            var charDict: [String: Any] = [
                                "id": char.id,
                                "characteristicType": char.characteristicType,
                                "isReadable": char.isReadable,
                                "isWritable": char.isWritable
                            ]
                            if let value = char.rawValue {
                                charDict["value"] = value
                            }
                            if let validValues = char.validValues {
                                charDict["validValues"] = validValues
                            }
                            if let minValue = char.minValue {
                                charDict["minValue"] = minValue
                            }
                            if let maxValue = char.maxValue {
                                charDict["maxValue"] = maxValue
                            }
                            if let stepValue = char.stepValue {
                                charDict["stepValue"] = stepValue
                            }
                            return charDict
                        }
                    ]
                }
            ]
            if let homeId = accessory.homeId {
                dict["homeId"] = homeId
            }
            if let roomId = accessory.roomId {
                dict["roomId"] = roomId
            }
            if let roomName = accessory.roomName {
                dict["roomName"] = roomName
            }
            return dict
        }
    }

    private func getAccessory(accessoryId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let accessory = try homeKitManager.getAccessory(id: accessoryId)
        var dict: [String: Any] = [
            "id": accessory.id,
            "name": accessory.name,
            "category": accessory.category,
            "isReachable": accessory.isReachable,
            "services": accessory.services.map { service in
                [
                    "id": service.id,
                    "name": service.name,
                    "serviceType": service.serviceType,
                    "characteristics": service.characteristics.map { char in
                        var charDict: [String: Any] = [
                            "id": char.id,
                            "characteristicType": char.characteristicType,
                            "isReadable": char.isReadable,
                            "isWritable": char.isWritable
                        ]
                        if let value = char.rawValue {
                            charDict["value"] = value
                        }
                        if let validValues = char.validValues {
                            charDict["validValues"] = validValues
                        }
                        if let minValue = char.minValue {
                            charDict["minValue"] = minValue
                        }
                        if let maxValue = char.maxValue {
                            charDict["maxValue"] = maxValue
                        }
                        if let stepValue = char.stepValue {
                            charDict["stepValue"] = stepValue
                        }
                        return charDict
                    }
                ]
            }
        ]
        if let homeId = accessory.homeId {
            dict["homeId"] = homeId
        }
        if let roomId = accessory.roomId {
            dict["roomId"] = roomId
        }
        if let roomName = accessory.roomName {
            dict["roomName"] = roomName
        }
        return dict
    }

    private func refreshAccessory(accessoryId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        try await homeKitManager.refreshAccessoryValues(id: accessoryId)
        return ["success": true, "accessoryId": accessoryId]
    }

    private func getCharacteristic(accessoryId: String, characteristicType: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let value = try await homeKitManager.readCharacteristic(accessoryId: accessoryId, characteristicType: characteristicType)
        return [
            "accessoryId": accessoryId,
            "characteristicType": characteristicType,
            "value": value
        ]
    }

    private func setCharacteristic(accessoryId: String, characteristicType: String, value: Any) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let result = try await homeKitManager.setCharacteristic(
            accessoryId: accessoryId,
            characteristicType: characteristicType,
            value: value
        )
        return [
            "success": result.success,
            "accessoryId": result.accessoryId,
            "characteristicType": result.characteristic,
            "value": result.newValue
        ]
    }

    private func listScenes(homeId: String) async throws -> [[String: Any]] {
        await homeKitManager.waitForReady()
        let scenes = try homeKitManager.listScenes(homeId: homeId)
        return scenes.map { scene in
            [
                "id": scene.id,
                "name": scene.name,
                "actionCount": scene.actionCount
            ]
        }
    }

    private func executeScene(sceneId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let result = try await homeKitManager.executeScene(sceneId: sceneId)
        return [
            "success": result.success,
            "sceneId": result.sceneId
        ]
    }

    private func listAutomations(homeId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let automations = try homeKitManager.listAutomations(homeId: homeId)
        return [
            "automations": automations.map { $0.toJSON().toFoundation() }
        ]
    }

    private func getAutomation(automationId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let automation = try homeKitManager.getAutomation(automationId: automationId)
        return automation.toJSON().toFoundation() as! [String: Any]
    }

    private func createAutomation(homeId: String, params: [String: Any]) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let automation = try await homeKitManager.createAutomation(homeId: homeId, params: params)
        return automation.toJSON().toFoundation() as! [String: Any]
    }

    private func updateAutomation(automationId: String, params: [String: Any]) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let automation = try await homeKitManager.updateAutomation(automationId: automationId, params: params)
        return automation.toJSON().toFoundation() as! [String: Any]
    }

    private func deleteAutomation(automationId: String) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        try await homeKitManager.deleteAutomation(automationId: automationId)
        return [
            "success": true,
            "automationId": automationId
        ]
    }

    private func setAutomationEnabled(automationId: String, enabled: Bool) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let automation = try await homeKitManager.setAutomationEnabled(automationId: automationId, enabled: enabled)
        return automation.toJSON().toFoundation() as! [String: Any]
    }

    private func setState(state: [String: [String: [String: Any]]], homeId: String?) async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let (ok, failed) = try await homeKitManager.setState(state: state, homeId: homeId)
        return [
            "success": failed.isEmpty,
            "ok": ok,
            "failed": failed
        ]
    }

    private func startObserving() -> [String: Any] {
        homeKitManager.startObservingChanges()
        return ["success": true, "observing": true]
    }

    private func stopObserving() -> [String: Any] {
        homeKitManager.stopObservingChanges()
        return ["success": true, "observing": false]
    }

    private func resetObservationTimeout() -> [String: Any] {
        homeKitManager.resetObservationTimeout()
        return ["success": true]
    }

    // MARK: - Relay Log Recording

    private func recordRelayLog(
        method: String,
        direction: String,
        payload: [String: Any]? = nil,
        result: Any? = nil,
        error: String? = nil,
        durationMs: Int? = nil
    ) {
        var entry: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": Self.logTimestampFormatter.string(from: Date()),
            "method": method,
            "direction": direction,
        ]

        if let payload = payload {
            entry["payload"] = formatPayloadForLog(payload)
        }
        if let result = result {
            entry["result"] = formatResultForLog(result)
        }
        if let error = error {
            entry["error"] = error
        }
        if let durationMs = durationMs {
            entry["durationMs"] = durationMs
        }

        relayLogBuffer.append(entry)

        // Cap buffer size
        if relayLogBuffer.count > Self.maxRelayLogs {
            relayLogBuffer.removeFirst(relayLogBuffer.count - Self.maxRelayLogs)
        }
    }

    // MARK: - Debug Operations

    private func getRelayLogs() -> [[String: Any]] {
        return relayLogBuffer
    }

    private func getWebViewLogs() -> [[String: Any]] {
        return []
    }

    private func getStats() async throws -> [String: Any] {
        await homeKitManager.waitForReady()
        let homes = homeKitManager.listHomes()

        var totalAccessories = 0
        var onlineAccessories = 0
        var offlineAccessories = 0
        var totalRooms = 0
        var totalZones = 0
        var totalScenes = 0
        var totalServiceGroups = 0

        for home in homes {
            totalRooms += home.roomCount
            totalAccessories += home.accessoryCount

            // Get accessories to count online/offline
            if let accessories = try? homeKitManager.listAccessories(homeId: home.id, roomId: nil, includeValues: false) {
                for accessory in accessories {
                    if accessory.isReachable {
                        onlineAccessories += 1
                    } else {
                        offlineAccessories += 1
                    }
                }
            }

            // Get zones count
            if let zones = try? homeKitManager.listZones(homeId: home.id) {
                totalZones += zones.count
            }

            // Get scenes count
            if let scenes = try? homeKitManager.listScenes(homeId: home.id) {
                totalScenes += scenes.count
            }

            // Get service groups count
            if let groups = try? homeKitManager.listServiceGroups(homeId: home.id) {
                totalServiceGroups += groups.count
            }
        }

        return [
            "homes": homes.count,
            "accessories": totalAccessories,
            "accessoriesOnline": onlineAccessories,
            "accessoriesOffline": offlineAccessories,
            "rooms": totalRooms,
            "zones": totalZones,
            "scenes": totalScenes,
            "serviceGroups": totalServiceGroups
        ]
    }

    private func clearRelayLogs() -> [String: Any] {
        relayLogBuffer.removeAll()
        return ["success": true]
    }

    private func clearWebViewLogs() -> [String: Any] {
        return ["success": true]
    }

    // MARK: - Settings Operations

    private func getLaunchAtLogin() -> [String: Any] {
        let status = SMAppService.mainApp.status
        return ["launchAtLogin": status == .enabled]
    }

    private func setLaunchAtLogin(enabled: Bool) -> [String: Any] {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = SMAppService.mainApp.status
            return ["success": true, "launchAtLogin": status == .enabled]
        } catch {
            print("[HomeKitBridge] Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            let status = SMAppService.mainApp.status
            return ["success": false, "launchAtLogin": status == .enabled]
        }
    }

    private func getEnvironment() -> [String: Any] {
        if AppConfig.isCommunity {
            return ["environment": "community"]
        }
        return ["environment": AppConfig.isStaging ? "staging" : "production"]
    }

    private func setEnvironment(environment: String) -> [String: Any] {
        let isCommunity = environment == "community"
        let isStaging = environment == "staging"

        // Set Community mode flag
        UserDefaults.standard.set(isCommunity, forKey: "com.homecast.communityMode")
        // Only update staging flag when not switching to Community
        if !isCommunity {
            UserDefaults.standard.set(isStaging, forKey: "com.homecast.stagingMode")
        }

        print("[HomeKitBridge] Environment set to \(environment)")
        NotificationCenter.default.post(name: .environmentDidChange, object: nil)
        return ["success": true, "environment": environment]
    }

    // MARK: - Send Responses to JavaScript

    private func sendSuccess(callbackId: String, result: Any) {
        sendCallback(callbackId: callbackId, success: true, data: result, error: nil)
    }

    private func sendError(callbackId: String, error: Error) {
        let errorMessage = error.localizedDescription
        let errorCode: String

        if let bridgeError = error as? HomeKitBridgeError {
            errorCode = bridgeError.code
        } else if let homeKitError = error as? HomeKitError {
            errorCode = homeKitError.code
        } else {
            errorCode = "INTERNAL_ERROR"
        }

        sendCallback(callbackId: callbackId, success: false, data: nil, error: [
            "code": errorCode,
            "message": errorMessage
        ])
    }

    private func sendCallback(callbackId: String, success: Bool, data: Any?, error: [String: String]?) {
        guard let webView = webView else {
            print("[HomeKitBridge] No WebView attached, cannot send callback")
            return
        }

        var payload: [String: Any] = [
            "callbackId": callbackId,
            "success": success
        ]

        if let data = data {
            // Sanitize data to ensure it's JSON-serializable (handles Data, etc.)
            payload["data"] = sanitizeForJSON(data)
        }

        if let error = error {
            payload["error"] = error
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[HomeKitBridge] Failed to serialize callback payload")
            return
        }

        let js = "window.__homekit_callback(\(jsonString));"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[HomeKitBridge] Failed to send callback: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Push Events to JavaScript

    private func pushEvent(type: String, payload: [String: Any]) {
        guard let webView = webView else {
            return
        }

        var eventPayload = sanitizeForJSON(payload) as? [String: Any] ?? [:]
        eventPayload["type"] = type

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[HomeKitBridge] Failed to serialize event payload")
            return
        }

        let js = "window.__homekit_event(\(jsonString));"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[HomeKitBridge] Failed to push event: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Manual Event Push (for menu bar control)

    /// Push a characteristic update event to the WebView.
    /// Used when we control devices directly and need to notify the UI.
    public func pushCharacteristicUpdate(accessoryId: String, homeId: String, characteristicType: String, value: Any) {
        let payload: [String: Any] = [
            "accessoryId": accessoryId,
            "characteristicType": characteristicType,
            "value": value,
            "homeId": homeId
        ]
        pushEvent(type: "characteristic.updated", payload: payload)
    }

    // MARK: - HomeKitManagerDelegate

    func characteristicDidUpdate(accessoryId: String, characteristicType: String, value: Any, context: AccessoryEventContext) {
        var payload: [String: Any] = [
            "accessoryId": accessoryId,
            "characteristicType": characteristicType,
            "value": value,
            "homeId": context.homeId
        ]
        if let roomId = context.roomId {
            payload["roomId"] = roomId
        }
        if !context.serviceGroupIds.isEmpty {
            payload["serviceGroupIds"] = context.serviceGroupIds
        }
        pushEvent(type: "characteristic.updated", payload: payload)

        // Forward to menu bar plugin for real-time updates
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.forwardCharacteristicUpdate(accessoryId: accessoryId, type: characteristicType, value: value)
        }
    }

    func accessoryReachabilityDidUpdate(accessoryId: String, isReachable: Bool, context: AccessoryEventContext) {
        var payload: [String: Any] = [
            "accessoryId": accessoryId,
            "isReachable": isReachable,
            "homeId": context.homeId
        ]
        if let roomId = context.roomId {
            payload["roomId"] = roomId
        }
        if !context.serviceGroupIds.isEmpty {
            payload["serviceGroupIds"] = context.serviceGroupIds
        }
        pushEvent(type: "accessory.reachability", payload: payload)

        // Forward to menu bar plugin for real-time updates
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.forwardReachabilityUpdate(accessoryId: accessoryId, isReachable: isReachable)
        }
    }

    func homesDidUpdate() {
        pushEvent(type: "homes.updated", payload: [:])
    }
}

// MARK: - Errors

enum HomeKitBridgeError: LocalizedError {
    case unknownMethod(String)
    case missingParameter(String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .unknownMethod(let method):
            return "Unknown method: \(method)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidPayload:
            return "Invalid payload format"
        }
    }

    var code: String {
        switch self {
        case .unknownMethod:
            return "UNKNOWN_METHOD"
        case .missingParameter:
            return "MISSING_PARAMETER"
        case .invalidPayload:
            return "INVALID_PAYLOAD"
        }
    }
}

#endif // targetEnvironment(macCatalyst)
