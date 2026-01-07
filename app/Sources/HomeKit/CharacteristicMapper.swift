import HomeKit
import Foundation

/// Maps between human-readable names and HomeKit characteristic/service types
enum CharacteristicMapper {

    // MARK: - Characteristic Type Mapping

    private static let characteristicMap: [String: String] = [
        // Power
        "power_state": HMCharacteristicTypePowerState,
        "on": HMCharacteristicTypePowerState,

        // Lighting
        "brightness": HMCharacteristicTypeBrightness,
        "hue": HMCharacteristicTypeHue,
        "saturation": HMCharacteristicTypeSaturation,
        "color_temperature": HMCharacteristicTypeColorTemperature,

        // Thermostat
        "current_temperature": HMCharacteristicTypeCurrentTemperature,
        "target_temperature": HMCharacteristicTypeTargetTemperature,
        "heating_cooling_current": HMCharacteristicTypeCurrentHeatingCooling,
        "heating_cooling_target": HMCharacteristicTypeTargetHeatingCooling,
        "relative_humidity": HMCharacteristicTypeCurrentRelativeHumidity,
        "target_humidity": HMCharacteristicTypeTargetRelativeHumidity,

        // Lock
        "lock_current_state": HMCharacteristicTypeCurrentLockMechanismState,
        "lock_target_state": HMCharacteristicTypeTargetLockMechanismState,

        // Door/Window
        "current_position": HMCharacteristicTypeCurrentPosition,
        "target_position": HMCharacteristicTypeTargetPosition,
        "position_state": HMCharacteristicTypePositionState,

        // Sensors
        "motion_detected": HMCharacteristicTypeMotionDetected,
        "occupancy_detected": HMCharacteristicTypeOccupancyDetected,
        "contact_state": HMCharacteristicTypeContactState,
        "smoke_detected": HMCharacteristicTypeSmokeDetected,
        "carbon_monoxide_detected": HMCharacteristicTypeCarbonMonoxideDetected,
        "carbon_dioxide_detected": HMCharacteristicTypeCarbonDioxideDetected,
        "water_level": HMCharacteristicTypeWaterLevel,

        // Battery
        "battery_level": HMCharacteristicTypeBatteryLevel,
        "charging_state": HMCharacteristicTypeChargingState,
        "status_low_battery": HMCharacteristicTypeStatusLowBattery,

        // Fan
        "rotation_speed": HMCharacteristicTypeRotationSpeed,
        "rotation_direction": HMCharacteristicTypeRotationDirection,

        // Outlet
        "outlet_in_use": HMCharacteristicTypeOutletInUse,

        // Security
        "security_system_current_state": HMCharacteristicTypeCurrentSecuritySystemState,
        "security_system_target_state": HMCharacteristicTypeTargetSecuritySystemState,

        // Audio
        "volume": HMCharacteristicTypeVolume,
        "mute": HMCharacteristicTypeMute,

        // General
        "name": HMCharacteristicTypeName,
        "identify": HMCharacteristicTypeIdentify,
        "manufacturer": HMCharacteristicTypeManufacturer,
        "model": HMCharacteristicTypeModel,
        "serial_number": HMCharacteristicTypeSerialNumber,
        "firmware_revision": HMCharacteristicTypeFirmwareVersion,
        "hardware_revision": HMCharacteristicTypeHardwareVersion,
    ]

    // MARK: - Service Type Mapping

    private static let serviceMap: [String: String] = [
        "lightbulb": HMServiceTypeLightbulb,
        "switch": HMServiceTypeSwitch,
        "outlet": HMServiceTypeOutlet,
        "thermostat": HMServiceTypeThermostat,
        "lock": HMServiceTypeLockMechanism,
        "door": HMServiceTypeDoor,
        "window": HMServiceTypeWindow,
        "window_covering": HMServiceTypeWindowCovering,
        "fan": HMServiceTypeFan,
        "garage_door": HMServiceTypeGarageDoorOpener,
        "motion_sensor": HMServiceTypeMotionSensor,
        "occupancy_sensor": HMServiceTypeOccupancySensor,
        "contact_sensor": HMServiceTypeContactSensor,
        "temperature_sensor": HMServiceTypeTemperatureSensor,
        "humidity_sensor": HMServiceTypeHumiditySensor,
        "light_sensor": HMServiceTypeLightSensor,
        "smoke_sensor": HMServiceTypeSmokeSensor,
        "carbon_monoxide_sensor": HMServiceTypeCarbonMonoxideSensor,
        "carbon_dioxide_sensor": HMServiceTypeCarbonDioxideSensor,
        "battery": HMServiceTypeBattery,
        "speaker": HMServiceTypeSpeaker,
        "security_system": HMServiceTypeSecuritySystem,
        "accessory_information": HMServiceTypeAccessoryInformation,
    ]

