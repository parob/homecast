import Foundation
import Network

/// A Homecast relay found on the local network.
struct DiscoveredRelay: Identifiable, Equatable {
    /// The relay's stable id from its TXT record, or the Bonjour instance name
    /// when it doesn't publish one (a relay older than TXT support).
    let id: String
    /// The Bonjour instance name — the Mac's hostname, and what to show.
    let name: String
    let origin: String
    let wsPort: Int?
    let version: String?
    /// Whether the relay asks for a login. Nil when it never said.
    let authEnabled: Bool?
}

/// Finds Homecast relays advertising `_homecast._tcp` on the local network.
///
/// Discovery is strictly additive: everything here can fail — permission
/// denied, client-isolated Wi-Fi, a network with no relay on it, a phone on
/// cellular — and the manual address field remains the way to connect. Nothing
/// in the UI is gated on a result arriving.
@MainActor
final class RelayDiscovery: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        /// Local Network permission was refused. Recoverable only in Settings.
        case denied
        /// Looked, found nothing. Usually a network that doesn't carry mDNS.
        case empty
        case failed(String)
    }

    @Published private(set) var relays: [DiscoveredRelay] = []
    @Published private(set) var state: State = .idle

    private var browser: NWBrowser?
    /// Keyed by the endpoint's Bonjour name, which is stable for a given
    /// service instance even before we've resolved it to an address.
    private var found: [String: DiscoveredRelay] = [:]
    private var pendingTXT: [String: NWTXTRecord] = [:]

    /// Resolution runs one at a time. A home has one relay, so this costs
    /// nothing there, and it avoids opening a burst of connections on a
    /// network that has several.
    private var resolveQueue: [NWEndpoint] = []
    private var resolving: NWConnection?
    private var emptyTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = 1

    /// The relay this device last connected to, floated to the top of the list.
    private var preferredId: String? {
        UserDefaults.standard.string(forKey: "com.homecast.pairedRelayInstanceId")
    }

    func start() {
        #if targetEnvironment(macCatalyst)
        // The Mac is the relay, not a client looking for one. Browsing here
        // would add a local-network privacy prompt to the Mac app for no
        // benefit, so the type exists but never looks.
        return
        #else
        guard browser == nil else { return }
        state = .searching
        relays = []
        found = [:]
        pendingTXT = [:]

        let params = NWParameters()
        params.includePeerToPeer = true
        // withTXTRecord, so a relay's ports and auth state arrive with the
        // browse result rather than needing a second round trip.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_homecast._tcp", domain: nil),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in self?.handle(browserState: browserState) }
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            Task { @MainActor in self?.handle(changes: changes) }
        }

        browser.start(queue: .main)
        self.browser = browser

        emptyTimer?.invalidate()
        emptyTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.relays.isEmpty, self.state == .searching else { return }
                self.state = .empty
            }
        }
        #endif
    }

    func stop() {
        emptyTimer?.invalidate()
        emptyTimer = nil
        restartWork?.cancel()
        restartWork = nil
        resolving?.cancel()
        resolving = nil
        resolveQueue.removeAll()
        browser?.cancel()
        browser = nil
        state = .idle
    }

    // MARK: - Browser

    private func handle(browserState: NWBrowser.State) {
        switch browserState {
        case .ready:
            restartDelay = 1
            if state != .empty { state = .searching }
        case .waiting(let error):
            if isPermissionDenied(error) { state = .denied }
        case .failed(let error):
            if isPermissionDenied(error) {
                state = .denied
            } else {
                state = .failed(error.localizedDescription)
                // Browsers die when the interface changes underneath them —
                // Wi-Fi to cellular and back is enough. Come back with backoff.
                scheduleRestart()
            }
        default:
            break
        }
    }

    /// iOS reports a refused Local Network permission as a DNS policy error
    /// rather than anything more specific.
    private func isPermissionDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self, self.browser != nil else { return }
                self.stop()
                self.start()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handle(changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                add(result)
            case .removed(let result):
                if let key = bonjourName(of: result.endpoint) {
                    found.removeValue(forKey: key)
                    pendingTXT.removeValue(forKey: key)
                    publish()
                }
            case .changed(_, let new, let flags):
                // A TXT-only change means auth was toggled or the WS port
                // landed — re-read the record, but don't resolve again.
                if flags.contains(.metadataChanged) {
                    if let key = bonjourName(of: new.endpoint) {
                        pendingTXT[key] = txt(of: new)
                        if let existing = found[key] {
                            found[key] = merge(existing, with: txt(of: new))
                            publish()
                        }
                    }
                } else {
                    add(new)
                }
            default:
                break
            }
        }
    }

    private func add(_ result: NWBrowser.Result) {
        guard let key = bonjourName(of: result.endpoint) else { return }
        pendingTXT[key] = txt(of: result)
        guard found[key] == nil else { return }
        resolveQueue.append(result.endpoint)
        pump()
    }

    // MARK: - Resolution

    /// A `.service` endpoint carries no address. Opening a connection to it and
    /// reading back the resolved path is the way to turn it into host:port —
    /// and has the useful side effect of proving the relay is reachable.
    private func pump() {
        guard resolving == nil, !resolveQueue.isEmpty else { return }
        let endpoint = resolveQueue.removeFirst()
        guard let key = bonjourName(of: endpoint) else { pump(); return }

        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving = connection

        var finished = false
        let finish: (NWEndpoint?) -> Void = { [weak self] resolved in
            guard !finished else { return }
            finished = true
            connection.cancel()
            Task { @MainActor in
                guard let self = self else { return }
                if let resolved = resolved { self.record(key: key, resolved: resolved) }
                self.resolving = nil
                self.pump()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(connection.currentPath?.remoteEndpoint)
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }

    private func record(key: String, resolved: NWEndpoint) {
        guard case let .hostPort(host, port) = resolved else { return }
        // Fall back to the Bonjour name when the address is IPv6-only: iOS
        // resolves .local natively, which beats formatting a link-local
        // literal with a zone id. (Android cannot do this — it has no mDNS
        // resolver — which is why its bridge always emits a numeric address.)
        let hostText = ipv4String(host) ?? "\(key).local"
        let record = pendingTXT[key]

        found[key] = DiscoveredRelay(
            id: record?["id"] ?? key,
            name: key,
            origin: "http://\(hostText):\(port.rawValue)",
            wsPort: record?["ws"].flatMap { Int($0) },
            version: record?["vs"],
            authEnabled: record?["au"].map { $0 == "1" }
        )
        publish()
    }

    private func merge(_ relay: DiscoveredRelay, with record: NWTXTRecord?) -> DiscoveredRelay {
        DiscoveredRelay(
            id: record?["id"] ?? relay.id,
            name: relay.name,
            origin: relay.origin,
            wsPort: record?["ws"].flatMap { Int($0) } ?? relay.wsPort,
            version: record?["vs"] ?? relay.version,
            authEnabled: record?["au"].map { $0 == "1" } ?? relay.authEnabled
        )
    }

    private func publish() {
        let preferred = preferredId
        relays = found.values.sorted { lhs, rhs in
            if let preferred = preferred {
                if lhs.id == preferred { return true }
                if rhs.id == preferred { return false }
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if !relays.isEmpty { state = .searching }
    }

    // MARK: - Endpoint helpers

    private func bonjourName(of endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    private func txt(of result: NWBrowser.Result) -> NWTXTRecord? {
        if case let .bonjour(record) = result.metadata { return record }
        return nil
    }

    /// The dotted-quad form, with any `%interface` suffix removed. Nil for a
    /// host that isn't IPv4.
    private func ipv4String(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return String("\(address)".split(separator: "%").first ?? "")
        case .name(let name, _):
            return name
        default:
            return nil
        }
    }
}
