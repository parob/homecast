//
//  ReportBridge.swift
//  Shake-to-report: native capture the web layer cannot do for itself.
//
//  Two gaps this fills, both specific to WKWebView:
//
//  * `getDisplayMedia` does not exist on iOS, so the web layer has no way to
//    record the screen at all. ReplayKit does, and it captures the whole
//    screen rather than the DOM's idea of it.
//  * A DOM rasterisation only draws what the page describes. Native surfaces —
//    a HomeKit sheet, a system alert, the very thing someone is often
//    complaining about — are simply absent from it. A real screenshot is not.
//
//  Mirrors HomeKitBridge: the web calls `window.homecastReport.call(method,
//  payload)` and gets a promise, resolved here by callback id.
//

import Foundation
import WebKit

#if os(iOS)
// AVFoundation explicitly: AVAssetWriter and CMSampleBuffer arrive transitively
// through ReplayKit today, but depending on that is a silent break waiting for
// an SDK change.
import AVFoundation
import ReplayKit
import UIKit
#endif

/// Ceiling on a single recording, matching the web layer's own.
/// A recording nobody stops is a large upload nobody wanted.
private let maxRecordingSeconds: TimeInterval = 60

final class ReportBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    #if os(iOS)
    private let recorder = RPScreenRecorder.shared()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var recordingTimer: Timer?
    #endif

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let method = body["method"] as? String
        let callbackId = body["callbackId"] as? String
        handle(method: method, callbackId: callbackId)
    }

    func handle(method: String?, callbackId: String?) {
        switch method {
        case "captureScreenshot":
            captureScreenshot(callbackId: callbackId)
        case "startRecording":
            startRecording(callbackId: callbackId)
        case "stopRecording":
            stopRecording(callbackId: callbackId)
        default:
            reject(callbackId, "UNKNOWN_METHOD")
        }
    }

    // MARK: - Screenshot

    private func captureScreenshot(callbackId: String?) {
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
            else {
                self?.reject(callbackId, "NO_WINDOW")
                return
            }

            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                // afterScreenUpdates: false — the report sheet is already on
                // screen by the time a retake would happen, and we want what
                // the user was looking at, not the dialog covering it.
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }

            guard let data = image.pngData() else {
                self?.reject(callbackId, "ENCODE_FAILED")
                return
            }
            self?.resolve(callbackId, ["data": data.base64EncodedString()])
        }
        #else
        reject(callbackId, "UNSUPPORTED_PLATFORM")
        #endif
    }

    // MARK: - Recording

    private func startRecording(callbackId: String?) {
        #if os(iOS)
        guard recorder.isAvailable else {
            reject(callbackId, "RECORDING_UNAVAILABLE")
            return
        }
        guard !recorder.isRecording else {
            reject(callbackId, "ALREADY_RECORDING")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("homecast-report-\(UUID().uuidString).mp4")
        outputURL = url

        do {
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

            // Deliberately not the native retina resolution. The recording has
            // to survive a base64 round trip through a JSON body into a service
            // that caps a request at 32 MiB, and base64 costs ~1.37x — so a
            // full-resolution 60s capture would simply fail to upload. Scaled
            // to 720px on the long edge at a fixed bitrate, a minute lands
            // around 9 MB, which is ample to show what a UI did.
            let bounds = UIScreen.main.bounds
            let scale = UIScreen.main.scale
            let nativeWidth = bounds.width * scale
            let nativeHeight = bounds.height * scale
            let longEdge = max(nativeWidth, nativeHeight)
            let factor = longEdge > 1280 ? 1280 / longEdge : 1.0
            // H.264 wants even dimensions.
            let width = Int((nativeWidth * factor / 2).rounded()) * 2
            let height = Int((nativeHeight * factor / 2).rounded()) * 2

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_200_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            assetWriter.add(input)
            writer = assetWriter
            videoInput = input
        } catch {
            reject(callbackId, "WRITER_FAILED")
            return
        }

        // Video only. Audio would pick up the room, which is a meaningful
        // privacy step beyond capturing the screen and is not needed to show
        // what a UI did.
        recorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
            guard error == nil, bufferType == .video else { return }
            guard let self, let writer = self.writer, let input = self.videoInput else { return }

            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            if writer.status == .writing, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }, completionHandler: { [weak self] error in
            guard let self else { return }
            if let error {
                self.reject(callbackId, "START_FAILED:\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                // Stop ourselves if the web layer never asks us to. Its own
                // timer covers the usual case; this covers the app being
                // backgrounded or the page reloading mid-recording.
                self.recordingTimer = Timer.scheduledTimer(
                    withTimeInterval: maxRecordingSeconds, repeats: false
                ) { [weak self] _ in
                    self?.stopRecording(callbackId: nil)
                }
            }
            self.resolve(callbackId, ["started": true])
        })
        #else
        reject(callbackId, "UNSUPPORTED_PLATFORM")
        #endif
    }

    private func stopRecording(callbackId: String?) {
        #if os(iOS)
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard recorder.isRecording else {
            reject(callbackId, "NOT_RECORDING")
            return
        }

        recorder.stopCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.cleanUp()
                self.reject(callbackId, "STOP_FAILED:\(error.localizedDescription)")
                return
            }
            guard let writer = self.writer, let input = self.videoInput else {
                self.reject(callbackId, "NO_WRITER")
                return
            }
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                defer { self.cleanUp() }

                guard writer.status == .completed,
                      let url = self.outputURL,
                      let data = try? Data(contentsOf: url) else {
                    self.reject(callbackId, "WRITE_INCOMPLETE")
                    return
                }
                // Removed once read: a screen recording is large and there is
                // no reason to leave one sitting in tmp.
                try? FileManager.default.removeItem(at: url)
                self.resolve(callbackId, [
                    "data": data.base64EncodedString(),
                    "mimeType": "video/mp4",
                ])
            }
        }
        #else
        reject(callbackId, "UNSUPPORTED_PLATFORM")
        #endif
    }

    #if os(iOS)
    private func cleanUp() {
        writer = nil
        videoInput = nil
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
    }
    #endif

    // MARK: - Shake

    /// Start listening for the shake gesture.
    ///
    /// iOS delivers a shake down the responder chain rather than as a
    /// notification, so `UIWindow` re-posts it (see the extension below) and we
    /// observe that. Using the OS gesture rather than sampling `devicemotion`
    /// in JavaScript avoids a permission prompt entirely and is far less noisy
    /// than a threshold on raw accelerometer values.
    func observeShakes() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShakeNotification),
            name: .homecastDeviceDidShake,
            object: nil
        )
        #endif
    }

    @objc private func handleShakeNotification() {
        notifyShake()
    }

    /// Tell the web layer a shake happened.
    func notifyShake() {
        evaluate("window.homecastReport && window.homecastReport._onShake && window.homecastReport._onShake();")
    }

    // MARK: - Replying

    private func resolve(_ callbackId: String?, _ payload: [String: Any]) {
        guard let callbackId else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else {
            reject(callbackId, "ENCODE_FAILED")
            return
        }
        evaluate("window.homecastReport._resolve('\(callbackId)', \(text));")
    }

    private func reject(_ callbackId: String?, _ code: String) {
        // Every refusal, with its reason. Without this a failed capture reaches
        // the user as one generic sentence and reaches us as nothing at all.
        NSLog("[Report] rejected: \(code)")
        guard let callbackId else { return }
        let escaped = code.replacingOccurrences(of: "'", with: "\\'")
        evaluate("window.homecastReport._reject('\(callbackId)', '\(escaped)');")
    }

    private func evaluate(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}


