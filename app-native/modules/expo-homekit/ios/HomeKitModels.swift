import Foundation
import HomeKit

// MARK: - Home Model

struct HomeModel {
    let id: String
    let name: String
    let isPrimary: Bool
    let roomCount: Int
    let accessoryCount: Int

    init(from home: HMHome) {
        self.id = home.uniqueIdentifier.uuidString
        self.name = home.name
        self.isPrimary = home.isPrimary
        self.roomCount = home.rooms.count
        self.accessoryCount = home.accessories.count
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "isPrimary": isPrimary,
            "roomCount": roomCount,
            "accessoryCount": accessoryCount
        ]
    }
}

// MARK: - Room Model

struct RoomModel {
    let id: String
    let name: String
    let accessoryCount: Int

    init(from room: HMRoom) {
        self.id = room.uniqueIdentifier.uuidString
        self.name = room.name
        self.accessoryCount = room.accessories.count
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "accessoryCount": accessoryCount
        ]
    }
}

// MARK: - Accessory Model

struct AccessoryModel {
    let id: String
    let name: String
    let category: String
    let isReachable: Bool
    let homeId: String?
    let roomId: String?
    let roomName: String?
    let services: [ServiceModel]

    init(from accessory: HMAccessory, home: HMHome?) {
        self.id = accessory.uniqueIdentifier.uuidString
        self.name = accessory.name
        self.category = accessory.category.categoryType
        self.isReachable = accessory.isReachable
        self.homeId = home?.uniqueIdentifier.uuidString
        self.roomId = accessory.room?.uniqueIdentifier.uuidString
        self.roomName = accessory.room?.name
        self.services = accessory.services.map { ServiceModel(from: $0) }
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "category": category,
            "isReachable": isReachable,
            "services": services.map { $0.toDictionary() }
        ]
        if let homeId = homeId { dict["homeId"] = homeId }
        if let roomId = roomId { dict["roomId"] = roomId }
        if let roomName = roomName { dict["roomName"] = roomName }
        return dict
    }
}

// MARK: - Service Model

struct ServiceModel {
    let id: String
    let name: String
    let serviceType: String
    let characteristics: [CharacteristicModel]

    init(from service: HMService) {
        self.id = service.uniqueIdentifier.uuidString
        self.name = service.name
        self.serviceType = CharacteristicMapper.mapServiceType(service.serviceType)
        self.characteristics = service.characteristics.map { CharacteristicModel(from: $0) }
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "serviceType": serviceType,
            "characteristics": characteristics.map { $0.toDictionary() }
        ]
    }
}

// MARK: - Characteristic Model

struct CharacteristicModel {
    let id: String
    let characteristicType: String
    let value: Any?
    let isReadable: Bool
    let isWritable: Bool
    let validValues: [Int]?
    let minValue: Double?
    let maxValue: Double?
    let stepValue: Double?

    init(from characteristic: HMCharacteristic) {
        self.id = characteristic.uniqueIdentifier.uuidString
        self.characteristicType = CharacteristicMapper.mapCharacteristicType(characteristic.characteristicType)
        self.value = characteristic.value
        self.isReadable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
        self.isWritable = characteristic.properties.contains(HMCharacteristicPropertyWritable)

        // Metadata
        if let metadata = characteristic.metadata {
            self.validValues = metadata.validValues?.map { $0.intValue }
            self.minValue = metadata.minimumValue?.doubleValue
            self.maxValue = metadata.maximumValue?.doubleValue
            self.stepValue = metadata.stepValue?.doubleValue
        } else {
            self.validValues = nil
            self.minValue = nil
            self.maxValue = nil
            self.stepValue = nil
        }
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "characteristicType": characteristicType,
            "isReadable": isReadable,
            "isWritable": isWritable
        ]
        if let value = value { dict["value"] = value }
        if let validValues = validValues { dict["validValues"] = validValues }
        if let minValue = minValue { dict["minValue"] = minValue }
        if let maxValue = maxValue { dict["maxValue"] = maxValue }
        if let stepValue = stepValue { dict["stepValue"] = stepValue }
        return dict
    }
}

// MARK: - Scene Model

struct SceneModel {
    let id: String
    let name: String
    let actionCount: Int

    init(from actionSet: HMActionSet) {
        self.id = actionSet.uniqueIdentifier.uuidString
        self.name = actionSet.name
        self.actionCount = actionSet.actions.count
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "actionCount": actionCount
        ]
    }
}

// MARK: - Zone Model

struct ZoneModel {
    let id: String
    let name: String
    let roomIds: [String]

    init(from zone: HMZone) {
        self.id = zone.uniqueIdentifier.uuidString
        self.name = zone.name
        self.roomIds = zone.rooms.map { $0.uniqueIdentifier.uuidString }
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "roomIds": roomIds
        ]
    }
}

