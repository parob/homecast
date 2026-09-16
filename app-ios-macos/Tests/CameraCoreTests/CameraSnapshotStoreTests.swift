import XCTest
@testable import CameraCore

final class CameraSnapshotStoreTests: XCTestCase {
    private var root: URL!
    private let home = UUID()
    private let camera = UUID()
    private let account = UUID()
    private var session: CameraCacheSession { CameraCacheSession(account: account, staging: false, generation: 1) }
    private var image: RelayCameraSnapshot {
        RelayCameraSnapshot(jpeg: Data("synthetic jpeg".utf8), capturedAt: Date(timeIntervalSince1970: 1000),
                            width: 720, height: 1280, source: "stream", requestedWidth: 1280)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("homecast-camera-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testReloadPreservesPixelsOriginalDateDimensionsAndSource() async throws {
        let first = CameraSnapshotStore(root: root)
        await first.save(image, home: home, accessory: camera, session: session)
        let reloaded = CameraSnapshotStore(root: root)
        let loaded = await reloaded.load(home: home, accessory: camera, session: session)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.jpeg, image.jpeg)
        XCTAssertEqual(stored.capturedAt, image.capturedAt)
        XCTAssertEqual(stored.width, 720)
        XCTAssertEqual(stored.height, 1280)
        XCTAssertEqual(stored.source, "stream")
        XCTAssertEqual(stored.requestedWidth, 1280)
    }

    func testOneLatestFilePerCameraAndNoOlderOverwrite() async throws {
        let store = CameraSnapshotStore(root: root)
        let newer = RelayCameraSnapshot(jpeg: Data("new".utf8), capturedAt: Date(timeIntervalSince1970: 2000),
                                        width: 720, height: 1280, source: "stream", requestedWidth: 1280)
        await store.save(image, home: home, accessory: camera, session: session)
        await store.save(newer, home: home, accessory: camera, session: session)
        await store.save(image, home: home, accessory: camera, session: session)
        let loaded = await store.load(home: home, accessory: camera, session: session)
        XCTAssertEqual(loaded?.jpeg, newer.jpeg)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(files[0]).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((rootAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testAccountsHomesAndEnvironmentsAreIsolatedOnColdStart() async {
        let store = CameraSnapshotStore(root: root)
        await store.save(image, home: home, accessory: camera, session: session)
        let other = CameraSnapshotStore(root: root)
        let wrongHome = await other.load(home: UUID(), accessory: camera, session: session)
        XCTAssertNil(wrongHome)
        let otherAccount = CameraSnapshotStore(root: root)
        let wrongAccount = await otherAccount.load(home: home, accessory: camera,
          session: CameraCacheSession(account: UUID(), staging: false, generation: 1))
        XCTAssertNil(wrongAccount)
        let staging = CameraSnapshotStore(root: root)
        let wrongEnvironment = await staging.load(home: home, accessory: camera,
          session: CameraCacheSession(account: account, staging: true, generation: 1))
        XCTAssertNil(wrongEnvironment)
    }

    func testLogoutDeletesDiskAndFencesDelayedWrites() async {
        let store = CameraSnapshotStore(root: root)
        await store.save(image, home: home, accessory: camera, session: session)
        await store.updateSession(CameraCacheSession(account: nil, staging: false, generation: 2))
        await store.save(image, home: home, accessory: camera, session: session)
        let stale = await store.load(home: home, accessory: camera, session: session)
        XCTAssertNil(stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAccountSwitchDeletesPreviousAccountAndRejectsOldSession() async {
        let store = CameraSnapshotStore(root: root)
        await store.save(image, home: home, accessory: camera, session: session)
        let next = CameraCacheSession(account: UUID(), staging: false, generation: 2)
        await store.updateSession(next)
        await store.save(image, home: home, accessory: camera, session: session)
        let reloaded = CameraSnapshotStore(root: root)
        let previous = await reloaded.load(home: home, accessory: camera, session: session)
        XCTAssertNil(previous)
    }

    func testMalformedFilesAndUnavailableStorageAreCacheMisses() async throws {
        let store = CameraSnapshotStore(root: root)
        await store.save(image, home: home, accessory: camera, session: session)
        let path = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.path).first { $0.hasSuffix(".json") })
        try Data("incomplete".utf8).write(to: root.appendingPathComponent(path))
        let corrupt = await store.load(home: home, accessory: camera, session: session)
        XCTAssertNil(corrupt)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let unavailable = CameraSnapshotStore(root: blocked.appendingPathComponent("cache"))
        await unavailable.save(image, home: home, accessory: camera, session: session)
        let missing = await unavailable.load(home: home, accessory: camera, session: session)
        XCTAssertNil(missing)
    }

    func testInvalidImageDoesNotReplaceLastGoodFile() async {
        let store = CameraSnapshotStore(root: root)
        await store.save(image, home: home, accessory: camera, session: session)
        let empty = RelayCameraSnapshot(jpeg: Data(), capturedAt: Date(), width: 720, height: 1280,
                                       source: "stream", requestedWidth: 1280)
        await store.save(empty, home: home, accessory: camera, session: session)
        let stored = await store.load(home: home, accessory: camera, session: session)
        XCTAssertEqual(stored?.jpeg, image.jpeg)
    }

    func testJWTSubjectIsOnlyASafeAccountNamespaceNotStoredCredentials() throws {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": account.uuidString, "exp": 1])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CameraCacheSession.accountID(token: "header.\(encoded).signature"), account)
        XCTAssertNil(CameraCacheSession.accountID(token: nil))
        XCTAssertNil(CameraCacheSession.accountID(token: "invalid"))
        let path = Data("{\"sub\":\"../../escape\"}".utf8).base64EncodedString()
        XCTAssertNil(CameraCacheSession.accountID(token: "header.\(path).signature"))
    }

    func testCachedFallbackCannotHideAuthorizationOrMissingCameraErrors() {
        for code in ["PERMISSION_DENIED", "UNAUTHORIZED", "CAMERAS_DISABLED", "ACCESSORY_NOT_FOUND", "CAMERA_NOT_SUPPORTED"] {
            XCTAssertFalse(CameraSnapshotPolicy.canServeStale(after: code))
        }
        for code in ["CAMERA_BUSY", "SNAPSHOT_TIMEOUT", "CAMERA_CAPTURE_UNAVAILABLE", "STREAM_FAILED"] {
            XCTAssertTrue(CameraSnapshotPolicy.canServeStale(after: code))
        }
    }
}
