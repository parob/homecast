import AppKit

/// Protocol for menu item views that can receive real-time characteristic updates
protocol CharacteristicUpdatable: AnyObject {
    /// The accessory ID this view represents (nil for groups)
    var accessoryId: String? { get }

    /// The service group ID this view represents (nil for accessories)
    var serviceGroupId: String? { get }

    /// Update a characteristic value in response to HomeKit changes
    /// - Parameters:
    ///   - type: The characteristic type (e.g., "PowerState", "Brightness")
    ///   - value: The new value
    func updateCharacteristic(_ type: String, value: Any)

    /// Update the reachability state of the device
    /// - Parameter isReachable: Whether the device is currently reachable
    func updateReachability(_ isReachable: Bool)
}

/// Default implementations
extension CharacteristicUpdatable {
    var accessoryId: String? { nil }
    var serviceGroupId: String? { nil }
}

/// Protocol for the menu bar controller to handle control actions
protocol MenuBarController: AnyObject {
    /// Set a characteristic on an accessory directly via HomeKit
    /// - Parameters:
    ///   - accessoryId: The accessory UUID
    ///   - type: The characteristic type
    ///   - value: The value to set
    func setCharacteristic(accessoryId: String, type: String, value: Any)

    /// Set a characteristic on all accessories in a service group
    /// - Parameters:
    ///   - groupId: The service group UUID
    ///   - homeId: The home UUID
    ///   - type: The characteristic type
    ///   - value: The value to set
    func setServiceGroupCharacteristic(groupId: String, homeId: String, type: String, value: Any)

    /// Execute a scene
    /// - Parameter sceneId: The scene UUID
    func executeScene(sceneId: String)
}

/// Configuration for a menu item view
struct MenuItemConfiguration {
    let accessory: [String: Any]?
    let group: [String: Any]?
    let homeId: String
    let roomName: String?

    /// Create configuration for an accessory
    static func accessory(_ accessory: [String: Any], homeId: String, roomName: String? = nil) -> MenuItemConfiguration {
        MenuItemConfiguration(accessory: accessory, group: nil, homeId: homeId, roomName: roomName)
    }

    /// Create configuration for a service group
    static func group(_ group: [String: Any], homeId: String, roomName: String? = nil) -> MenuItemConfiguration {
        MenuItemConfiguration(accessory: nil, group: group, homeId: homeId, roomName: roomName)
    }

    // MARK: - Accessory Properties

    var id: String? {
        accessory?["id"] as? String ?? group?["id"] as? String
    }

    var name: String {
        accessory?["name"] as? String ?? group?["name"] as? String ?? "Unknown"
    }

    var displayName: String {
        getDisplayName(name, prefix: roomName)
    }

    var category: String {
        accessory?["category"] as? String ?? group?["groupCategory"] as? String ?? ""
    }

    /// Resolved widget type from JS (e.g. "lightbulb", "thermostat", "lock").
    /// Set by MenuBarPlugin from cachedWidgetTypes when available.
    var resolvedWidgetType: String?

    /// Best category string for icon selection.
    /// Prefers the JS-resolved widget type (matches PhosphorIcon patterns perfectly),
    /// falls back to the raw HomeKit category.
    var iconCategory: String {
        resolvedWidgetType ?? category
    }

    var isReachable: Bool {
        accessory?["isReachable"] as? Bool ?? group?["isReachable"] as? Bool ?? true
    }

    var powerState: Bool? {
        if let value = accessory?["powerState"] as? Bool {
            return value
        }
        return group?["isOn"] as? Bool
    }

    var hasPower: Bool {
        accessory?["hasPower"] as? Bool ?? (group != nil)
    }

    var brightness: Int? {
        accessory?["brightness"] as? Int ?? group?["brightness"] as? Int
    }

    var hasBrightness: Bool {
        accessory?["hasBrightness"] as? Bool ?? group?["hasBrightness"] as? Bool ?? false
    }

    // MARK: - Color Properties

    var hue: Double? {
        accessory?["hue"] as? Double ?? group?["hue"] as? Double
    }

    var saturation: Double? {
        accessory?["saturation"] as? Double ?? group?["saturation"] as? Double
    }

    var hasRGB: Bool {
        accessory?["hasRGB"] as? Bool ?? group?["hasRGB"] as? Bool ?? false
    }

    var colorTemperature: Double? {
        accessory?["colorTemperature"] as? Double ?? group?["colorTemperature"] as? Double
    }

    var colorTemperatureMin: Double {
        accessory?["colorTemperatureMin"] as? Double ?? group?["colorTempMin"] as? Double ?? 153
    }

    var colorTemperatureMax: Double {
        accessory?["colorTemperatureMax"] as? Double ?? group?["colorTempMax"] as? Double ?? 500
    }

    var hasColorTemp: Bool {
        accessory?["hasColorTemp"] as? Bool ?? group?["hasColorTemp"] as? Bool ?? false
    }

