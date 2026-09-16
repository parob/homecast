import Foundation

/// The relay, not a browser or cloud worker, owns the HomeKit stream budget.
/// All mutations run on CameraCaptureService's main actor. No image data here.
struct CameraLiveRegistry {
    enum State: String { case queued, starting, streaming }
    enum Failure: Error { case capacity, conflictingViewer }
    struct Viewer {
        let id: String
        let instance: String
        let joinedAt: Date
        var touchedAt: Date
    }
    struct Camera {
        let accessoryId: String
        let homeId: String
        let streamId: String
        let order: Int
        var state: State = .queued
        var retryAt: Date = .distantPast
        var viewers: [String: Viewer] = [:]
    }
    struct EndedViewer {
        let camera: Camera
        let viewer: Viewer
        let reason: String
    }

    static let streamsPerHome = 2
    static let idleSeconds: TimeInterval = 30
    static let sessionSeconds: TimeInterval = 600
    static let maximumCameras = 64
    static let maximumViewersPerCamera = 64
    private(set) var cameras: [String: Camera] = [:]
    private var nextOrder = 0

    mutating func acquire(accessoryId: String, homeId: String, viewerId: String,
                          instance: String, now: Date = Date()) throws -> Camera {
        // A lease names exactly one camera and destination for its lifetime.
        if let existing = cameras.values.first(where: { $0.viewers[viewerId] != nil }),
           existing.accessoryId != accessoryId || existing.homeId != homeId || existing.viewers[viewerId]?.instance != instance {
            throw Failure.conflictingViewer
        }
        if let existing = cameras[accessoryId], existing.homeId != homeId { throw Failure.conflictingViewer }
        guard cameras[accessoryId] != nil || cameras.count < Self.maximumCameras else { throw Failure.capacity }
        if cameras[accessoryId] == nil {
            nextOrder += 1
            cameras[accessoryId] = Camera(accessoryId: accessoryId, homeId: homeId,
                                         streamId: UUID().uuidString, order: nextOrder)
        }
        var camera = cameras[accessoryId]!
        guard camera.viewers[viewerId] != nil || camera.viewers.count < Self.maximumViewersPerCamera else { throw Failure.capacity }
        if camera.viewers[viewerId] == nil {
            camera.viewers[viewerId] = Viewer(id: viewerId, instance: instance, joinedAt: now, touchedAt: now)
        } else {
            // Idempotent retries do not reset the maximum viewing duration.
            camera.viewers[viewerId]?.touchedAt = now
        }
        cameras[accessoryId] = camera
        return camera
    }

    mutating func touch(accessoryId: String, viewerId: String, now: Date = Date()) -> Camera? {
        guard let viewer = cameras[accessoryId]?.viewers[viewerId],
              now.timeIntervalSince(viewer.touchedAt) < Self.idleSeconds,
              now.timeIntervalSince(viewer.joinedAt) < Self.sessionSeconds else { return nil }
        cameras[accessoryId]?.viewers[viewerId]?.touchedAt = now
        return cameras[accessoryId]
    }

    @discardableResult
    mutating func release(accessoryId: String, viewerId: String) -> Viewer? {
        let viewer = cameras[accessoryId]?.viewers.removeValue(forKey: viewerId)
        if cameras[accessoryId]?.viewers.isEmpty == true { cameras.removeValue(forKey: accessoryId) }
        return viewer
    }

    @discardableResult
    mutating func finish(accessoryId: String, streamId: String? = nil) -> Camera? {
        guard let camera = cameras[accessoryId], streamId == nil || streamId == camera.streamId else { return nil }
        cameras.removeValue(forKey: accessoryId)
        return camera
    }

    mutating func expire(now: Date = Date()) -> [EndedViewer] {
        var ended: [EndedViewer] = []
        for camera in Array(cameras.values) {
            for viewer in camera.viewers.values {
                let reason: String?
                if now.timeIntervalSince(viewer.joinedAt) >= Self.sessionSeconds { reason = "expired" }
                else if now.timeIntervalSince(viewer.touchedAt) >= Self.idleSeconds { reason = "idle" }
                else { reason = nil }
                if let reason {
                    ended.append(EndedViewer(camera: camera, viewer: viewer, reason: reason))
                    release(accessoryId: camera.accessoryId, viewerId: viewer.id)
                }
            }
        }
        return ended
    }

    func occupied(homeId: String) -> Int {
        cameras.values.filter { $0.homeId == homeId && $0.state != .queued }.count
    }

    /// Reserve synchronously BEFORE the asynchronous HomeKit start. Short
    /// snapshot streams and cancelling starts are counted as external slots.
    mutating func reserveStarts(externalSlots: [String: Int] = [:], blockedAccessoryIds: Set<String> = [], now: Date = Date()) -> [Camera] {
        var starts: [Camera] = []
        for camera in cameras.values.sorted(by: { $0.order < $1.order }) {
            guard camera.state == .queued, camera.retryAt <= now, !blockedAccessoryIds.contains(camera.accessoryId),
                  occupied(homeId: camera.homeId) + externalSlots[camera.homeId, default: 0] < Self.streamsPerHome else { continue }
            cameras[camera.accessoryId]?.state = .starting
            starts.append(cameras[camera.accessoryId]!)
        }
        return starts
    }

    mutating func streaming(accessoryId: String, streamId: String) -> Bool {
        guard cameras[accessoryId]?.streamId == streamId, cameras[accessoryId]?.state == .starting else { return false }
        cameras[accessoryId]?.state = .streaming
        return true
    }

    /// HomeKit can also be busy outside Homecast. Release our reservation and
    /// retry without stealing another viewer's stream or blocking other homes.
    mutating func retry(accessoryId: String, streamId: String, after: Date) {
        guard cameras[accessoryId]?.streamId == streamId else { return }
        cameras[accessoryId]?.state = .queued
        cameras[accessoryId]?.retryAt = after
    }

    func queuePosition(accessoryId: String) -> Int? {
        guard let camera = cameras[accessoryId], camera.state == .queued else { return nil }
        return cameras.values.filter { $0.homeId == camera.homeId && $0.state == .queued && $0.order <= camera.order }.count
    }
}
