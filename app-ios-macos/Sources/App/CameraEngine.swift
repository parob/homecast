import Foundation
import SwiftUI

#if targetEnvironment(macCatalyst)

/// The relay's engine window.
///
/// A second scene, and so a second Mac window, that exists for the whole life
/// of the process **on a cloud-managed relay**. The `HMCameraView`s that
/// camera snapshots and live streams render into live here. HomeKit
/// composites those out of process, so the only way to get their pixels is to
/// capture the window they are in through the window server — which needs a
/// window that is always ordered in. The UI window is not that: the user
/// closes it.
///
/// A customer's own Mac never opens it. Cameras are a managed-relay feature,
/// and a 1280×720 black window — pinned below the desktop or not — has no
/// business on a self-hosted relay. `AppConfig.cameraEngineEnabled` is the
/// switch; the web app throws it through `camera.engine.set` once it knows
/// which account this Mac is signed in as.
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

    /// Should this Mac have an engine window at all?
    var isEnabled: Bool { AppConfig.cameraEngineEnabled }

    /// An `openWindow` has been issued and the canvas has not landed yet.
    /// Cleared when it does, or when the engine is switched off, so a second
    /// request can never stack a second window.
    private var windowRequested = false

    fileprivate func register(_ canvas: CameraEngineCanvas?) {
        self.canvas = canvas
        if canvas != nil { windowRequested = false }
        print("[CameraEngine] canvas \(canvas == nil ? "gone" : "ready") window=\(String(describing: canvas?.window))")
    }

    /// Open the engine window if this Mac should have one and does not yet.
    /// `open` is the SwiftUI `openWindow` action, which only a view can hold.
    func openIfWanted(_ open: () -> Void) {
        guard isEnabled, !isAvailable, !windowRequested else { return }
        windowRequested = true
        print("[CameraEngine] opening engine window")
        open()
    }

    /// The web app's verdict on this Mac: a cloud-managed relay or not.
    ///
    /// Turning it on opens the window now (through `RootView`, which holds
    /// `openWindow`) and on every later launch; a window that is merely
    /// hidden from an earlier "off" is ordered back instead of doubled.
    /// Turning it off — sign-out, or a non-managed account signing in on a
    /// Mac that once was managed — hides the window and forgets it, so the
    /// next launch never opens one.
    ///
    /// Hidden, not destroyed: `requestSceneSessionDestruction` is a silent
    /// no-op on Catalyst (measured 2026-09-18 — no error, window stays), the
    /// same family as scene activation doing nothing on 2026-09-15. The
    /// AppKit plugin orders the NSWindow out by title, which is what the user
    /// can see; the bridge refuses every capture method while the flag is off,
    /// so a hidden window is never captured from either.
    func setEnabled(_ enabled: Bool) {
        let was = AppConfig.cameraEngineEnabled
        AppConfig.cameraEngineEnabled = enabled
        if enabled {
            if !was { print("[CameraEngine] enabled — this Mac is a cloud-managed relay") }
            if isAvailable {
                NotificationCenter.default.post(name: .configureEngineWindow, object: nil)
            } else {
                NotificationCenter.default.post(name: .openCameraEngine, object: nil)
            }
            return
        }
        windowRequested = false
        if was { print("[CameraEngine] disabled\(isAvailable ? " — hiding engine window" : "")") }
        if isAvailable {
            NotificationCenter.default.post(name: .closeEngineWindow, object: nil)
        }
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
    /// The engine has been switched on; `RootView` should open its window.
    static let openCameraEngine = Notification.Name("homecast.openCameraEngine")
    /// The engine has been switched off; AppKit should order its window out.
    static let closeEngineWindow = Notification.Name("homecast.closeEngineWindow")
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
