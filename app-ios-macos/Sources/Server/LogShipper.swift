//
//  LogShipper.swift
//  Homecast
//
//  Batches log entries + POSTs them to the cloud server's /internal/logs
//  endpoint so Mac-side warnings and errors land in Cloud Logging alongside
//  server events, tagged source=mac and correlated by user_id.
//
//  Design:
//    - `enqueue(_:)` buffers entries in memory, capped at 2000 to prevent
//      unbounded growth if the endpoint is down.
//    - Flush on a 30s timer or immediately when the queue crosses a batch
//      threshold.
//    - Fire-and-forget — a failure just re-queues the batch for next flush.
//    - Auth token + API URL are injected by the caller (HomecastApp) via
//      `configure(apiURL:tokenProvider:)`. Community mode doesn't call this,
//      so Community builds never ship logs.
//

import Foundation

public final class LogShipper {

    public static let shared = LogShipper()

    // Config
    private var apiURL: URL?
    private var tokenProvider: (() -> String?)?
    private var source: String = "mac"
    private var sessionId: String = UUID().uuidString
    private var flushInterval: TimeInterval = 30

    // State
    private let queue = DispatchQueue(label: "cloud.homecast.log-shipper", qos: .utility)
    private var pending: [LogEntry] = []
    private let maxPending = 2_000
    private let batchSize = 100
    private let batchKickThreshold = 20   // flush eagerly when we hit this
    private var timer: DispatchSourceTimer?
    private var inFlight = false

    // Metrics (for Diagnostics UI)
    public private(set) var totalShipped: Int = 0
    public private(set) var totalDropped: Int = 0
    public private(set) var totalFailed: Int = 0
    public private(set) var lastError: String?
    public private(set) var lastFlushAt: Date?

    private init() {}

    public func configure(apiURL: URL,
                          tokenProvider: @escaping () -> String?,
                          source: String = "mac") {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.apiURL = apiURL
            self.tokenProvider = tokenProvider
            self.source = source
            self.startTimer()
            Log.info("LogShipper configured: api=\(apiURL.host ?? "?") source=\(source)",
                     category: "log-shipper")
        }
    }

    public func enqueue(_ entry: LogEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pending.append(entry)
            if self.pending.count > self.maxPending {
                let drop = self.pending.count - self.maxPending
                self.pending.removeFirst(drop)
                self.totalDropped += drop
            }
            if self.pending.count >= self.batchKickThreshold {
                self.flushLocked()
            }
        }
    }

    /// Force an immediate flush. Called from the Diagnostics UI and also on
    /// app termination (best-effort — short timeout).
    public func flushNow() {
        queue.async { [weak self] in self?.flushLocked() }
    }

    // MARK: - Internals

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    private func flushLocked() {
        guard !inFlight else { return }
        guard let url = apiURL else { return }
        guard let token = tokenProvider?(), !token.isEmpty else { return }
        guard !pending.isEmpty else { return }

        let take = min(batchSize, pending.count)
        let batch = Array(pending.prefix(take))
        pending.removeFirst(take)

        let body = buildBody(entries: batch)
        guard let bodyData = body else { return }

        inFlight = true
        lastFlushAt = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                self.inFlight = false
                let http = response as? HTTPURLResponse
                if let error = error {
                    // Network failure — requeue the batch and back off.
                    self.totalFailed += take
                    self.lastError = error.localizedDescription
                    self.pending.insert(contentsOf: batch, at: 0)
                    if self.pending.count > self.maxPending {
                        let drop = self.pending.count - self.maxPending
                        self.pending.removeFirst(drop)
                        self.totalDropped += drop
                    }
                    return
                }
                if let status = http?.statusCode, !(200..<300).contains(status) {
                    self.totalFailed += take
                    self.lastError = "HTTP \(status)"
                    // 4xx is likely auth or malformed — don't requeue. 5xx we try again.
                    if status >= 500 {
                        self.pending.insert(contentsOf: batch, at: 0)
                    }
                    _ = data
                    return
                }
                self.totalShipped += take
                self.lastError = nil
            }
        }.resume()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func buildBody(entries: [LogEntry]) -> Data? {
        let mapped: [[String: Any]] = entries.map { e in
            var d: [String: Any] = [
                "level": e.level.rawValue,
                "message": e.message,
                "timestamp": LogShipper.isoFormatter.string(from: e.timestamp),
            ]
            var md: [String: Any] = ["category": e.category]
            if let extra = e.metadata {
                for (k, v) in extra { md[k] = v }
            }
            d["metadata"] = md
            return d
        }
        let body: [String: Any] = [
            "source": source,
            "session_id": sessionId,
            "entries": mapped,
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }
}