    // MARK: - Conversion Methods

    /// Convert friendly name to HomeKit characteristic type UUID
    static func toHomeKitType(_ friendlyName: String) -> String {
        let normalized = friendlyName.lowercased().replacingOccurrences(of: " ", with: "_")
        return characteristicMap[normalized] ?? friendlyName
    }

    /// Convert HomeKit characteristic type UUID to friendly name
    static func fromHomeKitType(_ homeKitType: String) -> String {
        for (friendly, hkType) in characteristicMap {
            if hkType == homeKitType {
                return friendly
            }
        }
        // Return last component of UUID path if no mapping found
        return homeKitType.components(separatedBy: ".").last ?? homeKitType
    }

    /// Convert HomeKit service type UUID to friendly name
    static func fromHomeKitServiceType(_ homeKitType: String) -> String {
        for (friendly, hkType) in serviceMap {
            if hkType == homeKitType {
                return friendly
            }
        }
        return homeKitType.components(separatedBy: ".").last ?? homeKitType
    }

    // MARK: - Value Conversion

    /// Convert a value to the appropriate type for a characteristic
    static func convertValue(_ value: Any, for characteristic: HMCharacteristic) throws -> Any {
        // Get the expected format
        let format = characteristic.metadata?.format

        switch format {
        case HMCharacteristicMetadataFormatBool:
            return toBool(value)

        case HMCharacteristicMetadataFormatInt,
             HMCharacteristicMetadataFormatUInt8,
             HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32,
             HMCharacteristicMetadataFormatUInt64:
            guard let intValue = toInt(value) else {
                throw ConversionError.invalidValue("Cannot convert \(value) to integer")
            }
            return clampToRange(intValue, for: characteristic)

        case HMCharacteristicMetadataFormatFloat:
            guard let floatValue = toFloat(value) else {
                throw ConversionError.invalidValue("Cannot convert \(value) to float")
            }
            return clampToRange(floatValue, for: characteristic)

        case HMCharacteristicMetadataFormatString:
            return String(describing: value)

        default:
            // Try to infer type from value
            if let boolValue = value as? Bool {
                return boolValue
            } else if let intValue = toInt(value) {
                return intValue
            } else if let floatValue = toFloat(value) {
                return floatValue
            }
            return value
        }
    }

    private static func toBool(_ value: Any) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String {
            return s.lowercased() == "true" || s == "1" || s.lowercased() == "on"
        }
        return false
    }

    private static func toInt(_ value: Any) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        if let b = value as? Bool { return b ? 1 : 0 }
        return nil
    }

    private static func toFloat(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func clampToRange(_ value: Int, for characteristic: HMCharacteristic) -> Int {
        guard let metadata = characteristic.metadata else { return value }

        var result = value
        if let min = metadata.minimumValue as? Int {
            result = max(result, min)
        }
        if let max = metadata.maximumValue as? Int {
            result = min(result, max)
        }
        return result
    }

    private static func clampToRange(_ value: Double, for characteristic: HMCharacteristic) -> Double {
        guard let metadata = characteristic.metadata else { return value }

        var result = value
        if let min = metadata.minimumValue as? Double {
            result = max(result, min)
        }
        if let max = metadata.maximumValue as? Double {
            result = Swift.min(result, max)
        }
        return result
    }
}

// MARK: - Errors

enum ConversionError: LocalizedError {
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message):
            return message
        }
    }
}