    var position: Int? {
        accessory?["position"] as? Int ?? group?["position"] as? Int
    }

    var hasPosition: Bool {
        accessory?["hasPosition"] as? Bool ?? group?["hasPosition"] as? Bool ?? false
    }

    var powerCharType: String {
        accessory?["powerCharType"] as? String ?? "PowerState"
    }

    // MARK: - Group-specific Properties

    var isGroup: Bool {
        group != nil
    }

    var groupCategory: String {
        group?["groupCategory"] as? String ?? "Lightbulb"
    }

    var accessoryCount: Int {
        group?["accessoryCount"] as? Int ?? 0
    }

    var onCount: Int {
        group?["onCount"] as? Int ?? 0
    }

    // MARK: - Group Color Properties

    var groupHasRGB: Bool {
        group?["hasRGB"] as? Bool ?? false
    }

    var groupHasColorTemp: Bool {
        group?["hasColorTemp"] as? Bool ?? false
    }

    var groupColorTemperature: Double? {
        group?["colorTemperature"] as? Double
    }

    var groupColorTempMin: Double {
        group?["colorTempMin"] as? Double ?? 153
    }

    var groupColorTempMax: Double {
        group?["colorTempMax"] as? Double ?? 500
    }

    var groupHue: Double? {
        group?["hue"] as? Double
    }

    var groupSaturation: Double? {
        group?["saturation"] as? Double
    }

    // MARK: - Thermostat Properties

    var currentTemperature: Double? {
        if let value = accessory?["currentTemperature"] as? Double {
            return value
        }
        if let value = accessory?["currentTemperature"] as? Int {
            return Double(value)
        }
        return nil
    }

    var targetTemperature: Double? {
        if let value = accessory?["targetTemperature"] as? Double {
            return value
        }
        if let value = accessory?["targetTemperature"] as? Int {
            return Double(value)
        }
        return nil
    }

    var hvacMode: Int? {
        accessory?["hvacMode"] as? Int
    }

    var heatingThreshold: Double? {
        if let value = accessory?["heatingThreshold"] as? Double {
            return value
        }
        if let value = accessory?["heatingThreshold"] as? Int {
            return Double(value)
        }
        return nil
    }

    var coolingThreshold: Double? {
        if let value = accessory?["coolingThreshold"] as? Double {
            return value
        }
        if let value = accessory?["coolingThreshold"] as? Int {
            return Double(value)
        }
        return nil
    }

    var hasThresholds: Bool {
        accessory?["hasThresholds"] as? Bool ?? false
    }

    /// Whether this is a HeaterCooler (AC) device vs standard thermostat
    var isHeaterCooler: Bool {
        accessory?["isHeaterCooler"] as? Bool ?? false
    }

    // MARK: - Sensor Properties

    var sensorValue: Any? {
        accessory?["sensorValue"]
    }

    var sensorUnit: String? {
        accessory?["sensorUnit"] as? String
    }

    // MARK: - Smoke Alarm Properties

    var smokeDetected: Bool? {
        accessory?["smokeDetected"] as? Bool
    }

    var coDetected: Bool? {
        accessory?["coDetected"] as? Bool
    }

    // MARK: - Battery Properties

    var batteryLevel: Int? {
        accessory?["batteryLevel"] as? Int
    }

    var statusLowBattery: Bool? {
        accessory?["statusLowBattery"] as? Bool
    }

    // MARK: - Button/Remote Properties

    var buttonCount: Int? {
        accessory?["buttonCount"] as? Int
    }

    // MARK: - Lock Properties

    var lockState: Int? {
        accessory?["lockState"] as? Int
    }

    var targetLockState: Int? {
        accessory?["targetLockState"] as? Int
    }

    // MARK: - Garage Door Properties

    var doorState: Int? {
        accessory?["doorState"] as? Int
    }

    var targetDoorState: Int? {
        accessory?["targetDoorState"] as? Int
    }

    // MARK: - Security System Properties

    var securityCurrentState: Int? {
        accessory?["securityCurrentState"] as? Int
    }

    var securityTargetState: Int? {
        accessory?["securityTargetState"] as? Int
    }

    // MARK: - Helpers

    /// Strip room name prefix from accessory/group name (matching app-web behavior)
    private func getDisplayName(_ name: String, prefix: String?) -> String {
        guard let prefix = prefix, !prefix.isEmpty, !name.isEmpty else { return name }

        let nameLower = name.lowercased()
        let prefixLower = prefix.lowercased()

        if nameLower.hasPrefix(prefixLower) {
            var stripped = String(name.dropFirst(prefix.count))
            // Remove leading separators
            while stripped.hasPrefix(" ") || stripped.hasPrefix("-") || stripped.hasPrefix("_") {
                stripped = String(stripped.dropFirst())
            }
            if !stripped.isEmpty {
                return stripped
            }
        }

        return name
    }
}
