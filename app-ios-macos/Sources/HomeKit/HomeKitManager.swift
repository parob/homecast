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

    /// The authorization HomeKit reports *right now*.
    ///
    /// `authorizationStatus` above is a cache that only moves when
    /// `didUpdateAuthorizationStatus` fires — and it does not fire when nothing
    /// changed, which is exactly the common case: permission was granted on a
    /// previous launch, so this launch sees no change and keeps the seeded
    /// `.determined`. Reading the manager directly is the only way to get the
    /// truth on a cold start.
    var liveAuthorizationStatus: HMHomeManagerAuthorizationStatus {
        homeManager.authorizationStatus
    }

    /// Whether this device can actually read home data.
    ///
    /// Beware `HMHomeManagerAuthorizationStatusDetermined`: Apple's own header
    /// says it "indicates the user has **not yet** made a choice", so the flag
    /// named `.determined` means *un*determined. Reading it as "has decided"
    /// gets the logic exactly backwards.
    ///
    /// Homes are the tiebreaker rather than the flags: if HomeKit has handed us
    /// a home, we are authorized, whatever the bits say. That keeps a slow or
    /// unreported status from being misreported as a refusal.
    var isHomeDataAuthorized: Bool {
        if !homeManager.homes.isEmpty { return true }
        return homeManager.authorizationStatus.contains(.authorized)
    }

    /// Delegate for characteristic change notifications
    weak var delegate: HomeKitManagerDelegate?

    /// Track which accessories we've set ourselves as delegate for
    private var observedAccessories: Set<UUID> = []

    /// Cached accessory UUID → event context for O(1) lookups in delegate callbacks
    private var accessoryContextCache: [UUID: AccessoryEventContext] = [:]

    /// Last-seen timestamps per accessory UUID, updated on successful characteristic reads.
    /// Used to override a stale `HMAccessory.isReachable == false` when we have recent evidence
    /// the device is actually responsive. HomeKit's reachability bit can get stuck after a transient
    /// failure (notably on WiFi plugs like Meross) — if we just read a value back, the device is up.
    private var lastSeenAt: [UUID: Date] = [:]

    /// Treat as reachable if HomeKit says so OR we successfully read from it within this window.
    private let reachabilityGracePeriod: TimeInterval = 120

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

    /// A one-off catch-up pass, run when a client attaches. See
    /// `scheduleCatchUpRefresh()` for why that moment in particular.
    private var catchUpRefreshTask: Task<Void, Never>?

    /// When the last full key-characteristic pass finished, and whether one is
    /// running now. A pass costs one HAP read per key characteristic on every
    /// accessory, so the three things that can trigger it — launch, a client
    /// attaching, the 60s timer — have to coalesce rather than stack up.
    private var lastFullRefreshAt: Date?
    private var isRefreshing = false

    /// How many bulk writes are in flight.
    ///
    /// The periodic refresh reads the same HomeKit stack a write goes out on,
    /// and the two compete: this codebase already records twelve reads racing
    /// the group write that triggered them until the write timed out. A bulk
    /// write is that hazard at two hundred accessories, so refreshing stands
    /// aside while one is travelling — including mid-pass, because a refresh
    /// that started first would otherwise read straight through it.
    ///
    /// A counter rather than a flag: two batches can overlap, and the second
    /// finishing must not re-open the door on the first.
    private var bulkWritesInFlight = 0

    /// A client attaching this soon after a completed pass gets that pass's
    /// result instead of provoking another one.
    private let catchUpMinInterval: TimeInterval = 15

    /// When a client last confirmed it is listening, and how long a gap in that
    /// counts as "this process was not running". Clients send every 30s.
    private var lastKeepAliveAt: Date?
    private let keepAliveGapTolerance: TimeInterval = 120

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

        // Catch up on whatever happened while nobody was watching.
        //
        // Deliberately before the `isObserving` guard: this fires on every
        // client attach, including the second one and including a re-arm after
        // an iOS suspension, and those are precisely the cases where we are
        // already observing but our picture of the home is old.
        scheduleCatchUpRefresh()

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

        // The keep-alive doubles as a liveness signal for *us*. Clients send it
        // every 30s, so a much longer gap means this process was not running:
        // a slept Mac, a backgrounded iPhone. Everything that happened in the
        // gap happened without us watching, which is the relaunch case wearing
        // a different hat — and the timeout task that would normally have
        // noticed was suspended right along with everything else.
        let now = Date()
        if let last = lastKeepAliveAt, now.timeIntervalSince(last) > keepAliveGapTolerance {
            print("[HomeKit] ⏳ \(Int(now.timeIntervalSince(last)))s since the last keep-alive — catching up")
            scheduleCatchUpRefresh()
        }
        lastKeepAliveAt = now

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

    /// Re-read everything once, now, because a client just started listening.
    ///
    /// HomeKit only tells us about changes while we are subscribed, and we are
    /// only subscribed while the app is running. A light switched off in the
    /// Apple Home app — or by hand, or by a HomeKit automation — while Homecast
    /// was closed therefore produces no event we will ever see: on the next
    /// launch HomeKit simply hands us the new value as if it had always been so.
    ///
    /// Detecting that means re-reading and comparing, and *when* we do it is the
    /// whole difficulty. Reading in the background at launch is too early: it
    /// corrects HomeKit's own cache in silence, and once corrected the
    /// difference is gone for good — the 60s periodic pass then compares the new
    /// value against itself, finds nothing, and a client that fetched the
    /// accessory list a moment earlier keeps the old value it was handed for a
    /// further five minutes.
    ///
    /// A client attaching is the moment that cannot be too early: it is by
    /// definition after that client's own view was formed, and a relaunch, a
    /// foreground and a second browser all look like it from here.
    private func scheduleCatchUpRefresh() {
        guard catchUpRefreshTask == nil else { return }
        if let last = lastFullRefreshAt, Date().timeIntervalSince(last) < catchUpMinInterval { return }

        catchUpRefreshTask = Task { @MainActor in
            defer { self.catchUpRefreshTask = nil }
            // Wait out a pass already in flight rather than dropping ours — the
            // startup fill is the likeliest thing to be running when the first
            // client of a launch attaches, and this pass is the entire reason
            // that client will see the truth.
            while self.isRefreshing {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Bigger batches than the periodic poll: this one is racing the
            // first screen, the same way the startup read used to.
            await self.refreshAndBroadcastChanges(batchSize: 50, label: "Catch-up refresh")
        }
    }

    /// Periodically refresh key characteristics and broadcast any changes.
    /// Safety net for when enableNotification-based HAP subscriptions are lost.
    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor in
            var cycleCount = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                } catch {
                    break
                }
                guard self.isObserving else { break }
                await self.refreshAndBroadcastChanges()

                // Every 3rd cycle (~3 min), prod unreachable accessories by re-subscribing
                // to HAP event notifications. This forces HomeKit to attempt a new connection
                // to the device — the same nudge that toggling in Apple Home provides.
                cycleCount += 1
                if cycleCount % 3 == 0 {
                    await self.probeUnreachableAccessories()
                }
            }
        }
    }

    /// Re-subscribe to event notifications on unreachable accessories.
    /// enableNotification(true) forces HomeKit to attempt a fresh HAP connection;
    /// if it succeeds, HomeKit flips isReachable → true and fires the delegate.
    private func probeUnreachableAccessories() async {
        guard bulkWritesInFlight == 0 else { return }
        let unreachable = homes.flatMap { $0.accessories }.filter { !$0.isReachable }
        guard !unreachable.isEmpty else { return }

        var probed = 0
        for accessory in unreachable {
            for service in accessory.services {
                if service.serviceType == HMServiceTypeAccessoryInformation { continue }
                for characteristic in service.characteristics {
                    if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
                       Self.keyCharacteristicTypes.contains(characteristic.characteristicType) {
                        characteristic.enableNotification(true) { _ in }
                        probed += 1
                    }
                }
            }
        }
        if probed > 0 {
            print("[HomeKit] 🔍 Probed \(unreachable.count) unreachable accessor(y|ies) (\(probed) notification subscriptions)")
        }
    }

    /// Re-read key characteristics and manually fire delegate events for any that changed.
    /// readValue() does NOT trigger didUpdateValueFor, so we must detect and broadcast changes ourselves.
    ///
    /// We deliberately do NOT filter by `isReachable` here: HMAccessory.isReachable can be stale
    /// (devices HomeKit last failed to reach stay flagged as unreachable even after they recover).
    /// Probing them lets HomeKit re-establish contact and fire accessoryDidUpdateReachability.
    /// Reads to genuinely-offline devices fail fast and are swallowed by `try?` below.
    ///
    /// - Parameters:
    ///   - batchSize: how many reads to have in flight at once. Small for the
    ///     background poll so it doesn't crowd out a user's tap; larger when
    ///     somebody is waiting on the result.
    ///   - onlyUnread: restrict to characteristics HomeKit has no cached value
    ///     for at all. Those are the only ones safe to read at launch, because
    ///     reading them cannot destroy evidence of a change nobody has seen —
    ///     see `refreshKeyCharacteristics()`.
    ///   - label: what to call this pass in the log.
    @discardableResult
    private func refreshAndBroadcastChanges(
        batchSize: Int = 15,
        onlyUnread: Bool = false,
        label: String = "Periodic refresh"
    ) async -> Int {
        guard !isRefreshing else { return 0 }
        guard bulkWritesInFlight == 0 else { return 0 }
        isRefreshing = true
        defer {
            isRefreshing = false
            // A partial pass must not suppress the catch-up that follows it.
            if !onlyUnread { lastFullRefreshAt = Date() }
        }

        let allAccessories = homes.flatMap { $0.accessories }

        // Collect characteristics with their current cached values
        var toRefresh: [(characteristic: HMCharacteristic, accessory: HMAccessory, oldValue: Any?)] = []
        for accessory in allAccessories {
            for service in accessory.services {
                if service.serviceType == HMServiceTypeAccessoryInformation { continue }
                for characteristic in service.characteristics {
                    if onlyUnread && characteristic.value != nil { continue }
                    if characteristic.properties.contains(HMCharacteristicPropertyReadable),
                       Self.keyCharacteristicTypes.contains(characteristic.characteristicType) {
                        toRefresh.append((characteristic, accessory, characteristic.value))
                    }
                }
            }
        }

        guard !toRefresh.isEmpty else { return 0 }

        // Read in batches, detect changes, and fire events.
        // Batches keep us from overwhelming HomeKit devices — see `batchSize`.
        var changedCount = 0
        for batch in stride(from: 0, to: toRefresh.count, by: batchSize) {
            // A write started while this pass was draining. Reads are a safety
            // net; the write is what the user is waiting for.
            if bulkWritesInFlight > 0 {
                print("[HomeKit] ⏸️ \(label) yielding to a bulk write in flight")
                break
            }
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
                    // Successful read — record evidence of liveness (may flip effective reachability
                    // from false → true and fire the delegate if HomeKit still reports unreachable).
                    recordSuccessfulRead(accessory)
                    guard !Self.valuesEqual(oldValue, newValue) else { continue }

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

        // Diagnostic: report refresh outcome including per-accessory read success, so we can
        // tell reachability-override failures apart from missed-broadcast failures.
        let attemptedAccessories = Set(toRefresh.map { $0.accessory.uniqueIdentifier })
        let succeededAccessories = Set(lastSeenAt.compactMap { (uuid, seen) -> UUID? in
            attemptedAccessories.contains(uuid) && Date().timeIntervalSince(seen) < 5 ? uuid : nil
        })
        let failedAccessories = attemptedAccessories.subtracting(succeededAccessories)
        if !failedAccessories.isEmpty {
            let failedNames = failedAccessories.compactMap { uuid in
                homes.flatMap { $0.accessories }.first(where: { $0.uniqueIdentifier == uuid })?.name
            }
            print("[HomeKit] 🔴 Refresh: \(failedAccessories.count) accessor(y|ies) had ALL reads fail → \(failedNames.prefix(5).joined(separator: ", "))")
        }
        if changedCount > 0 {
            print("[HomeKit] 🔄 \(label) found \(changedCount) changed characteristic(s) across \(succeededAccessories.count)/\(attemptedAccessories.count) responsive accessories")
        } else {
            print("[HomeKit] ✓ \(label): \(succeededAccessories.count)/\(attemptedAccessories.count) accessories responded, no changes")
        }
        return changedCount
    }

    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a as NSObject, b as NSObject): return a.isEqual(b)
        default: return false
        }
    }

    /// Effective reachability: trust HomeKit when true, fall back to recent successful-read
    /// evidence when HomeKit reports false (its bit is notoriously stale for WiFi plugs).
    func isEffectivelyReachable(_ accessory: HMAccessory) -> Bool {
        if accessory.isReachable { return true }
        if let seen = lastSeenAt[accessory.uniqueIdentifier],
           Date().timeIntervalSince(seen) < reachabilityGracePeriod {
            return true
        }
        return false
    }

    /// Record a successful characteristic read. If this flips the effective reachability
    /// from false → true (i.e. HomeKit still says unreachable but we just heard from the
    /// device), fire the delegate so the UI updates without waiting for HomeKit to notice.
    private func recordSuccessfulRead(_ accessory: HMAccessory) {
        let uuid = accessory.uniqueIdentifier
        let wasEffectivelyReachable = isEffectivelyReachable(accessory)
        lastSeenAt[uuid] = Date()
        if !accessory.isReachable && !wasEffectivelyReachable {
            print("[HomeKit] 🟢 Reachability override: \(accessory.name) — HomeKit says unreachable but we just read a value; reporting reachable")
            if let context = findAccessoryContext(accessory) {
                delegate?.accessoryReachabilityDidUpdate(
                    accessoryId: uuid.uuidString,
                    isReachable: true,
                    context: context
                )
            } else {
                print("[HomeKit] ⚠️ No context found for \(accessory.name); cannot broadcast reachability override")
            }
        }
    }

    /// How long any one bridge call will wait for HomeKit to load its homes.
    ///
    /// Generous, because a cold HomeKit on a large home genuinely takes
    /// seconds — but finite, because the alternative is worse (see below).
    static let readyTimeout: TimeInterval = 20

    /// Wait for HomeKit to be ready (homes loaded), giving up after
    /// `readyTimeout`. Returns whether it actually became ready.
    ///
    /// This used to await a continuation with no deadline, which was safe only
    /// because the Mac relay's HomeKit always answers eventually. It is not
    /// safe on iPhone: if the user declines Home access,
    /// `homeManagerDidUpdateHomes` never fires, the continuation never
    /// resolves, and every bridge call hangs forever. The wedge watchdog reads
    /// that as a frozen WebView and reloads the page — on a loop, out from
    /// under whatever the user was doing.
    ///
    /// Giving up instead lets the call fail as an ordinary HomeKit error
    /// (`homeNotFound`, or an empty home list), which the web app can render
    /// as a calm empty state.
    ///
    /// Polls rather than racing the continuation against a timer: a race would
    /// leave the stored continuation dangling when the deadline won, and
    /// resuming it later would trap.
    @discardableResult
    func waitForReady() async -> Bool {
        if isReady { return true }

        let deadline = Date().addingTimeInterval(HomeKitManager.readyTimeout)
        while !isReady && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !isReady {
            print("[HomeKit] ⚠️ Not ready after \(Int(HomeKitManager.readyTimeout))s (authorization: \(authorizationStatus.rawValue)) — proceeding anyway")
        }
        return isReady
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

    /// Rooms in a home, including the default room.
    ///
    /// `home.rooms` deliberately excludes `roomForEntireHome()`, but accessories
    /// assigned to it still report its identifier as their `roomId`. Every
    /// caller joins accessories to rooms on that id, so leaving it out left
    /// those accessories pointing at a room nobody could resolve: they showed as
    /// "Unknown Room" in REST and got hoisted to the home's top level in MQTT.
    /// It is a real room with a real name — Apple just keeps it out of the list.
    ///
    /// Appended last so the user's own rooms keep their existing order.
    func listRooms(homeId: String) throws -> [RoomModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        var rooms = home.rooms.map { RoomModel(from: $0) }
        let defaultRoom = home.roomForEntireHome()
        if !rooms.contains(where: { $0.id == defaultRoom.uniqueIdentifier.uuidString }) {
            rooms.append(RoomModel(from: defaultRoom, isDefault: true))
        }
        return rooms
    }

    /// Create a room. Needs no accessory — used for the Homecast enrollment
    /// code challenge (a named, visible room carrying the verification code).
    func createRoom(homeId: String, name: String) async throws -> RoomModel {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        let room: HMRoom = try await withCheckedThrowingContinuation { continuation in
            home.addRoom(withName: name) { room, error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.invalidRequest("Failed to add room: \(error.localizedDescription)"))
                } else if let room = room {
                    continuation.resume(returning: room)
                } else {
                    continuation.resume(throwing: HomeKitError.invalidRequest("Failed to add room"))
                }
            }
        }
        return RoomModel(from: room)
    }

    /// Delete a room by ID. Only removes rooms with no accessories to reassign
    /// (the challenge room is always empty).
    func deleteRoom(homeId: String, roomId: String) async throws {
        guard let hUuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == hUuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        guard let rUuid = UUID(uuidString: roomId),
              let room = home.rooms.first(where: { $0.uniqueIdentifier == rUuid }) else {
            throw HomeKitError.invalidId(roomId)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeRoom(room) { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.invalidRequest("Failed to remove room: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Zone Operations

    func listZones(homeId: String) throws -> [ZoneModel] {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        return home.zones.map { ZoneModel(from: $0) }
    }

    // MARK: - Characteristic Writes

    /// Ceiling for a single HomeKit write. HMCharacteristic.writeValue's
    /// completion handler can simply never fire for an unreachable or wedged
    /// accessory, and an unbounded await there holds the whole relay request
    /// open until the cloud gives up at 30s — so one dead bulb stalls the
    /// entire group it belongs to, and the client sees a timeout rather than
    /// the lights that did respond.
    /// `nonisolated` so the write helper below (which must run off the main
    /// actor) can read it without hopping back — required under Swift 6.
    nonisolated static let writeTimeoutSeconds: Double = 10.0

    /// The per-write bound inside a *bulk* write.
    ///
    /// The same 10s as a single write, and deliberately so: an accessory that
    /// is merely slow deserves the same patience whether it was written on its
    /// own or alongside two hundred others.
    ///
    /// This was briefly 7s, to leave room for the answer to beat a cloud
    /// ceiling that does not exist on this path. The web client's relay route
    /// calls `route_request` with no timeout argument, so it takes the 30s
    /// default; the 10s figure belongs to the identity code's own
    /// `accessories.list` calls. There was never a race to lose.
    ///
    /// Every timer starts together — the whole batch is dispatched at once —
    /// so this bounds the batch, not merely each write in it.
    nonisolated static let bulkWriteTimeoutSeconds: Double = 10.0

    /// The bound for an accessory HomeKit already reports unreachable.
    ///
    /// A Hue bulb switched off at the wall cannot answer, and waiting the full
    /// ten seconds to be told so is most of what makes "All lights" feel slow:
    /// five dead bulbs hold the whole batch open long after the other two
    /// hundred have landed.
    ///
    /// Still attempted, and that is the point of a short bound rather than a
    /// skip — `isReachable` goes stale, and a bulb that is actually fine must
    /// not be silently dropped from "all lights off". Two seconds is long
    /// enough for one that was only marked down in error to answer, and short
    /// enough that the ones which are really gone stop being the slowest thing
    /// in the house.
    nonisolated static let unreachableWriteTimeoutSeconds: Double = 2.0

    /// Write a characteristic, giving up after `seconds`. Returns false on
    /// write failure or timeout.
    ///
    /// The underlying HomeKit write is deliberately left in flight — it can't
    /// be cancelled, and in practice it often still lands once the accessory
    /// answers. Bounding the *wait* is the point: it keeps one unresponsive
    /// device from holding up every other write in the batch.
    ///
    /// `quiet` drops the per-write success line. A bulk write of two hundred
    /// accessories would otherwise emit two hundred log lines that all say the
    /// same thing, through one stdio lock, while the writes they describe are
    /// trying to go out together. Failures are still printed either way: they
    /// are rare and they are the ones worth reading.
    nonisolated static func writeValue(
        _ characteristic: HMCharacteristic,
        _ value: Any,
        serviceName: String,
        seconds: Double = HomeKitManager.writeTimeoutSeconds,
        quiet: Bool = false
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        characteristic.writeValue(value) { error in
                            if let error = error {
                                print("[HomeKit] ❌ Write failed for '\(serviceName)': \(error.localizedDescription)")
                                continuation.resume(throwing: error)
                            } else {
                                if !quiet { print("[HomeKit] ✅ Write successful for '\(serviceName)'") }
                                continuation.resume()
                            }
                        }
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                print("[HomeKit] ⏱️ Write timed out after \(seconds)s for '\(serviceName)' — leaving it in flight")
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
                    await HomeKitManager.writeValue(characteristic, convertedValue, serviceName: serviceName)
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
            result = accessories.map { AccessoryModel(from: $0, homeId: homeId, includeValues: includeValues, reachableOverride: isEffectivelyReachable($0)) }
        } else {
            // No home filter - iterate through all homes and include homeId
            for home in homes {
                let hid = home.uniqueIdentifier.uuidString
                var accessories = home.accessories
                if let roomId = roomId, let roomUuid = UUID(uuidString: roomId) {
                    accessories = accessories.filter { $0.room?.uniqueIdentifier == roomUuid }
                }
                result.append(contentsOf: accessories.map { AccessoryModel(from: $0, homeId: hid, includeValues: includeValues, reachableOverride: isEffectivelyReachable($0)) })
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
                return AccessoryModel(from: accessory, homeId: home.uniqueIdentifier.uuidString, reachableOverride: isEffectivelyReachable(accessory))
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

        // Do not short-circuit on !isReachable: HMAccessory.isReachable can be stale after a
        // transient failure. Let the reads through — a successful read nudges HomeKit to update
        // reachability via accessoryDidUpdateReachability; a genuine offline read fails fast.

        // Read all readable characteristics concurrently
        var anySucceeded = false
        await withTaskGroup(of: Bool.self) { group in
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
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                }
            }
            for await success in group where success {
                anySucceeded = true
            }
        }
        if anySucceeded { recordSuccessfulRead(accessory) }
    }

    // MARK: - Characteristic Operations

    func readCharacteristic(accessoryId: String, characteristicType: String) async throws -> Any {
        let (accessory, characteristic) = try findCharacteristic(accessoryId: accessoryId, type: characteristicType)

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            characteristic.readValue { error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.readFailed(error))
                } else {
                    continuation.resume(returning: characteristic.value ?? NSNull())
                }
            }
        }
        recordSuccessfulRead(accessory)
        return value
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

        // Bounded — an unreachable accessory can leave writeValue's completion
        // handler unfired indefinitely, which used to hang the request until
        // the cloud timed out at 30s.
        let wrote = await HomeKitManager.writeValue(
            characteristic, convertedValue, serviceName: accessory.name
        )
        guard wrote else {
            throw HomeKitError.writeFailed(
                NSError(domain: "Homecast", code: -1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(AccessoryModel.userFacingName(of: accessory)) did not confirm the write "
                        + "within \(Int(HomeKitManager.writeTimeoutSeconds))s — it may be unreachable.",
                ])
            )
        }
        // Successful write is strong evidence the device is reachable, regardless of HomeKit's bit.
        recordSuccessfulRead(accessory)

        return ControlResult(
            success: true,
            accessoryId: accessoryId,
            characteristic: characteristicType,
            newValue: String(describing: convertedValue)
        )
    }

    // MARK: - Bulk Characteristic Writes

    /// One entry in a bulk characteristic write.
    struct BulkWrite: @unchecked Sendable {
        let accessoryId: String
        let characteristicType: String
        let value: Any

        /// `Any` is not Sendable, but only JSON primitives ever reach here —
        /// the same reasoning as `setState`'s `WriteOp`.
        nonisolated init(accessoryId: String, characteristicType: String, value: Any) {
            self.accessoryId = accessoryId
            self.characteristicType = characteristicType
            self.value = value
        }
    }

    /// What became of one entry, paired back to the accessory that caused it.
    struct BulkWriteResult {
        let accessoryId: String
        let characteristicType: String
        let value: Any?
        let success: Bool
        let error: String?
        /// HomeKit already considered this accessory unreachable when the write
        /// went out. A failure here is a bulb off at the wall, not a fault —
        /// the difference the caller needs in order to decide whether anyone
        /// should be told about it.
        let unreachable: Bool
    }

    /// A resolved write, ready to go out.
    ///
    /// Carries the service name rather than the accessory, so nothing reaches
    /// into HomeKit's object graph from off the main actor.
    private struct ResolvedWrite: @unchecked Sendable {
        let position: Int
        let characteristic: HMCharacteristic
        let value: Any
        let serviceName: String
        /// Decided on the main actor while resolving, because reachability is
        /// HomeKit state and the write itself runs off-actor.
        let seconds: Double
        let reachable: Bool

        nonisolated init(position: Int, characteristic: HMCharacteristic, value: Any, serviceName: String, seconds: Double, reachable: Bool) {
            self.position = position
            self.characteristic = characteristic
            self.value = value
            self.serviceName = serviceName
            self.seconds = seconds
            self.reachable = reachable
        }
    }

    /// Write many characteristics as one operation.
    ///
    /// `setCharacteristic` × N is the wrong shape at scale. A 223-light home
    /// paid 223 bridge round trips, and every one of them re-entered the main
    /// actor to linear-scan every accessory of every home before it could
    /// write — on the order of 10^5 comparisons per press, competing with
    /// SwiftUI and the web view for the same thread. Here the whole batch
    /// resolves in a single pass over one index, then goes out as one group.
    ///
    /// **The fan-out is deliberately unbounded**, matching `setState`. HomeKit's
    /// daemon coalesces writes that reach the same accessory server close
    /// together into a single HAP request, and a bridge is one accessory
    /// server — so simultaneity is precisely what turns forty bulbs behind a
    /// bridge into one write rather than forty. Pacing them defeats it. Each
    /// write is still bounded individually by `writeValue`'s own timeout, so
    /// one unreachable accessory cannot hold up the rest.
    ///
    /// Addressed by accessory id, unlike `setState`, whose `findAccessoryByKey`
    /// resolves room/accessory slugs and skips anything with no room — which
    /// silently drops virtual accessories and HomeKit's default room.
    ///
    /// Never throws. A batch reports per entry, because the entire point is to
    /// tell the caller which accessories moved and which did not.
    func setCharacteristics(_ writes: [BulkWrite]) async -> [BulkWriteResult] {
        guard !writes.isEmpty else { return [] }

        // One index for the whole batch, built once rather than rescanned per
        // write. This is the change that keeps a large press off the main
        // thread's back.
        var accessoriesById: [UUID: HMAccessory] = [:]
        for home in homes {
            for accessory in home.accessories {
                accessoriesById[accessory.uniqueIdentifier] = accessory
            }
        }

        var results: [BulkWriteResult?] = Array(repeating: nil, count: writes.count)
        var resolved: [ResolvedWrite] = []
        var accessoriesByPosition: [Int: HMAccessory] = [:]

        for (position, write) in writes.enumerated() {
            func fail(_ message: String) {
                results[position] = BulkWriteResult(
                    accessoryId: write.accessoryId,
                    characteristicType: write.characteristicType,
                    value: nil,
                    success: false,
                    error: message,
                    unreachable: false
                )
            }

            guard let uuid = UUID(uuidString: write.accessoryId) else {
                fail("Invalid accessory id")
                continue
            }
            guard let accessory = accessoriesById[uuid] else {
                fail("Accessory not found")
                continue
            }
            guard let characteristic = firstCharacteristic(on: accessory, type: write.characteristicType) else {
                fail("Characteristic '\(write.characteristicType)' not found on \(accessory.name)")
                continue
            }
            guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
                fail("Characteristic '\(write.characteristicType)' is not writable")
                continue
            }
            do {
                let converted = try CharacteristicMapper.convertValue(write.value, for: characteristic)
                accessoriesByPosition[position] = accessory
                let reachable = isEffectivelyReachable(accessory)
                resolved.append(ResolvedWrite(
                    position: position,
                    characteristic: characteristic,
                    value: converted,
                    serviceName: AccessoryModel.userFacingName(of: accessory),
                    seconds: reachable
                        ? HomeKitManager.bulkWriteTimeoutSeconds
                        : HomeKitManager.unreachableWriteTimeoutSeconds,
                    reachable: reachable
                ))
            } catch {
                fail(error.localizedDescription)
            }
        }

        print("[HomeKit] 📝 setCharacteristics: \(resolved.count) resolved of \(writes.count), writing as one batch")

        // Claimed around the dispatch itself, not the resolution: the reads we
        // are keeping out of the way only matter once the writes are travelling.
        bulkWritesInFlight += 1
        defer { bulkWritesInFlight -= 1 }

        let written: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self, returning: [(Int, Bool)].self) { group in
            for item in resolved {
                group.addTask {
                    let ok = await HomeKitManager.writeValue(
                        item.characteristic, item.value, serviceName: item.serviceName,
                        seconds: item.seconds, quiet: true
                    )
                    return (item.position, ok)
                }
            }
            var collected: [(Int, Bool)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let valuesByPosition = Dictionary(uniqueKeysWithValues: resolved.map { ($0.position, $0.value) })
        let reachableByPosition = Dictionary(uniqueKeysWithValues: resolved.map { ($0.position, $0.reachable) })
        var okCount = 0
        for (position, ok) in written {
            let write = writes[position]
            if ok {
                okCount += 1
                // A confirmed write is strong evidence the accessory is
                // reachable, whatever HomeKit's own bit currently says.
                if let accessory = accessoriesByPosition[position] {
                    recordSuccessfulRead(accessory)
                }
            }
            let wasReachable = reachableByPosition[position] ?? true
            results[position] = BulkWriteResult(
                accessoryId: write.accessoryId,
                characteristicType: write.characteristicType,
                value: ok ? valuesByPosition[position] : nil,
                success: ok,
                // Two different facts, said differently. An unreachable
                // accessory is not responding — a sentence about the light. A
                // reachable one that did not confirm is a sentence about our
                // timeout, and only that case deserves the number.
                error: ok ? nil : (wasReachable
                    ? "Did not confirm the write within \(Int(HomeKitManager.bulkWriteTimeoutSeconds))s."
                    : "Not responding."),
                unreachable: !wasReachable
            )
        }
        print("[HomeKit] 📝 setCharacteristics: \(okCount)/\(writes.count) confirmed")

        // Defensive rather than force-unwrapped: every position is filled above,
        // but a batch that quietly returned fewer results than it was asked for
        // would be a very bad thing to discover downstream.
        return results.enumerated().map { position, result in
            result ?? BulkWriteResult(
                accessoryId: writes[position].accessoryId,
                characteristicType: writes[position].characteristicType,
                value: nil,
                success: false,
                error: "Write did not complete",
                unreachable: false
            )
        }
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

    func createScene(homeId: String, params: [String: Any]) async throws -> SceneModel {
        guard let uuid = UUID(uuidString: homeId),
              let home = homes.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw HomeKitError.homeNotFound(homeId)
        }
        guard let name = params["name"] as? String else {
            throw HomeKitError.invalidRequest("Missing scene name")
        }
        guard let actionsParams = params["actions"] as? [[String: Any]], !actionsParams.isEmpty else {
            throw HomeKitError.invalidRequest("At least one action is required")
        }

        let actionSet: HMActionSet = try await withCheckedThrowingContinuation { continuation in
            home.addActionSet(withName: name) { actionSet, error in
                if let error = error {
                    continuation.resume(throwing: HomeKitError.sceneCreationFailed(error))
                } else if let actionSet = actionSet {
                    continuation.resume(returning: actionSet)
                } else {
                    continuation.resume(throwing: HomeKitError.invalidRequest("Failed to create action set"))
                }
            }
        }

        // Add characteristic write actions — roll the action set back on any
        // failure so a rejected create doesn't leave an empty orphaned scene.
        do {
            try await addWriteActions(actionsParams, to: actionSet)
        } catch {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                home.removeActionSet(actionSet) { removeError in
                    if let removeError = removeError {
                        print("[HomeKit] Rollback: failed to remove scene '\(actionSet.name)': \(removeError.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
            throw error
        }

        return SceneModel(from: actionSet)
    }

    func updateScene(sceneId: String, params: [String: Any]) async throws -> SceneModel {
        guard let uuid = UUID(uuidString: sceneId) else {
            throw HomeKitError.invalidId(sceneId)
        }

        for home in homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == uuid }) {
                guard actionSet.actionSetType == HMActionSetTypeUserDefined else {
                    throw HomeKitError.invalidRequest("Built-in scenes cannot be modified")
                }

                if let newName = params["name"] as? String {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        actionSet.updateName(newName) { error in
                            if let error = error {
                                continuation.resume(throwing: HomeKitError.sceneUpdateFailed(error))
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }

                if let actionsParams = params["actions"] as? [[String: Any]] {
                    guard !actionsParams.isEmpty else {
                        throw HomeKitError.invalidRequest("actions must not be empty (delete the scene instead)")
                    }
                    // Replace: remove all existing actions, then add the new set
                    for action in actionSet.actions {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            actionSet.removeAction(action) { error in
                                if let error = error {
                                    continuation.resume(throwing: HomeKitError.sceneUpdateFailed(error))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                    try await addWriteActions(actionsParams, to: actionSet)
                }

                return SceneModel(from: actionSet)
            }
        }

        throw HomeKitError.sceneNotFound(sceneId)
    }

    /// Add characteristic-write actions to an action set (shared by scene
    /// create/update; automation create has its own inline copy with
    /// automation-specific error wrapping).
    private func addWriteActions(_ actionsParams: [[String: Any]], to actionSet: HMActionSet) async throws {
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
                        continuation.resume(throwing: HomeKitError.sceneUpdateFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func deleteScene(sceneId: String) async throws {
        guard let uuid = UUID(uuidString: sceneId) else {
            throw HomeKitError.invalidId(sceneId)
        }

        for home in homes {
            if let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == uuid }) {
                // Built-in scenes (Good Morning, Good Night, ...) can't be removed
                guard actionSet.actionSetType == HMActionSetTypeUserDefined else {
                    throw HomeKitError.invalidRequest("Built-in scenes cannot be deleted")
                }
                // A scene attached to an automation IS that automation's action
                // list — deleting it would gut the automation.
                if let owner = home.triggers.first(where: { trigger in
                    trigger.actionSets.contains(where: { $0.uniqueIdentifier == uuid })
                }) {
                    throw HomeKitError.invalidRequest(
                        "Scene is used by automation \"\(owner.name)\" — delete the automation instead"
                    )
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeActionSet(actionSet) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.sceneDeletionFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return
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

        // Steps 3-5 run after the trigger exists in the home — roll back on
        // failure so a rejected create doesn't leave a disabled half-automation
        // and an orphaned scene (the action set) behind.
        var createdActionSet: HMActionSet? = nil
        do {
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
                createdActionSet = newActionSet
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
        } catch {
            if let orphan = createdActionSet {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    home.removeActionSet(orphan) { removeError in
                        if let removeError = removeError {
                            print("[HomeKit] Rollback: failed to remove action set '\(orphan.name)': \(removeError.localizedDescription)")
                        }
                        continuation.resume()
                    }
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                home.removeTrigger(trigger) { removeError in
                    if let removeError = removeError {
                        print("[HomeKit] Rollback: failed to remove trigger '\(trigger.name)': \(removeError.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
            throw error
        }

        return AutomationModel(from: trigger, homeId: homeId)
    }

    /// Remove action sets Homecast created for a trigger (they carry the
    /// automation's name) once no trigger references them any more. Without
    /// this, deleting an automation leaves its action set behind as an
    /// orphaned scene in Apple Home. User scenes attached deliberately keep
    /// their own names and other references, so they never match.
    private func removeOrphanedActionSets(_ actionSets: [HMActionSet], named name: String, in home: HMHome) async {
        for actionSet in actionSets {
            guard actionSet.actionSetType == HMActionSetTypeUserDefined else { continue }
            guard actionSet.name == name else { continue }
            let stillReferenced = home.triggers.contains { other in
                other.actionSets.contains { $0.uniqueIdentifier == actionSet.uniqueIdentifier }
            }
            if stillReferenced { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                home.removeActionSet(actionSet) { error in
                    if let error = error {
                        print("[HomeKit] Failed to remove orphaned action set '\(actionSet.name)': \(error.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
        }
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
            var candidate = Calendar.current.date(from: components) ?? Date()
            // HomeKit rejects fire dates in the past — if the time already
            // passed today, roll to the next occurrence (tomorrow).
            if candidate <= Date() {
                candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            fireDate = candidate
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
            // Save current action sets (also used for orphaned-scene cleanup —
            // the recreate makes a fresh action set, stranding the old one)
            let currentActionSets = trigger.actionSets
            let oldTriggerName = trigger.name

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
            let recreated = try await createAutomation(homeId: homeId, params: createParams)
            // The recreate built a fresh action set; clean up the old trigger's
            // now-unreferenced one so it doesn't linger as an orphaned scene.
            await removeOrphanedActionSets(currentActionSets, named: oldTriggerName, in: home)
            return recreated
        }

        return AutomationModel(from: trigger, homeId: home.uniqueIdentifier.uuidString)
    }

    func deleteAutomation(automationId: String) async throws {
        guard let uuid = UUID(uuidString: automationId) else {
            throw HomeKitError.invalidId(automationId)
        }

        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == uuid }) {
                // Capture before removal — needed for orphaned-scene cleanup after
                let attachedActionSets = trigger.actionSets
                let triggerName = trigger.name
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    home.removeTrigger(trigger) { error in
                        if let error = error {
                            continuation.resume(throwing: HomeKitError.automationDeletionFailed(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
                await removeOrphanedActionSets(attachedActionSets, named: triggerName, in: home)
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
                // Must be the same name we published the accessory under, or a
                // slug we handed out is one we can no longer resolve.
                let accKey = self.accessoryKey(
                    AccessoryModel.userFacingName(of: accessory),
                    id: accessory.uniqueIdentifier
                )

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
    struct StateSetChange {
        let accessoryId: String
        let characteristicType: String
        let value: Any
    }

    func setState(state: [String: [String: [String: Any]]], homeId: String? = nil) async throws -> (ok: Int, failed: [String], changes: [StateSetChange]) {
        // Collect all write operations first, then execute concurrently
        struct WriteOp: @unchecked Sendable {
            let label: String
            let accessoryId: String?
            let groupId: String?
            let charType: String
            let value: Any
            let homeId: String?
            let simpleName: String

            // Sendable-safe initializer (Any is not Sendable, but we only pass JSON primitives)
            nonisolated init(label: String, accessoryId: String? = nil, groupId: String? = nil, charType: String, value: Any, homeId: String? = nil, simpleName: String = "") {
                self.label = label
                self.accessoryId = accessoryId
                self.groupId = groupId
                self.charType = charType
                self.value = value
                self.homeId = homeId
                self.simpleName = simpleName
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
                        ops.append(WriteOp(label: "\(fullKey).\(prop)", accessoryId: accessory.uniqueIdentifier.uuidString, charType: charType, value: convertedValue, simpleName: prop))
                    }
                } else if let (group, _) = findServiceGroupByKey(groupKey: accKey, homeId: homeId) {
                    for (prop, value) in properties {
                        if prop == "type" || prop == "_settable" { continue }
                        let charType = CharacteristicMapper.fromSimpleName(prop)
                        let convertedValue = CharacteristicMapper.convertSimpleValue(value, forProperty: prop)
                        print("[HomeKit] 📝 setState (group): \(fullKey).\(prop) = \(value) -> \(charType)=\(convertedValue)")
                        ops.append(WriteOp(label: "\(fullKey).\(prop)", groupId: group.uniqueIdentifier.uuidString, charType: charType, value: convertedValue, homeId: homeId, simpleName: prop))
                    }
                } else {
                    print("[HomeKit] ⚠️ setState: \(fullKey) not found")
                    notFound.append("\(fullKey): not found")
                }
            }
        }

        // Execute all writes concurrently, track which ops succeeded
        let results: [(Bool, String?, Int)] = await withTaskGroup(of: (Bool, String?, Int).self, returning: [(Bool, String?, Int)].self) { group in
            for (index, op) in ops.enumerated() {
                group.addTask {
                    do {
                        if let accessoryId = op.accessoryId {
                            let _ = try await self.setCharacteristic(accessoryId: accessoryId, characteristicType: op.charType, value: op.value)
                        } else if let groupId = op.groupId {
                            let _ = try await self.setServiceGroupCharacteristic(homeId: op.homeId, groupId: groupId, characteristicType: op.charType, value: op.value)
                        }
                        return (true, nil, index)
                    } catch {
                        print("[HomeKit] ❌ setState failed: \(op.label): \(error)")
                        return (false, "\(op.label): \(error.localizedDescription)", index)
                    }
                }
            }
            var collected: [(Bool, String?, Int)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let okCount = results.filter { $0.0 }.count
        let failed = notFound + results.compactMap { $0.1 }

        // Build list of successful changes with resolved UUIDs and HomeKit characteristic types
        var changes: [StateSetChange] = []
        for (success, _, index) in results where success {
            let op = ops[index]
            let friendlyType = CharacteristicMapper.fromHomeKitType(op.charType)

            if let accessoryId = op.accessoryId {
                // Individual accessory
                changes.append(StateSetChange(accessoryId: accessoryId, characteristicType: friendlyType, value: op.value))
            } else if let groupId = op.groupId {
                // Service group — emit changes for the group AND each member accessory
                changes.append(StateSetChange(accessoryId: groupId, characteristicType: friendlyType, value: op.value))
                if let groupUUID = UUID(uuidString: groupId) {
                    for home in homes {
                        if let group = home.serviceGroups.first(where: { $0.uniqueIdentifier == groupUUID }) {
                            let memberIds = Set(group.services.compactMap { service in
                                home.accessories.first(where: { $0.services.contains(service) })?.uniqueIdentifier.uuidString
                            })
                            for memberId in memberIds {
                                changes.append(StateSetChange(accessoryId: memberId, characteristicType: friendlyType, value: op.value))
                            }
                            break
                        }
                    }
                }
            }
        }

        return (okCount, failed, changes)
    }

    // MARK: - Private Helpers

    /// The characteristic types to try for `type`, in the order to try them.
    ///
    /// Power control is the awkward one: some accessories carry PowerState and
    /// others Active, and callers name either. Shared by the single-write and
    /// bulk-write paths so the two cannot drift on which fallbacks exist.
    nonisolated static func characteristicTypesToTry(for type: String) -> [String] {
        // Build list of types to try (with fallbacks for power control)
        var typesToTry = [CharacteristicMapper.toHomeKitType(type)]

        // For power control, also try Active as fallback (for heaters, coolers, air purifiers, etc.)
        let typeLower = type.lowercased().replacingOccurrences(of: "_", with: "")
        if typeLower == "powerstate" || typeLower == "on" {
            typesToTry.append(HMCharacteristicTypeActive)
        }
        // Also try PowerState if Active was requested
        if typeLower == "active" {
            typesToTry.append(HMCharacteristicTypePowerState)
        }
        return typesToTry
    }

    /// The first characteristic on `accessory` matching `type`, or nil.
    private func firstCharacteristic(on accessory: HMAccessory, type: String) -> HMCharacteristic? {
        // Try each type in order
        for typeToTry in HomeKitManager.characteristicTypesToTry(for: type) {
            for service in accessory.services {
                if let characteristic = service.characteristics.first(where: { $0.characteristicType == typeToTry }) {
                    return characteristic
                }
            }
        }
        return nil
    }

    private func findCharacteristic(accessoryId: String, type: String) throws -> (HMAccessory, HMCharacteristic) {
        guard let uuid = UUID(uuidString: accessoryId) else {
            throw HomeKitError.invalidId(accessoryId)
        }

        for home in homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
                if let characteristic = firstCharacteristic(on: accessory, type: type) {
                    return (accessory, characteristic)
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

    /// Every characteristic history is allowed to record. A type that is not
    /// subscribed here gets no HAP notification and no periodic re-read, so it
    /// only ever changes on a full accessory reload — which is why a Nest
    /// Protect reported its low-battery flag (in this set) and never its smoke
    /// or CO state (not). Derived from the mapper by name so the two cannot
    /// drift; app-web's swift-key-chars pin fails if a profiled type is
    /// missing from it.
    private static let historyBackedTypes: [String] = [
        "smoke_detected", "carbon_monoxide_detected", "carbon_dioxide_detected",
        "leak_detected", "obstruction_detected",
        "current_ambient_light_level", "air_quality",
        "carbon_monoxide_level", "carbon_monoxide_peak_level",
        "carbon_dioxide_level", "carbon_dioxide_peak_level",
        "pm2_5_density", "pm10_density", "voc_density",
        "lock_current_state", "security_system_current_state", "security_system_target_state",
        "current_heater_cooler_state", "current_humidifier_dehumidifier_state",
        "current_fan_state", "current_air_purifier_state",
        "water_level", "charging_state", "mute", "volume",
        "current_tilt_angle", "eve_air_pressure",
        "eve_energy_watt", "eve_energy_kwh", "eve_voltage", "eve_ampere",
    ]

    /// Important characteristic types to refresh (controls and sensors, not info)
    private static let keyCharacteristicTypes: Set<String> = Set(baseKeyCharacteristicTypes)
        .union(historyBackedTypes.map { CharacteristicMapper.toHomeKitType($0) })

    private static let baseKeyCharacteristicTypes: [String] = [
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

    /// Fill in key characteristics HomeKit has no value for, as soon as it hands
    /// us its homes, so the first screen has something real to draw.
    ///
    /// Deliberately limited to characteristics with **no cached value at all**.
    /// It used to re-read every key characteristic, and that is where the
    /// "closed the app, changed a light, reopened, still shows the old state"
    /// bug lived: reading corrects HomeKit's own cache in silence, and once
    /// corrected there is no difference left for anything to notice. The
    /// periodic pass then compared the new value against itself and reported
    /// nothing, while a client that had fetched the accessory list moments
    /// earlier held the old value for a further five minutes.
    ///
    /// Reading a characteristic that has no value cannot destroy that evidence,
    /// because there was nothing to contradict. Correcting values that a client
    /// may already have been handed belongs to `scheduleCatchUpRefresh()`,
    /// which runs when a client attaches and so cannot get in front of it.
    ///
    /// Larger batches than the periodic poll — HomeKit handles concurrent reads
    /// well, and this one is racing the first screen.
    func refreshKeyCharacteristics() async {
        await refreshAndBroadcastChanges(
            batchSize: 50,
            onlyUnread: true,
            label: "Startup fill"
        )
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
