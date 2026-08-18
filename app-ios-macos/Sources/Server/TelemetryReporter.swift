import CryptoKit
import Foundation
import Network
import UIKit

/// Anonymous once-a-day usage report from a Community relay.
///
/// Community Edition has no account and no cloud connection, so nothing
/// otherwise tells us how many relays are live, how big the homes they serve
/// are, or which app versions are still in the field. This sends counts — and
/// only counts — to `api.homecast.cloud` once every 24 hours.
///
/// **Never sent:** home, room, accessory or scene names, any HomeKit or hc_ id,
/// characteristic values, IP addresses, hostnames, the Bonjour `instanceId`,
/// MQTT broker addresses, user names or emails, automation contents.
///
/// ## Fail-silent
///
/// This is a side-channel. A Community user must never see, feel or wait for
/// it, so every path here is written to fail into silence:
///
/// - it lives outside the WKWebView, so it cannot throw into the web app;
/// - nothing it does reaches a UI surface, `/health`, `/config.json` or Bonjour;
/// - one short attempt per cycle, no retry inside the cycle, and a backoff that
///   doubles to a 6h ceiling so an unreachable endpoint cannot become a
///   request loop;
/// - the counters it keeps are `O(1)` integer bumps on a queue of its own, so
///   the request path never waits on it;
/// - `NSLog` only under `TELEMETRY_VERBOSE`, because a failure that prints on
///   every cycle is a failure the user can see.
///
/// It reports only from the **relay**. A phone, a Tauri desktop client or a Mac
/// in client mode stays silent and is instead *counted* by the relay it talks
/// to, so a household produces one report rather than one per device.
final class TelemetryReporter {

    static let shared = TelemetryReporter()

    // MARK: - Defaults keys

    private enum Key {
        static let installId = "com.homecast.telemetryInstallId"
        static let salt = "com.homecast.telemetrySalt"
        static let counters = "com.homecast.telemetryCounters"
        static let windowStart = "com.homecast.telemetryWindowStart"
        static let lastReport = "com.homecast.telemetryLastReport"
        static let nextAttempt = "com.homecast.telemetryNextAttempt"
        static let backoff = "com.homecast.telemetryBackoff"
        static let firstSeen = "com.homecast.telemetryFirstSeen"
        static let restarts = "com.homecast.telemetryRestarts"
        /// Lets a DEBUG build report anyway, so the pipeline can be tested end
        /// to end without shipping a build. Off by default.
        static let forceSend = "com.homecast.telemetryForceSend"
    }

    // MARK: - Tuning

    /// How often the timer wakes. The send itself is gated on the day boundary.
    private static let tickInterval: TimeInterval = 30 * 60
    private static let reportInterval: TimeInterval = 24 * 60 * 60
    /// The first report of a brand-new install, so an install that is opened
    /// once and abandoned still registers.
    private static let firstReportDelay: TimeInterval = 10 * 60
    private static let backoffFloor: TimeInterval = 30 * 60
    private static let backoffCeiling: TimeInterval = 6 * 60 * 60
    private static let requestTimeout: TimeInterval = 10
    /// Bound on the distinct-client set. A household has a handful; this only
    /// exists so a hostile or pathological LAN cannot grow it without limit.
    private static let maxDistinctClients = 1000

    // MARK: - State

    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "com.homecast.telemetry", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var started = false

    private let defaults = UserDefaults.standard

    /// Server-observed counters for the current window.
    private var counters: [String: Int] = [:]
    /// Truncated HMACs of the clients seen this window. The salt never leaves
    /// the device and only the *count* is ever sent — this exists so "6 devices
    /// connected" can be distinguished from "one device reconnected 6 times",
    /// without the relay retaining anything that identifies either.
    private var distinctClients: Set<String> = []
    private var liveWSClients = 0

    /// The latest topology + feature snapshot pushed down from the web app.
    /// Replaced wholesale; the web app is the only thing that can read
    /// IndexedDB or enumerate HomeKit.
    private var snapshot: [String: Any] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        // Never queue behind connectivity. A relay on a boat should drop the
        // report, not hold a request open waiting for a network.
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Identity

