import Foundation
#if canImport(HomeKit) && targetEnvironment(macCatalyst)
import HomeKit
import UIKit
import CoreGraphics

/// Camera snapshots and live frames for the cloud relay.
///
/// HomeKit renders a camera only into an `HMCameraView`, and it composites
/// that out of process — no UIKit or Core Animation call ever sees the pixels.
/// The one public door is the window server: capture the window the view is
/// in (`CGWindowListCreateImage`) and crop. So every camera view lives in the
/// engine window (`CameraEngine`), which is always ordered in, sits below the
/// desktop so nobody sees it. macOS allows an app to capture its own windows
/// without granting access to the rest of the screen.
///
/// One capture per frame serves every camera on the canvas; the cost that
/// scales with cameras is HomeKit's decoding and our JPEG encoding, not the
/// capture. Layout is a grid whose cell size shrinks as sessions are added.
///
/// Cloud relay only: Community mode never reaches this (the bridge refuses
/// first), and iOS has no window server to ask.
@MainActor
final class CameraCaptureService: NSObject {
    private let homeKitManager: HomeKitManager

    init(homeKitManager: HomeKitManager) {
        self.homeKitManager = homeKitManager
    }

    // MARK: - Limits

    /// HomeKit refuses a third concurrent stream per home (HMError 14, busy),
    /// measured on two homes. Reported so the UI can explain, not enforced
    /// here — HomeKit enforces it and we surface the answer.
    static let maxStreamsPerHome = 2
    static let streamStartBound: TimeInterval = 20
    /// A live session with no keepalive for this long is stopped.
    static let liveIdle: TimeInterval = 30
    /// A live session never outlives this without being restarted.
    static let liveHardCap: TimeInterval = 10 * 60
    static let defaultFps: Double = 4
    static let defaultLiveWidth = 960
    static let defaultLiveQuality: CGFloat = 0.6
    static let snapshotQuality: CGFloat = 0.7

    // MARK: - Capability

    static func capability(of accessory: HMAccessory) -> [String: Any]? {
        guard let profile = accessory.cameraProfiles?.first else { return nil }
        return [
            "snapshot": profile.snapshotControl != nil,
            "stream": profile.streamControl != nil,
        ]
    }

    /// Whether the window server will give us pixels.
    ///
    /// This is NOT a Screen Recording permission check. Our own window can be
    /// captured when CGPreflightScreenCaptureAccess() is false. Test whether
    /// the engine window is capturable, without requesting broader access.
    static var captureAvailable: Bool {
        guard let canvas = CameraEngine.shared.canvas, canvas.window != nil,
              let (cg, _) = captureWindowImage(of: canvas) else { return false }
        // An opaque canvas proves the window is capturable, not that macOS
        // granted Screen Recording. Snapshot capture also checks image content.
        return isOpaque(cg)
    }

    private static func isOpaque(_ cg: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var alpha = 0
        for i in stride(from: 3, to: pixels.count, by: 4) { alpha += Int(pixels[i]) }
        return alpha > 0
    }

    func capabilities() -> [String: Any] {
        let available = Self.captureAvailable
        return [
            "supported": true,
            "engineWindow": CameraEngine.shared.isAvailable,
            "captureAvailable": available,
            "screenRecordingAuthorization": CGPreflightScreenCaptureAccess() ? "granted" : "denied",
            // Legacy field: build 70 named capture readiness as permission.
            // Preserve its meaning for older clients; new clients use the two
            // explicit fields above and never infer permission from capture.
            "screenRecording": available ? "granted" : "denied",
            "maxStreamsPerHome": Self.maxStreamsPerHome,
            "activeStreams": liveSessions.count,
            "fps": Self.defaultFps,
        ]
    }

    /// Ask macOS for Screen Recording. Prompts the first time; afterwards the
    /// user has to use System Settings, which is why the answer is reported.
    func requestScreenRecording() -> [String: Any] {
        let granted = CGRequestScreenCaptureAccess()
        return ["screenRecording": granted ? "granted" : "denied"]
    }

