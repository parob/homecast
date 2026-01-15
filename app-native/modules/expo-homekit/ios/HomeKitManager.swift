import Foundation
import HomeKit

// MARK: - Delegate Protocol

protocol HomeKitManagerDelegate: AnyObject {
    func homesDidUpdate(_ homes: [HomeModel])
    func characteristicDidChange(accessoryId: String, characteristicType: String, value: Any)
    func reachabilityDidChange(accessoryId: String, isReachable: Bool)
}

// MARK: - Errors

enum HomeKitError: Error, LocalizedError {
    case homeNotFound(String)
    case accessoryNotFound(String)
    case characteristicNotFound(String)
    case characteristicNotWritable(String)
    case invalidId(String)
    case readFailed(Error)
    case writeFailed(Error)
    case sceneNotFound(String)
    case sceneExecutionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .homeNotFound(let id): return "Home not found: \(id)"
        case .accessoryNotFound(let id): return "Accessory not found: \(id)"
        case .characteristicNotFound(let type): return "Characteristic not found: \(type)"
        case .characteristicNotWritable(let type): return "Characteristic not writable: \(type)"
        case .invalidId(let id): return "Invalid ID: \(id)"
        case .readFailed(let error): return "Read failed: \(error.localizedDescription)"
        case .writeFailed(let error): return "Write failed: \(error.localizedDescription)"
        case .sceneNotFound(let id): return "Scene not found: \(id)"
        case .sceneExecutionFailed(let error): return "Scene execution failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - HomeKitManager

class HomeKitManager: NSObject {
    private let homeManager: HMHomeManager
    private var homes: [HMHome] = []
    private var isReady = false
    private var observedAccessories: Set<UUID> = []

    weak var delegate: HomeKitManagerDelegate?

    override init() {
        self.homeManager = HMHomeManager()
        super.init()
        self.homeManager.delegate = self
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (HMHomeManagerAuthorizationStatus) -> Void) {
        // HomeKit automatically triggers authorization on first access
        // We just need to wait for the delegate callback
        if isReady {
            completion(homeManager.authorizationStatus)
        } else {
            // Wait a moment for initial load then return status
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(self.homeManager.authorizationStatus)
            }
        }
    }

    // MARK: - Home Operations

    func listHomes() -> [HomeModel] {
        return homes.map { HomeModel(from: $0) }
    }

