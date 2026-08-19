import Foundation

/// The relays this device knows about, and every way it has found to reach them.
///
/// A relay is one machine with several addresses — on the LAN, over a mesh VPN,
/// through a tunnel someone typed. Storing a single address is what made
/// leaving the house break the app: the stored LAN address stops answering and
/// there is nothing else to try.
///
/// Identity is the relay's `instanceId`, which is exactly what it was minted
/// for. Addresses come and go around it; the id does not.
///
/// The mirror of `app-web/src/lib/saved-relays.ts`, which carries the tests for
/// this logic — there is no Swift test target, so the rules are pinned there
/// and kept deliberately identical here.

enum AddressSource: String, Codable {
    /// Found on the network over Bonjour.
    case discovered
    /// The relay named it itself, on /health.
    case advertised
    /// Somebody typed it.
    case manual
}

struct SavedAddress: Codable, Equatable {
    let origin: String
    var source: AddressSource
    /// When this address last answered. Nil means it never has.
    var lastOkAt: Double?
}

struct SavedRelay: Codable, Equatable, Identifiable {
    /// The relay's stable instanceId.
    let id: String
    var name: String
    var addresses: [SavedAddress]
    var wsPort: Int?
    var authEnabled: Bool?
    /// Tried first next time — usually right, and free when it is.
    var lastConnectedOrigin: String?
    var lastSeenAt: Double?

    /// Every origin worth trying, best guess first.
    var candidateOrigins: [String] {
        let rest = addresses.map { $0.origin }.filter { $0 != lastConnectedOrigin }
        if let last = lastConnectedOrigin { return [last] + rest }
        return rest
    }

    /// What to show when the relay has never told us a name.
    var displayName: String {
        if !name.isEmpty { return name }
        if let first = addresses.first?.origin, let host = URL(string: first)?.host { return host }
        return id
    }
}

enum SavedRelayStore {
    static let key = "com.homecast.savedRelays"

    // MARK: - Storage

    static func load() -> [SavedRelay] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedRelay].self, from: data) else { return [] }
        // A record with no id cannot be matched to a relay again, so it is not
        // worth keeping — and one bad row should not empty the picker.
        return list.filter { !$0.id.isEmpty }
    }

    static func save(_ list: [SavedRelay]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Replace the entry with this id, or append it. Order is otherwise kept.
    static func upsert(_ list: [SavedRelay], _ relay: SavedRelay) -> [SavedRelay] {
        guard !relay.id.isEmpty else { return list }
        var next = list
        if let i = next.firstIndex(where: { $0.id == relay.id }) {
            next[i] = relay
        } else {
            next.append(relay)
        }
        return next
    }

    static func forget(_ id: String) {
        save(load().filter { $0.id != id })
    }

    // MARK: - Learning

    /// Fold a successful probe into what we already knew about a relay.
    ///
    /// The rule that matters: **a typed address is never dropped.** The relay
    /// advertises the interfaces it can see, which will not include a tunnel
    /// hostname someone configured — so treating /health as the complete list
    /// would silently delete the only address that works from outside the
    /// house. Advertised addresses are merged in alongside, not swapped in.
    static func merge(
        existing: SavedRelay?,
        health: RelayProbe.Health,
        source: AddressSource = .manual,
        now: Double = Date().timeIntervalSince1970
    ) -> SavedRelay {
        var addresses: [SavedAddress] = []
        var seen = Set<String>()

        func add(_ origin: String, _ src: AddressSource, _ lastOkAt: Double?) {
            guard !origin.isEmpty, seen.insert(origin).inserted else { return }
            addresses.append(SavedAddress(origin: origin, source: src, lastOkAt: lastOkAt))
        }

        // The one that just answered, first — the most trustworthy thing here.
        let known = existing?.addresses.first { $0.origin == health.origin }
        add(health.origin, known?.source ?? source, now)

        // Everything we already had, keeping its provenance and last success.
        for a in existing?.addresses ?? [] { add(a.origin, a.source, a.lastOkAt) }

        // What the relay says about itself. New ones only — an address we
        // already hold keeps the source it was added under.
        for origin in health.addresses { add(origin, .advertised, nil) }

        return SavedRelay(
            id: health.instanceId ?? existing?.id ?? "",
            name: health.name ?? existing?.name ?? "",
            addresses: addresses,
            wsPort: health.wsPort ?? existing?.wsPort,
            authEnabled: health.authEnabled ?? existing?.authEnabled,
            lastConnectedOrigin: health.origin,
            lastSeenAt: now
        )
    }

    /// Record a successful connection, learning whatever the relay reported.
    @discardableResult
    static func remember(_ health: RelayProbe.Health, source: AddressSource = .manual) -> SavedRelay? {
        guard health.instanceId != nil else { return nil }   // nothing stable to file it under
        let list = load()
        let merged = merge(existing: list.first { $0.id == health.instanceId }, health: health, source: source)
        save(upsert(list, merged))
        return merged
    }

    /// Add an address a user typed, without needing the relay to be reachable.
    static func addManualAddress(_ id: String, _ origin: String) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }),
              !origin.isEmpty,
              !list[i].addresses.contains(where: { $0.origin == origin }) else { return }
        list[i].addresses.append(SavedAddress(origin: origin, source: .manual, lastOkAt: nil))
        save(list)
    }

    /// Drop one address. The last cannot go — that is forgetting the relay.
    static func removeAddress(_ id: String, _ origin: String) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }), list[i].addresses.count > 1 else { return }
        list[i].addresses.removeAll { $0.origin == origin }
        if list[i].lastConnectedOrigin == origin { list[i].lastConnectedOrigin = nil }
        save(list)
    }

    // MARK: - Migration

    /// Fold the pre-list single-relay scalars into a record, once.
    ///
    /// The old keys are deliberately left in place: they are still what
    /// `showRelayConnect` and the WebView injection read for "the currently
    /// selected relay", and this list sits above them rather than replacing
    /// them.
    static func migrateLegacyIfNeeded() {
        guard let address = AppConfig.relayAddress,
              let pairedId = AppConfig.pairedRelayInstanceId,
              !pairedId.isEmpty else { return }
        let list = load()
        guard !list.contains(where: { $0.id == pairedId }) else { return }
        let relay = SavedRelay(
            id: pairedId,
            name: "",
            addresses: [SavedAddress(origin: address, source: .manual, lastOkAt: nil)],
            wsPort: AppConfig.relayWsPort,
            authEnabled: nil,
            lastConnectedOrigin: address,
            lastSeenAt: nil
        )
        save(upsert(list, relay))
        NSLog("[SavedRelays] Migrated the paired relay %@ into the saved list", pairedId)
    }
}
