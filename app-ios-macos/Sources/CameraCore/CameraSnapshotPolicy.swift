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
