import Foundation
import SwiftUI

/// Manages application logs for display in the UI
@MainActor
class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var journeyLogs: [JourneyLogEntry] = []

    private let maxLogs = 500
    private let maxJourneyLogs = 200
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private init() {}

    func log(_ message: String, category: LogCategory = .general, direction: LogDirection? = nil) {
        let entry = LogEntry(
            timestamp: Date(),
            message: message,
            category: category,
            direction: direction
        )

        logs.append(entry)

        // Trim old logs
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }

        // Also print to console
        let dirStr = direction.map { $0 == .incoming ? "←" : "→" } ?? "•"
        print("[\(category.rawValue)] \(dirStr) \(message)")
    }

    /// Log a detailed journey entry for request/response tracking
    func logJourney(
        requestId: String,
        action: String,
        phase: JourneyPhase,
        route: String,
        isPubsub: Bool,
        durationMs: Int? = nil,
        details: String? = nil,
        responseData: ResponseData? = nil,
        sourceInstance: String? = nil,
        targetInstance: String? = nil
    ) {
        let entry = JourneyLogEntry(
            timestamp: Date(),
            requestId: requestId,
            action: action,
            phase: phase,
            route: route,
            isPubsub: isPubsub,
            durationMs: durationMs,
            details: details,
            responseData: responseData,
            sourceInstance: sourceInstance,
            targetInstance: targetInstance
        )

        journeyLogs.append(entry)

        // Trim old journey logs
        if journeyLogs.count > maxJourneyLogs {
            journeyLogs.removeFirst(journeyLogs.count - maxJourneyLogs)
        }

        // Console output
        let phaseEmoji = phase == .request ? "📥" : (phase == .response ? "📤" : "⚡️")
        let routeEmoji = isPubsub ? "🌐" : "⚡️"
        let durationStr = durationMs.map { " (\($0)ms)" } ?? ""
        let responseStr = responseData.map { " | \($0.payloadSummary ?? "")".trimmingCharacters(in: .whitespaces) } ?? ""
        print("[\(requestId.prefix(8))] \(phaseEmoji) \(action) | \(routeEmoji) \(route)\(durationStr)\(responseStr)")
    }

    func clear() {
        logs.removeAll()
    }

    func clearJourneys() {
        journeyLogs.removeAll()
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let category: LogCategory
    let direction: LogDirection?

    var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: timestamp)
    }
}

// MARK: - Journey Log Entry

struct JourneyLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let requestId: String
    let action: String
    let phase: JourneyPhase
    let route: String
    let isPubsub: Bool
    let durationMs: Int?
    let details: String?
    let responseData: ResponseData?

    // Detailed routing info
    let sourceInstance: String?
    let targetInstance: String?

    var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: timestamp)
    }

    var shortId: String {
        String(requestId.prefix(8))
    }

    /// Whether source and target are the same instance
    var isSameInstance: Bool {
        guard let source = sourceInstance, let target = targetInstance else { return false }
        return source == target
    }
}

/// Data about the response we sent
struct ResponseData {
    let isSuccess: Bool
    let errorCode: String?
    let errorMessage: String?
    let payloadSummary: String?  // Brief summary of what we returned
    let payloadSize: Int?        // Size in bytes
    let itemCount: Int?          // For list responses, how many items
}

enum JourneyPhase: String {
    case request = "REQ"
    case processing = "PROC"
    case response = "RESP"
}

enum LogCategory: String, CaseIterable {
    case general = "App"
    case websocket = "WS"
    case homekit = "HK"
    case auth = "Auth"
}

enum LogDirection {
    case incoming  // Server → App
    case outgoing  // App → Server
}