    func getHome(id: String) -> HMHome? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return homes.first { $0.uniqueIdentifier == uuid }
    }

    // MARK: - Room Operations

    func listRooms(homeId: String) -> [RoomModel] {
        guard let home = getHome(id: homeId) else { return [] }
        return home.rooms.map { RoomModel(from: $0) }
    }

    // MARK: - Accessory Operations

    func listAccessories(homeId: String?, roomId: String?) -> [AccessoryModel] {
        var result: [AccessoryModel] = []

        if let homeId = homeId, let home = getHome(id: homeId) {
            var accessories = home.accessories
            if let roomId = roomId, let roomUuid = UUID(uuidString: roomId) {
                accessories = accessories.filter { $0.room?.uniqueIdentifier == roomUuid }
            }
            result = accessories.map { AccessoryModel(from: $0, home: home) }
        } else {
            // All accessories from all homes
            for home in homes {
                result.append(contentsOf: home.accessories.map { AccessoryModel(from: $0, home: home) })
            }
        }

        return result
    }

    func getAccessory(accessoryId: String) -> AccessoryModel? {
        guard let uuid = UUID(uuidString: accessoryId) else { return nil }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                return AccessoryModel(from: accessory, home: home)
            }
        }

        return nil
    }

    private func findAccessory(id: String) -> HMAccessory? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                return accessory
            }
        }

        return nil
    }

    // MARK: - Characteristic Operations

    func readCharacteristic(
        accessoryId: String,
        characteristicType: String,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let accessory = findAccessory(id: accessoryId) else {
            completion(.failure(HomeKitError.accessoryNotFound(accessoryId)))
            return
        }

        let hmCharType = CharacteristicMapper.reverseMapCharacteristicType(characteristicType)

        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == hmCharType }) {
                characteristic.readValue { error in
                    if let error = error {
                        completion(.failure(HomeKitError.readFailed(error)))
                    } else {
                        completion(.success(characteristic.value ?? NSNull()))
                    }
                }
                return
            }
        }

        completion(.failure(HomeKitError.characteristicNotFound(characteristicType)))
    }

    func setCharacteristic(
        accessoryId: String,
        characteristicType: String,
        value: Any,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let accessory = findAccessory(id: accessoryId) else {
            completion(.failure(HomeKitError.accessoryNotFound(accessoryId)))
            return
        }

        let hmCharType = CharacteristicMapper.reverseMapCharacteristicType(characteristicType)

        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == hmCharType }) {
                guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
                    completion(.failure(HomeKitError.characteristicNotWritable(characteristicType)))
                    return
                }

                // Convert value to appropriate type
                let convertedValue = convertValue(value, for: characteristic)

                characteristic.writeValue(convertedValue) { error in
                    if let error = error {
                        completion(.failure(HomeKitError.writeFailed(error)))
                    } else {
                        completion(.success([
                            "success": true,
                            "accessoryId": accessoryId,
                            "characteristicType": characteristicType,
                            "value": convertedValue
                        ]))
                    }
                }
                return
            }
        }

        completion(.failure(HomeKitError.characteristicNotFound(characteristicType)))
    }

    private func convertValue(_ value: Any, for characteristic: HMCharacteristic) -> Any {
        let format = characteristic.metadata?.format

        switch format {
        case HMCharacteristicMetadataFormatBool:
            return toBool(value)

        case HMCharacteristicMetadataFormatInt,
             HMCharacteristicMetadataFormatUInt8,
             HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32,
             HMCharacteristicMetadataFormatUInt64:
            return toInt(value) ?? value

        case HMCharacteristicMetadataFormatFloat:
            return toFloat(value) ?? value

        default:
            return value
        }
    }

    private func toBool(_ value: Any) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String { return s.lowercased() == "true" || s == "1" }
        return false
    }

    private func toInt(_ value: Any) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        if let b = value as? Bool { return b ? 1 : 0 }
        return nil
    }

    private func toFloat(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Scene Operations

    func listScenes(homeId: String) -> [SceneModel] {
        guard let home = getHome(id: homeId) else { return [] }
        return home.actionSets.map { SceneModel(from: $0) }
    }

    func executeScene(sceneId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let uuid = UUID(uuidString: sceneId) else {
            completion(.failure(HomeKitError.invalidId(sceneId)))
            return
        }

        for home in homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == uuid }) {
                home.executeActionSet(actionSet) { error in
                    if let error = error {
                        completion(.failure(HomeKitError.sceneExecutionFailed(error)))
                    } else {
                        completion(.success([
                            "success": true,
                            "sceneId": sceneId
                        ]))
                    }
                }
                return
            }
        }

        completion(.failure(HomeKitError.sceneNotFound(sceneId)))
    }

    // MARK: - Zone Operations

    func listZones(homeId: String) -> [ZoneModel] {
        guard let home = getHome(id: homeId) else { return [] }
        return home.zones.map { ZoneModel(from: $0) }
    }

    // MARK: - Service Group Operations

    func listServiceGroups(homeId: String) -> [ServiceGroupModel] {
        guard let home = getHome(id: homeId) else { return [] }
        return home.serviceGroups.map { ServiceGroupModel(from: $0) }
    }

    // MARK: - Observation

    func startObserving() {
        for home in homes {
            for accessory in home.accessories {
                observeAccessory(accessory)
            }
        }
    }

    func stopObserving() {
        for home in homes {
            for accessory in home.accessories {
                if observedAccessories.contains(accessory.uniqueIdentifier) {
                    accessory.delegate = nil
                }
            }
        }
        observedAccessories.removeAll()
    }

    private func observeAccessory(_ accessory: HMAccessory) {
        guard !observedAccessories.contains(accessory.uniqueIdentifier) else { return }
        accessory.delegate = self
        observedAccessories.insert(accessory.uniqueIdentifier)
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        self.homes = manager.homes
        self.isReady = true

        // Re-observe accessories if we were observing
        if !observedAccessories.isEmpty {
            for home in homes {
                for accessory in home.accessories {
                    observeAccessory(accessory)
                }
            }
        }

        // Notify delegate
        delegate?.homesDidUpdate(homes.map { HomeModel(from: $0) })
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        self.homes = manager.homes
        delegate?.homesDidUpdate(homes.map { HomeModel(from: $0) })
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        self.homes = manager.homes
        delegate?.homesDidUpdate(homes.map { HomeModel(from: $0) })
    }
}

// MARK: - HMAccessoryDelegate

extension HomeKitManager: HMAccessoryDelegate {
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let charType = CharacteristicMapper.mapCharacteristicType(characteristic.characteristicType)
        let value = characteristic.value ?? NSNull()

        delegate?.characteristicDidChange(
            accessoryId: accessoryId,
            characteristicType: charType,
            value: value
        )
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let isReachable = accessory.isReachable

        delegate?.reachabilityDidChange(
            accessoryId: accessoryId,
            isReachable: isReachable
        )
    }
}
