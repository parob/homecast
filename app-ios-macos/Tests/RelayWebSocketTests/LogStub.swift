import Foundation

// The transport's logger is the only app dependency this executable replaces.
// The real bridge and real URLSessionWebSocketTask are compiled below it.
enum Log {
    static func info(_ text: String, category: String, metadata: [String: String] = [:]) {}
    static func warning(_ text: String, category: String, metadata: [String: String] = [:]) {}
}