    /// Minted once and kept for the life of the install.
    ///
    /// Deliberately *not* `com.homecast.relayInstanceId`: that one is 32 bits
    /// (collisions become likely in the tens of thousands of installs) and it
    /// is broadcast on the user's LAN in the Bonjour TXT record, so reusing it
    /// would make a row here linkable to something an observer on their network
    /// can already see.
    private lazy var installId: String = {
        if let existing = defaults.string(forKey: Key.installId) { return existing }
        let minted = UUID().uuidString.lowercased()
        defaults.set(minted, forKey: Key.installId)
        return minted
    }()

    /// Per-install HMAC key for the distinct-client set. Never transmitted.
    ///
    /// Cached rather than recomputed: `noteClient` runs on every HTTP request,
    /// and reading UserDefaults plus rebuilding a `SymmetricKey` per request is
    /// real work on the path that serves the LAN.
    private lazy var clientSalt: SymmetricKey = {
        if let raw = defaults.data(forKey: Key.salt), raw.count >= 32 {
            return SymmetricKey(data: raw)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        defaults.set(data, forKey: Key.salt)
        return SymmetricKey(data: data)
    }()

    // MARK: - Lifecycle

    /// Begin reporting. Safe to call more than once.
    ///
    /// Only a network-exposed server calls this — a loopback server (iOS) has
    /// no external clients and is not the relay.
    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true

            self.loadPersistedState()
            self.counters["restarts", default: 0] += 1

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: Self.tickInterval, leeway: .seconds(60))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer

