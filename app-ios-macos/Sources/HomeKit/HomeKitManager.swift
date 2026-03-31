import HomeKit
import Foundation

/// Context for event routing (subscription-based filtering)
struct AccessoryEventContext {
    let homeId: String
    let roomId: String?
    let serviceGroupIds: [String]
}

extension Notification.Name {
    static let homeKitDidBecomeReady = Notification.Name("homeKitDidBecomeReady")
}

/// Delegate to receive characteristic value change notifications
@MainActor
protocol HomeKitManagerDelegate: AnyObject {
    func characteristicDidUpdate(accessoryId: String, characteristicType: String, value: Any, context: AccessoryEventContext)
    func accessoryReachabilityDidUpdate(accessoryId: String, isReachable: Bool, context: AccessoryEventContext)
    func homesDidUpdate()
}

extension HomeKitManagerDelegate {
    func homesDidUpdate() {}
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

    /// Cached accessory UUID → event context for O(1) lookups in delegate callbacks
    private var accessoryContextCache: [UUID: AccessoryEventContext] = [:]

    override init() {
        self.homeManager = HMHomeManager()
        super.init()
        self.homeManager.delegate = self
    }

    /// Whether we're currently observing characteristic changes
    private(set) var isObserving: Bool = false

    /// Timer to auto-stop observing if no confirmation received
    private var observationTimeoutTask: Task<Void, Never>?

    /// Periodic refresh to catch missed delegate callbacks
    private var periodicRefreshTask: Task<Void, Never>?

    /// How long to wait for confirmation before stopping observation (seconds)
    private let observationTimeout: TimeInterval = 90

    /// How often to refresh key characteristics while observing (seconds)
    private let refreshInterval: TimeInterval = 60

    /// Rebuild the accessory UUID → context lookup cache from current homes.
    /// Called whenever HomeKit reports home/accessory changes.
    private func rebuildAccessoryContextCache() {
        var cache: [UUID: AccessoryEventContext] = [:]
        for home in homes {
            let homeId = home.uniqueIdentifier.uuidString
            for accessory in home.accessories {
                let roomId = accessory.room?.uniqueIdentifier.uuidString
                let accessoryServiceIds = Set(accessory.services.map { $0.uniqueIdentifier })
                var serviceGroupIds: [String] = []
                for group in home.serviceGroups {
                    let groupServiceIds = Set(group.services.map { $0.uniqueIdentifier })
                    if !accessoryServiceIds.isDisjoint(with: groupServiceIds) {
                        serviceGroupIds.append(group.uniqueIdentifier.uuidString)
                    }
                }
                cache[accessory.uniqueIdentifier] = AccessoryEventContext(
                    homeId: homeId,
                    roomId: roomId,
                    serviceGroupIds: serviceGroupIds
                )
            }
        }
        accessoryContextCache = cache
    }

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

        // Start periodic refresh to catch missed delegate callbacks
        startPeriodicRefresh()
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
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil

        guard isObserving else { return }

        let count = observedAccessories.count
        isObserving = false

