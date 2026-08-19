import Foundation

/// Asking a relay "are you there, and are you the one I mean?".
///
/// A relay is reachable at several addresses at once — on the LAN, over a mesh
/// VPN, through a tunnel — and which of them works depends on where the client
/// is standing. Rather than storing one address and hoping, ask all of them and
/// take the best answer.
///
/// The mirror of `app-web/src/lib/relay-probe.ts`, which carries the unit tests
/// for this logic: there is no Swift test target, so the shared rules are
/// pinned on the web side and kept deliberately identical here.
enum RelayProbe {

    // MARK: - Address classification

    /// What kind of address this is, which decides how much we want it.
    ///
    /// The order matters more than it looks: a LAN address that answers is
    /// worth preferring over a mesh one that also answers, because the mesh
    /// route can be a relayed hop halfway across the country while the LAN one
    /// is a switch away.
    enum Kind: Int {
        case lan = 1
        case cgnat = 2
        case other = 3
    }

    /// Classify a bare host — `192.168.1.5`, `localhost`, `home.example.com`.
    static func classify(host rawHost: String) -> Kind {
        let host = rawHost.lowercased()
        if host == "localhost" || host.hasSuffix(".local") { return .lan }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return .other }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return .lan
        // 172.16.0.0/12 is 172.16 through 172.31 — not all of 172.
        case (172, 16...31): return .lan
        case (169, 254): return .lan
        // 100.64.0.0/10 — carrier-grade NAT, where Tailscale and most mesh VPNs
        // live. Reachable from anywhere on the mesh, which is why it is worth
        // keeping, but never a LAN address and never preferred over one.
        case (100, 64...127): return .cgnat
        default: return .other
        }
    }

    /// Classify a full origin, e.g. `http://192.168.1.5:5656`.
    static func classify(origin: String) -> Kind {
        guard let host = URL(string: origin)?.host else { return .other }
        return classify(host: host)
    }

    /// Whether this origin is somewhere only a nearby device can reach.
    ///
    /// Used to decide whether an unprotected relay deserves a warning: on the
    /// LAN or a private mesh, no password is merely relaxed; on a public
    /// hostname it means anyone who finds the address controls the home.
    static func isLocalHost(_ origin: String) -> Bool {
        let kind = classify(origin: origin)
        return kind == .lan || kind == .cgnat
    }

    /// Lower is better. `prefer` is last-known-good, which beats everything —
    /// it is usually right, and free when it is.
    static func rank(_ origin: String, prefer: String?) -> Int {
        if let prefer = prefer, origin == prefer { return 0 }
        return classify(origin: origin).rawValue
    }

    // MARK: - Probing

    /// What a relay says about itself on `/health`.
    struct Health {
        /// The origin that answered — not necessarily the one stored.
        let origin: String
        /// Stable relay id. Nil on relays older than the instanceId work.
        let instanceId: String?
        let name: String?
        let wsPort: Int?
        /// Nil when the relay has not reported yet — "unknown", not "no".
        let authEnabled: Bool?
        /// Every origin the relay believes it can be reached at.
        let addresses: [String]
    }

    /// Ask one origin whether a Homecast relay is listening there.
    ///
    /// Never throws: an unreachable address is an ordinary answer here, not an
    /// error, and `pickReachable` awaits these in order — one thrown error
    /// would take the whole race down with it.
    static func probe(_ origin: String, timeout: TimeInterval = 3) async -> Health? {
        guard let url = URL(string: "\(origin)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Something else may well be listening on 5656. Only a relay says both.
        guard json["status"] as? String == "ok",
              json["mode"] as? String == "community" else { return nil }

        let id = json["instanceId"] as? String
        let name = json["name"] as? String
        let wsPort = json["wsPort"] as? Int
        return Health(
            origin: origin,
            instanceId: (id?.isEmpty == false) ? id : nil,
            name: (name?.isEmpty == false) ? name : nil,
            wsPort: (wsPort ?? 0) > 0 ? wsPort : nil,
            authEnabled: json["authEnabled"] as? Bool,
            addresses: (json["addresses"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }

    /// The best address that answers, or nil if none do.
    ///
    /// Every candidate is probed **concurrently**, but awaited in preference
    /// order. That gets both halves right: a dead LAN address costs nothing
    /// extra because the mesh probe has been running alongside it the whole
    /// time, and a live LAN address wins even when a slower mesh route would
    /// also have worked.
    ///
    /// - Parameter expectedId: the relay we mean. A probe answering with a
    ///   different id is rejected — DHCP recycles addresses, and silently
    ///   binding to whichever Mac now holds `192.168.1.211` would hand someone
    ///   else's home to this client. A relay too old to report an id cannot
    ///   prove it is the one we mean, so it does not qualify either.
    static func pickReachable(
        _ origins: [String],
        expectedId: String? = nil,
        prefer: String? = nil,
        timeout: TimeInterval = 3
    ) async -> Health? {
        var seen = Set<String>()
        let unique = origins.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }

        let ranked = unique.sorted { rank($0, prefer: prefer) < rank($1, prefer: prefer) }
        // Start them all now; await below in preference order.
        let tasks = ranked.map { origin in
            Task { await probe(origin, timeout: timeout) }
        }
        defer { tasks.forEach { $0.cancel() } }

        for task in tasks {
            guard let health = await task.value else { continue }
            if let expectedId = expectedId, health.instanceId != expectedId { continue }
            return health
        }
        return nil
    }
}
