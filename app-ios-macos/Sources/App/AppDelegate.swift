import UIKit
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published var homeKitManager: HomeKitManager!
    @Published var connectionManager: ConnectionManager!
    @Published var homeKitBridge: HomeKitBridge!
    private var menuBarPlugin: AnyObject?

    /// Local HTTP server for Community mode (Mac only)
    #if targetEnvironment(macCatalyst)
    var localHTTPServer: LocalHTTPServer?
    #endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Initialize HomeKit manager
        homeKitManager = HomeKitManager()

        // Initialize HomeKit bridge for WebView relay mode
        // On Mac, this enables the full relay functionality
        // On iOS, this is a no-op dummy bridge
        #if targetEnvironment(macCatalyst)
        homeKitBridge = HomeKitBridge(homeKitManager: homeKitManager)
        #else
        homeKitBridge = HomeKitBridge()
        #endif

        // Initialize connection manager (handles auth credentials)
        connectionManager = ConnectionManager()

        // Load menu bar plugin on Mac
        #if targetEnvironment(macCatalyst)
        loadMenuBarPlugin()

        // Start local HTTP server if Community mode is enabled
        if AppConfig.isCommunity {
            startLocalServer()
        }

        // Listen for sleep/wake to restart the local server
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSWorkspaceDidWakeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, AppConfig.isCommunity else { return }
            print("[Homecast] Mac woke from sleep — restarting local server")
            self.localHTTPServer?.restart()
            NotificationCenter.default.post(name: .reloadWebView, object: nil)
        }

        // Listen for Community mode toggle
        NotificationCenter.default.addObserver(
            forName: .environmentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if AppConfig.isCommunity {
                self?.startLocalServer()
            } else {
                self?.stopLocalServer()
            }
        }
        #endif

        return true
    }

    // MARK: - Local Server Lifecycle

    #if targetEnvironment(macCatalyst)
    func startLocalServer() {
        guard localHTTPServer == nil else { return }
        let server = LocalHTTPServer()
        server.start()
        localHTTPServer = server
        LocalHTTPServer.shared = server
    }

    func stopLocalServer() {
        localHTTPServer?.stop()
        localHTTPServer = nil
        print("[Homecast] Community mode: local server stopped")
    }
    #endif

    // MARK: - Scene Configuration

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // MARK: - Menu Bar Plugin

    #if targetEnvironment(macCatalyst)
    private func loadMenuBarPlugin() {
        // Load the AppKit bundle for menu bar functionality
        guard let pluginURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("MenuBarPlugin.bundle") else {
            print("[Homecast] MenuBarPlugin.bundle not found in PlugIns")
            return
        }

        guard let bundle = Bundle(url: pluginURL), bundle.load() else {
            print("[Homecast] Failed to load MenuBarPlugin bundle")
            return
        }

        guard let pluginClass = bundle.principalClass as? NSObject.Type else {
            print("[Homecast] Failed to get principal class from MenuBarPlugin")
            return
        }

        // Create the plugin instance
        menuBarPlugin = pluginClass.init()

        // Set up the plugin with our status provider and config
        if let plugin = menuBarPlugin {
            let setupSelector = NSSelectorFromString("setupWithStatusProvider:showWindowOnLaunch:")
            if plugin.responds(to: setupSelector) {
                let method = plugin.method(for: setupSelector)
                typealias SetupMethod = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
                let impl = unsafeBitCast(method, to: SetupMethod.self)
                impl(plugin, setupSelector, self, AppConfig.showWindowOnLaunch)
            }
        }

        // Listen for HomeKit ready notification to preload menu bar data
        NotificationCenter.default.addObserver(
            forName: .homeKitDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyMenuBarHomeKitReady()
        }

        // Listen for relay status changes from WebView for menu bar icon updates
        NotificationCenter.default.addObserver(
            forName: .relayStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let connectionState = userInfo["connectionState"] as? String else {
                return
            }
            let relayStatus = userInfo["relayStatus"] as? NSNumber
            self?.forwardRelayStatusToMenuBar(connectionState: connectionState, relayStatus: relayStatus?.boolValue)
        }

        print("[Homecast] Menu bar plugin loaded successfully")
    }

    // MARK: - Menu Bar Plugin Data Providers

    @objc func isHomeKitReady() -> NSNumber {
        return NSNumber(value: homeKitManager?.isReady ?? false)
    }

    @objc func homeNames() -> [String] {
        return homeKitManager?.homes.map { $0.name } ?? []
    }

    @objc func accessoryCounts() -> [NSNumber] {
        return homeKitManager?.homes.map { NSNumber(value: $0.accessories.count) } ?? []
    }

    @objc func isConnectedToRelay() -> NSNumber {
        // Connection is now managed by WebView relay - just check if authenticated
        return NSNumber(value: connectionManager?.isAuthenticated ?? false)
    }

    @objc func isAuthenticated() -> NSNumber {
        return NSNumber(value: connectionManager?.isAuthenticated ?? false)
    }

    @objc func connectedEmail() -> String {
        return connectionManager?.savedEmail ?? ""
    }

    @objc func currentStatus() -> String {
        if homeKitManager.isReady {
            return "ready"
        } else {
            return "loading"
        }
    }

    @objc func showWindow() {
        // Bring the app to front and show window
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
    }

    @objc func quitApp() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }

    @objc func reconnectRelay() {
        // Relay reconnection is now handled by WebView - trigger a page reload
        NotificationCenter.default.post(name: .reloadWebView, object: nil)
    }

    /// Forward relay connection status to the menu bar plugin for icon updates
    private func forwardRelayStatusToMenuBar(connectionState: String, relayStatus: Bool?) {
        guard let plugin = menuBarPlugin else { return }

        let selector = NSSelectorFromString("relayStatusDidChangeWithConnectionState:relayStatus:")
        if plugin.responds(to: selector) {
            let method = plugin.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, NSNumber?) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(plugin, selector, connectionState, relayStatus.map { NSNumber(value: $0) })
        }
    }

    // MARK: - Menu Bar HomeKit Data

    /// Get all homes for menu bar display
    @objc func menuGetHomes() -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        return manager.listHomes().map { home in
            [
                "id": home.id,
                "name": home.name,
                "isPrimary": home.isPrimary
            ]
        }
    }

    /// Get rooms in a home for menu bar display
    @objc func menuGetRooms(homeId: String) -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        do {
            return try manager.listRooms(homeId: homeId).map { room in
                [
                    "id": room.id,
                    "name": room.name
                ]
            }
        } catch {
            print("[AppDelegate] menuGetRooms failed: \(error)")
            return []
        }
    }

    /// Convert an AccessoryModel to a menu bar dictionary with characteristic info
    private func menuAccessoryDict(from accessory: AccessoryModel) -> [String: Any] {
        var result: [String: Any] = [
            "id": accessory.id,
            "name": accessory.name,
            "category": accessory.category,
            "isReachable": accessory.isReachable
        ]

        if let roomId = accessory.roomId {
            result["roomId"] = roomId
        }

        // Find controllable characteristics
        for service in accessory.services {
            for char in service.characteristics {
                let charType = char.characteristicType.lowercased()

                // Power state - check all variants including "active" for HVAC devices
                // Only set if not already set (prefer power_state over active)
                if charType == "power_state" || charType == "powerstate" || charType == "on" {
                    if let value = char.rawValue as? Bool {
                        result["powerState"] = value
                        result["powerCharType"] = char.characteristicType
                    } else if let value = char.rawValue as? Int {
                        result["powerState"] = value != 0
                        result["powerCharType"] = char.characteristicType
                    }
                } else if charType == "active" && result["powerCharType"] == nil {
                    // Use "active" for devices that don't have power_state (HVAC, fans, etc.)
                    if let value = char.rawValue as? Bool {
                        result["powerState"] = value
                        result["powerCharType"] = char.characteristicType
                    } else if let value = char.rawValue as? Int {
                        result["powerState"] = value != 0
                        result["powerCharType"] = char.characteristicType
                    }
                }

                // Brightness
                if charType == "brightness" {
                    if let value = char.rawValue as? Int {
                        result["brightness"] = value
                    } else if let value = char.rawValue as? Double {
                        result["brightness"] = Int(value)
                    }
                }

                // Hue (for RGB lights)
                if charType == "hue" {
                    if let value = char.rawValue as? Double {
                        result["hue"] = value
                    } else if let value = char.rawValue as? Int {
                        result["hue"] = Double(value)
                    }
                }

                // Saturation (for RGB lights)
                if charType == "saturation" {
                    if let value = char.rawValue as? Double {
                        result["saturation"] = value
                    } else if let value = char.rawValue as? Int {
                        result["saturation"] = Double(value)
                    }
                }

                // Color temperature (in mireds)
                if charType == "color_temperature" || charType == "colortemperature" {
                    if let value = char.rawValue as? Double {
                        result["colorTemperature"] = value
                    } else if let value = char.rawValue as? Int {
                        result["colorTemperature"] = Double(value)
                    }
                    // Get min/max from characteristic metadata if available
                    if let minValue = char.minValue as? Double {
                        result["colorTemperatureMin"] = minValue
                    }
                    if let maxValue = char.maxValue as? Double {
                        result["colorTemperatureMax"] = maxValue
                    }
                }

                // Window covering position
                if charType == "currentposition" || charType == "current_position" {
                    if let value = char.rawValue as? Int {
                        result["position"] = value
                    } else if let value = char.rawValue as? Double {
                        result["position"] = Int(value)
                    }
                }

                // Target position (for control)
                if charType == "targetposition" || charType == "target_position" {
                    result["hasTargetPosition"] = true
                }

                // Thermostat: Current temperature
                if charType == "currenttemperature" || charType == "current_temperature" {
                    if let value = char.rawValue as? Double {
                        result["currentTemperature"] = value
                    } else if let value = char.rawValue as? Int {
                        result["currentTemperature"] = Double(value)
                    }
                }

                // Thermostat: Target temperature
                if charType == "targettemperature" || charType == "target_temperature" {
                    if let value = char.rawValue as? Double {
                        result["targetTemperature"] = value
                    } else if let value = char.rawValue as? Int {
                        result["targetTemperature"] = Double(value)
                    }
                }

                // Thermostat: Target heating/cooling state (mode)
                // CharacteristicMapper uses "heating_cooling_target"
                if charType == "heating_cooling_target" || charType == "targetheatingcoolingstate" {
                    if let value = char.rawValue as? Int {
                        result["hvacMode"] = value
                    }
                }

                // Thermostat: Heating threshold temperature (for auto mode)
                // CharacteristicMapper uses "heating_threshold"
                if charType == "heating_threshold" || charType == "heatingthreshold" {
                    if let value = char.rawValue as? Double {
                        result["heatingThreshold"] = value
                    } else if let value = char.rawValue as? Int {
                        result["heatingThreshold"] = Double(value)
                    }
                }

                // Thermostat: Cooling threshold temperature (for auto mode)
                // CharacteristicMapper uses "cooling_threshold"
                if charType == "cooling_threshold" || charType == "coolingthreshold" {
                    if let value = char.rawValue as? Double {
                        result["coolingThreshold"] = value
                    } else if let value = char.rawValue as? Int {
                        result["coolingThreshold"] = Double(value)
                    }
                }

                // HeaterCooler (AC): Target state (0=auto, 1=heat, 2=cool)
                if charType == "targetheatercoolerstate" || charType == "target_heater_cooler_state" {
                    if let value = char.rawValue as? Int {
                        // Map HeaterCooler states to thermostat-compatible states
                        // HeaterCooler: 0=auto, 1=heat, 2=cool
                        // Thermostat: 0=off, 1=heat, 2=cool, 3=auto
                        let mappedMode: Int
                        switch value {
                        case 0: mappedMode = 3  // auto -> 3
                        case 1: mappedMode = 1  // heat -> 1
                        case 2: mappedMode = 2  // cool -> 2
                        default: mappedMode = value
                        }
                        result["hvacMode"] = mappedMode
                        result["isHeaterCooler"] = true
                    }
                }

                // HeaterCooler (AC): Current state (0=inactive, 1=idle, 2=heating, 3=cooling)
                if charType == "currentheatercoolerstate" || charType == "current_heater_cooler_state" {
                    if let value = char.rawValue as? Int {
                        result["currentHeaterCoolerState"] = value
                    }
                }

                // Security System: Current state (0=stayArm, 1=awayArm, 2=nightArm, 3=disarmed, 4=triggered)
                if charType == "securitysystemcurrentstate" || charType == "security_system_current_state" {
                    if let value = char.rawValue as? Int {
                        result["securityCurrentState"] = value
                    }
                }

                // Security System: Target state (0=stayArm, 1=awayArm, 2=nightArm, 3=disarm)
                if charType == "securitysystemtargetstate" || charType == "security_system_target_state" {
                    if let value = char.rawValue as? Int {
                        result["securityTargetState"] = value
                    }
                }

                // Lock: Current state (0=unlocked, 1=locked, 2=jammed, 3=unknown)
                if charType == "lockcurrentstate" || charType == "lock_current_state" {
                    if let value = char.rawValue as? Int {
                        result["lockState"] = value
                    }
                }

                // Lock: Target state (0=unlocked, 1=locked)
                if charType == "locktargetstate" || charType == "lock_target_state" {
                    if let value = char.rawValue as? Int {
                        result["targetLockState"] = value
                    }
                }

                // Garage Door: Current state (0=open, 1=closed, 2=opening, 3=closing, 4=stopped)
                if charType == "currentdoorstate" || charType == "current_door_state" {
                    if let value = char.rawValue as? Int {
                        result["doorState"] = value
                    }
                }

                // Garage Door: Target state (0=open, 1=closed)
                if charType == "targetdoorstate" || charType == "target_door_state" {
                    if let value = char.rawValue as? Int {
                        result["targetDoorState"] = value
                    }
                }

                // Motion sensor
                if charType == "motiondetected" || charType == "motion_detected" {
                    if let value = char.rawValue as? Bool {
                        result["motionDetected"] = value
                    } else if let value = char.rawValue as? Int {
                        result["motionDetected"] = value != 0
                    }
                }

                // Occupancy sensor
                if charType == "occupancydetected" || charType == "occupancy_detected" {
                    if let value = char.rawValue as? Bool {
                        result["occupancyDetected"] = value
                    } else if let value = char.rawValue as? Int {
                        result["occupancyDetected"] = value != 0
                    }
                }

                // Contact sensor (0=detected/closed, 1=not detected/open)
                if charType == "contactstate" || charType == "contact_state" {
                    if let value = char.rawValue as? Int {
                        result["contactState"] = value
                    }
                }

                // Smoke sensor
                if charType == "smokedetected" || charType == "smoke_detected" {
                    if let value = char.rawValue as? Bool {
                        result["smokeDetected"] = value
                    } else if let value = char.rawValue as? Int {
                        result["smokeDetected"] = value != 0
                    }
                }

                // Carbon monoxide sensor
                if charType == "carbonmonoxidedetected" || charType == "carbon_monoxide_detected" {
                    if let value = char.rawValue as? Bool {
                        result["coDetected"] = value
                    } else if let value = char.rawValue as? Int {
                        result["coDetected"] = value != 0
                    }
                }

                // Battery level
                if charType == "batterylevel" || charType == "battery_level" {
                    if let value = char.rawValue as? Int {
                        result["batteryLevel"] = value
                    } else if let value = char.rawValue as? Double {
                        result["batteryLevel"] = Int(value)
                    }
                }

                // Low battery status
                if charType == "statuslowbattery" || charType == "status_low_battery" {
                    if let value = char.rawValue as? Bool {
                        result["statusLowBattery"] = value
                    } else if let value = char.rawValue as? Int {
                        result["statusLowBattery"] = value != 0
                    }
                }
            }
        }

        // Count button services for remote/button widgets
        let buttonServiceCount = accessory.services.filter {
            $0.serviceType == "stateless_programmable_switch"
        }.count
        if buttonServiceCount > 0 {
            result["buttonCount"] = buttonServiceCount
        }

        // Service types for widget type resolution (human-readable names from CharacteristicMapper)
        result["serviceTypes"] = accessory.services.map { $0.serviceType }

        result["hasPower"] = result["powerCharType"] != nil
        result["hasSecuritySystem"] = result["securityCurrentState"] != nil
        result["hasBrightness"] = result["brightness"] != nil
        result["hasPosition"] = result["position"] != nil
        result["hasRGB"] = result["hue"] != nil && result["saturation"] != nil
        result["hasColorTemp"] = result["colorTemperature"] != nil
        // Thermostat: has currentTemperature + hvacMode (from TargetHeatingCoolingState)
        // HeaterCooler: has currentTemperature + hvacMode (from TargetHeaterCoolerState, mapped)
        result["hasThermostat"] = result["currentTemperature"] != nil && result["hvacMode"] != nil
        result["hasThresholds"] = result["heatingThreshold"] != nil && result["coolingThreshold"] != nil

        return result
    }

    /// Get accessories in a room for menu bar display
    @objc func menuGetAccessories(homeId: String, roomId: String) -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        do {
            let accessories = try manager.listAccessories(homeId: homeId, roomId: roomId, includeValues: true)
            return accessories.map { menuAccessoryDict(from: $0) }
        } catch {
            print("[AppDelegate] menuGetAccessories failed: \(error)")
            return []
        }
    }

    /// Get all accessories in a home for menu bar display (single bulk call)
    /// Each accessory dict includes a "roomId" field for grouping
    @objc func menuGetAllAccessories(homeId: String) -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        do {
            let accessories = try manager.listAccessories(homeId: homeId, roomId: nil, includeValues: true)
            return accessories.map { menuAccessoryDict(from: $0) }
        } catch {
            print("[AppDelegate] menuGetAllAccessories failed: \(error)")
            return []
        }
    }

    /// Get scenes in a home for menu bar display
    @objc func menuGetScenes(homeId: String) -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        do {
            return try manager.listScenes(homeId: homeId).map { scene in
                [
                    "id": scene.id,
                    "name": scene.name
                ]
            }
        } catch {
            print("[AppDelegate] menuGetScenes failed: \(error)")
            return []
        }
    }

    /// Get service groups in a home for menu bar display
    /// Includes room info to allow placing groups within rooms
    @objc func menuGetServiceGroups(homeId: String) -> [[String: Any]] {
        guard let manager = homeKitManager, manager.isReady else {
            return []
        }

        do {
            let groups = try manager.listServiceGroups(homeId: homeId)
            return groups.compactMap { group -> [String: Any]? in
                var isOn = false
                var accessoryCount = 0
                var onCount = 0
                var totalBrightness = 0
                var brightnessCount = 0
                var totalPosition = 0
                var positionCount = 0
                var roomIds = Set<String>()
                var roomName: String? = nil
                var categoryCounts: [String: Int] = [:]

                // Color tracking
                var totalHue = 0.0
                var totalSaturation = 0.0
                var rgbCount = 0
                var totalColorTemp = 0.0
                var colorTempCount = 0
                var colorTempMin = 500.0
                var colorTempMax = 153.0

                // Reachability tracking
                var reachableCount = 0

                // Get accessories by IDs
                if let accessories = try? manager.listAccessories(homeId: homeId, roomId: nil, includeValues: true) {
                    let groupAccessoryIds = Set(group.accessoryIds)
                    let groupAccessories = accessories.filter { groupAccessoryIds.contains($0.id) }
                    accessoryCount = groupAccessories.count

                    for accessory in groupAccessories {
                        if accessory.isReachable {
                            reachableCount += 1
                        }
                        // Track categories to determine group type
                        categoryCounts[accessory.category, default: 0] += 1
                        // Track rooms
                        if let rid = accessory.roomId {
                            roomIds.insert(rid)
                        }
                        if roomName == nil, let rname = accessory.roomName {
                            roomName = rname
                        }

                        // Track per-accessory color capabilities
                        var hasHue = false
                        var hasSat = false
                        var accHue = 0.0
                        var accSat = 0.0
                        var accColorTemp = 0.0
                        var hasAccColorTemp = false

                        for service in accessory.services {
                            for char in service.characteristics {
                                let charType = char.characteristicType.lowercased()

                                // Power state - check all variants including "active" for HVAC devices
                                if charType == "power_state" || charType == "powerstate" || charType == "on" || charType == "active" {
                                    if let value = char.rawValue as? Bool, value {
                                        onCount += 1
                                        isOn = true
                                    } else if let value = char.rawValue as? Int, value != 0 {
                                        onCount += 1
                                        isOn = true
                                    }
                                }

                                // Brightness
                                if charType == "brightness" {
                                    if let value = char.rawValue as? Int {
                                        totalBrightness += value
                                        brightnessCount += 1
                                    } else if let value = char.rawValue as? Double {
                                        totalBrightness += Int(value)
                                        brightnessCount += 1
                                    }
                                }

                                // Position
                                if charType == "currentposition" || charType == "current_position" {
                                    if let value = char.rawValue as? Int {
                                        totalPosition += value
                                        positionCount += 1
                                    } else if let value = char.rawValue as? Double {
                                        totalPosition += Int(value)
                                        positionCount += 1
                                    }
                                }

                                // Hue (for RGB lights)
                                if charType == "hue" {
                                    if let value = char.rawValue as? Double {
                                        accHue = value
                                        hasHue = true
                                    } else if let value = char.rawValue as? Int {
                                        accHue = Double(value)
                                        hasHue = true
                                    }
                                }

                                // Saturation (for RGB lights)
                                if charType == "saturation" {
                                    if let value = char.rawValue as? Double {
                                        accSat = value
                                        hasSat = true
                                    } else if let value = char.rawValue as? Int {
                                        accSat = Double(value)
                                        hasSat = true
                                    }
                                }

                                // Color temperature (in mireds)
                                if charType == "color_temperature" || charType == "colortemperature" {
                                    if let value = char.rawValue as? Double {
                                        accColorTemp = value
                                        hasAccColorTemp = true
                                    } else if let value = char.rawValue as? Int {
                                        accColorTemp = Double(value)
                                        hasAccColorTemp = true
                                    }
                                    // Track min/max from characteristic metadata
                                    if let minValue = char.minValue as? Double {
                                        colorTempMin = min(colorTempMin, minValue)
                                    }
                                    if let maxValue = char.maxValue as? Double {
                                        colorTempMax = max(colorTempMax, maxValue)
                                    }
                                }
                            }
                        }

                        // Aggregate RGB values if accessory has both hue and saturation
                        if hasHue && hasSat {
                            totalHue += accHue
                            totalSaturation += accSat
                            rgbCount += 1
                        }

                        // Aggregate color temp
                        if hasAccColorTemp {
                            totalColorTemp += accColorTemp
                            colorTempCount += 1
                        }
                    }
                }

                // Determine dominant category for group icon
                // First try accessory categories, but fall back to inferring from characteristics
                var dominantCategory = categoryCounts.max(by: { $0.value < $1.value })?.key ?? "Lightbulb"

                // If category is generic/unknown but we have light characteristics, it's a light group
                let isLightCategory = dominantCategory.lowercased().contains("light") || dominantCategory.lowercased().contains("bulb")
                if !isLightCategory && (brightnessCount > 0 || rgbCount > 0 || colorTempCount > 0) {
                    dominantCategory = "Lightbulb"
                }
                // If category is generic but we have position, it's a blind/covering group
                let isBlindCategory = dominantCategory.lowercased().contains("window") || dominantCategory.lowercased().contains("blind") || dominantCategory.lowercased().contains("covering")
                if !isBlindCategory && positionCount > 0 && brightnessCount == 0 {
                    dominantCategory = "Window Covering"
                }

                var result: [String: Any] = [
                    "id": group.id,
                    "name": group.name,
                    "accessoryIds": group.accessoryIds,  // Include IDs so menu can hide grouped accessories
                    "accessoryCount": accessoryCount,
                    "isOn": isOn,
                    "onCount": onCount,
                    "groupCategory": dominantCategory,
                    "isReachable": reachableCount > 0  // Group reachable if at least one member is
                ]

                // Skip groups with no accessories (HomeKit not fully loaded yet)
                if accessoryCount == 0 {
                    return nil
                }

                // If all accessories are in the same room, include roomId
                if roomIds.count == 1, let singleRoomId = roomIds.first {
                    result["roomId"] = singleRoomId
                    result["roomName"] = roomName ?? ""
                }

                // Average brightness
                if brightnessCount > 0 {
                    result["brightness"] = totalBrightness / brightnessCount
                    result["hasBrightness"] = true
                }

                // Average position
                if positionCount > 0 {
                    result["position"] = totalPosition / positionCount
                    result["hasPosition"] = true
                }

                // Color temperature (only if all light accessories support it)
                if colorTempCount > 0 && colorTempCount == brightnessCount {
                    result["colorTemperature"] = totalColorTemp / Double(colorTempCount)
                    result["colorTempMin"] = colorTempMin
                    result["colorTempMax"] = colorTempMax
                    result["hasColorTemp"] = true
                }

                // RGB (only if all light accessories support it)
                if rgbCount > 0 && rgbCount == brightnessCount {
                    result["hue"] = totalHue / Double(rgbCount)
                    result["saturation"] = totalSaturation / Double(rgbCount)
                    result["hasRGB"] = true
                }

                return result
            }
        } catch {
            print("[AppDelegate] menuGetServiceGroups failed: \(error)")
            return []
        }
    }

    /// Toggle all accessories in a service group
    @objc func menuToggleServiceGroup(groupId: String, value: Bool, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuToggleServiceGroup: No WebView available")
            return
        }

        let valueStr = value ? "true" : "false"
        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'PowerState', \(valueStr), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group control failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuToggleServiceGroup JS error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu Bar Control (via WebView JS)

    /// Set power state on an accessory via WebView JavaScript
    /// This routes through the web app's serverConnection to ensure WebSocket broadcasts
    @objc func menuSetPower(accessoryId: String, characteristicType: String, value: Bool) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetPower: No WebView available")
            return
        }

        let valueStr = value ? "true" : "false"
        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setCharacteristic) {
                    try {
                        await window.menuBarControl.setCharacteristic('\(accessoryId)', '\(characteristicType)', \(valueStr));
                    } catch (e) {
                        console.error('[MenuBar] Control failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetPower JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set brightness on an accessory via WebView JavaScript
    @objc func menuSetBrightness(accessoryId: String, value: Int) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetBrightness: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setCharacteristic) {
                    try {
                        await window.menuBarControl.setCharacteristic('\(accessoryId)', 'Brightness', \(value));
                    } catch (e) {
                        console.error('[MenuBar] Brightness control failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetBrightness JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set target position on an accessory (window covering) via WebView JavaScript
    @objc func menuSetPosition(accessoryId: String, value: Int) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetPosition: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setCharacteristic) {
                    try {
                        await window.menuBarControl.setCharacteristic('\(accessoryId)', 'TargetPosition', \(value));
                    } catch (e) {
                        console.error('[MenuBar] Position control failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetPosition JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set brightness on a service group via WebView JavaScript
    @objc func menuSetServiceGroupBrightness(groupId: String, value: Int, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetServiceGroupBrightness: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'Brightness', \(value), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group brightness failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetServiceGroupBrightness JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set target position on a service group (window coverings) via WebView JavaScript
    @objc func menuSetServiceGroupPosition(groupId: String, value: Int, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetServiceGroupPosition: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'TargetPosition', \(value), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group position failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetServiceGroupPosition JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set color temperature on a service group via WebView JavaScript
    @objc func menuSetServiceGroupColorTemp(groupId: String, value: Int, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetServiceGroupColorTemp: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'ColorTemperature', \(value), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group color temp failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetServiceGroupColorTemp JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set hue on a service group via WebView JavaScript
    @objc func menuSetServiceGroupHue(groupId: String, value: Float, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetServiceGroupHue: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'Hue', \(value), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group hue failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetServiceGroupHue JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Set saturation on a service group via WebView JavaScript
    @objc func menuSetServiceGroupSaturation(groupId: String, value: Float, homeId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuSetServiceGroupSaturation: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.setServiceGroupCharacteristic) {
                    try {
                        await window.menuBarControl.setServiceGroupCharacteristic('\(groupId)', 'Saturation', \(value), '\(homeId)');
                    } catch (e) {
                        console.error('[MenuBar] Service group saturation failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuSetServiceGroupSaturation JS error: \(error.localizedDescription)")
            }
        }
    }

    /// Execute a scene via WebView JavaScript
    /// This routes through the web app's serverConnection to ensure WebSocket broadcasts
    @objc func menuExecuteScene(sceneId: String) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] menuExecuteScene: No WebView available")
            return
        }

        let js = """
            (async function() {
                if (window.menuBarControl && window.menuBarControl.executeScene) {
                    try {
                        await window.menuBarControl.executeScene('\(sceneId)');
                    } catch (e) {
                        console.error('[MenuBar] Scene execution failed:', e);
                    }
                } else {
                    console.warn('[MenuBar] menuBarControl not available');
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuExecuteScene JS error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Direct HomeKit Control (bypasses WebView)

    /// Set a characteristic on an accessory directly via HomeKit
    /// This bypasses WebView for more reliable control from the menu bar
    @objc func menuSetCharacteristicDirect(accessoryId: String, characteristicType: String, value: Any) {
        Task { @MainActor in
            do {
                let result = try await homeKitManager.setCharacteristic(
                    accessoryId: accessoryId,
                    characteristicType: characteristicType,
                    value: value
                )
                print("[AppDelegate] Direct control succeeded: \(result.characteristic) = \(result.newValue)")

                // Notify WebView for sync with other clients
                notifyWebViewOfChange(accessoryId: accessoryId, type: characteristicType, value: value)

                // Manually forward update to menu bar (HomeKit may not notify for our own writes)
                forwardCharacteristicUpdate(accessoryId: accessoryId, type: characteristicType, value: value)

                // Push event to WebView so it updates its UI
                if let homeId = try? homeKitManager.getAccessory(id: accessoryId).homeId {
                    homeKitBridge?.pushCharacteristicUpdate(
                        accessoryId: accessoryId,
                        homeId: homeId,
                        characteristicType: characteristicType,
                        value: value
                    )
                }
            } catch {
                print("[AppDelegate] Direct control failed: \(error.localizedDescription)")
            }
        }
    }

    /// Set a characteristic on all accessories in a service group directly via HomeKit
    @objc func menuSetServiceGroupDirect(groupId: String, homeId: String, characteristicType: String, value: Any) {
        Task { @MainActor in
            do {
                let successCount = try await homeKitManager.setServiceGroupCharacteristic(
                    homeId: homeId,
                    groupId: groupId,
                    characteristicType: characteristicType,
                    value: value
                )
                print("[AppDelegate] Direct group control succeeded: \(successCount) accessories updated")

                // Notify WebView for sync with other clients
                notifyWebViewOfGroupChange(groupId: groupId, homeId: homeId, type: characteristicType, value: value)

                // Manually forward update to menu bar (HomeKit may not notify for our own writes)
                forwardCharacteristicUpdate(accessoryId: groupId, type: characteristicType, value: value)

                // Also broadcast to WebView as characteristic updates for each accessory in the group
                broadcastGroupCharacteristicUpdate(groupId: groupId, homeId: homeId, type: characteristicType, value: value)
            } catch {
                print("[AppDelegate] Direct group control failed: \(error.localizedDescription)")
            }
        }
    }

    /// Broadcast characteristic update events for all accessories in a group
    private func broadcastGroupCharacteristicUpdate(groupId: String, homeId: String, type: String, value: Any) {
        // Get accessory IDs from the group
        guard let groups = try? homeKitManager.listServiceGroups(homeId: homeId) else { return }
        guard let group = groups.first(where: { $0.id == groupId }) else { return }

        // Push an event for each accessory in the group
        for accessoryId in group.accessoryIds {
            homeKitBridge?.pushCharacteristicUpdate(
                accessoryId: accessoryId,
                homeId: homeId,
                characteristicType: type,
                value: value
            )
        }
    }

    /// Execute a scene directly via HomeKit
    @objc func menuExecuteSceneDirect(sceneId: String) {
        Task { @MainActor in
            do {
                let result = try await homeKitManager.executeScene(sceneId: sceneId)
                print("[AppDelegate] Direct scene execution succeeded: \(result.sceneId)")

                // Optional: notify WebView for sync
                notifyWebViewOfSceneExecution(sceneId: sceneId)
            } catch {
                print("[AppDelegate] Direct scene execution failed: \(error.localizedDescription)")
            }
        }
    }

    /// Notify WebView of a characteristic change (for sync with other clients)
    private func notifyWebViewOfChange(accessoryId: String, type: String, value: Any) {
        guard let webView = homeKitBridge?.webView else { return }

        let valueJson: String
        if let boolValue = value as? Bool {
            valueJson = boolValue ? "true" : "false"
        } else if let intValue = value as? Int {
            valueJson = "\(intValue)"
        } else if let doubleValue = value as? Double {
            valueJson = "\(doubleValue)"
        } else {
            valueJson = "'\(value)'"
        }

        let js = """
            if (window.menuBarControl && window.menuBarControl.notifyChange) {
                window.menuBarControl.notifyChange('\(accessoryId)', '\(type)', \(valueJson));
            }
            """

        webView.evaluateJavaScript(js) { _, _ in }
    }

    /// Notify WebView of a service group change
    private func notifyWebViewOfGroupChange(groupId: String, homeId: String, type: String, value: Any) {
        guard let webView = homeKitBridge?.webView else {
            print("[AppDelegate] notifyWebViewOfGroupChange: WebView not available")
            return
        }

        let valueJson: String
        if let boolValue = value as? Bool {
            valueJson = boolValue ? "true" : "false"
        } else if let intValue = value as? Int {
            valueJson = "\(intValue)"
        } else if let doubleValue = value as? Double {
            valueJson = "\(doubleValue)"
        } else {
            valueJson = "'\(value)'"
        }

        print("[AppDelegate] notifyWebViewOfGroupChange: \(groupId.prefix(8)), \(type), \(valueJson)")

        let js = """
            (function() {
                console.log('[MenuBar] notifyGroupChange called from Swift');
                if (window.menuBarControl && window.menuBarControl.notifyGroupChange) {
                    window.menuBarControl.notifyGroupChange('\(groupId)', '\(homeId)', '\(type)', \(valueJson));
                    return 'called';
                } else {
                    console.log('[MenuBar] menuBarControl.notifyGroupChange not available');
                    return 'not available';
                }
            })();
            """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] notifyWebViewOfGroupChange JS error: \(error.localizedDescription)")
            } else {
                print("[AppDelegate] notifyWebViewOfGroupChange JS result: \(result ?? "nil")")
            }
        }
    }

    /// Notify WebView of a scene execution
    private func notifyWebViewOfSceneExecution(sceneId: String) {
        guard let webView = homeKitBridge?.webView else { return }

        let js = """
            if (window.menuBarControl && window.menuBarControl.notifySceneExecuted) {
                window.menuBarControl.notifySceneExecuted('\(sceneId)');
            }
            """

        webView.evaluateJavaScript(js) { _, _ in }
    }

    // MARK: - HomeKit Observation for Menu Bar

    /// Start observing HomeKit changes for real-time menu updates
    @objc func startHomeKitObservation() {
        homeKitManager.startObservingChanges()
    }

    /// Stop observing HomeKit changes
    @objc func stopHomeKitObservation() {
        homeKitManager.stopObservingChanges()
    }

    /// Notify menu bar plugin that HomeKit is ready so it can preload data
    func notifyMenuBarHomeKitReady() {
        guard let plugin = menuBarPlugin else { return }

        let selector = NSSelectorFromString("homeKitDidBecomeReady")
        if plugin.responds(to: selector) {
            _ = plugin.perform(selector)
        }
    }

    /// Forward characteristic updates to the menu bar plugin
    func forwardCharacteristicUpdate(accessoryId: String, type: String, value: Any) {
        print("[AppDelegate] forwardCharacteristicUpdate: \(accessoryId.prefix(8)), \(type), \(value)")

        guard let plugin = menuBarPlugin else {
            print("[AppDelegate] forwardCharacteristicUpdate: No menu bar plugin")
            return
        }

        let selector = NSSelectorFromString("characteristicDidUpdateWithAccessoryId:characteristicType:value:")
        if plugin.responds(to: selector) {
            let method = plugin.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, String, Any) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(plugin, selector, accessoryId, type, value)
        } else {
            print("[AppDelegate] forwardCharacteristicUpdate: Plugin doesn't respond to selector")
        }
    }

    /// Forward reachability updates to the menu bar plugin
    func forwardReachabilityUpdate(accessoryId: String, isReachable: Bool) {
        guard let plugin = menuBarPlugin else { return }

        let selector = NSSelectorFromString("accessoryReachabilityDidUpdateWithAccessoryId:isReachable:")
        if plugin.responds(to: selector) {
            let method = plugin.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, Bool) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(plugin, selector, accessoryId, isReachable)
        }
    }

    // MARK: - Menu Bar Settings (Visibility, Ordering, Collections)

    /// Cached settings from WebView - updated periodically
    private var cachedMenuBarSettings: [String: Any]?

    /// Prefetch menu bar data from server (async).
    /// This ensures layout data is in Apollo cache before getMenuBarSettings is called.
    @objc func menuPrefetchData(homeIds: [String], roomIds: [String], completion: @escaping () -> Void) {
        guard let webView = homeKitBridge?.webView else {
            completion()
            return
        }

        // Serialize arrays to JSON for JS
        guard let homeIdsJson = try? JSONSerialization.data(withJSONObject: homeIds),
              let homeIdsStr = String(data: homeIdsJson, encoding: .utf8),
              let roomIdsJson = try? JSONSerialization.data(withJSONObject: roomIds),
              let roomIdsStr = String(data: roomIdsJson, encoding: .utf8) else {
            completion()
            return
        }

        // Start prefetch (fire and forget - WKWebView can't await Promises)
        let js = """
            (function() {
                if (window.menuBarControl && window.menuBarControl.prefetchMenuBarData) {
                    window.menuBarControl.prefetchMenuBarData(\(homeIdsStr), \(roomIdsStr))
                        .catch(e => console.error('[MenuBar] prefetchMenuBarData failed:', e));
                }
                return null;
            })();
            """

        webView.evaluateJavaScript(js) { _, _ in }

        // Wait a short time for prefetch to likely complete, then call completion
        // The data will be in Apollo cache for getMenuBarSettings to read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion()
        }
    }

    /// Get cached menu bar settings (non-blocking).
    /// Returns whatever settings are cached, or nil if not yet loaded.
    @objc func menuGetSettingsSync(homeIds: [String], roomIds: [String]) -> [String: Any]? {
        // Trigger async refresh if needed
        refreshMenuBarSettingsAsync(homeIds: homeIds, roomIds: roomIds)
        // Return cached immediately (may be nil on first call)
        return cachedMenuBarSettings
    }

    /// Evaluate arbitrary JavaScript on the WebView (for MenuBarPlugin to call)
    @objc func menuEvaluateJavaScript(_ js: String, completion: @escaping (String?) -> Void) {
        guard let webView = homeKitBridge?.webView else {
            completion(nil)
            return
        }

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[AppDelegate] menuEvaluateJavaScript error: \(error.localizedDescription)")
                completion(nil)
            } else if let resultStr = result as? String {
                completion(resultStr)
            } else {
                completion(nil)
            }
        }
    }

    /// Refresh settings asynchronously (non-blocking)
    private func refreshMenuBarSettingsAsync(homeIds: [String], roomIds: [String]) {
        guard let webView = homeKitBridge?.webView else { return }

        // Serialize arrays to JSON for JS
        guard let homeIdsJson = try? JSONSerialization.data(withJSONObject: homeIds),
              let homeIdsStr = String(data: homeIdsJson, encoding: .utf8),
              let roomIdsJson = try? JSONSerialization.data(withJSONObject: roomIds),
              let roomIdsStr = String(data: roomIdsJson, encoding: .utf8) else {
            return
        }

        let js = """
            (function() {
                if (window.menuBarControl && window.menuBarControl.getMenuBarSettings) {
                    try {
                        var result = window.menuBarControl.getMenuBarSettings(\(homeIdsStr), \(roomIdsStr));
                        return JSON.stringify(result);
                    } catch (e) {
                        console.error('[MenuBar] getMenuBarSettings failed:', e);
                        return null;
                    }
                } else {
                    return null;
                }
            })();
            """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self,
                  error == nil,
                  let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8),
                  let settings = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }
            self.cachedMenuBarSettings = settings

            // Forward to menu bar plugin so it picks up settings immediately
            // (menuGetSettingsSync returns the previous cached value, so without this
            // the plugin wouldn't get settings until the next full cache refresh cycle)
            if let plugin = self.menuBarPlugin {
                let sel = NSSelectorFromString("settingsDidUpdate:")
                if plugin.responds(to: sel) {
                    _ = plugin.perform(sel, with: settings as NSDictionary)
                }
            }
        }
    }

    /// Clear cached settings (called when settings change in WebView)
    @objc func invalidateMenuBarSettings() {
        cachedMenuBarSettings = nil
    }

    func showInDock() {
        if let plugin = menuBarPlugin {
            let selector = NSSelectorFromString("showInDock")
            if plugin.responds(to: selector) {
                _ = plugin.perform(selector)
            }
        }
    }

    func hideFromDock() {
        if let plugin = menuBarPlugin {
            let selector = NSSelectorFromString("hideFromDock")
            if plugin.responds(to: selector) {
                _ = plugin.perform(selector)
            }
        }
    }
    #endif
}

// MARK: - Scene Delegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var isFirstLaunch = true

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if targetEnvironment(macCatalyst)
        // Configure window for Mac - hide titlebar for full-bleed WebView
        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
            // Separate the title bar so it doesn't capture clicks
            titlebar.separatorStyle = .none
        }

        // Set window size — minimum 960px to match WKWebView's minimum viewport width
        // (Mac Catalyst enforces ~960px viewport regardless of frame size)
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 960, height: 600)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1400, height: 1000)

        // Check if we should show window on first launch
        if SceneDelegate.isFirstLaunch {
            SceneDelegate.isFirstLaunch = false

            if !AppConfig.showWindowOnLaunch {
                // Close the window - app will run in menu bar only
                DispatchQueue.main.async {
                    UIApplication.shared.requestSceneSessionDestruction(
                        session,
                        options: nil,
                        errorHandler: nil
                    )
                }
                return
            }
        }

        // Show in dock when window opens
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.showInDock()
        }
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Window closed - app continues running in menu bar
        print("[Homecast] Window closed - continuing in background")

        #if targetEnvironment(macCatalyst)
        // Hide from dock when window closes
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.hideFromDock()
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        print("[Homecast] Window became active")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        print("[Homecast] Window will resign active")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showMainWindow = Notification.Name("showMainWindow")
}