    private func readyCanvas() throws -> CameraEngineCanvas {
        guard let canvas = CameraEngine.shared.canvas, canvas.window != nil else {
            throw CameraError.engineUnavailable
        }
        guard Self.captureAvailable else { throw CameraError.captureUnavailable }
        return canvas
    }

    // MARK: - Snapshot

    private struct CachedSnapshot {
        let jpeg: Data
        let capturedAt: Date
        let width: Int
        let height: Int
        let source: String
        let requestedWidth: Int
    }
    private var snapshotCache: [String: CachedSnapshot] = [:]
    private var snapshotInFlight: [String: Task<CachedSnapshot, Error>] = [:]
    private var lastPhysicalSnapshot: [String: Date] = [:]
    /// A still temporarily owns a stream, but never publishes live frames.
    private var snapshotStreams: Set<String> = []

    func snapshot(accessoryId: String, maxWidth: Int?, maxAgeSec: Double?) async throws -> [String: Any] {
        let width = CameraSnapshotPolicy.requestedWidth(maxWidth)
        let maxAge = maxAgeSec ?? 10
        if let cached = snapshotCache[accessoryId],
           CameraSnapshotPolicy.canReuse(capturedAt: cached.capturedAt, cachedWidth: cached.requestedWidth,
                                         requestedWidth: width, maxAge: maxAge) {
            return Self.snapshotPayload(accessoryId: accessoryId, cached, fromCache: true)
        }
        if let inFlight = snapshotInFlight[accessoryId] {
            return Self.snapshotPayload(accessoryId: accessoryId, try await inFlight.value, fromCache: true)
        }
        let task = Task<CachedSnapshot, Error> { @MainActor in
            try await self.captureSnapshot(accessoryId: accessoryId, width: width)
        }
        snapshotInFlight[accessoryId] = task
        defer { snapshotInFlight[accessoryId] = nil }
        let result = try await task.value
        snapshotCache[accessoryId] = result
        return Self.snapshotPayload(accessoryId: accessoryId, result, fromCache: false)
    }

    private static func snapshotPayload(accessoryId: String, _ s: CachedSnapshot, fromCache: Bool) -> [String: Any] {
        [
            "accessoryId": accessoryId,
            "mimeType": "image/jpeg",
            "jpeg": s.jpeg,
            "capturedAt": ISO8601DateFormatter().string(from: s.capturedAt),
            "width": s.width,
            "height": s.height,
            "cached": fromCache,
            "source": s.source,
        ]
    }

    private func captureSnapshot(accessoryId: String, width: Int) async throws -> CachedSnapshot {
        let accessory = try homeKitManager.hmAccessory(id: accessoryId)
        guard let profile = accessory.cameraProfiles?.first else {
            throw CameraError.notSupported
        }
        // Pace physical requests even when the previous one failed or HomeKit
        // returned an old captureDate. Cache age alone cannot enforce this.
        let remaining = CameraSnapshotPolicy.waitBeforeCapture(lastAttempt: lastPhysicalSnapshot[accessoryId])
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        let canvas = try readyCanvas()
        lastPhysicalSnapshot[accessoryId] = Date()

        // HomeKit's captureDate is the SNAPSHOT REQUEST date. Several cameras
        // return old pixels with a new date. A short stream gives us
        // a current frame without relying on that snapshot cache. Measured by
        // changing room lights: takeSnapshot stayed dark, the stream did not.
        if let control = profile.streamControl {
            return try await captureStreamStill(accessoryId: accessoryId, control: control,
                                                canvas: canvas, width: width)
        }
        guard let control = profile.snapshotControl else { throw CameraError.notSupported }
        let snapshot = try await takeSnapshot(control)
        // Snapshot-only accessories cannot promise pixel freshness. The source
        // flag lets clients label this as a request time rather than a capture.
        return try await captureSource(snapshot, accessoryId: accessoryId, canvas: canvas,
                                       width: width, capturedAt: snapshot.captureDate, source: "snapshot")
    }