#if os(iOS)

extension Notification.Name {
    /// Posted when the device is shaken. See `FocusableWebView.motionEnded`.
    static let homecastDeviceDidShake = Notification.Name("homecastDeviceDidShake")
}

/// Forward a shake to anyone listening.
///
/// Called from **two** places on purpose — `FocusableWebView.motionEnded` and
/// the `UIWindow` extension below.
///
/// A motion event is delivered to the first responder and then walks up the
/// responder chain, so where you put the override decides whether you see it.
/// The web view is first responder (it calls `becomeFirstResponder` in
/// `didMoveToWindow`) and the window is the far end of the same chain; anything
/// in between that consumes the event — WKWebView's own shake-to-undo handling
/// in editable content is the obvious candidate — takes the window's copy with
/// it. Build 51 had only the window override and the gesture did not fire on a
/// real device, so both ends now listen and the debounce below makes the
/// overlap harmless.
///
/// The debounce is what makes this safe rather than sloppy: when both overrides
/// do see the same shake, the second post lands within microseconds of the
/// first and is dropped.
private var lastShakePost: TimeInterval = 0

func postShakeNotification() {
    let now = Date().timeIntervalSince1970
    guard now - lastShakePost > 0.5 else { return }
    lastShakePost = now
    NSLog("[Report] shake detected")
    NotificationCenter.default.post(name: .homecastDeviceDidShake, object: nil)
}

extension UIWindow {
    /// The far end of the responder chain. See `postShakeNotification()` for why
    /// this is not the only place the gesture is caught.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            postShakeNotification()
        }
    }
}

#endif