            self.observeLifecycle()
        }
    }

    /// The timer already persists every 30 minutes; these only shorten how much
    /// counting a quit or a suspend can throw away.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.started = false
            self.persist()
        }
    }

    /// Flush counters to disk. Called on background/terminate so an app restart
    /// loses minutes of counting rather than a day of it.
    func flush() {
        queue.async { [weak self] in self?.persist() }
    }

    // MARK: - Recording (called from the server queue)

    /// One HTTP request served. Classifies the surface and the client kind.
    func recordHTTP(path: String, userAgent: String?, endpoint: NWEndpoint?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.counters["httpRequests", default: 0] += 1

            if path.hasPrefix("/rest/") {
                self.counters["restCalls", default: 0] += 1
            } else if path.hasPrefix("/mcp") {
                self.counters["mcpCalls", default: 0] += 1
            } else if path.hasPrefix("/graphql") {
                self.counters["graphqlCalls", default: 0] += 1
            }

            let kind = Self.clientKind(path: path, userAgent: userAgent)
            self.noteClient(kind: kind, userAgent: userAgent, endpoint: endpoint)
        }
    }

    func recordWSConnect(userAgent: String?, endpoint: NWEndpoint?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.liveWSClients += 1
            if self.liveWSClients > self.counters["peakConcurrent", default: 0] {
                self.counters["peakConcurrent"] = self.liveWSClients
            }
            self.noteClient(kind: Self.clientKind(path: "/ws", userAgent: userAgent),
                            userAgent: userAgent, endpoint: endpoint)
        }
    }

    func recordWSDisconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.liveWSClients = max(0, self.liveWSClients - 1)
        }
    }

    func recordWSMessage() {
        queue.async { [weak self] in
            self?.counters["wsMessages", default: 0] += 1
        }
    }

    /// Counter deltas from the web app — the things only it can see
    /// (characteristic writes, scene runs, automation runs).
    func applyCounterDeltas(_ deltas: [String: Int]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for (key, value) in deltas where value > 0 {
                guard Self.webCounterKeys.contains(key) else { continue }
                self.counters[key, default: 0] += value
            }
        }
    }

    /// Latest topology + feature snapshot from the web app. Replaces wholesale.
    func applySnapshot(_ next: [String: Any]) {
        queue.async { [weak self] in
            self?.snapshot = next
        }
    }

    // MARK: - Classification

    /// Counter names the web app is allowed to contribute. An allow-list rather
    /// than a merge, so a bug on the JS side cannot invent fields that then
    /// have to be explained on the receiving end.
    private static let webCounterKeys: Set<String> = [
        "characteristicWrites", "sceneRuns", "automationRuns", "automationErrors",
    ]

    static func clientKind(path: String, userAgent: String?) -> String {
        // The MCP endpoint identifies the client better than its User-Agent
        // does — AI assistants present as whatever HTTP library they use.
        if path.hasPrefix("/mcp") { return "mcp" }

        let ua = (userAgent ?? "").lowercased()
        if ua.isEmpty { return "other" }

        if ua.contains("homecast-ios") { return "ios" }
        if ua.contains("homecast-android") { return "android" }
        if ua.contains("homeassistant") || ua.contains("home assistant") { return "homeassistant" }
        if ua.contains("tauri") || ua.contains("homecast-desktop") { return "desktop" }
        if ua.contains("homecast") {
            // The Mac and iOS apps both embed WebKit; the platform token is
            // what separates them.
            if ua.contains("iphone") || ua.contains("ipad") { return "ios" }
            return "desktop"
        }
        if ua.contains("iphone") || ua.contains("ipad") { return "ios" }
        if ua.contains("mozilla") || ua.contains("safari") || ua.contains("chrome") { return "browser" }
        return "other"
    }

    /// Remember that *a* client of this kind was seen, without remembering
    /// which one. The address and User-Agent go into an HMAC keyed by a salt
    /// that never leaves the device, and only the resulting set's *size* is
    /// reported.
    private func noteClient(kind: String, userAgent: String?, endpoint: NWEndpoint?) {
        counters["client_\(kind)", default: 0] += 1

        guard distinctClients.count < Self.maxDistinctClients else { return }
        let material = "\(Self.hostToken(endpoint))|\(userAgent ?? "")"
        guard let data = material.data(using: .utf8) else { return }
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: clientSalt)
        let digest = Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
        distinctClients.insert(digest)
    }

    /// The remote address, for hashing only. Never stored, never sent.
    private static func hostToken(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint = endpoint else { return "" }
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let v4): return "\(v4)"
            case .ipv6(let v6): return "\(v6)"
            case .name(let name, _): return name
            @unknown default: return ""
            }
        }
        return ""
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let stored = defaults.dictionary(forKey: Key.counters) as? [String: Int] {
            counters = stored
        }
        if defaults.object(forKey: Key.windowStart) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Key.windowStart)
        }
        if defaults.object(forKey: Key.firstSeen) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Key.firstSeen)
        }
        // Distinct clients deliberately do not persist: the set is a
        // within-run observation, and rehydrating it across restarts would
        // outlive the salt's usefulness for no gain in accuracy.
    }

    private func persist() {
        defaults.set(counters, forKey: Key.counters)
    }

    // MARK: - The cycle

    private func tick() {
        persist()

        guard Self.isEnabled else { return }

        let now = Date().timeIntervalSince1970
        let lastReport = defaults.double(forKey: Key.lastReport)
        let nextAttempt = defaults.double(forKey: Key.nextAttempt)

        // Backing off from an earlier failure.
        guard now >= nextAttempt else { return }

        // Forced: report on the next tick. Without this, verifying the pipeline
        // end to end means waiting out the first-report delay and then a 30-min
        // tick — half an hour to find out whether anything works at all, which
        // is long enough that "it isn't reporting" and "it hasn't reported yet"
        // are indistinguishable.
        if !defaults.bool(forKey: Key.forceSend) {
            if lastReport == 0 {
                // Never reported. Wait out the first-report delay so a launch
                // burst does not report a 30-second-old install.
                let firstSeen = defaults.double(forKey: Key.firstSeen)
                guard now - firstSeen >= Self.firstReportDelay else { return }
            } else {
                guard now - lastReport >= Self.reportInterval else { return }
                // Report at this install's own time of day rather than
                // everyone's midnight, so the fleet does not arrive in one spike.
                guard Self.isPreferredHour(installId: installId, now: now) else { return }
            }
        }

        send(now: now)
    }

    /// A stable per-install minute-of-day derived from the install id. Combined
    /// with the 24h floor above this spreads the fleet evenly across the day.
    static func isPreferredHour(installId: String, now: TimeInterval) -> Bool {
        let hash = installId.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let preferredHour = Int(hash % 24)
        let currentHour = Int((now / 3600).truncatingRemainder(dividingBy: 24))
        return currentHour == preferredHour
    }

    /// Reporting is off in DEBUG so development does not pollute the fleet
    /// numbers, unless explicitly forced for an end-to-end test.
    private static var isEnabled: Bool {
        if UserDefaults.standard.bool(forKey: Key.forceSend) { return true }
        #if DEBUG
        return false
        #else
        return AppConfig.isCommunity
        #endif
    }

    private static var endpointURL: URL? {
        let host = AppConfig.isStaging ? "staging.api.homecast.cloud" : "api.homecast.cloud"
        return URL(string: "https://\(host)/telemetry/community")
    }

    private func send(now: TimeInterval) {
        guard let url = Self.endpointURL else { return }

        let windowStart = defaults.double(forKey: Key.windowStart)
        let payload = buildPayload(now: now, windowStart: windowStart)

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            // Unserialisable payload means a bug here, not a transient fault.
            // Drop the window rather than retrying it forever.
            resetWindow(at: now)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self = self else { return }
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200..<300:
                    self.resetWindow(at: Date().timeIntervalSince1970)
                case 400..<500 where status != 429:
                    // The server rejected the shape of this report. Retrying it
                    // unchanged would fail identically every cycle, so drop the
                    // window and start a clean one.
                    self.resetWindow(at: Date().timeIntervalSince1970)
                default:
                    self.backOff()
                }
            }
        }.resume()
    }

    /// A successful (or unrecoverable) report closes the window: counters go
    /// back to zero and the next one starts now.
    private func resetWindow(at now: TimeInterval) {
        counters.removeAll()
        distinctClients.removeAll()
        // Keep the live count — the clients are still connected, and zeroing it
        // would under-report the next window's peak.
        counters["peakConcurrent"] = liveWSClients
        defaults.set(now, forKey: Key.lastReport)
        defaults.set(now, forKey: Key.windowStart)
        defaults.set(0.0, forKey: Key.nextAttempt)
        defaults.set(0.0, forKey: Key.backoff)
        persist()
    }

    /// Counters are deliberately *not* cleared here. An offline week produces
    /// one report covering that week rather than seven lost ones — which is
    /// why the payload carries the real `windowSeconds` instead of assuming
    /// 86400.
    private func backOff() {
        let previous = defaults.double(forKey: Key.backoff)
        let next = previous <= 0
            ? Self.backoffFloor
            : min(previous * 2, Self.backoffCeiling)
        defaults.set(next, forKey: Key.backoff)
        defaults.set(Date().timeIntervalSince1970 + next, forKey: Key.nextAttempt)
    }

    // MARK: - Payload

    private func buildPayload(now: TimeInterval, windowStart: TimeInterval) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let firstSeen = defaults.double(forKey: Key.firstSeen)
        let ageDays = firstSeen > 0 ? Int((now - firstSeen) / 86400) : 0
        let windowSeconds = windowStart > 0 ? max(0, Int(now - windowStart)) : 0

        var clientsByKind: [String: Int] = [:]
        for (key, value) in counters where key.hasPrefix("client_") {
            clientsByKind[String(key.dropFirst("client_".count))] = value
        }

        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion

        var payload: [String: Any] = [
            "v": 1,
            "installId": installId,
            "sentAt": formatter.string(from: Date(timeIntervalSince1970: now)),
            "windowSeconds": windowSeconds,
            "app": [
                "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": info?["CFBundleVersion"] as? String ?? "unknown",
                "platform": Self.platform,
                "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                "locale": Locale.current.identifier,
                "env": AppConfig.isStaging ? "staging" : "prod",
            ],
            "relay": [
                "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
                "restarts": counters["restarts"] ?? 0,
                "ageDays": ageDays,
            ],
            "clients": [
                "peakConcurrent": counters["peakConcurrent"] ?? 0,
                "distinct": distinctClients.count,
                "byKind": clientsByKind,
            ],
            "usage": [
                "httpRequests": counters["httpRequests"] ?? 0,
                "wsMessages": counters["wsMessages"] ?? 0,
                "restCalls": counters["restCalls"] ?? 0,
                "mcpCalls": counters["mcpCalls"] ?? 0,
                "graphqlCalls": counters["graphqlCalls"] ?? 0,
                "characteristicWrites": counters["characteristicWrites"] ?? 0,
                "sceneRuns": counters["sceneRuns"] ?? 0,
                "automationRuns": counters["automationRuns"] ?? 0,
                "automationErrors": counters["automationErrors"] ?? 0,
            ],
        ]

        // The web app owns everything below; if it has never reported, the
        // report still goes without them rather than being held back.
        if let scale = snapshot["scale"] as? [String: Any] { payload["scale"] = scale }
        if let categories = snapshot["categories"] as? [String: Any] { payload["categories"] = categories }
        if let features = snapshot["features"] as? [String: Any] { payload["features"] = features }

        return payload
    }

    private static var platform: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }
}