    private func captureStreamStill(accessoryId: String, control: HMCameraStreamControl,
                                    canvas: CameraEngineCanvas, width: Int) async throws -> CachedSnapshot {
        // A live viewer already owns the stream: borrow it, never stop it.
        if let live = liveSessions[accessoryId], control.streamState == .streaming {
            // Reuse its rendered view too. Binding a second HMCameraView is
            // unnecessary and could disturb the live viewer's compositor slot.
            return try await captureSlot(live.slot, canvas: canvas, width: width, source: "stream")
        }
        guard streamSettles[ObjectIdentifier(control)] == nil,
              !snapshotStreams.contains(accessoryId),
              control.streamState == .notStreaming else { throw CameraError.busy }
        snapshotStreams.insert(accessoryId)
        // Stop on success, timeout, cancellation, empty capture, or any error.
        // This is deliberately not startLive: no ticker, fan-out, or idle lease.
        defer {
            control.stopStream()
            snapshotStreams.remove(accessoryId)
        }
        switch await startStream(control, timeout: CameraSnapshotPolicy.streamStartTimeout) {
        case .started: break
        case .timeout: throw CameraError.snapshotTimeout
        case .failed(let error):
            if (error as NSError).domain == HMErrorDomain,
               (error as NSError).code == HMError.accessoryIsBusy.rawValue { throw CameraError.busy }
            throw CameraError.streamFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let stream = control.cameraStream, control.streamState == .streaming else {
            throw CameraError.streamFailed("The camera stream ended before a frame arrived.")
        }
        // A still never opts into listening or talkback.
        try await muteStillStream(stream)
        return try await captureSource(stream, accessoryId: accessoryId, canvas: canvas,
                                       width: width, source: "stream")
    }

    private func muteStillStream(_ stream: HMCameraStream) async throws {
        guard stream.audioStreamSetting != .muted else { return }
        // Do not render a still's stream unless incoming AND outgoing audio
        // are muted. Keep this callback bounded too: waiting indefinitely for
        // the async HomeKit alternative would leak our short-lived stream.
        let settle = MuteSettle()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            settle.continuation = continuation
            stream.updateAudioStreamSetting(.muted) { error in
                Task { @MainActor in
                    guard let cont = settle.claim() else { return }
                    if let error {
                        cont.resume(throwing: CameraError.streamFailed("Could not mute camera audio: \(error.localizedDescription)"))
                    } else {
                        cont.resume()
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(CameraSnapshotPolicy.streamMuteTimeout * 1_000_000_000))
                settle.claim()?.resume(throwing: CameraError.streamFailed("Could not confirm muted camera audio in time."))
            }
        }
    }

    private func captureSource(_ cameraSource: HMCameraSource, accessoryId: String,
                               canvas: CameraEngineCanvas, width: Int,
                               capturedAt: Date? = nil, source: String) async throws -> CachedSnapshot {
        let slot = allocateSlot(kind: .snapshot, accessoryId: accessoryId, aspect: cameraSource.aspectRatio)
        defer { releaseSlot(slot) }
        canvas.addSubview(slot.view)
        slot.view.cameraSource = cameraSource
        // Start-stream means transport is established, not that the first
        // decoded frame has reached the out-of-process compositor yet.
        if source == "stream" {
            try await Task.sleep(nanoseconds: UInt64(CameraSnapshotPolicy.streamWarmup * 1_000_000_000))
        }
        return try await captureSlot(slot, canvas: canvas, width: width,
                                     capturedAt: capturedAt, source: source)
    }

    private func captureSlot(_ slot: Slot, canvas: CameraEngineCanvas, width: Int,
                             capturedAt: Date? = nil, source: String) async throws -> CachedSnapshot {
        // The image lands in the slot asynchronously; poll the window until
        // the crop stops being empty.
        var best: (Data, Int, Int)?
        for _ in 0..<Int(CameraSnapshotPolicy.compositorTimeout / 0.05) {
            try await Task.sleep(nanoseconds: 50_000_000)
            guard let (cg, scale) = Self.captureWindowImage(of: canvas) else { continue }
            guard let crop = Self.crop(cg, to: slot.view, in: canvas, scale: scale) else { continue }
            let stats = Self.stats(of: crop)
            if stats.isPicture, let data = Self.jpeg(crop, maxWidth: width, quality: Self.snapshotQuality) {
                let encodedWidth = min(crop.width, width)
                best = (data, encodedWidth, Int(Double(crop.height) * Double(encodedWidth) / Double(crop.width)))
                break
            }
        }
        guard let (data, w, h) = best else { throw CameraError.captureEmpty }
        return CachedSnapshot(jpeg: data, capturedAt: capturedAt ?? Date(), width: w, height: h,
                              source: source, requestedWidth: width)
    }

    private var snapshotSettles: [ObjectIdentifier: SnapshotSettle] = [:]

    private func takeSnapshot(_ control: HMCameraSnapshotControl) async throws -> HMCameraSnapshot {
        let key = ObjectIdentifier(control)
        if snapshotSettles[key] != nil { throw CameraError.busy }
        let settle = SnapshotSettle()
        snapshotSettles[key] = settle
        defer { snapshotSettles[key] = nil }
        control.delegate = self
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMCameraSnapshot, Error>) in
            settle.continuation = continuation
            control.takeSnapshot()
            // A plain timer arm: nothing can cancel the HomeKit call, so the
            // clock answers when the delegate never does.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(CameraSnapshotPolicy.snapshotTimeout * 1_000_000_000))
                // A timer belongs to this request. Looking up by control here
                // could claim a newer request after this one already finished.
                guard let cont = settle.claim() else { return }
                cont.resume(throwing: CameraError.snapshotTimeout)
            }
        }
    }

    // MARK: - Live

    /// A frame ready to leave the relay. Set by the bridge.
    var onFrame: ((_ payload: [String: Any]) -> Void)?
    /// A session started, stopped, or failed. Set by the bridge.
    var onLiveState: ((_ payload: [String: Any]) -> Void)?

    private final class LiveSession {
        let accessoryId: String
        let homeId: String?
        let name: String
        let control: HMCameraStreamControl
        let slot: Slot
        let started = Date()
        var lastKeepalive = Date()
        var seq = 0
        let quality: CGFloat
        let maxWidth: Int
        init(accessoryId: String, homeId: String?, name: String, control: HMCameraStreamControl, slot: Slot, quality: CGFloat, maxWidth: Int) {
            self.accessoryId = accessoryId; self.homeId = homeId; self.name = name; self.control = control
            self.slot = slot; self.quality = quality; self.maxWidth = maxWidth
        }
    }
    private var liveSessions: [String: LiveSession] = [:]
    private var ticker: Task<Void, Never>?
    private var fps: Double = CameraCaptureService.defaultFps
    private(set) var lastCaptureMs = 0

    func startLive(accessoryId: String, fps: Double?, maxWidth: Int?, quality: Double?) async throws -> [String: Any] {
        if let existing = liveSessions[accessoryId] {
            existing.lastKeepalive = Date()
            return liveStatus(existing, started: false)
        }
        let accessory = try homeKitManager.hmAccessory(id: accessoryId)
        guard let control = accessory.cameraProfiles?.first?.streamControl else {
            throw CameraError.notSupported
        }
        guard streamSettles[ObjectIdentifier(control)] == nil,
              !snapshotStreams.contains(accessoryId) else { throw CameraError.busy }
        let canvas = try readyCanvas()
        let homeId = homeKitManager.homes.first { $0.accessories.contains(accessory) }?.uniqueIdentifier.uuidString

        let outcome = await startStream(control)
        switch outcome {
        case .started: break
        case .timeout: throw CameraError.streamTimeout
        case .failed(let error):
            if let hm = error as? HMError, hm.code == .accessoryIsBusy { throw CameraError.busy }
            if (error as NSError).domain == HMErrorDomain, (error as NSError).code == HMError.accessoryIsBusy.rawValue { throw CameraError.busy }
            throw CameraError.streamFailed(error.localizedDescription)
        }
        guard let stream = control.cameraStream else { control.stopStream(); throw CameraError.streamFailed("no stream") }

        let slot = allocateSlot(kind: .live, accessoryId: accessoryId, aspect: stream.aspectRatio)
        canvas.addSubview(slot.view)
        slot.view.cameraSource = stream
        let session = LiveSession(accessoryId: accessoryId, homeId: homeId,
                                  name: AccessoryModel.userFacingName(of: accessory), control: control, slot: slot,
                                  quality: CGFloat(quality ?? Double(Self.defaultLiveQuality)),
                                  maxWidth: min(max(maxWidth ?? Self.defaultLiveWidth, 160), 1280))
        liveSessions[accessoryId] = session
        if let fps = fps { self.fps = min(max(fps, 0.5), 10) }
        ensureTicker()
        onLiveState?(["accessoryId": accessoryId, "state": "streaming"])
        return liveStatus(session, started: true)
    }

    func keepalive(accessoryId: String) -> [String: Any] {
        guard let s = liveSessions[accessoryId] else { return ["accessoryId": accessoryId, "state": "stopped"] }
        s.lastKeepalive = Date()
        return liveStatus(s, started: false)
    }

    func stopLive(accessoryId: String?) -> [String: Any] {
        if let id = accessoryId { endLive(id, reason: "stopped") } else { for id in Array(liveSessions.keys) { endLive(id, reason: "stopped") } }
        return ["activeStreams": liveSessions.count]
    }

    private func liveStatus(_ s: LiveSession, started: Bool) -> [String: Any] {
        [
            "accessoryId": s.accessoryId,
            "state": "streaming",
            "started": started,
            "fps": fps,
            "width": Int(s.slot.view.bounds.width),
            "height": Int(s.slot.view.bounds.height),
            "activeStreams": liveSessions.count,
        ]
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while let self = self, !self.liveSessions.isEmpty, !Task.isCancelled {
                self.tick()
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / self.fps))
            }
            self?.ticker = nil
        }
    }

    private func tick() {
        let now = Date()
        for (id, s) in liveSessions {
            if now.timeIntervalSince(s.lastKeepalive) > Self.liveIdle { endLive(id, reason: "idle") }
            else if now.timeIntervalSince(s.started) > Self.liveHardCap { endLive(id, reason: "expired") }
            else if s.control.streamState == .notStreaming { endLive(id, reason: "stream ended") }
        }
        guard !liveSessions.isEmpty, let canvas = CameraEngine.shared.canvas else { return }
        let t0 = DispatchTime.now()
        guard let (cg, scale) = Self.captureWindowImage(of: canvas) else { return }
        lastCaptureMs = Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
        for s in liveSessions.values {
            guard let crop = Self.crop(cg, to: s.slot.view, in: canvas, scale: scale),
                  let data = Self.jpeg(crop, maxWidth: s.maxWidth, quality: s.quality) else { continue }
            s.seq += 1
            let encodedWidth = min(crop.width, s.maxWidth)
            onFrame?([
                "accessoryId": s.accessoryId,
                "seq": s.seq,
                "capturedAt": ISO8601DateFormatter().string(from: now),
                "width": encodedWidth,
                "height": Int(Double(crop.height) * Double(encodedWidth) / Double(crop.width)),
                "jpeg": data,
            ])
        }
    }

    private func endLive(_ accessoryId: String, reason: String) {
        guard let s = liveSessions.removeValue(forKey: accessoryId) else { return }
        releaseSlot(s.slot)
        s.control.stopStream()
        print("[Camera] live session ended for \(s.name): \(reason) after \(s.seq) frames")
        onLiveState?(["accessoryId": accessoryId, "state": "stopped", "reason": reason])
    }

    private enum StreamOutcome { case started, timeout, failed(Error) }
    private var streamSettles: [ObjectIdentifier: StreamSettle] = [:]

    private func startStream(_ control: HMCameraStreamControl, timeout: TimeInterval? = nil) async -> StreamOutcome {
        let bound = timeout ?? Self.streamStartBound
        let key = ObjectIdentifier(control)
        control.delegate = self
        let settle = StreamSettle()
        streamSettles[key] = settle
        defer { streamSettles[key] = nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<StreamOutcome, Never>) in
            settle.continuation = continuation
            control.startStream()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(bound * 1_000_000_000))
                guard let cont = settle.claim() else { return }
                control.stopStream()
                cont.resume(returning: .timeout)
            }
        }
    }

    // MARK: - Layout

    private enum SlotKind { case snapshot, live }

    @MainActor private final class Slot {
        let kind: SlotKind
        let accessoryId: String
        let aspect: CGFloat
        let view: HMCameraView
        init(kind: SlotKind, accessoryId: String, aspect: CGFloat) {
            self.kind = kind; self.accessoryId = accessoryId; self.aspect = aspect
            self.view = HMCameraView(frame: .zero)
        }
    }
    private var slots: [Slot] = []

    private func allocateSlot(kind: SlotKind, accessoryId: String, aspect: Double) -> Slot {
        let slot = Slot(kind: kind, accessoryId: accessoryId, aspect: aspect > 0 ? CGFloat(aspect) : 16.0 / 9.0)
        slots.append(slot)
        layoutSlots()
        return slot
    }

    private func releaseSlot(_ slot: Slot) {
        slot.view.removeFromSuperview()
        slots.removeAll { $0 === slot }
        layoutSlots()
    }

    /// A grid inside the canvas: one camera gets the whole canvas, up to four
    /// get a 2×2, more get a 3×3. Every crop follows the view's frame, so a
    /// re-layout just changes what the next capture returns.
    private func layoutSlots() {
        let canvas = CameraEngineCanvas.size
        let n = slots.count
        let cols = max(1, Int(ceil(Double(n).squareRoot())))
        let cell = CGSize(width: (canvas.width / CGFloat(cols)).rounded(.down), height: (canvas.height / CGFloat(cols)).rounded(.down))
        for (i, slot) in slots.enumerated() {
            let origin = CGPoint(x: CGFloat(i % cols) * cell.width, y: CGFloat(i / cols) * cell.height)
            // Fit the camera's aspect inside the cell, top-left aligned.
            var size = CGSize(width: cell.width, height: (cell.width / slot.aspect).rounded(.down))
            if size.height > cell.height { size = CGSize(width: (cell.height * slot.aspect).rounded(.down), height: cell.height) }
            slot.view.frame = CGRect(origin: origin, size: size)
        }
    }

    // MARK: - Capture

    /// One window-server capture of the window hosting `view`, plus its
    /// pixels-per-point scale. Require the engine's title AND its below-desktop
    /// level; dimensions alone also match a resized dashboard window. Do not
    /// require AppKit's point dimensions to equal UIKit's: Catalyst scales
    /// 1280×720 to 1153×649 on some displays. The pixel ratio below accounts
    /// for that scale as well as Retina backing resolution.
    private static func captureWindowImage(of view: UIView) -> (CGImage, CGFloat)? {
        guard let window = view.window else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        let match = mine.first { w in
            w[kCGWindowName as String] as? String == CameraEngine.windowTitle &&
            w[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.desktopWindow)) - 1
        }
        guard let number = match?[kCGWindowNumber as String] as? UInt32,
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number), [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        return (cg, CGFloat(cg.width) / max(window.bounds.width, 1))
    }

    private static func crop(_ cg: CGImage, to view: UIView, in canvas: UIView, scale: CGFloat) -> CGImage? {
        guard let window = canvas.window else { return nil }
        let f = view.convert(view.bounds, to: window)
        let rect = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
        return cg.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)))
    }

    private static func jpeg(_ cg: CGImage, maxWidth: Int, quality: CGFloat) -> Data? {
        var image = UIImage(cgImage: cg)
        if cg.width > maxWidth {
            let target = CGSize(width: maxWidth, height: Int(Double(cg.height) * Double(maxWidth) / Double(cg.width)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        }
        return image.jpegData(compressionQuality: quality)
    }

    private struct Stats {
        let mean: Double
        let stddev: Double
        var isPicture: Bool { mean > 0.03 && stddev > 0.02 }
    }

    /// Downsampled luminance; enough to tell an empty slot from a picture.
    private static func stats(of cg: CGImage) -> Stats {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Stats(mean: 0, stddev: 0)
        }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0, sumSq = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let l = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
            sum += l; sumSq += l * l
        }
        let n = Double(side * side)
        let mean = sum / n
        return Stats(mean: mean, stddev: max(0, sumSq / n - mean * mean).squareRoot())
    }

    // MARK: - Settles

    private final class SnapshotSettle {
        var continuation: CheckedContinuation<HMCameraSnapshot, Error>?
        func claim() -> CheckedContinuation<HMCameraSnapshot, Error>? { defer { continuation = nil }; return continuation }
    }
    private final class StreamSettle {
        var continuation: CheckedContinuation<StreamOutcome, Never>?
        func claim() -> CheckedContinuation<StreamOutcome, Never>? { defer { continuation = nil }; return continuation }
    }
    @MainActor private final class MuteSettle {
        var continuation: CheckedContinuation<Void, Error>?
        func claim() -> CheckedContinuation<Void, Error>? { defer { continuation = nil }; return continuation }
    }
}

