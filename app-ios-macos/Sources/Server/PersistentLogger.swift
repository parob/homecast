//
//  PersistentLogger.swift
//  Homecast
//
//  Centralised logging that:
//    - Writes to the unified logging system (`os.log` / `Logger`) so Console.app
//      and Xcode see structured entries.
//    - Mirrors INFO+ entries to a rotating on-disk file in
//      Application Support/Homecast/logs/ (10 × 1MB rotation). Crashes that
//      happen before shutdown still leave a breadcrumb on disk we can read
//      back on next launch.
//    - Keeps a small in-memory ring buffer (last 500 entries) so the
//      Diagnostics UI can render recent logs without hitting OSLogStore.
//    - Emits entries to LogShipper.shared so WARN+ get posted to
//      /internal/logs, correlated by user_id on the server side.
//
//  Replace `print(...)` / `NSLog(...)` with `Log.info/warning/error/debug(...)`
//  incrementally. Existing NSLog calls still work — the unified log handles
//  them too — but shipped observability only kicks in once a site is migrated.
//

import Foundation
import os.log

public enum LogLevel: String, Codable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARNING"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info:  return .info
        case .warn:  return .default
        case .error: return .error
        }
    }

    /// For filtering the ring buffer / Diagnostics UI.
    var ordinal: Int {
        switch self {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }
}

public struct LogEntry: Codable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]?
}

/// Central log facade. Thread-safe.
///
/// Usage: `Log.info("ws connected", category: "websocket")`.
public enum Log {

    // Unified `Logger` instances per category. os.log under the hood;
    // Logger gives us the privacy-aware interpolation syntax.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cloud.homecast.app"
    private static var loggers: [String: Logger] = [:]
    private static let lock = NSLock()

    private static func logger(for category: String) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
    }

    // MARK: - Public API

    public static func debug(_ message: String, category: String = "app", metadata: [String: String]? = nil) {
        write(.debug, message, category: category, metadata: metadata)
    }

    public static func info(_ message: String, category: String = "app", metadata: [String: String]? = nil) {
        write(.info, message, category: category, metadata: metadata)
    }

    public static func warning(_ message: String, category: String = "app", metadata: [String: String]? = nil) {
        write(.warn, message, category: category, metadata: metadata)
    }

    public static func error(_ message: String, category: String = "app", metadata: [String: String]? = nil) {
        write(.error, message, category: category, metadata: metadata)
    }

    // MARK: - Write path

    private static func write(_ level: LogLevel, _ message: String, category: String, metadata: [String: String]?) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )

        // 1) Unified log — visible in Console.app + Xcode.
        let l = logger(for: category)
        switch level {
        case .debug: l.debug("\(message, privacy: .public)")
        case .info:  l.info("\(message, privacy: .public)")
        case .warn:  l.warning("\(message, privacy: .public)")
        case .error: l.error("\(message, privacy: .public)")
        }

        // 2) Ring buffer — for in-app Diagnostics UI.
        PersistentLogStore.shared.appendToRingBuffer(entry)

        // 3) Rotating file — INFO+ only to keep the file tight.
        if level.ordinal >= LogLevel.info.ordinal {
            PersistentLogStore.shared.appendToFile(entry)
        }

        // 4) Ship WARN+ to the server (fire-and-forget; queues if offline).
        if level.ordinal >= LogLevel.warn.ordinal {
            LogShipper.shared.enqueue(entry)
        }
    }
}

/// Handles the ring buffer + rotating disk log file. Kept separate from the
/// `Log` facade so tests can inject an alternative store.
public final class PersistentLogStore {

    public static let shared = PersistentLogStore()

    private let queue = DispatchQueue(label: "cloud.homecast.persistent-logger", qos: .utility)
    private let ringLock = NSLock()

    // Ring buffer
    private var ring: [LogEntry] = []
    private let ringCap = 500

    // File rotation
    private let maxFileSize: Int = 1_000_000   // 1 MB
    private let maxFiles: Int = 10

    // Subscribers — Diagnostics UI listens for new entries.
    private var subscribers: [(LogEntry) -> Void] = []
    private let subLock = NSLock()

    // MARK: - Subscription (for Diagnostics UI)

    @discardableResult
    public func subscribe(_ cb: @escaping (LogEntry) -> Void) -> () -> Void {
        subLock.lock(); defer { subLock.unlock() }
        subscribers.append(cb)
        let idx = subscribers.count - 1
        return { [weak self] in
            self?.subLock.lock(); defer { self?.subLock.unlock() }
            guard let self = self, idx < self.subscribers.count else { return }
            // Replace with noop rather than remove to avoid index invalidation
            self.subscribers[idx] = { _ in }
        }
    }

    public func snapshot() -> [LogEntry] {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring
    }

    public func clearRing() {
        ringLock.lock(); defer { ringLock.unlock() }
        ring.removeAll()
    }

    // MARK: - Internal write paths

    func appendToRingBuffer(_ entry: LogEntry) {
        ringLock.lock()
        ring.append(entry)
        if ring.count > ringCap {
            ring.removeFirst(ring.count - ringCap)
        }
        ringLock.unlock()

        subLock.lock()
        let subs = subscribers
        subLock.unlock()
        for cb in subs { cb(entry) }
    }

    func appendToFile(_ entry: LogEntry) {
        queue.async { [weak self] in
            self?.writeToActiveFile(entry)
        }
    }

    // MARK: - Disk file rotation

    private lazy var logsDirectory: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("Homecast", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func activeFileURL() -> URL {
        logsDirectory.appendingPathComponent("homecast.log")
    }

    private func writeToActiveFile(_ entry: LogEntry) {
        let url = activeFileURL()

        // Serialise as one JSON line per entry (easy to grep, parse, ship).
        guard let line = jsonLine(for: entry) else { return }

        // Rotate if file exceeds max size.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size >= maxFileSize {
            rotate()
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Intentionally silent — the unified log still captured this entry.
        }
    }

    private func rotate() {
        let fm = FileManager.default
        let base = logsDirectory
        // Shift homecast.9.log → drop; homecast.N.log → homecast.(N+1).log.
        let oldest = base.appendingPathComponent("homecast.\(maxFiles - 1).log")
        try? fm.removeItem(at: oldest)
        for i in stride(from: maxFiles - 2, through: 0, by: -1) {
            let src = i == 0
                ? base.appendingPathComponent("homecast.log")
                : base.appendingPathComponent("homecast.\(i).log")
            let dst = base.appendingPathComponent("homecast.\(i + 1).log")
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func jsonLine(for entry: LogEntry) -> Data? {
        var obj: [String: Any] = [
            "timestamp": PersistentLogStore.isoFormatter.string(from: entry.timestamp),
            "level": entry.level.rawValue,
            "category": entry.category,
            "message": entry.message,
        ]
        if let md = entry.metadata { obj["metadata"] = md }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var line = data
        line.append(0x0A) // newline
        return line
    }

    /// Returns all log files in oldest-first order. For "copy for support" bundles.
    public func allLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: logsDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("homecast") && $0.pathExtension == "log" }
            .sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad < bd
            }
    }
}
