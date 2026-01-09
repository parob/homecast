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
        "heating_threshold": HMCharacteristicTypeHeatingThreshold,
        "cooling_threshold": HMCharacteristicTypeCoolingThreshold,
        "relative_humidity": HMCharacteristicTypeCurrentRelativeHumidity,
        "target_humidity": HMCharacteristicTypeTargetRelativeHumidity,
        "temperature_units": HMCharacteristicTypeTemperatureUnits,

        // Active/In Use
        "active": HMCharacteristicTypeActive,
        "in_use": HMCharacteristicTypeInUse,
        "is_configured": HMCharacteristicTypeIsConfigured,
        "program_mode": HMCharacteristicTypeProgramMode,
        "status_active": HMCharacteristicTypeStatusActive,

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
        // Lighting
        "lightbulb": HMServiceTypeLightbulb,

        // Switches & Outlets
        "switch": HMServiceTypeSwitch,
        "outlet": HMServiceTypeOutlet,
        "stateless_programmable_switch": HMServiceTypeStatelessProgrammableSwitch,

        // Climate Control
        "thermostat": HMServiceTypeThermostat,
        "heater_cooler": HMServiceTypeHeaterCooler,
        "fan": HMServiceTypeFan,
        "air_purifier": HMServiceTypeAirPurifier,
        "humidifier_dehumidifier": HMServiceTypeHumidifierDehumidifier,
        "filter_maintenance": HMServiceTypeFilterMaintenance,

        // Doors, Windows & Locks
        "lock": HMServiceTypeLockMechanism,
        "door": HMServiceTypeDoor,
        "doorbell": HMServiceTypeDoorbell,
        "window": HMServiceTypeWindow,
        "window_covering": HMServiceTypeWindowCovering,
        "garage_door": HMServiceTypeGarageDoorOpener,
        "slats": HMServiceTypeSlats,

        // Water
        "faucet": HMServiceTypeFaucet,
        "valve": HMServiceTypeValve,
        "irrigation_system": HMServiceTypeIrrigationSystem,

        // Sensors
        "motion_sensor": HMServiceTypeMotionSensor,
        "occupancy_sensor": HMServiceTypeOccupancySensor,
        "contact_sensor": HMServiceTypeContactSensor,
        "temperature_sensor": HMServiceTypeTemperatureSensor,
        "humidity_sensor": HMServiceTypeHumiditySensor,
        "light_sensor": HMServiceTypeLightSensor,
        "smoke_sensor": HMServiceTypeSmokeSensor,
        "carbon_monoxide_sensor": HMServiceTypeCarbonMonoxideSensor,
        "carbon_dioxide_sensor": HMServiceTypeCarbonDioxideSensor,
        "air_quality_sensor": HMServiceTypeAirQualitySensor,
        "leak_sensor": HMServiceTypeLeakSensor,

        // Power & Battery
        "battery": HMServiceTypeBattery,

        // Audio & Video
        "speaker": HMServiceTypeSpeaker,
        "microphone": HMServiceTypeMicrophone,
        "camera_rtp_stream_management": HMServiceTypeCameraRTPStreamManagement,
        "camera_control": HMServiceTypeCameraControl,

        // Security
        "security_system": HMServiceTypeSecuritySystem,

        // Accessory Info
        "accessory_information": HMServiceTypeAccessoryInformation,
        "label": HMServiceTypeLabel,
    ]

    // MARK: - Simplified Name Mapping (matches server's CHAR_TO_SIMPLE)
    // Maps server's simplified names to HomeKit characteristic types

    private static let simpleNameMap: [String: String] = [
        // Power
        "on": HMCharacteristicTypePowerState,

        // Lighting
        "brightness": HMCharacteristicTypeBrightness,
        "hue": HMCharacteristicTypeHue,
        "saturation": HMCharacteristicTypeSaturation,
        "color_temp": HMCharacteristicTypeColorTemperature,

        // Climate
        "current_temp": HMCharacteristicTypeCurrentTemperature,
        "heat_target": HMCharacteristicTypeHeatingThreshold,
        "cool_target": HMCharacteristicTypeCoolingThreshold,
        "active": HMCharacteristicTypeActive,
        "hvac_mode": "000000B2-0000-1000-8000-0026BB765291",  // Target heater/cooler state
        "hvac_state": "000000B1-0000-1000-8000-0026BB765291", // Current heater/cooler state

        // Lock
        "locked": HMCharacteristicTypeCurrentLockMechanismState,
        "lock_target": HMCharacteristicTypeTargetLockMechanismState,

        // Security/Alarm
        "alarm_state": HMCharacteristicTypeCurrentSecuritySystemState,
        "alarm_target": HMCharacteristicTypeTargetSecuritySystemState,

        // Sensors
        "motion": HMCharacteristicTypeMotionDetected,
        "contact": HMCharacteristicTypeContactState,

        // Position (blinds, etc)
        "position": HMCharacteristicTypeCurrentPosition,
        "target": HMCharacteristicTypeTargetPosition,

        // Fan
        "speed": HMCharacteristicTypeRotationSpeed,

        // Audio
        "volume": HMCharacteristicTypeVolume,
        "mute": HMCharacteristicTypeMute,

        // Battery
        "battery": HMCharacteristicTypeBatteryLevel,
    ]

    // MARK: - Conversion Methods

    /// Convert server's simplified name to HomeKit characteristic type UUID
    static func fromSimpleName(_ simpleName: String) -> String {
        let normalized = simpleName.lowercased()
        // Try simple name map first, then fall back to standard map
        return simpleNameMap[normalized] ?? characteristicMap[normalized] ?? simpleName
    }

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

    /// Convert alarm_target string to HomeKit value
    private static let alarmTargetMap: [String: Int] = [
        "home": 0, "away": 1, "night": 2, "off": 3
    ]

    /// Convert hvac_mode string to HomeKit value
    private static let hvacModeMap: [String: Int] = [
        "auto": 0, "heat": 1, "cool": 2
    ]

    /// Convert a simplified value to HomeKit value based on property name
    static func convertSimpleValue(_ value: Any, forProperty prop: String) -> Any {
        let propLower = prop.lowercased()

        // alarm_target: "away" -> 1
        if propLower == "alarm_target" {
            if let str = value as? String, let intVal = alarmTargetMap[str.lowercased()] {
                return intVal
            }
        }

        // hvac_mode: "heat" -> 1
        if propLower == "hvac_mode" {
            if let str = value as? String, let intVal = hvacModeMap[str.lowercased()] {
                return intVal
            }
        }

        // lock_target: true -> 1, false -> 0
        if propLower == "lock_target" {
            if let boolVal = value as? Bool {
                return boolVal ? 1 : 0
            }
            if let intVal = value as? Int {
                return intVal != 0 ? 1 : 0
            }
        }

        return value
    }

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
