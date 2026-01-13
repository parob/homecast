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

        // Heater/Cooler (different from thermostat)
        "current_heater_cooler_state": "000000B1-0000-1000-8000-0026BB765291",
        "target_heater_cooler_state": "000000B2-0000-1000-8000-0026BB765291",
        "swing_mode": "000000B6-0000-1000-8000-0026BB765291",
        "lock_physical_controls": "000000A7-0000-1000-8000-0026BB765291",

        // Fan states
        "current_fan_state": "000000AF-0000-1000-8000-0026BB765291",
        "target_fan_state": "000000BF-0000-1000-8000-0026BB765291",

        // Air purifier/humidifier
        "current_air_purifier_state": "000000A9-0000-1000-8000-0026BB765291",
        "target_air_purifier_state": "000000A8-0000-1000-8000-0026BB765291",
        "current_humidifier_dehumidifier_state": "000000B3-0000-1000-8000-0026BB765291",
        "target_humidifier_dehumidifier_state": "000000B4-0000-1000-8000-0026BB765291",
        "water_level": "000000B5-0000-1000-8000-0026BB765291",

        // Slats/tilt
        "current_tilt_angle": "000000C1-0000-1000-8000-0026BB765291",
        "target_tilt_angle": "000000C2-0000-1000-8000-0026BB765291",
        "slat_type": "000000C0-0000-1000-8000-0026BB765291",
        "current_slat_state": "000000AA-0000-1000-8000-0026BB765291",

        // Window covering
        "obstruction_detected": HMCharacteristicTypeObstructionDetected,
        "hold_position": HMCharacteristicTypeHoldPosition,
        "current_horizontal_tilt": HMCharacteristicTypeCurrentHorizontalTilt,
        "target_horizontal_tilt": HMCharacteristicTypeTargetHorizontalTilt,
        "current_vertical_tilt": HMCharacteristicTypeCurrentVerticalTilt,
        "target_vertical_tilt": HMCharacteristicTypeTargetVerticalTilt,

        // Thread/WiFi transport (newer HomeKit)
        "thread_node_capabilities": "0000023A-0000-1000-8000-0026BB765291",
        "thread_status": "0000023C-0000-1000-8000-0026BB765291",
        "thread_control_point": "0000024A-0000-1000-8000-0026BB765291",
        "current_transport": "0000022B-0000-1000-8000-0026BB765291",
        "wifi_capabilities": "00000702-0000-1000-8000-0026BB765291",
        "wifi_configuration_control": "00000703-0000-1000-8000-0026BB765291",
        "wifi_satellite_status": "00000706-0000-1000-8000-0026BB765291",

        // Eve custom characteristics
        "eve_energy_watt": "E863F10D-079E-48FF-8F27-9C2605A29F52",
        "eve_energy_kwh": "E863F10C-079E-48FF-8F27-9C2605A29F52",
        "eve_voltage": "E863F10A-079E-48FF-8F27-9C2605A29F52",
        "eve_ampere": "E863F126-079E-48FF-8F27-9C2605A29F52",
        "eve_history_request": "E863F11C-079E-48FF-8F27-9C2605A29F52",
        "eve_history_status": "E863F116-079E-48FF-8F27-9C2605A29F52",
        "eve_history_entries": "E863F117-079E-48FF-8F27-9C2605A29F52",
        "eve_reset_total": "E863F112-079E-48FF-8F27-9C2605A29F52",
        "eve_firmware": "E863F11E-079E-48FF-8F27-9C2605A29F52",
        "eve_set_time": "E863F121-079E-48FF-8F27-9C2605A29F52",
        "eve_weather_trend": "E863F136-079E-48FF-8F27-9C2605A29F52",
        "eve_elevation": "E863F130-079E-48FF-8F27-9C2605A29F52",
        "eve_air_pressure": "E863F10F-079E-48FF-8F27-9C2605A29F52",
        "eve_sensitivity": "E863F120-079E-48FF-8F27-9C2605A29F52",
        "eve_duration": "E863F12D-079E-48FF-8F27-9C2605A29F52",
        "eve_last_activation": "E863F11A-079E-48FF-8F27-9C2605A29F52",
        "eve_closed_duration": "E863F118-079E-48FF-8F27-9C2605A29F52",
        "eve_open_duration": "E863F119-079E-48FF-8F27-9C2605A29F52",
        "eve_times_opened": "E863F129-079E-48FF-8F27-9C2605A29F52",
        "eve_command": "E863F11D-079E-48FF-8F27-9C2605A29F52",
        "eve_program_data": "E863F12F-079E-48FF-8F27-9C2605A29F52",
        "eve_valve_position": "E863F12E-079E-48FF-8F27-9C2605A29F52",
        "eve_program_command": "E863F12C-079E-48FF-8F27-9C2605A29F52",
        "eve_current_consumption": "E863F10D-079E-48FF-8F27-9C2605A29F52",
        "eve_total_consumption": "E863F10C-079E-48FF-8F27-9C2605A29F52",
        "eve_motion_sensitivity": "E863F120-079E-48FF-8F27-9C2605A29F52",
        "eve_blinds_movement": "E863F158-079E-48FF-8F27-9C2605A29F52",
        "eve_calibration_data": "E863F131-079E-48FF-8F27-9C2605A29F52",

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

        // Camera
        "night_vision": "0000011B-0000-1000-8000-0026BB765291",
        "camera_operating_mode_indicator": "0000021B-0000-1000-8000-0026BB765291",
        "third_party_camera_active": "0000021C-0000-1000-8000-0026BB765291",
        "homekit_camera_active": "0000021D-0000-1000-8000-0026BB765291",
        "event_snapshots_active": "00000223-0000-1000-8000-0026BB765291",
        "periodic_snapshots_active": "00000225-0000-1000-8000-0026BB765291",
        "recording_audio_active": "00000226-0000-1000-8000-0026BB765291",
        "manually_disabled": "00000227-0000-1000-8000-0026BB765291",
        "diagonal_field_of_view": "00000224-0000-1000-8000-0026BB765291",

        // General
        "name": HMCharacteristicTypeName,
        "identify": HMCharacteristicTypeIdentify,
        "manufacturer": HMCharacteristicTypeManufacturer,
        "model": HMCharacteristicTypeModel,
        "serial_number": HMCharacteristicTypeSerialNumber,
        "firmware_revision": HMCharacteristicTypeFirmwareVersion,
        "hardware_revision": HMCharacteristicTypeHardwareVersion,
        "configured_name": "000000E3-0000-1000-8000-0026BB765291",
        "label_index": "00000090-0000-1000-8000-0026BB765291",
        "label_namespace": "000000CD-0000-1000-8000-0026BB765291",
        "version": "00000037-0000-1000-8000-0026BB765291",
        "accessory_flags": "000000A6-0000-1000-8000-0026BB765291",
        "product_data": "00000220-0000-1000-8000-0026BB765291",
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
        "camera_operating_mode": "0000021A-0000-1000-8000-0026BB765291",

        // Security
        "security_system": HMServiceTypeSecuritySystem,

        // Accessory Info
        "accessory_information": HMServiceTypeAccessoryInformation,
        "label": HMServiceTypeLabel,

        // Thread/WiFi transport services
        "thread_transport": "00000239-0000-1000-8000-0026BB765291",
        "wifi_transport": "00000701-0000-1000-8000-0026BB765291",

        // Eve custom service (history/energy)
        "eve_history": "E863F007-079E-48FF-8F27-9C2605A29F52",
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