// MARK: - Delegates

extension CameraCaptureService: HMCameraSnapshotControlDelegate {
    nonisolated func cameraSnapshotControl(_ control: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
        Task { @MainActor in
            guard let cont = self.snapshotSettles[ObjectIdentifier(control)]?.claim() else { return }
            if let snapshot = snapshot { cont.resume(returning: snapshot) }
            else { cont.resume(throwing: CameraError.snapshotFailed(error?.localizedDescription ?? "no snapshot")) }
        }
    }
}

extension CameraCaptureService: HMCameraStreamControlDelegate {
    nonisolated func cameraStreamControlDidStartStream(_ control: HMCameraStreamControl) {
        Task { @MainActor in self.streamSettles[ObjectIdentifier(control)]?.claim()?.resume(returning: .started) }
    }
    nonisolated func cameraStreamControl(_ control: HMCameraStreamControl, didStopStreamWithError error: Error?) {
        Task { @MainActor in
            if let cont = self.streamSettles[ObjectIdentifier(control)]?.claim() {
                cont.resume(returning: .failed(error ?? CameraError.streamFailed("stopped")))
            }
            // A running session whose stream died is reaped on the next tick.
        }
    }
}

#endif

// MARK: - Errors

enum CameraError: LocalizedError {
    case notSupported
    case engineUnavailable
    case captureUnavailable
    case busy
    case snapshotTimeout
    case snapshotFailed(String)
    case captureEmpty
    case streamTimeout
    case streamFailed(String)

