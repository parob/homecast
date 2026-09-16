import XCTest
@testable import CameraCore

final class CameraLiveRegistryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)

    func testDifferentUsersShareOneStreamAndCannotStopEachOther() throws {
        var registry = CameraLiveRegistry()
        let first = try registry.acquire(accessoryId: "a", homeId: "home", viewerId: "one", instance: "pod1", now: now)
        let second = try registry.acquire(accessoryId: "a", homeId: "home", viewerId: "two", instance: "pod2", now: now)
        XCTAssertEqual(first.streamId, second.streamId)
        XCTAssertEqual(registry.reserveStarts(now: now).count, 1)
        XCTAssertTrue(registry.streaming(accessoryId: "a", streamId: first.streamId))
        registry.release(accessoryId: "a", viewerId: "unknown")
        registry.release(accessoryId: "a", viewerId: "one")
        XCTAssertEqual(registry.cameras["a"]?.viewers.count, 1)
        XCTAssertEqual(registry.occupied(homeId: "home"), 1)
        registry.release(accessoryId: "a", viewerId: "two")
        XCTAssertTrue(registry.cameras.isEmpty)
    }

    func testThirdCameraQueuesAndStartsInFIFOOrderWhenASlotIsFreed() throws {
        var registry = CameraLiveRegistry()
        for id in ["a", "b", "c", "d"] {
            _ = try registry.acquire(accessoryId: id, homeId: "home", viewerId: id, instance: "pod", now: now)
        }
        XCTAssertEqual(registry.reserveStarts(now: now).map(\.accessoryId), ["a", "b"])
        XCTAssertTrue(registry.reserveStarts(now: now).isEmpty, "Concurrent starts already own their slots")
        XCTAssertEqual(registry.queuePosition(accessoryId: "c"), 1)
        XCTAssertEqual(registry.queuePosition(accessoryId: "d"), 2)
        registry.release(accessoryId: "a", viewerId: "a")
        XCTAssertEqual(registry.reserveStarts(now: now).map(\.accessoryId), ["c"])
    }

    func testDifferentHomesHaveIndependentLimitsAndSnapshotsCount() throws {
        var registry = CameraLiveRegistry()
        for id in ["a", "b", "c"] {
            _ = try registry.acquire(accessoryId: id, homeId: "home", viewerId: id, instance: "pod", now: now)
        }
        _ = try registry.acquire(accessoryId: "other", homeId: "other-home", viewerId: "other", instance: "pod", now: now)
        XCTAssertEqual(registry.reserveStarts(externalSlots: ["home": 1], now: now).map(\.accessoryId), ["a", "other"])
        XCTAssertEqual(registry.reserveStarts(now: now).map(\.accessoryId), ["b"])
    }

    func testIdleViewerExpiresWithoutInterruptingAnActiveViewer() throws {
        var registry = CameraLiveRegistry()
        _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "one", instance: "pod", now: now)
        _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "two", instance: "pod", now: now)
        XCTAssertNotNil(registry.touch(accessoryId: "a", viewerId: "two", now: now.addingTimeInterval(20)))
        let ended = registry.expire(now: now.addingTimeInterval(30))
        XCTAssertEqual(ended.map(\.viewer.id), ["one"])
        XCTAssertEqual(ended.first?.reason, "idle")
        XCTAssertEqual(registry.cameras["a"]?.viewers.count, 1)
        XCTAssertNil(registry.touch(accessoryId: "a", viewerId: "one", now: now.addingTimeInterval(31)))
    }

    func testRepeatedAcquireCannotBypassMaximumDuration() throws {
        var registry = CameraLiveRegistry()
        for seconds in stride(from: 0, to: 600, by: 10) {
            _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "one", instance: "pod", now: now.addingTimeInterval(Double(seconds)))
        }
        XCTAssertNil(registry.touch(accessoryId: "a", viewerId: "one", now: now.addingTimeInterval(600)))
        let ended = registry.expire(now: now.addingTimeInterval(600))
        XCTAssertEqual(ended.first?.reason, "expired")
        XCTAssertTrue(registry.cameras.isEmpty)
    }

    func testViewerCannotMoveToAnotherCameraHomeOrDestination() throws {
        var registry = CameraLiveRegistry()
        _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "one", instance: "pod", now: now)
        for (camera, home, instance) in [("b", "h", "pod"), ("a", "other", "pod"), ("a", "h", "other")] {
            XCTAssertThrowsError(try registry.acquire(accessoryId: camera, homeId: home, viewerId: "one", instance: instance, now: now))
        }
    }

    func testBusyRetryReleasesCapacityAndAnOldCompletionCannotAffectNewSession() throws {
        var registry = CameraLiveRegistry()
        let camera = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "one", instance: "pod", now: now)
        _ = registry.reserveStarts(now: now)
        registry.retry(accessoryId: "a", streamId: camera.streamId, after: now.addingTimeInterval(3))
        XCTAssertEqual(registry.occupied(homeId: "h"), 0)
        XCTAssertTrue(registry.reserveStarts(now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(registry.reserveStarts(now: now.addingTimeInterval(3)).count, 1)
        registry.finish(accessoryId: "a")
        let replacement = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "new", instance: "pod", now: now)
        XCTAssertNotEqual(camera.streamId, replacement.streamId)
        XCTAssertFalse(registry.streaming(accessoryId: "a", streamId: camera.streamId))
        XCTAssertNil(registry.finish(accessoryId: "a", streamId: camera.streamId))
        XCTAssertNotNil(registry.cameras["a"])
    }

    func testBoundedViewerCountAllowsIdempotentRetriesAtTheLimit() throws {
        var registry = CameraLiveRegistry()
        for index in 0..<CameraLiveRegistry.maximumViewersPerCamera {
            _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: String(index), instance: "pod", now: now)
        }
        XCTAssertThrowsError(try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "too-many", instance: "pod", now: now))
        XCTAssertNoThrow(try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "0", instance: "pod", now: now))
    }

    func testCancellingPhysicalStartKeepsItsSlotUntilCleanupFinishes() throws {
        var registry = CameraLiveRegistry()
        _ = try registry.acquire(accessoryId: "a", homeId: "h", viewerId: "replacement", instance: "pod", now: now)
        XCTAssertTrue(registry.reserveStarts(externalSlots: ["h": 1], blockedAccessoryIds: ["a"], now: now).isEmpty)
        XCTAssertEqual(registry.cameras["a"]?.state, .queued)
        XCTAssertEqual(registry.reserveStarts(now: now).map(\.accessoryId), ["a"])
    }
}
