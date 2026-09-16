import XCTest
@testable import CameraCore

final class CameraSnapshotPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testExplicitRefreshNeverUsesEvenAVeryRecentCache() {
        XCTAssertFalse(CameraSnapshotPolicy.canReuse(capturedAt: now, cachedWidth: 1280,
                                                      requestedWidth: 1280, maxAge: 0, now: now))
        XCTAssertFalse(CameraSnapshotPolicy.canReuse(capturedAt: now, cachedWidth: 1280,
                                                      requestedWidth: 1280, maxAge: -1, now: now))
    }

    func testPermittedCacheMustBeRecentAndMatchTheRequestedResolution() {
        let captured = now.addingTimeInterval(-5)
        XCTAssertTrue(CameraSnapshotPolicy.canReuse(capturedAt: captured, cachedWidth: 1280,
                                                     requestedWidth: 1280, maxAge: 8, now: now))
        XCTAssertFalse(CameraSnapshotPolicy.canReuse(capturedAt: captured, cachedWidth: 320,
                                                      requestedWidth: 1280, maxAge: 8, now: now))
        XCTAssertFalse(CameraSnapshotPolicy.canReuse(capturedAt: captured, cachedWidth: 1280,
                                                      requestedWidth: 1280, maxAge: 4, now: now))
    }

    func testClockRollbackDoesNotMakeAnOldImageFresh() {
        XCTAssertFalse(CameraSnapshotPolicy.canReuse(capturedAt: now.addingTimeInterval(60),
                                                      cachedWidth: 1280, requestedWidth: 1280,
                                                      maxAge: 8, now: now))
    }

    func testMinimumIntervalPacesPhysicalCapturesInsteadOfReturningOldPixels() {
        XCTAssertEqual(CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: nil, now: now), 0)
        XCTAssertEqual(CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: now, now: now), 3)
        XCTAssertEqual(CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: now.addingTimeInterval(-2), now: now), 1)
        XCTAssertEqual(CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: now.addingTimeInterval(-4), now: now), 0)
        XCTAssertEqual(CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: now.addingTimeInterval(60), now: now), 3)
    }

    func testWidthsAreBounded() {
        XCTAssertEqual(CameraSnapshotPolicy.requestedWidth(nil), 1280)
        XCTAssertEqual(CameraSnapshotPolicy.requestedWidth(Int.min), 160)
        XCTAssertEqual(CameraSnapshotPolicy.requestedWidth(960), 960)
        XCTAssertEqual(CameraSnapshotPolicy.requestedWidth(Int.max), 1920)
    }

    func testBothCapturePathsLeaveTimeInsideThe25SecondBridgeDeadline() {
        let pacing = CameraSnapshotPolicy.minimumInterval
        let rendering = CameraSnapshotPolicy.compositorTimeout
        XCTAssertLessThanOrEqual(pacing + CameraSnapshotPolicy.streamStartTimeout +
                                 CameraSnapshotPolicy.streamMuteTimeout + CameraSnapshotPolicy.streamWarmup + rendering, 23)
        XCTAssertLessThanOrEqual(pacing + CameraSnapshotPolicy.snapshotTimeout + rendering, 23)
    }
}

final class CameraLogPolicyTests: XCTestCase {
    func testCameraLoggingKeepsMetadataWithoutImageDataOrUnknownFields() throws {
        let pixels = Data("PRIVATE_CAMERA_PIXELS".utf8)
        let response: [String: Any] = ["jpeg": pixels, "width": 320, "height": 180,
                                       "cached": false, "source": "stream", "futureImage": pixels]
        let logged = try XCTUnwrap(CameraLogPolicy.metadata(method: "camera.snapshot", value: response) as? [String: Any])
        XCTAssertNil(logged["jpeg"])
        XCTAssertNil(logged["futureImage"])
        XCTAssertEqual(logged["width"] as? Int, 320)
        XCTAssertEqual(logged["height"] as? Int, 180)
        XCTAssertEqual(logged["cached"] as? Bool, false)
        XCTAssertEqual(logged["source"] as? String, "stream")
        XCTAssertEqual(response["jpeg"] as? Data, pixels)
    }

    func testUnexpectedCameraPayloadsAreOmittedRatherThanStringified() {
        XCTAssertEqual(CameraLogPolicy.metadata(method: "camera.snapshot", value: ["PRIVATE_CAMERA_PIXELS"]) as? String,
                       "[camera payload omitted]")
        let logged = CameraLogPolicy.metadata(method: "camera.snapshot", value: ["width": ["jpeg": "PRIVATE_CAMERA_PIXELS"]])
        XCTAssertTrue((logged as? [String: Any])?.isEmpty == true)
    }

    func testNonCameraResponsesKeepTheirNormalDiagnosticContent() {
        let response = ["value": 42]
        XCTAssertEqual(CameraLogPolicy.metadata(method: "characteristic.get", value: response) as? [String: Int], response)
    }
}
