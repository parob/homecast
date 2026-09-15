import Foundation
import SwiftUI

#if targetEnvironment(macCatalyst)

/// The relay's engine window.
///
/// A second scene, and so a second Mac window, that exists for the whole life
/// of the process. The `HMCameraView`s that camera snapshots and live streams
/// render into live here. HomeKit composites those out of process, so the only
/// way to get their pixels is to capture the window they are in through the
/// window server — which needs a window that is always ordered in. The UI
/// window is not that: the user closes it.
///
/// Closing the UI window does not disconnect its scene, even with multiple
/// scenes enabled: macOS hides the window and the relay's web view keeps
/// running in it, exactly as it did before this window existed. Measured, not
/// assumed — see the 2026-09-15 spike notes.
@MainActor
final class CameraEngine {
    static let shared = CameraEngine()

    static let windowGroupID = "camera-engine"
    static let windowTitle = "Homecast Camera Engine"

    /// The view inside the engine window that hosts everything. Set by the
    /// canvas when it lands in a window, cleared when it leaves one.
    private(set) weak var canvas: CameraEngineCanvas?

    var isAvailable: Bool { canvas?.window != nil }

    fileprivate func register(_ canvas: CameraEngineCanvas?) {
        self.canvas = canvas
        print("[CameraEngine] canvas \(canvas == nil ? "gone" : "ready") window=\(String(describing: canvas?.window))")
    }

    /// The scene that is the engine window, if it is connected.
    var scene: UIWindowScene? { canvas?.window?.windowScene }

    /// Is this scene the engine, rather than a UI window?
    func owns(_ scene: UIScene) -> Bool { scene === self.scene }
}

/// The engine window's only view. Hosts the camera views.
final class CameraEngineCanvas: UIView {
    static let size = CGSize(width: 1280, height: 720)


    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window = window, let scene = window.windowScene else {
            CameraEngine.shared.register(nil)
            return
        }
        scene.title = CameraEngine.windowTitle
        if let titlebar = scene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
        }
        scene.sizeRestrictions?.minimumSize = Self.size
        scene.sizeRestrictions?.maximumSize = Self.size
        CameraEngine.shared.register(self)
        // The NSWindow behind this scene exists once the scene is on screen;
        // give AppKit a beat, then pin it below the desktop. Twice, because
        // the first attempt can land before the title is applied.
        for delay in [0.3, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .configureEngineWindow, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// The engine canvas has a window; AppKit should pin and hide it.
    static let configureEngineWindow = Notification.Name("homecast.configureEngineWindow")
}

struct CameraEngineView: View {
    var body: some View {
        CameraEngineHost()
            .frame(width: CameraEngineCanvas.size.width, height: CameraEngineCanvas.size.height)
            .ignoresSafeArea()
    }
}

private struct CameraEngineHost: UIViewRepresentable {
    func makeUIView(context: Context) -> CameraEngineCanvas {
        let view = CameraEngineCanvas(frame: CGRect(origin: .zero, size: CameraEngineCanvas.size))
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ uiView: CameraEngineCanvas, context: Context) {}
}

#endif
