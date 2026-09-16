import Foundation

/// Platform-independent rules shared by the native capture service and its tests.
enum CameraSnapshotPolicy {
    static let minimumInterval: TimeInterval = 3
    static let streamStartTimeout: TimeInterval = 12
    static let streamMuteTimeout: TimeInterval = 2
    static let streamWarmup: TimeInterval = 1
    static let snapshotTimeout: TimeInterval = 17
    static let compositorTimeout: TimeInterval = 2

    static func requestedWidth(_ width: Int?) -> Int {
        min(max(width ?? 1280, 160), 1920)
    }

    static func canReuse(capturedAt: Date, cachedWidth: Int, requestedWidth: Int,
                         maxAge: TimeInterval, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        // maxAge == 0 is an explicit refresh, not permission to use the
        // minimum-interval cache. Clock rollback must not extend cache life.
        return maxAge > 0 && age >= 0 && age <= maxAge && cachedWidth == requestedWidth
    }

    static func waitBeforeCapture(lastAttempt: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        // A clock adjustment must not turn a three-second floor into minutes.
        return min(minimumInterval, max(0, minimumInterval - now.timeIntervalSince(lastAttempt)))
    }
}

/// Logging is metadata-only even for images small enough to fit a log limit.
enum CameraLogPolicy {
    private static let metadataKeys = Set([
        "homeId", "accessoryId", "capturedAt", "mimeType", "width", "height", "cached", "source",
        "maxWidth", "maxAgeSec", "seq", "state", "reason", "started", "activeStreams", "fps", "quality",
        "supported", "engineWindow", "captureAvailable", "screenRecordingAuthorization", "screenRecording",
        "maxStreamsPerHome",
    ])

    static func metadata(method: String, value: Any) -> Any {
        let object = value as? [String: Any]
        guard method.hasPrefix("camera.") || object?["jpeg"] != nil else { return value }
        guard let object else { return "[camera payload omitted]" }
        var result: [String: Any] = [:]
        for key in metadataKeys {
            if let text = object[key] as? String { result[key] = String(text.prefix(200)) }
            else if let number = object[key] as? NSNumber { result[key] = number }
            else if object[key] is NSNull { result[key] = NSNull() }
        }
        return result
    }
}
