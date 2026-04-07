import Foundation

/// Generates Home Assistant MQTT Discovery config payloads.
/// Maps HomeKit service types to HA component types and publishes
/// retained config messages for automatic device discovery.
struct MQTTDiscovery {

    // MARK: - HomeKit Service → HA Component Mapping

    /// Maps HomeKit service type (friendly name) to HA component + config generator
    private static let componentMap: [String: String] = [
        "lightbulb": "light",
        "switch": "switch",
        "outlet": "switch",
        "fan": "fan",
        "fanv2": "fan",
        "lock": "lock",
        "door": "cover",
        "window": "cover",
        "window_covering": "cover",
        "garage_door": "cover",
        "thermostat": "climate",
        "heater_cooler": "climate",
        "motion_sensor": "binary_sensor",
        "occupancy_sensor": "binary_sensor",
        "contact_sensor": "binary_sensor",
        "smoke_sensor": "binary_sensor",
        "leak_sensor": "binary_sensor",
        "temperature_sensor": "sensor",
        "humidity_sensor": "sensor",
        "light_sensor": "sensor",
        "air_quality_sensor": "sensor",
        "security_system": "alarm_control_panel",
        "valve": "valve",
        "speaker": "media_player",
    ]

    // MARK: - Config Generation

    /// Generate HA discovery configs for an accessory.
    /// Returns array of (topic, payload) tuples to publish as retained messages.
    func generateConfigs(
        accessory: [String: Any],
        topicPrefix: String,
        topicPath: String,          // e.g. "beach-house-a7f2/room/living-room/desk-lamp"
        discoveryPrefix: String     // e.g. "homeassistant"
    ) -> [(topic: String, payload: Data)] {
        guard let accId = accessory["id"] as? String,
              let accName = accessory["name"] as? String,
              let services = accessory["services"] as? [[String: Any]] else { return [] }

        var configs: [(String, Data)] = []

        // Determine primary service type for the accessory
        let primaryService = findPrimaryService(services: services)
        guard let serviceType = primaryService?["serviceType"] as? String else { return [] }

        let friendlyServiceType = serviceType.lowercased()
        guard let haComponent = MQTTDiscovery.componentMap[friendlyServiceType] else { return [] }

        // Unique ID: use first 8 chars of accessory UUID for brevity
        let uniqueId = accId.replacingOccurrences(of: "-", with: "")
        let nodeId = "homecast_\(String(uniqueId.prefix(8)))"

        // Build config payload
        var config: [String: Any] = [
            "name": accName,
            "unique_id": nodeId,
            "state_topic": "\(topicPrefix)/\(topicPath)/state",
            "availability_topic": "\(topicPrefix)/\(topicPath)/availability",
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": [
                "identifiers": [nodeId],
                "name": accName,
                "manufacturer": getManufacturer(services: services),
                "model": getModel(services: services),
                "via_device": "homecast",
            ] as [String: Any],
        ]

