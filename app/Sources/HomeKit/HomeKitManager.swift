import HomeKit
import Foundation

/// Delegate to receive characteristic value change notifications
protocol HomeKitManagerDelegate: AnyObject {
    func characteristicDidUpdate(accessoryId: String, characteristicType: String, value: Any)
    func accessoryReachabilityDidUpdate(accessoryId: String, isReachable: Bool)
}

@MainActor
class HomeKitManager: NSObject, ObservableObject {
    private let homeManager: HMHomeManager
    @Published private(set) var homes: [HMHome] = []
    @Published private(set) var isReady: Bool = false
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = .determined

    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Delegate for characteristic change notifications
    weak var delegate: HomeKitManagerDelegate?

    /// Track which accessories we've set ourselves as delegate for
    private var observedAccessories: Set<UUID> = []

    override init() {
        self.homeManager = HMHomeManager()
        super.init()
        self.homeManager.delegate = self
    }

    /// Whether we're currently observing characteristic changes
    private(set) var isObserving: Bool = false

    /// Timer to auto-stop observing if no confirmation received
    private var observationTimeoutTask: Task<Void, Never>?

    /// How long to wait for confirmation before stopping observation (seconds)
    private let observationTimeout: TimeInterval = 90

    /// Start observing characteristic changes for all accessories
    func startObservingChanges() {
        // Reset timeout even if already observing
        resetObservationTimeout()

        guard !isObserving else { return }
        isObserving = true

        let totalAccessories = homes.reduce(0) { $0 + $1.accessories.count }
        print("[HomeKit] 🔔 Starting observation for \(totalAccessories) accessories across \(homes.count) homes...")

        for home in homes {
            for accessory in home.accessories {
                observeAccessory(accessory)
            }
        }

        print("[HomeKit] ✅ Now observing \(observedAccessories.count) accessories for real-time changes")
    }

