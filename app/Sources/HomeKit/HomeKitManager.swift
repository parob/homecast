import HomeKit
import Foundation

@MainActor
class HomeKitManager: NSObject, ObservableObject {
    private let homeManager: HMHomeManager
    @Published private(set) var homes: [HMHome] = []
    @Published private(set) var isReady: Bool = false
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = .determined

    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    override init() {
        self.homeManager = HMHomeManager()
        super.init()
        self.homeManager.delegate = self
    }

    /// Wait for HomeKit to be ready (homes loaded)
    func waitForReady() async {
        if isReady { return }

        await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    // MARK: - Home Operations

    func listHomes() -> [HomeModel] {
        homes.map { HomeModel(from: $0) }
    }

    func getHome(id: String) throws -> HomeModel {
        guard let uuid = UUID(uuidString: id),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(id)
        }
        return HomeModel(from: home)
    }

    // MARK: - Room Operations

    func listRooms(homeId: String) throws -> [RoomModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.rooms.map { RoomModel(from: $0) }
    }

    // MARK: - Accessory Operations

    func listAccessories(homeId: String? = nil, roomId: String? = nil) throws -> [AccessoryModel] {
        var accessories: [HMAccessory] = []

        if let homeId = homeId, let uuid = UUID(uuidString: homeId) {
            guard let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
                throw HomeKitError.homeNotFound(homeId)
            }
            accessories = home.accessories
        } else {
            accessories = homes.flatMap { $0.accessories }
        }

        if let roomId = roomId, let uuid = UUID(uuidString: roomId) {
            accessories = accessories.filter { $0.room?.uniqueIdentifier == uuid }
        }

        return accessories.map { AccessoryModel(from: $0) }
    }

    func getAccessory(id: String) throws -> AccessoryModel {
        guard let uuid = UUID(uuidString: id) else {
            throw HomeKitError.invalidId(id)
        }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                return AccessoryModel(from: accessory)
            }
        }

        throw HomeKitError.accessoryNotFound(id)
    }

    // MARK: - Characteristic Operations

    func readCharacteristic(accessoryId: String, characteristicType: String) async throws -> Any {
        let (_, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)

        return try await withCheckedThrowingContinuation { continuation in
            characteristic.readValue { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.readFailed(error))
                } else {
                    continuation.resume(returning: characteristic.value ?? NSNull())
                }
            }
        }
    }

    func setCharacteristic(accessoryId: String, characteristicType: String, value: Any) async throws -> ControlResult {
        let (_, characteristic) = try await MainActor.run {
            try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
        }

        // Validate writable
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw HomeKitError.characteristicNotWritable(characteristicType)
        }

        // Convert value to appropriate type
        let convertedValue = try CharacteristicMapper.convertValue(value, for: characteristic)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(convertedValue) { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.writeFailed(error))
                } else {
                    continuation.resume()
                }
            }
        }

        return ControlResult(
            success: true,
            accessoryId: accessoryId,
            characteristic: characteristicType,
            newValue: String(describing: convertedValue)
        )
    }

    // MARK: - Scene Operations

    func listScenes(homeId: String) throws -> [SceneModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.actionSets.map { SceneModel(from: $0) }
    }

    func executeScene(sceneId: String) async throws -> ExecuteResult {
        guard let uuid = UUID(uuidString: sceneId) else {
            throw HomeKitError.invalidId(sceneId)
        }

        for home in homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == uuid }) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.executeActionSet(actionSet) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.sceneExecutionFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return ExecuteResult(success: true, sceneId: sceneId)
            }
        }

        throw HomeKitError.sceneNotFound(sceneId)
    }

    // MARK: - Private Helpers

    private func findCharacteristic(accessoryId: String, type: String) throws -> (HMAccessory, HMCharacteristic) {
        guard let uuid = UUID(uuidString: accessoryId) else {
            throw HomeKitError.invalidId(accessoryId)
        }

        let characteristicType = CharacteristicMapper.toHomeKitType(type)

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                for service in accessory.services {
                    if let characteristic = service.characteristics.first(where: { $0.characteristicType == characteristicType }) {
                        return (accessory, characteristic)
                    }
                }
                throw HomeKitError.characteristicNotFound(type)
            }
        }

        throw HomeKitError.accessoryNotFound(accessoryId)
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.homes = manager.homes
            self.isReady = true

            // Resume any waiting continuations
            for continuation in readyContinuations {
                continuation.resume()
            }
            readyContinuations.removeAll()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor in
            self.homes = manager.homes
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor in
            self.homes = manager.homes
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }
}