// MARK: - Service Group Model

struct ServiceGroupModel {
    let id: String
    let name: String
    let serviceIds: [String]
    let accessoryIds: [String]

    init(from group: HMServiceGroup) {
        self.id = group.uniqueIdentifier.uuidString
        self.name = group.name
        self.serviceIds = group.services.map { $0.uniqueIdentifier.uuidString }
        self.accessoryIds = Array(Set(group.services.compactMap { $0.accessory?.uniqueIdentifier.uuidString }))
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "serviceIds": serviceIds,
            "accessoryIds": accessoryIds
        ]
    }
}

// MARK: - Characteristic Mapper

struct CharacteristicMapper {
    static func mapCharacteristicType(_ type: String) -> String {
        switch type {
        case HMCharacteristicTypePowerState: return "power-state"
        case HMCharacteristicTypeBrightness: return "brightness"
        case HMCharacteristicTypeHue: return "hue"
        case HMCharacteristicTypeSaturation: return "saturation"
        case HMCharacteristicTypeColorTemperature: return "color-temperature"
        case HMCharacteristicTypeCurrentTemperature: return "current-temperature"
        case HMCharacteristicTypeTargetTemperature: return "target-temperature"
        case HMCharacteristicTypeCurrentHeatingCooling: return "current-heating-cooling"
        case HMCharacteristicTypeTargetHeatingCooling: return "target-heating-cooling"
        case HMCharacteristicTypeCurrentLockMechanismState: return "lock-current-state"
        case HMCharacteristicTypeTargetLockMechanismState: return "lock-target-state"
        case HMCharacteristicTypeMotionDetected: return "motion-detected"
        case HMCharacteristicTypeContactState: return "contact-state"
        case HMCharacteristicTypeCurrentPosition: return "current-position"
        case HMCharacteristicTypeTargetPosition: return "target-position"
        case HMCharacteristicTypeObstructionDetected: return "obstruction-detected"
        case HMCharacteristicTypeActive: return "active"
        case HMCharacteristicTypeCurrentRelativeHumidity: return "current-humidity"
        case HMCharacteristicTypeTargetRelativeHumidity: return "target-humidity"
        case HMCharacteristicTypeBatteryLevel: return "battery-level"
        case HMCharacteristicTypeStatusLowBattery: return "low-battery"
        default: return type
        }
    }

    static func mapServiceType(_ type: String) -> String {
        switch type {
        case HMServiceTypeLightbulb: return "lightbulb"
        case HMServiceTypeSwitch: return "switch"
        case HMServiceTypeOutlet: return "outlet"
        case HMServiceTypeThermostat: return "thermostat"
        case HMServiceTypeLockMechanism: return "lock"
        case HMServiceTypeGarageDoorOpener: return "garage-door"
        case HMServiceTypeDoor: return "door"
        case HMServiceTypeWindow: return "window"
        case HMServiceTypeWindowCovering: return "window-covering"
        case HMServiceTypeFan: return "fan"
        case HMServiceTypeMotionSensor: return "motion-sensor"
        case HMServiceTypeContactSensor: return "contact-sensor"
        case HMServiceTypeTemperatureSensor: return "temperature-sensor"
        case HMServiceTypeHumiditySensor: return "humidity-sensor"
        case HMServiceTypeLightSensor: return "light-sensor"
        case HMServiceTypeSecuritySystem: return "security-system"
        case HMServiceTypeBattery: return "battery"
        case HMServiceTypeAccessoryInformation: return "accessory-information"
        default: return type
        }
    }

    static func reverseMapCharacteristicType(_ type: String) -> String {
        switch type {
        case "power-state": return HMCharacteristicTypePowerState
        case "brightness": return HMCharacteristicTypeBrightness
        case "hue": return HMCharacteristicTypeHue
        case "saturation": return HMCharacteristicTypeSaturation
        case "color-temperature": return HMCharacteristicTypeColorTemperature
        case "current-temperature": return HMCharacteristicTypeCurrentTemperature
        case "target-temperature": return HMCharacteristicTypeTargetTemperature
        case "current-heating-cooling": return HMCharacteristicTypeCurrentHeatingCooling
        case "target-heating-cooling": return HMCharacteristicTypeTargetHeatingCooling
        case "lock-current-state": return HMCharacteristicTypeCurrentLockMechanismState
        case "lock-target-state": return HMCharacteristicTypeTargetLockMechanismState
        case "motion-detected": return HMCharacteristicTypeMotionDetected
        case "contact-state": return HMCharacteristicTypeContactState
        case "current-position": return HMCharacteristicTypeCurrentPosition
        case "target-position": return HMCharacteristicTypeTargetPosition
        case "active": return HMCharacteristicTypeActive
        default: return type
        }
    }
}