    var code: String {
        switch self {
        case .notSupported: return "CAMERA_NOT_SUPPORTED"
        case .engineUnavailable: return "CAMERA_UNAVAILABLE"
        case .captureUnavailable: return "CAMERA_CAPTURE_UNAVAILABLE"
        case .busy: return "CAMERA_BUSY"
        case .snapshotTimeout: return "SNAPSHOT_TIMEOUT"
        case .snapshotFailed: return "SNAPSHOT_FAILED"
        case .captureEmpty: return "SNAPSHOT_EMPTY"
        case .streamTimeout: return "STREAM_TIMEOUT"
        case .streamFailed: return "STREAM_FAILED"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSupported: return "This accessory has no camera"
        case .engineUnavailable: return "The camera engine window is not available on this relay"
        case .captureUnavailable: return "The camera engine window could not be captured; restart Homecast on the relay Mac"
        case .busy: return "The camera is busy — HomeKit allows two live streams per home"
        case .snapshotTimeout: return "The camera did not return a snapshot in time"
        case .snapshotFailed(let m): return "Snapshot failed: \(m)"
        case .captureEmpty: return "The snapshot could not be captured"
        case .streamTimeout: return "The camera did not start streaming in time"
        case .streamFailed(let m): return "Stream failed: \(m)"
        }
    }
}
