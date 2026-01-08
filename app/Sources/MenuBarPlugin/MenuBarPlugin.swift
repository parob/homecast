import AppKit

/// AppKit plugin that creates and manages the menu bar status item.
/// This runs in the same process as the Mac Catalyst app but has access to AppKit APIs.
@objc(MenuBarPlugin)
public class MenuBarPlugin: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var statusProvider: AnyObject?
    private var updateTimer: Timer?

    // Cached status values for menu building
    private var cachedHomeKitReady = false
    private var cachedServerRunning = false
    private var cachedServerPort = 0
    private var cachedHomeNames: [String] = []
    private var cachedAccessoryCounts: [Int] = []
    private var cachedRelayConnected = false
    private var cachedIsAuthenticated = false
    private var cachedUserEmail = ""

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
            self.startUpdateTimer()
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

        // Build initial menu
        rebuildAndAssignMenu()
    }

    private func rebuildAndAssignMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    public func menuDidClose(_ menu: NSMenu) {
        // Rebuild menu after close to ensure fresh state and avoid click-blocking
        DispatchQueue.main.async { [weak self] in
            self?.rebuildAndAssignMenu()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status section
        if cachedHomeKitReady {
            let totalAccessories = cachedAccessoryCounts.reduce(0, +)
            menu.addItem(NSMenuItem(title: "HomeKit: \(cachedHomeNames.count) homes, \(totalAccessories) accessories", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "HomeKit: Loading...", action: nil, keyEquivalent: ""))
        }

        if cachedServerRunning {
            menu.addItem(NSMenuItem(title: "Server: Port \(cachedServerPort)", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Server: Stopped", action: nil, keyEquivalent: ""))
        }

        if cachedIsAuthenticated {
            menu.addItem(NSMenuItem(title: cachedRelayConnected ? "Relay: Connected" : "Relay: Connecting...", action: nil, keyEquivalent: ""))
            if !cachedUserEmail.isEmpty {
                menu.addItem(NSMenuItem(title: cachedUserEmail, action: nil, keyEquivalent: ""))
            }
        } else {
            menu.addItem(NSMenuItem(title: "Relay: Not signed in", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        // Reconnect
        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectRelay), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        // Open window
        let openItem = NSMenuItem(title: "Open Homecast...", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Homecast", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateTimer?.fire()
    }

    private func updateStatus() {
        guard let provider = statusProvider else { return }

        // Get status info
        var homeKitReady = false
        var serverRunning = false
        var serverPort: Int = 0
        var homeNames: [String] = []
        var accessoryCounts: [Int] = []
        var relayConnected = false
        var isAuthenticated = false
        var userEmail = ""

        // HomeKit ready
        let readySelector = NSSelectorFromString("isHomeKitReady")
        if provider.responds(to: readySelector) {
            homeKitReady = (provider.perform(readySelector)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }

        // Server running
        let serverSelector = NSSelectorFromString("isServerRunning")
        if provider.responds(to: serverSelector) {
            serverRunning = (provider.perform(serverSelector)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }

        // Server port
        let portSelector = NSSelectorFromString("serverPort")
        if provider.responds(to: portSelector) {
            serverPort = (provider.perform(portSelector)?.takeUnretainedValue() as? NSNumber)?.intValue ?? 0
        }

        // Home names
        let homesSelector = NSSelectorFromString("homeNames")
        if provider.responds(to: homesSelector) {
            homeNames = (provider.perform(homesSelector)?.takeUnretainedValue() as? [String]) ?? []
        }

        // Accessory counts
        let countsSelector = NSSelectorFromString("accessoryCounts")
        if provider.responds(to: countsSelector) {
            accessoryCounts = (provider.perform(countsSelector)?.takeUnretainedValue() as? [NSNumber])?.map { $0.intValue } ?? []
        }

        // Relay connection status
        let relaySelector = NSSelectorFromString("isConnectedToRelay")
        if provider.responds(to: relaySelector) {
            relayConnected = (provider.perform(relaySelector)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }

        // Authentication status
        let authSelector = NSSelectorFromString("isAuthenticated")
        if provider.responds(to: authSelector) {
            isAuthenticated = (provider.perform(authSelector)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        }

        // User email
        let emailSelector = NSSelectorFromString("connectedEmail")
        if provider.responds(to: emailSelector) {
            userEmail = (provider.perform(emailSelector)?.takeUnretainedValue() as? String) ?? ""
        }

        DispatchQueue.main.async {
            // Cache values for menu building
            self.cachedHomeKitReady = homeKitReady
            self.cachedServerRunning = serverRunning
            self.cachedServerPort = serverPort
            self.cachedHomeNames = homeNames
            self.cachedAccessoryCounts = accessoryCounts
            self.cachedRelayConnected = relayConnected
            self.cachedIsAuthenticated = isAuthenticated
            self.cachedUserEmail = userEmail

            // Update menu bar icon
            self.updateMenuBarIcon()
        }
    }

    private func updateMenuBarIcon() {
        // Keep icon simple - always white/template style
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

    @objc private func reconnectRelay() {
        if let provider = statusProvider {
            let selector = NSSelectorFromString("reconnectRelay")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
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
        updateTimer?.invalidate()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
