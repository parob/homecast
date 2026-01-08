import AppKit

/// AppKit plugin that creates and manages the menu bar status item.
/// This runs in the same process as the Mac Catalyst app but has access to AppKit APIs.
@objc(MenuBarPlugin)
public class MenuBarPlugin: NSObject {
    private var statusItem: NSStatusItem?
    private weak var statusProvider: AnyObject?

    public override init() {
        super.init()
    }

    /// Called by the main app to set up the menu bar
    /// - Parameters:
    ///   - provider: Object that provides status information
    ///   - showWindowOnLaunch: Whether to show the window (and dock icon) on launch
    @objc public func setup(withStatusProvider provider: AnyObject, showWindowOnLaunch: Bool) {
        self.statusProvider = provider

        DispatchQueue.main.async {
            self.createStatusItem()
            self.observeWindowClose()

            // Show in dock on launch only if window should be shown
            if showWindowOnLaunch {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Check if all windows are closed (except status bar)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let visibleWindows = NSApp.windows.filter {
                    $0.isVisible && $0.className != "NSStatusBarWindow"
                }
                if visibleWindows.isEmpty {
                    self?.hideFromDock()
                }
            }
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Homecast")
            button.image?.isTemplate = true
        }

        // Attach menu directly so it inherits proper system appearance
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Open window
        let openItem = NSMenuItem(title: "Open Homecast", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Homecast", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openWindow() {
        // Show in dock first
        showInDock()

        // Activate app and bring all windows to front
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Tell the main app to show its window
        if let provider = statusProvider {
            let selector = NSSelectorFromString("showWindow")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
            }
        }

        // Ensure all windows come to front
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    @objc private func quitApp() {
        if let provider = statusProvider {
            let selector = NSSelectorFromString("quitApp")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
                return
            }
        }

        NSApplication.shared.terminate(nil)
    }

    // MARK: - Dock Visibility

    /// Show app in dock (when window is open)
    @objc public func showInDock() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Hide app from dock (when window is closed, menu bar only)
    @objc public func hideFromDock() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    deinit {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