        // Add component-specific config
        switch haComponent {
        case "light":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["schema"] = "json"
            config["state_value_template"] = "{{ value_json.on }}"
            config["payload_on"] = "{\"on\":true}"
            config["payload_off"] = "{\"on\":false}"
            if hasCharacteristic(services: services, type: "brightness") {
                config["brightness"] = true
                config["brightness_value_template"] = "{{ value_json.brightness }}"
                config["brightness_command_topic"] = "\(topicPrefix)/\(topicPath)/set"
                config["brightness_scale"] = 100
            }
            if hasCharacteristic(services: services, type: "color_temperature") {
                config["color_temp"] = true
                config["color_temp_value_template"] = "{{ value_json.color_temp }}"
                config["color_temp_command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            }
            if hasCharacteristic(services: services, type: "hue") {
                config["hs"] = true
                config["hs_value_template"] = "{{ value_json.hue }},{{ value_json.saturation }}"
                config["hs_command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            }

        case "switch":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["value_template"] = "{{ value_json.on }}"
            config["payload_on"] = "{\"on\":true}"
            config["payload_off"] = "{\"on\":false}"
            config["state_on"] = "true"
            config["state_off"] = "false"

        case "fan":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["state_value_template"] = "{{ value_json.active }}"
            config["payload_on"] = "{\"active\":1}"
            config["payload_off"] = "{\"active\":0}"
            if hasCharacteristic(services: services, type: "rotation_speed") {
                config["percentage_command_topic"] = "\(topicPrefix)/\(topicPath)/set"
                config["percentage_value_template"] = "{{ value_json.speed }}"
            }

        case "lock":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["value_template"] = "{{ value_json.locked }}"
            config["payload_lock"] = "{\"lock_target\":true}"
            config["payload_unlock"] = "{\"lock_target\":false}"
            config["state_locked"] = "1"
            config["state_unlocked"] = "0"

        case "cover":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["position_topic"] = "\(topicPrefix)/\(topicPath)/state"
            config["set_position_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["position_template"] = "{{ value_json.position }}"
            config["set_position_template"] = "{\"target\":{{ position }}}"
            if friendlyServiceType == "garage_door" {
                config["device_class"] = "garage"
            } else {
                config["device_class"] = "blind"
            }

        case "climate":
            config["temperature_command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["current_temperature_topic"] = "\(topicPrefix)/\(topicPath)/state"
            config["current_temperature_template"] = "{{ value_json.current_temp }}"
            config["temperature_state_topic"] = "\(topicPrefix)/\(topicPath)/state"
            config["temperature_state_template"] = "{{ value_json.heat_target | default(value_json.cool_target, true) }}"

        case "binary_sensor":
            switch friendlyServiceType {
            case "motion_sensor":
                config["device_class"] = "motion"
                config["value_template"] = "{{ value_json.motion }}"
                config["payload_on"] = "true"
                config["payload_off"] = "false"
            case "contact_sensor":
                config["device_class"] = "door"
                config["value_template"] = "{{ value_json.contact }}"
                config["payload_on"] = "1"
                config["payload_off"] = "0"
            case "smoke_sensor":
                config["device_class"] = "smoke"
                config["value_template"] = "{{ value_json.smoke }}"
            case "leak_sensor":
                config["device_class"] = "moisture"
                config["value_template"] = "{{ value_json.leak }}"
            default:
                config["value_template"] = "{{ value_json.on }}"
            }

        case "sensor":
            switch friendlyServiceType {
            case "temperature_sensor":
                config["device_class"] = "temperature"
                config["unit_of_measurement"] = "°C"
                config["value_template"] = "{{ value_json.current_temp }}"
            case "humidity_sensor":
                config["device_class"] = "humidity"
                config["unit_of_measurement"] = "%"
                config["value_template"] = "{{ value_json.relative_humidity | default(value_json.current_temp) }}"
            case "light_sensor":
                config["device_class"] = "illuminance"
                config["unit_of_measurement"] = "lx"
                config["value_template"] = "{{ value_json.light_level }}"
            default:
                break
            }

        case "alarm_control_panel":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["state_topic"] = "\(topicPrefix)/\(topicPath)/state"
            config["value_template"] = "{{ value_json.alarm_state }}"
            config["command_template"] = "{\"alarm_target\":\"{{ action }}\"}"

        case "valve":
            config["command_topic"] = "\(topicPrefix)/\(topicPath)/set"
            config["value_template"] = "{{ value_json.active }}"
            config["payload_on"] = "{\"active\":1}"
            config["payload_off"] = "{\"active\":0}"

        default:
            break
        }

        // Serialize config
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            let objectId = accName.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .joined()
            let topic = "\(discoveryPrefix)/\(haComponent)/\(nodeId)/\(objectId)/config"
            configs.append((topic, data))
        }

        return configs
    }

    // MARK: - Helpers

    private func findPrimaryService(services: [[String: Any]]) -> [String: Any]? {
        let skipTypes: Set<String> = [
            "accessory_information", "battery", "label",
            "thread_transport", "wifi_transport",
            "camera_rtp_stream_management", "camera_control",
            "camera_operating_mode",
        ]

        for service in services {
            guard let type = service["serviceType"] as? String else { continue }
            let normalized = type.lowercased()
            if !skipTypes.contains(normalized) && !normalized.contains("eve_") {
                return service
            }
        }
        return nil
    }

    private func hasCharacteristic(services: [[String: Any]], type: String) -> Bool {
        for service in services {
            guard let chars = service["characteristics"] as? [[String: Any]] else { continue }
            for char in chars {
                if let charType = char["characteristicType"] as? String,
                   charType.lowercased() == type {
                    return true
                }
            }
        }
        return false
    }

    private func getManufacturer(services: [[String: Any]]) -> String {
        return getInfoCharacteristic(services: services, type: "manufacturer") ?? "Unknown"
    }

    private func getModel(services: [[String: Any]]) -> String {
        return getInfoCharacteristic(services: services, type: "model") ?? "HomeKit Accessory"
    }

    private func getInfoCharacteristic(services: [[String: Any]], type: String) -> String? {
        for service in services {
            guard let serviceType = service["serviceType"] as? String,
                  serviceType.lowercased() == "accessory_information",
                  let chars = service["characteristics"] as? [[String: Any]] else { continue }
            for char in chars {
                if let charType = char["characteristicType"] as? String,
                   charType.lowercased() == type,
                   let value = char["value"] as? String {
                    return value
                }
            }
        }
        return nil
    }
}