    /// Reset the observation timeout (call when server confirms listeners exist)
    func resetObservationTimeout() {
        observationTimeoutTask?.cancel()

        guard isObserving else { return }

        observationTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(observationTimeout * 1_000_000_000))
                // Timeout expired - no confirmation received
                print("[HomeKit] ⏱️ Observation timeout - no listener confirmation for \(Int(self.observationTimeout))s")
                self.stopObservingChanges()
            } catch {
                // Task cancelled - this is expected when timeout is reset
            }
        }
    }

    /// Stop observing characteristic changes
    func stopObservingChanges() {
        observationTimeoutTask?.cancel()
        observationTimeoutTask = nil

        guard isObserving else { return }

        let count = observedAccessories.count
        isObserving = false

        // Clear delegates from all observed accessories
        for home in homes {
            for accessory in home.accessories {
                if observedAccessories.contains(accessory.uniqueIdentifier) {
                    accessory.delegate = nil
                }
            }
        }
        observedAccessories.removeAll()
        print("[HomeKit] 🔕 Stopped observing \(count) accessories")
    }

    /// Observe a single accessory for changes
    private func observeAccessory(_ accessory: HMAccessory) {
        guard isObserving else { return }
        guard !observedAccessories.contains(accessory.uniqueIdentifier) else { return }
        accessory.delegate = self
        observedAccessories.insert(accessory.uniqueIdentifier)
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

    // MARK: - Zone Operations

    func listZones(homeId: String) throws -> [ZoneModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.zones.map { ZoneModel(from: $0) }
    }

    // MARK: - Service Group Operations

    func listServiceGroups(homeId: String) throws -> [ServiceGroupModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.serviceGroups.map { ServiceGroupModel(from: $0) }
    }

    /// Set a characteristic on all services in a group
    func setServiceGroupCharacteristic(homeId: String?, groupId: String, characteristicType: String, value: Any) async throws -> Int {
        print("[HomeKit] 📝 setServiceGroupCharacteristic: group=\(groupId.prefix(8))..., type=\(characteristicType), value=\(value)")

        // Find group across all homes if homeId not specified
        var targetGroup: HMServiceGroup?
        var targetHome: HMHome?

        if let homeId = homeId, let homeUUID = UUID(uuidString: homeId) {
            guard let home = homes.first(where: { $0.uniqueIdentifier == homeUUID }) else {
                throw HomeKitError.homeNotFound(homeId)
            }
            targetHome = home
            if let groupUUID = UUID(uuidString: groupId) {
                targetGroup = home.serviceGroups.first(where: { $0.uniqueIdentifier == groupUUID })
            }
        } else {
            // Search all homes for the group
            if let groupUUID = UUID(uuidString: groupId) {
                for home in homes {
                    if let group = home.serviceGroups.first(where: { $0.uniqueIdentifier == groupUUID }) {
                        targetGroup = group
                        targetHome = home
                        break
                    }
                }
            }
        }

        guard let group = targetGroup else {
            print("[HomeKit] ❌ Service group not found: \(groupId)")
            throw HomeKitError.invalidRequest("Service group not found: \(groupId)")
        }

        print("[HomeKit] 📝 Found group '\(group.name)' with \(group.services.count) services")

        var successCount = 0

        // Find the characteristic on each service and set it
        for service in group.services {
            let charType = CharacteristicMapper.toHomeKitType(characteristicType)
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == charType }) {
                if characteristic.properties.contains(HMCharacteristicPropertyWritable) {
                    do {
                        let convertedValue = try CharacteristicMapper.convertValue(value, for: characteristic)
                        print("[HomeKit] 📝 Writing to service '\(service.name)': \(value) -> \(convertedValue)")
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            characteristic.writeValue(convertedValue) { error in
                                if let error = error {
                                    print("[HomeKit] ❌ Write failed for '\(service.name)': \(error.localizedDescription)")
                                    continuation.resume(throwing: error)
                                } else {
                                    print("[HomeKit] ✅ Write successful for '\(service.name)'")
                                    continuation.resume()
                                }
                            }
                        }
                        successCount += 1
                    } catch {
                        print("[HomeKit] ❌ Failed to set \(characteristicType) on service \(service.name): \(error)")
                    }
                } else {
                    print("[HomeKit] ⚠️ Characteristic \(characteristicType) not writable on service '\(service.name)'")
                }
            } else {
                print("[HomeKit] ⚠️ Characteristic \(characteristicType) not found on service '\(service.name)'")
            }
        }

        print("[HomeKit] 📝 setServiceGroupCharacteristic complete: \(successCount)/\(group.services.count) succeeded")
        return successCount
    }

    // MARK: - Accessory Operations

    func listAccessories(homeId: String? = nil, roomId: String? = nil, includeValues: Bool = false) throws -> [AccessoryModel] {
        var result: [AccessoryModel] = []

        if let homeId = homeId, let uuid = UUID(uuidString: homeId) {
            guard let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
                throw HomeKitError.homeNotFound(homeId)
            }
            var accessories = home.accessories
            if let roomId = roomId, let roomUuid = UUID(uuidString: roomId) {
                accessories = accessories.filter { $0.room?.uniqueIdentifier == roomUuid }
            }
            result = accessories.map { AccessoryModel(from: $0, homeId: homeId, includeValues: includeValues) }
        } else {
            // No home filter - iterate through all homes and include homeId
            for home in homes {
                let hid = home.uniqueIdentifier.uuidString
                var accessories = home.accessories
                if let roomId = roomId, let roomUuid = UUID(uuidString: roomId) {
                    accessories = accessories.filter { $0.room?.uniqueIdentifier == roomUuid }
                }
                result.append(contentsOf: accessories.map { AccessoryModel(from: $0, homeId: hid, includeValues: includeValues) })
            }
        }

        return result
    }

    func getAccessory(id: String) throws -> AccessoryModel {
        guard let uuid = UUID(uuidString: id) else {
            throw HomeKitError.invalidId(id)
        }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                return AccessoryModel(from: accessory, homeId: home.uniqueIdentifier.uuidString)
            }
        }

        throw HomeKitError.accessoryNotFound(id)
    }

    /// Read all readable characteristics for an accessory to refresh cached values
    func refreshAccessoryValues(id: String) async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw HomeKitError.invalidId(id)
        }

        var accessory: HMAccessory?
        for home in homes {
            if let found = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                accessory = found
                break
            }
        }

        guard let accessory = accessory else {
            throw HomeKitError.accessoryNotFound(id)
        }

        guard accessory.isReachable else {
            return // Can't read from unreachable device
        }

        // Read all readable characteristics concurrently
        await withTaskGroup(of: Void.self) { group in
            for service in accessory.services {
                for characteristic in service.characteristics {
                    if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        group.addTask {
                            do {
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    characteristic.readValue { error in
                                        if let error = error {
                                            continuation.resume(throwing: error)
                                        } else {
                                            continuation.resume()
                                        }
                                    }
                                }
                            } catch {
                                // Ignore individual read errors
                            }
                        }
                    }
                }
            }
        }
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
        print("[HomeKit] 📝 setCharacteristic: finding characteristic \(characteristicType) on \(accessoryId.prefix(8))...")

        let (accessory, characteristic) = try await MainActor.run {
            try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
        }

        print("[HomeKit] 📝 Found accessory: \(accessory.name), characteristic: \(characteristic.characteristicType)")

        // Validate writable
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            print("[HomeKit] ❌ Characteristic not writable!")
            throw HomeKitError.characteristicNotWritable(characteristicType)
        }

        // Convert value to appropriate type
        let convertedValue = try CharacteristicMapper.convertValue(value, for: characteristic)
        print("[HomeKit] 📝 Writing value: \(value) -> converted: \(convertedValue) (type: \(type(of: convertedValue)))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(convertedValue) { error in
                if let error = error {
                    print("[HomeKit] ❌ Write failed: \(error.localizedDescription)")
                    continuation.resume(throwing: HomeKitError.writeFailed(error))
                } else {
                    print("[HomeKit] ✅ Write successful!")
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

    // MARK: - State Operations (simplified API)

    /// Sanitize a name to match server convention (spaces to underscores, lowercase)
    private func sanitizeName(_ name: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\s+", options: [])
        let range = NSRange(name.startIndex..., in: name)
        let result = pattern.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "_")
        return result.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Generate unique key: sanitized_name_shortid (last 4 chars of UUID)
    private func uniqueKey(_ name: String, id: UUID) -> String {
        let sanitized = sanitizeName(name)
        let shortId = String(id.uuidString.suffix(4)).lowercased()
        return "\(sanitized)_\(shortId)"
    }

    /// Generate unique room key
    private func roomKey(_ name: String, id: UUID) -> String {
        return uniqueKey(name, id: id)
    }

    /// Generate unique accessory key
    private func accessoryKey(_ name: String, id: UUID) -> String {
        return uniqueKey(name, id: id)
    }

    /// Generate unique group key
    private func groupKey(_ name: String, id: UUID) -> String {
        return uniqueKey(name, id: id)
    }

    /// Find an accessory by key (format: sanitized_name_shortid for both room and accessory)
    func findAccessoryByKey(roomKey: String, accessoryKey: String, homeId: String? = nil) -> HMAccessory? {
        let targetRoomKey = roomKey.lowercased()
        let targetAccKey = accessoryKey.lowercased()

        let homesToSearch: [HMHome]
        if let homeId = homeId, let uuid = UUID(uuidString: homeId),
           let home = homes.first(where: { $0.uniqueIdentifier == uuid }) {
            homesToSearch = [home]
        } else {
            homesToSearch = homes
        }

        for home in homesToSearch {
            for accessory in home.accessories {
                guard let room = accessory.room else { continue }
                let accRoomKey = self.roomKey(room.name, id: room.uniqueIdentifier)
                let accKey = self.accessoryKey(accessory.name, id: accessory.uniqueIdentifier)

                if accRoomKey == targetRoomKey && accKey == targetAccKey {
                    return accessory
                }
            }
        }
        return nil
    }

    /// Find a service group by key (format: sanitized_name_shortid)
    func findServiceGroupByKey(groupKey: String, homeId: String? = nil) -> (HMServiceGroup, HMHome)? {
        let targetKey = groupKey.lowercased()

        let homesToSearch: [HMHome]
        if let homeId = homeId, let uuid = UUID(uuidString: homeId),
           let home = homes.first(where: { $0.uniqueIdentifier == uuid }) {
            homesToSearch = [home]
        } else {
            homesToSearch = homes
        }

        for home in homesToSearch {
            for group in home.serviceGroups {
                let generatedKey = self.groupKey(group.name, id: group.uniqueIdentifier)
                if generatedKey == targetKey {
                    return (group, home)
                }
            }
        }
        return nil
    }

    /// Set state using simplified format: {room: {accessory: {prop: value}}}
    func setState(state: [String: [String: [String: Any]]], homeId: String? = nil) async throws -> (ok: Int, failed: [String]) {
        var okCount = 0
        var failed: [String] = []

        for (roomKey, accessories) in state {
            // Skip special keys
            if roomKey == "scenes" || roomKey == "groups" {
                continue
            }

            for (accKey, properties) in accessories {
                let fullKey = "\(roomKey)/\(accKey)"

                // Try to find as accessory first (using key format: name_shortid)
                if let accessory = findAccessoryByKey(roomKey: roomKey, accessoryKey: accKey, homeId: homeId) {
                    for (prop, value) in properties {
                        // Skip metadata properties
                        if prop == "type" || prop == "_settable" {
                            continue
                        }

                        do {
                            let charType = CharacteristicMapper.fromSimpleName(prop)
                            // Convert simplified values (e.g., "heat" -> 1 for hvac_mode)
                            let convertedValue = CharacteristicMapper.convertSimpleValue(value, forProperty: prop)
                            print("[HomeKit] 📝 setState: \(fullKey).\(prop) = \(value) -> \(charType)=\(convertedValue)")

                            let _ = try await setCharacteristic(
                                accessoryId: accessory.uniqueIdentifier.uuidString,
                                characteristicType: charType,
                                value: convertedValue
                            )
                            okCount += 1
                        } catch {
                            print("[HomeKit] ❌ setState failed: \(fullKey).\(prop): \(error)")
                            failed.append("\(fullKey).\(prop): \(error.localizedDescription)")
                        }
                    }
                }
                // Try as service group (using key format: name_shortid)
                else if let (group, _) = findServiceGroupByKey(groupKey: accKey, homeId: homeId) {
                    for (prop, value) in properties {
                        if prop == "type" || prop == "_settable" {
                            continue
                        }

                        do {
                            let charType = CharacteristicMapper.fromSimpleName(prop)
                            // Convert simplified values (e.g., "heat" -> 1 for hvac_mode)
                            let convertedValue = CharacteristicMapper.convertSimpleValue(value, forProperty: prop)
                            print("[HomeKit] 📝 setState (group): \(fullKey).\(prop) = \(value) -> \(charType)=\(convertedValue)")

                            let _ = try await setServiceGroupCharacteristic(
                                homeId: homeId,
                                groupId: group.uniqueIdentifier.uuidString,
                                characteristicType: charType,
                                value: convertedValue
                            )
                            okCount += 1
                        } catch {
                            print("[HomeKit] ❌ setState (group) failed: \(fullKey).\(prop): \(error)")
                            failed.append("\(fullKey).\(prop): \(error.localizedDescription)")
                        }
                    }
                } else {
                    print("[HomeKit] ⚠️ setState: \(fullKey) not found")
                    failed.append("\(fullKey): not found")
                }
            }
        }

        return (okCount, failed)
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
                // Log available characteristics for debugging
                let availableTypes = accessory.services.flatMap { $0.characteristics }.map { CharacteristicMapper.fromHomeKitType($0.characteristicType) }
                print("[HomeKit] Characteristic '\(type)' not found on \(accessory.name). Available: \(availableTypes.joined(separator: ", "))")
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

            // If we were already observing, re-observe new accessories
            if self.isObserving {
                for home in manager.homes {
                    for accessory in home.accessories {
                        self.observeAccessory(accessory)
                    }
                }
            }

            // Resume any waiting continuations
            for continuation in readyContinuations {
                continuation.resume()
            }
            readyContinuations.removeAll()

            // Refresh key characteristic values in background first (fast)
            // Then refresh info characteristics at a slower rate
            Task.detached(priority: .background) {
                await self.refreshKeyCharacteristics()
                await self.refreshInfoCharacteristics()
            }
        }
    }

    /// Important characteristic types to refresh (controls and sensors, not info)
    private static let keyCharacteristicTypes: Set<String> = [
        HMCharacteristicTypePowerState,
        HMCharacteristicTypeBrightness,
        HMCharacteristicTypeHue,
        HMCharacteristicTypeSaturation,
        HMCharacteristicTypeColorTemperature,
        HMCharacteristicTypeCurrentTemperature,
        HMCharacteristicTypeTargetTemperature,
        HMCharacteristicTypeCurrentRelativeHumidity,
        HMCharacteristicTypeTargetRelativeHumidity,
        HMCharacteristicTypeCurrentPosition,
        HMCharacteristicTypeTargetPosition,
        HMCharacteristicTypePositionState,
        HMCharacteristicTypeCurrentDoorState,
        HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeActive,
        HMCharacteristicTypeInUse,
        HMCharacteristicTypeRotationSpeed,
        HMCharacteristicTypeSwingMode,
        HMCharacteristicTypeCurrentHeatingCooling,
        HMCharacteristicTypeTargetHeatingCooling,
        HMCharacteristicTypeContactState,
        HMCharacteristicTypeMotionDetected,
        HMCharacteristicTypeOccupancyDetected,
        HMCharacteristicTypeBatteryLevel,
        HMCharacteristicTypeStatusLowBattery,
        HMCharacteristicTypeOutletInUse,
    ]

    /// Refresh only key characteristics for UI display (skips info services)
    func refreshKeyCharacteristics() async {
        let allAccessories = homes.flatMap { $0.accessories }.filter { $0.isReachable }

        // Collect all key characteristics to read
        var characteristicsToRead: [HMCharacteristic] = []
        for accessory in allAccessories {
            for service in accessory.services {
                // Skip info service - those values rarely change
                if service.serviceType == HMServiceTypeAccessoryInformation {
                    continue
                }
                for characteristic in service.characteristics {
                    if characteristic.properties.contains(HMCharacteristicPropertyReadable),
                       Self.keyCharacteristicTypes.contains(characteristic.characteristicType) {
                        characteristicsToRead.append(characteristic)
                    }
                }
            }
        }

        // Read in larger batches - HomeKit handles concurrent reads well
        let batchSize = 50
        for batch in stride(from: 0, to: characteristicsToRead.count, by: batchSize) {
            let end = min(batch + batchSize, characteristicsToRead.count)
            let batchChars = Array(characteristicsToRead[batch..<end])

            await withTaskGroup(of: Void.self) { group in
                for characteristic in batchChars {
                    group.addTask {
                        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            characteristic.readValue { error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Refresh info characteristics (manufacturer, serial, model, firmware) at a slower rate
    func refreshInfoCharacteristics() async {
        let allAccessories = homes.flatMap { $0.accessories }.filter { $0.isReachable }

        // Collect info characteristics to read
        var characteristicsToRead: [HMCharacteristic] = []
        for accessory in allAccessories {
            for service in accessory.services {
                // Only info service
                guard service.serviceType == HMServiceTypeAccessoryInformation else {
                    continue
                }
                for characteristic in service.characteristics {
                    if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        characteristicsToRead.append(characteristic)
                    }
                }
            }
        }

        print("[HomeKit] 📋 Refreshing \(characteristicsToRead.count) info characteristics...")

        // Read in smaller batches with delays between them
        let batchSize = 20
        for batch in stride(from: 0, to: characteristicsToRead.count, by: batchSize) {
            let end = min(batch + batchSize, characteristicsToRead.count)
            let batchChars = Array(characteristicsToRead[batch..<end])

            await withTaskGroup(of: Void.self) { group in
                for characteristic in batchChars {
                    group.addTask {
                        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            characteristic.readValue { error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            }

            // Small delay between batches to avoid overwhelming devices
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        print("[HomeKit] ✅ Info characteristics refresh complete")
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

// MARK: - HMAccessoryDelegate

extension HomeKitManager: HMAccessoryDelegate {
    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        let accessoryName = accessory.name
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let charType = CharacteristicMapper.fromHomeKitType(characteristic.characteristicType)
        let value = characteristic.value ?? NSNull()

        // Log the change
        print("[HomeKit] 📡 Change: \(accessoryName) → \(charType) = \(value)")

        Task { @MainActor in
            self.delegate?.characteristicDidUpdate(
                accessoryId: accessoryId,
                characteristicType: charType,
                value: value
            )
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let accessoryName = accessory.name
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let isReachable = accessory.isReachable

        // Log the change
        print("[HomeKit] 📡 Reachability: \(accessoryName) → \(isReachable ? "reachable" : "unreachable")")

        Task { @MainActor in
            self.delegate?.accessoryReachabilityDidUpdate(
                accessoryId: accessoryId,
                isReachable: isReachable
            )
        }
    }
}