        // Disable notifications and clear delegates from all observed accessories
        for home in homes {
            for accessory in home.accessories {
                if observedAccessories.contains(accessory.uniqueIdentifier) {
                    for service in accessory.services {
                        if service.serviceType == HMServiceTypeAccessoryInformation { continue }
                        for characteristic in service.characteristics {
                            if characteristic.isNotificationEnabled {
                                characteristic.enableNotification(false) { _ in }
                            }
                        }
                    }
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

        // Enable event notifications on key characteristics so HomeKit
        // actively subscribes to HAP events from the device
        for service in accessory.services {
            if service.serviceType == HMServiceTypeAccessoryInformation { continue }
            for characteristic in service.characteristics {
                if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
                   Self.keyCharacteristicTypes.contains(characteristic.characteristicType) {
                    characteristic.enableNotification(true) { _ in }
                }
            }
        }
    }

    /// Periodically refresh key characteristics and broadcast any changes.
    /// Safety net for when enableNotification-based HAP subscriptions are lost.
    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                } catch {
                    break
                }
                guard self.isObserving else { break }
                await self.refreshAndBroadcastChanges()
            }
        }
    }

    /// Re-read key characteristics and manually fire delegate events for any that changed.
    /// readValue() does NOT trigger didUpdateValueFor, so we must detect and broadcast changes ourselves.
    private func refreshAndBroadcastChanges() async {
        let allAccessories = homes.flatMap { $0.accessories }.filter { $0.isReachable }

        // Collect characteristics with their current cached values
        var toRefresh: [(characteristic: HMCharacteristic, accessory: HMAccessory, oldValue: Any?)] = []
        for accessory in allAccessories {
            for service in accessory.services {
                if service.serviceType == HMServiceTypeAccessoryInformation { continue }
                for characteristic in service.characteristics {
                    if characteristic.properties.contains(HMCharacteristicPropertyReadable),
                       Self.keyCharacteristicTypes.contains(characteristic.characteristicType) {
                        toRefresh.append((characteristic, accessory, characteristic.value))
                    }
                }
            }
        }

        guard !toRefresh.isEmpty else { return }

        // Read in batches, detect changes, and fire events
        // Keep batch size small to avoid overwhelming HomeKit devices
        let batchSize = 15
        var changedCount = 0
        for batch in stride(from: 0, to: toRefresh.count, by: batchSize) {
            let end = min(batch + batchSize, toRefresh.count)
            let batchItems = Array(toRefresh[batch..<end])

            await withTaskGroup(of: (HMAccessory, String, String, Any?, Any?)?.self) { group in
                for item in batchItems {
                    group.addTask {
                        do {
                            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                                item.characteristic.readValue { error in
                                    if let error = error { cont.resume(throwing: error) }
                                    else { cont.resume() }
                                }
                            }
                            let charType = CharacteristicMapper.fromHomeKitType(item.characteristic.characteristicType)
                            return (item.accessory, item.accessory.uniqueIdentifier.uuidString, charType, item.oldValue, item.characteristic.value)
                        } catch {
                            return nil
                        }
                    }
                }
                for await result in group {
                    guard let (accessory, accessoryId, charType, oldValue, newValue) = result else { continue }
                    if !Self.valuesEqual(oldValue, newValue) {
                        changedCount += 1
                        let value = newValue ?? NSNull()
                        if let context = findAccessoryContext(accessory) {
                            delegate?.characteristicDidUpdate(
                                accessoryId: accessoryId,
                                characteristicType: charType,
                                value: value,
                                context: context
                            )
                        }
                    }
                }
            }
        }

        if changedCount > 0 {
            print("[HomeKit] 🔄 Periodic refresh found \(changedCount) changed characteristic(s)")
        }
    }

    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a as NSObject, b as NSObject): return a.isEqual(b)
        default: return false
        }
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

    /// Set a characteristic on all services in a group (parallel execution)
    func setServiceGroupCharacteristic(homeId: String?, groupId: String, characteristicType: String, value: Any) async throws -> Int {
        print("[HomeKit] 📝 setServiceGroupCharacteristic: group=\(groupId.prefix(8))..., type=\(characteristicType), value=\(value)")

        // Find group across all homes if homeId not specified
        var targetGroup: HMServiceGroup?

        if let homeId = homeId, let homeUUID = UUID(uuidString: homeId) {
            guard let home = homes.first(where: { $0.uniqueIdentifier == homeUUID }) else {
                throw HomeKitError.homeNotFound(homeId)
            }
            if let groupUUID = UUID(uuidString: groupId) {
                targetGroup = home.serviceGroups.first(where: { $0.uniqueIdentifier == groupUUID })
            }
        } else {
            // Search all homes for the group
            if let groupUUID = UUID(uuidString: groupId) {
                for home in homes {
                    if let group = home.serviceGroups.first(where: { $0.uniqueIdentifier == groupUUID }) {
                        targetGroup = group
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

        // Build list of write tasks (service name, characteristic, converted value)
        var writeTasks: [(serviceName: String, characteristic: HMCharacteristic, convertedValue: Any)] = []
        let charType = CharacteristicMapper.toHomeKitType(characteristicType)

        // Build list of types to try (with fallbacks for power control)
        var typesToTry = [charType]
        let typeLower = characteristicType.lowercased().replacingOccurrences(of: "_", with: "")
        if typeLower == "powerstate" || typeLower == "on" {
            typesToTry.append(HMCharacteristicTypeActive)
        }
        if typeLower == "active" {
            typesToTry.append(HMCharacteristicTypePowerState)
        }

        print("[HomeKit] 📝 Looking for characteristic: '\(characteristicType)' -> trying \(typesToTry.count) types")

        for service in group.services {
            // Try each characteristic type in order
            var foundCharacteristic: HMCharacteristic?
            for typeToTry in typesToTry {
                if let char = service.characteristics.first(where: { $0.characteristicType == typeToTry }) {
                    foundCharacteristic = char
                    break
                }
            }

            if let characteristic = foundCharacteristic {
                if characteristic.properties.contains(HMCharacteristicPropertyWritable) {
                    do {
                        let convertedValue = try CharacteristicMapper.convertValue(value, for: characteristic)
                        writeTasks.append((service.name, characteristic, convertedValue))
                        print("[HomeKit] 📝 Queued write to '\(service.name)': \(value) -> \(convertedValue)")
                    } catch {
                        print("[HomeKit] ⚠️ Failed to convert value for '\(service.name)': \(error)")
                    }
                } else {
                    print("[HomeKit] ⚠️ Characteristic \(characteristicType) not writable on service '\(service.name)'")
                }
            } else {
                // Log available characteristics for debugging
                let availableTypes = service.characteristics.map { CharacteristicMapper.fromHomeKitType($0.characteristicType) }
                print("[HomeKit] ⚠️ Characteristic '\(characteristicType)' not found on service '\(service.name)'. Available: \(availableTypes.joined(separator: ", "))")
            }
        }

        print("[HomeKit] 📝 Executing \(writeTasks.count) writes in parallel...")

        // Execute all writes in parallel using TaskGroup
        let successCount = await withTaskGroup(of: Bool.self, returning: Int.self) { taskGroup in
            for (serviceName, characteristic, convertedValue) in writeTasks {
                taskGroup.addTask {
                    do {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            characteristic.writeValue(convertedValue) { error in
                                if let error = error {
                                    print("[HomeKit] ❌ Write failed for '\(serviceName)': \(error.localizedDescription)")
                                    continuation.resume(throwing: error)
                                } else {
                                    print("[HomeKit] ✅ Write successful for '\(serviceName)'")
                                    continuation.resume()
                                }
                            }
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }

            // Collect results
            var count = 0
            for await success in taskGroup {
                if success { count += 1 }
            }
            return count
        }

        print("[HomeKit] 📝 setServiceGroupCharacteristic complete: \(successCount)/\(writeTasks.count) succeeded")
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
        // Build a map of action set UUID → automation name for cross-referencing
        var actionSetToAutomation: [UUID: String] = [:]
        for trigger in home.triggers {
            for actionSet in trigger.actionSets {
                actionSetToAutomation[actionSet.uniqueIdentifier] = trigger.name
            }
        }
        return home.actionSets.map { SceneModel(from: $0, automationName: actionSetToAutomation[$0.uniqueIdentifier]) }
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

    // MARK: - Automation Operations

    func listAutomations(homeId: String) throws -> [AutomationModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.triggers.map { AutomationModel(from: $0, homeId: homeId) }
    }

    func getAutomation(automationId: String) throws -> AutomationModel {
        guard let uuid = UUID(uuidString: automationId) else {
            throw HomeKitError.invalidId(automationId)
        }
        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == uuid }) {
                return AutomationModel(from: trigger, homeId: home.uniqueIdentifier.uuidString)
            }
        }
        throw HomeKitError.automationNotFound(automationId)
    }

    func createAutomation(homeId: String, params: [String: Any]) async throws -> AutomationModel {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }

        guard let name = params["name"] as? String else {
            throw HomeKitError.invalidRequest("Missing automation name")
        }
        guard let triggerParams = params["trigger"] as? [String: Any],
              let triggerType = triggerParams["type"] as? String else {
            throw HomeKitError.invalidRequest("Missing trigger configuration")
        }
        guard let actionsParams = params["actions"] as? [[String: Any]], !actionsParams.isEmpty else {
            throw HomeKitError.invalidRequest("At least one action is required")
        }

        // 1. Create the trigger first
        let trigger: HMTrigger
        if triggerType == "timer" {
            trigger = try await createTimerTrigger(name: name, params: triggerParams)
        } else if triggerType == "event" {
            trigger = try await createEventTrigger(name: name, params: triggerParams, home: home)
        } else {
            throw HomeKitError.invalidRequest("Unknown trigger type: \(triggerType)")
        }

        // 2. Add trigger to home
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                } else {
                    continuation.resume()
                }
            }
        }

        // 3. Check if trigger has a trigger-owned action set, otherwise create one
        let actionSet: HMActionSet
        if let existingActionSet = trigger.actionSets.first {
            // Trigger already has an action set (may be trigger-owned)
            actionSet = existingActionSet
        } else {
            // No action set yet — create one via home and attach to trigger
            let newActionSet: HMActionSet = try await withCheckedThrowingContinuation { continuation in
                home.addActionSet(withName: name) { actionSet, error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                    } else if let actionSet = actionSet {
                        continuation.resume(returning: actionSet)
                    } else {
                        continuation.resume(throwing: HomeKitError.invalidRequest("Failed to create action set"))
                    }
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.addActionSet(newActionSet) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
            actionSet = newActionSet
        }

        // 4. Add characteristic write actions
        for actionParam in actionsParams {
            guard let accessoryId = actionParam["accessoryId"] as? String,
                  let characteristicType = actionParam["characteristicType"] as? String,
                  let targetValue = actionParam["targetValue"] else {
                continue
            }
            let (_, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
            let convertedValue = try CharacteristicMapper.convertValue(targetValue, for: characteristic)
            let writeAction = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: convertedValue as! NSCopying)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                actionSet.addAction(writeAction) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // 5. Enable the trigger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(true) { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                } else {
                    continuation.resume()
                }
            }
        }

        return AutomationModel(from: trigger, homeId: homeId)
    }

    private func createTimerTrigger(name: String, params: [String: Any]) async throws -> HMTimerTrigger {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let fireDate: Date
        if let fireDateStr = params["fireDate"] as? String, let parsed = formatter.date(from: fireDateStr) {
            fireDate = parsed
        } else if let hour = params["hour"] as? Int, let minute = params["minute"] as? Int {
            // Build fire date from hour/minute components (next occurrence)
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = hour
            components.minute = minute
            components.second = 0
            fireDate = Calendar.current.date(from: components) ?? Date()
        } else {
            throw HomeKitError.invalidRequest("Timer trigger requires fireDate or hour/minute")
        }

        var recurrence: DateComponents? = nil
        if let recurrenceParams = params["recurrence"] as? [String: Any] {
            var dc = DateComponents()
            if let hour = recurrenceParams["hour"] as? Int { dc.hour = hour }
            if let minute = recurrenceParams["minute"] as? Int { dc.minute = minute }
            if let day = recurrenceParams["day"] as? Int { dc.day = day }
            if let weekday = recurrenceParams["weekday"] as? Int { dc.weekday = weekday }
            if let month = recurrenceParams["month"] as? Int { dc.month = month }
            recurrence = dc
        } else if let recurrenceType = params["recurrenceType"] as? String {
            switch recurrenceType {
            case "daily":
                var dc = DateComponents()
                dc.day = 1
                recurrence = dc
            case "weekly":
                var dc = DateComponents()
                dc.weekOfYear = 1
                recurrence = dc
            default:
                break  // "once" = nil recurrence
            }
        }

        let timeZone: TimeZone?
        if let tzId = params["timeZone"] as? String {
            timeZone = TimeZone(identifier: tzId)
        } else {
            timeZone = .current
        }

        return HMTimerTrigger(
            name: name,
            fireDate: fireDate,
            timeZone: timeZone,
            recurrence: recurrence,
            recurrenceCalendar: nil
        )
    }

    private func parseEvents(from eventsParams: [[String: Any]]) throws -> [HMEvent] {
        var events: [HMEvent] = []
        for eventParam in eventsParams {
            guard let eventType = eventParam["type"] as? String else { continue }

            switch eventType {
            case "characteristic":
                guard let accessoryId = eventParam["accessoryId"] as? String,
                      let characteristicType = eventParam["characteristicType"] as? String else {
                    throw HomeKitError.invalidRequest("Characteristic event requires accessoryId and characteristicType")
                }
                let (_, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
                let triggerValue: NSCopying?
                if let val = eventParam["triggerValue"] {
                    triggerValue = try CharacteristicMapper.convertValue(val, for: characteristic) as? NSCopying
                } else {
                    triggerValue = nil
                }
                events.append(HMCharacteristicEvent(characteristic: characteristic, triggerValue: triggerValue))

            case "significantTime":
                guard let sigEvent = eventParam["significantEvent"] as? String else {
                    throw HomeKitError.invalidRequest("Significant time event requires significantEvent")
                }
                let hmEvent: HMSignificantEvent = sigEvent == "sunrise" ? .sunrise : .sunset
                var offset: DateComponents? = nil
                if let offsetMinutes = eventParam["offsetMinutes"] as? Int {
                    var dc = DateComponents()
                    dc.minute = offsetMinutes
                    offset = dc
                }
                events.append(HMSignificantTimeEvent(significantEvent: hmEvent, offset: offset))

            case "calendar":
                var dc = DateComponents()
                if let comps = eventParam["calendarComponents"] as? [String: Int] {
                    if let hour = comps["hour"] { dc.hour = hour }
                    if let minute = comps["minute"] { dc.minute = minute }
                    if let day = comps["day"] { dc.day = day }
                    if let month = comps["month"] { dc.month = month }
                    if let weekday = comps["weekday"] { dc.weekday = weekday }
                }
                events.append(HMCalendarEvent(fire: dc))

            case "duration":
                guard let seconds = eventParam["durationSeconds"] as? Double else {
                    throw HomeKitError.invalidRequest("Duration event requires durationSeconds")
                }
                events.append(HMDurationEvent(duration: seconds))

            default:
                throw HomeKitError.invalidRequest("Unsupported event type for creation: \(eventType)")
            }
        }
        return events
    }

    private func parseRecurrences(from params: [String: Any]) -> [DateComponents]? {
        guard let recurrencesParams = params["recurrences"] as? [[String: Int]] else { return nil }
        let result = recurrencesParams.map { dict -> DateComponents in
            var dc = DateComponents()
            if let hour = dict["hour"] { dc.hour = hour }
            if let minute = dict["minute"] { dc.minute = minute }
            if let day = dict["day"] { dc.day = day }
            if let weekday = dict["weekday"] { dc.weekday = weekday }
            if let month = dict["month"] { dc.month = month }
            if let weekOfYear = dict["weekOfYear"] { dc.weekOfYear = weekOfYear }
            return dc
        }
        return result.isEmpty ? nil : result
    }

    private func createEventTrigger(name: String, params: [String: Any], home: HMHome) async throws -> HMEventTrigger {
        guard let eventsParams = params["events"] as? [[String: Any]], !eventsParams.isEmpty else {
            throw HomeKitError.invalidRequest("Event trigger requires at least one event")
        }

        let events = try parseEvents(from: eventsParams)

        // Parse end events (events that deactivate the trigger)
        var endEvents: [HMEvent]? = nil
        if let endEventsParams = params["endEvents"] as? [[String: Any]], !endEventsParams.isEmpty {
            endEvents = try parseEvents(from: endEventsParams)
        }

        // Parse recurrences
        let recurrences = parseRecurrences(from: params)

        // Build predicate from conditions if provided
        var predicates: [NSPredicate] = []
        if let conditionsParams = params["conditions"] as? [[String: Any]] {
            for condParam in conditionsParams {
                guard let condType = condParam["type"] as? String else { continue }
                if condType == "characteristic" {
                    guard let accessoryId = condParam["accessoryId"] as? String,
                          let characteristicType = condParam["characteristicType"] as? String,
                          let value = condParam["value"] else { continue }
                    let (_, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
                    let convertedValue = try CharacteristicMapper.convertValue(value, for: characteristic)
                    let predicate = HMEventTrigger.predicateForEvaluatingTrigger(
                        characteristic,
                        relatedBy: .equalTo,
                        toValue: convertedValue
                    )
                    predicates.append(predicate)
                }
            }
        }

        let predicate: NSPredicate?
        if predicates.isEmpty {
            predicate = nil
        } else if predicates.count == 1 {
            predicate = predicates[0]
        } else {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        // Use the extended init with endEvents and recurrences (iOS 11+)
        let trigger = HMEventTrigger(
            name: name,
            events: events,
            end: endEvents,
            recurrences: recurrences,
            predicate: predicate
        )

        // Set executeOnce if requested
        if let executeOnce = params["executeOnce"] as? Bool, executeOnce {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.updateExecuteOnce(executeOnce) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationCreationFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        return trigger
    }

    func updateAutomation(automationId: String, params: [String: Any]) async throws -> AutomationModel {
        guard let uuid = UUID(uuidString: automationId) else {
            throw HomeKitError.invalidId(automationId)
        }

        var foundTrigger: HMTrigger?
        var foundHome: HMHome?
        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == uuid }) {
                foundTrigger = trigger
                foundHome = home
                break
            }
        }
        guard let trigger = foundTrigger, let home = foundHome else {
            throw HomeKitError.automationNotFound(automationId)
        }

        // Update name if provided
        if let newName = params["name"] as? String, newName != trigger.name {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.updateName(newName) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // Update enabled state if provided
        if let enabled = params["enabled"] as? Bool, enabled != trigger.isEnabled {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                trigger.enable(enabled) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        // Update actions if provided
        if let actionsParams = params["actions"] as? [[String: Any]] {
            // Remove existing action sets and their actions
            for actionSet in trigger.actionSets {
                for action in actionSet.actions {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        actionSet.removeAction(action) { error in
                            if let error = error {
                                continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }

            // If there are existing action sets, add new actions to the first one
            // Otherwise create a new action set
            let actionSet: HMActionSet
            if let existing = trigger.actionSets.first {
                actionSet = existing
            } else {
                let newActionSet: HMActionSet = try await withCheckedThrowingContinuation { continuation in
                    home.addActionSet(withName: "Homecast: \(trigger.name)") { as_, error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                        } else if let as_ = as_ {
                            continuation.resume(returning: as_)
                        } else {
                            continuation.resume(throwing: HomeKitError.invalidRequest("Failed to create action set"))
                        }
                    }
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    trigger.addActionSet(newActionSet) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                actionSet = newActionSet
            }

            // Add new actions
            for actionParam in actionsParams {
                guard let accessoryId = actionParam["accessoryId"] as? String,
                      let characteristicType = actionParam["characteristicType"] as? String,
                      let targetValue = actionParam["targetValue"] else { continue }
                let (_, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)
                let convertedValue = try CharacteristicMapper.convertValue(targetValue, for: characteristic)
                let writeAction = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: convertedValue as! NSCopying)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    actionSet.addAction(writeAction) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        }

        // If trigger params changed (fire date, events, etc.), we need to delete and recreate
        if params["trigger"] != nil {
            let homeId = home.uniqueIdentifier.uuidString
            // Save current action sets
            let currentActionSets = trigger.actionSets

            // Delete old trigger
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                home.removeTrigger(trigger) { error in
                    if let error = error {
                        continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }

            // Recreate with merged params (keep existing values where not overridden)
            var createParams = params
            if createParams["name"] == nil { createParams["name"] = trigger.name }
            if createParams["actions"] == nil {
                // Reconstruct actions from saved action sets
                var actionsArr: [[String: Any]] = []
                for actionSet in currentActionSets {
                    for action in actionSet.actions {
                        if let writeAction = action as? HMCharacteristicWriteAction<NSCopying> {
                            let char = writeAction.characteristic
                            actionsArr.append([
                                "accessoryId": char.service?.accessory?.uniqueIdentifier.uuidString ?? "",
                                "characteristicType": CharacteristicMapper.fromHomeKitType(char.characteristicType),
                                "targetValue": writeAction.targetValue
                            ])
                        }
                    }
                }
                createParams["actions"] = actionsArr
            }
            return try await createAutomation(homeId: homeId, params: createParams)
        }

        return AutomationModel(from: trigger, homeId: home.uniqueIdentifier.uuidString)
    }

    func deleteAutomation(automationId: String) async throws {
        guard let uuid = UUID(uuidString: automationId) else {
            throw HomeKitError.invalidId(automationId)
        }

        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == uuid }) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationDeletionFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return
            }
        }

        throw HomeKitError.automationNotFound(automationId)
    }

    func setAutomationEnabled(automationId: String, enabled: Bool) async throws -> AutomationModel {
        guard let uuid = UUID(uuidString: automationId) else {
            throw HomeKitError.invalidId(automationId)
        }

        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == uuid }) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    trigger.enable(enabled) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationUpdateFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return AutomationModel(from: trigger, homeId: home.uniqueIdentifier.uuidString)
            }
        }

        throw HomeKitError.automationNotFound(automationId)
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
    /// Writes are executed concurrently via TaskGroup for minimum latency.
    func setState(state: [String: [String: [String: Any]]], homeId: String? = nil) async throws -> (ok: Int, failed: [String]) {
        // Collect all write operations first, then execute concurrently
        struct WriteOp: @unchecked Sendable {
            let label: String
            let accessoryId: String?
            let groupId: String?
            let charType: String
            let value: Any
            let homeId: String?

            // Sendable-safe initializer (Any is not Sendable, but we only pass JSON primitives)
            nonisolated init(label: String, accessoryId: String? = nil, groupId: String? = nil, charType: String, value: Any, homeId: String? = nil) {
                self.label = label
                self.accessoryId = accessoryId
                self.groupId = groupId
                self.charType = charType
                self.value = value
                self.homeId = homeId
            }
        }

        var ops: [WriteOp] = []
        var notFound: [String] = []

        for (roomKey, accessories) in state {
            if roomKey == "scenes" || roomKey == "groups" {
                continue
            }

            for (accKey, properties) in accessories {
                let fullKey = "\(roomKey)/\(accKey)"

                if let accessory = findAccessoryByKey(roomKey: roomKey, accessoryKey: accKey, homeId: homeId) {
                    for (prop, value) in properties {
                        if prop == "type" || prop == "_settable" { continue }
                        let charType = CharacteristicMapper.fromSimpleName(prop)
                        let convertedValue = CharacteristicMapper.convertSimpleValue(value, forProperty: prop)
                        print("[HomeKit] 📝 setState: \(fullKey).\(prop) = \(value) -> \(charType)=\(convertedValue)")
                        ops.append(WriteOp(label: "\(fullKey).\(prop)", accessoryId: accessory.uniqueIdentifier.uuidString, charType: charType, value: convertedValue))
                    }
                } else if let (group, _) = findServiceGroupByKey(groupKey: accKey, homeId: homeId) {
                    for (prop, value) in properties {
                        if prop == "type" || prop == "_settable" { continue }
                        let charType = CharacteristicMapper.fromSimpleName(prop)
                        let convertedValue = CharacteristicMapper.convertSimpleValue(value, forProperty: prop)
                        print("[HomeKit] 📝 setState (group): \(fullKey).\(prop) = \(value) -> \(charType)=\(convertedValue)")
                        ops.append(WriteOp(label: "\(fullKey).\(prop)", groupId: group.uniqueIdentifier.uuidString, charType: charType, value: convertedValue, homeId: homeId))
                    }
                } else {
                    print("[HomeKit] ⚠️ setState: \(fullKey) not found")
                    notFound.append("\(fullKey): not found")
                }
            }
        }

        // Execute all writes concurrently
        let results: [(Bool, String?)] = await withTaskGroup(of: (Bool, String?).self, returning: [(Bool, String?)].self) { group in
            for op in ops {
                group.addTask {
                    do {
                        if let accessoryId = op.accessoryId {
                            let _ = try await self.setCharacteristic(accessoryId: accessoryId, characteristicType: op.charType, value: op.value)
                        } else if let groupId = op.groupId {
                            let _ = try await self.setServiceGroupCharacteristic(homeId: op.homeId, groupId: groupId, characteristicType: op.charType, value: op.value)
                        }
                        return (true, nil)
                    } catch {
                        print("[HomeKit] ❌ setState failed: \(op.label): \(error)")
                        return (false, "\(op.label): \(error.localizedDescription)")
                    }
                }
            }
            var collected: [(Bool, String?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let okCount = results.filter { $0.0 }.count
        let failed = notFound + results.compactMap { $0.1 }
        return (okCount, failed)
    }

    // MARK: - Private Helpers

    private func findCharacteristic(accessoryId: String, type: String) throws -> (HMAccessory, HMCharacteristic) {
        guard let uuid = UUID(uuidString: accessoryId) else {
            throw HomeKitError.invalidId(accessoryId)
        }

        let characteristicType = CharacteristicMapper.toHomeKitType(type)

        // Build list of types to try (with fallbacks for power control)
        var typesToTry = [characteristicType]

        // For power control, also try Active as fallback (for heaters, coolers, air purifiers, etc.)
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")
        if typeLower == "powerstate" || typeLower == "on" {
            typesToTry.append(HMCharacteristicTypeActive)
        }
        // Also try PowerState if Active was requested
        if typeLower == "active" {
            typesToTry.append(HMCharacteristicTypePowerState)
        }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                // Try each type in order
                for typeToTry in typesToTry {
                    for service in accessory.services {
                        if let characteristic = service.characteristics.first(where: { $0.characteristicType == typeToTry }) {
                            return (accessory, characteristic)
                        }
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
            self.rebuildAccessoryContextCache()

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

            // Notify menu bar plugin that HomeKit data is now available for preloading
            NotificationCenter.default.post(name: .homeKitDidBecomeReady, object: nil)

            // Notify delegate that homes list changed (for relay → server propagation)
            self.delegate?.homesDidUpdate()

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
        HMCharacteristicTypeHeatingThreshold,
        HMCharacteristicTypeCoolingThreshold,
        // Heater/Cooler specific (no HM constants, use UUIDs)
        "000000B1-0000-1000-8000-0026BB765291", // current_heater_cooler_state
        "000000B2-0000-1000-8000-0026BB765291", // target_heater_cooler_state
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
    /// Find the home, room, and service groups containing an accessory (O(1) via cache)
    private func findAccessoryContext(_ accessory: HMAccessory) -> AccessoryEventContext? {
        return accessoryContextCache[accessory.uniqueIdentifier]
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        let accessoryName = accessory.name
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let charType = CharacteristicMapper.fromHomeKitType(characteristic.characteristicType)
        let value = characteristic.value ?? NSNull()

        // Log the change
        print("[HomeKit] 📡 Change: \(accessoryName) → \(charType) = \(value)")

        Task { @MainActor in
            guard let context = self.findAccessoryContext(accessory) else {
                print("[HomeKit] ⚠️ Could not find context for accessory \(accessoryName)")
                return
            }
            self.delegate?.characteristicDidUpdate(
                accessoryId: accessoryId,
                characteristicType: charType,
                value: value,
                context: context
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
            guard let context = self.findAccessoryContext(accessory) else {
                print("[HomeKit] ⚠️ Could not find context for accessory \(accessoryName)")
                return
            }
            self.delegate?.accessoryReachabilityDidUpdate(
                accessoryId: accessoryId,
                isReachable: isReachable,
                context: context
            )
        }
    }
}
