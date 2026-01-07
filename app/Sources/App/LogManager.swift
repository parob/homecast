import Foundation
import SwiftUI

/// Manages application logs for display in the UI
@MainActor
class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []

    private let maxLogs = 500
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

    func clear() {
        logs.removeAll()
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

enum LogCategory: String {
    case general = "App"
    case websocket = "WS"
    case homekit = "HK"
    case auth = "Auth"
}

enum LogDirection {
    case incoming  // Server → App
    case outgoing  // App → Server
}
