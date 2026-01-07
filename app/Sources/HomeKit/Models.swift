import HomeKit
import Foundation

// MARK: - Home Model

struct HomeModel: Codable {
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

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "isPrimary": .bool(isPrimary),
            "roomCount": .int(roomCount),
            "accessoryCount": .int(accessoryCount)
        ])
    }
}

// MARK: - Room Model

struct RoomModel: Codable {
    let id: String
    let name: String
    let accessoryCount: Int

    init(from room: HMRoom) {
        self.id = room.uniqueIdentifier.uuidString
        self.name = room.name
        self.accessoryCount = room.accessories.count
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "accessoryCount": .int(accessoryCount)
        ])
    }
}

// MARK: - Accessory Model

struct AccessoryModel: Codable {
    let id: String
    let name: String
    let roomId: String?
    let roomName: String?
    let category: String
    let isReachable: Bool
    let services: [ServiceModel]

    init(from accessory: HMAccessory, includeValues: Bool = true) {
        self.id = accessory.uniqueIdentifier.uuidString
        self.name = accessory.name
        self.roomId = accessory.room?.uniqueIdentifier.uuidString
        self.roomName = accessory.room?.name
        self.category = accessory.category.localizedDescription
        self.isReachable = accessory.isReachable
        self.services = accessory.services.map { ServiceModel(from: $0, includeValues: includeValues) }
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "category": .string(category),
            "isReachable": .bool(isReachable),
            "services": .array(services.map { $0.toJSON() })
        ]
        if let roomId = roomId {
            obj["roomId"] = .string(roomId)
        }
        if let roomName = roomName {
            obj["roomName"] = .string(roomName)
        }
        return .object(obj)
    }
}

// MARK: - Service Model

struct ServiceModel: Codable {
    let id: String
    let name: String
    let serviceType: String
    let characteristics: [CharacteristicModel]

    init(from service: HMService, includeValues: Bool = true) {
        self.id = service.uniqueIdentifier.uuidString
        self.name = service.name
        self.serviceType = CharacteristicMapper.fromHomeKitServiceType(service.serviceType)
        self.characteristics = service.characteristics.map { CharacteristicModel(from: $0, includeValue: includeValues) }
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "serviceType": .string(serviceType),
            "characteristics": .array(characteristics.map { $0.toJSON() })
        ])
    }
}

// MARK: - Characteristic Model

struct CharacteristicModel: Codable {
    let id: String
    let characteristicType: String
    let value: String?
    let isReadable: Bool
    let isWritable: Bool

    init(from characteristic: HMCharacteristic, includeValue: Bool = true) {
        self.id = characteristic.uniqueIdentifier.uuidString
        self.characteristicType = CharacteristicMapper.fromHomeKitType(characteristic.characteristicType)
        // Note: Accessing .value can trigger network reads on some devices
        // For large accessory lists, skip values for performance
        self.value = includeValue ? characteristic.value.map { String(describing: $0) } : nil
        self.isReadable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
        self.isWritable = characteristic.properties.contains(HMCharacteristicPropertyWritable)
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "characteristicType": .string(characteristicType),
            "isReadable": .bool(isReadable),
            "isWritable": .bool(isWritable)
        ]
        if let value = value {
            obj["value"] = .string(value)
        }
        return .object(obj)
    }
}

// MARK: - Scene Model

struct SceneModel: Codable {
    let id: String
    let name: String
    let actionCount: Int

    init(from actionSet: HMActionSet) {
        self.id = actionSet.uniqueIdentifier.uuidString
        self.name = actionSet.name
        self.actionCount = actionSet.actions.count
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "actionCount": .int(actionCount)
        ])
    }
}

// MARK: - Result Models

struct ControlResult: Codable {
    let success: Bool
    let accessoryId: String
    let characteristic: String
    let newValue: String

    func toJSON() -> JSONValue {
        .object([
            "success": .bool(success),
            "accessoryId": .string(accessoryId),
            "characteristic": .string(characteristic),
            "newValue": .string(newValue)
        ])
    }
}

struct ExecuteResult: Codable {
    let success: Bool
    let sceneId: String

    func toJSON() -> JSONValue {
        .object([
            "success": .bool(success),
            "sceneId": .string(sceneId)
        ])
    }
}

// MARK: - Errors

enum HomeKitError: LocalizedError {
    case homeNotFound(String)
    case roomNotFound(String)
    case accessoryNotFound(String)
    case sceneNotFound(String)
    case characteristicNotFound(String)
    case characteristicNotWritable(String)
    case invalidId(String)
    case invalidRequest(String)
    case readFailed(Error)
    case writeFailed(Error)
    case sceneExecutionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .homeNotFound(let id):
            return "Home not found: \(id)"
        case .roomNotFound(let id):
            return "Room not found: \(id)"
        case .accessoryNotFound(let id):
            return "Accessory not found: \(id)"
        case .sceneNotFound(let id):
            return "Scene not found: \(id)"
        case .characteristicNotFound(let type):
            return "Characteristic not found: \(type)"
        case .characteristicNotWritable(let type):
            return "Characteristic not writable: \(type)"
        case .invalidId(let id):
            return "Invalid ID format: \(id)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .readFailed(let error):
            return "Read failed: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Write failed: \(error.localizedDescription)"
        case .sceneExecutionFailed(let error):
            return "Scene execution failed: \(error.localizedDescription)"
        }
    }
}
