import AppKit

/// AppKit plugin that creates and manages the menu bar status item.
/// This runs in the same process as the Mac Catalyst app but has access to AppKit APIs.
@objc(MenuBarPlugin)
public class MenuBarPlugin: NSObject {
    private var statusItem: NSStatusItem?
    private weak var statusProvider: AnyObject?
    private var updateTimer: Timer?

    // Menu item tags for dynamic updates
    private let homeKitStatusTag = 100
    private let serverStatusTag = 101
    private let relayStatusTag = 102
    private let userEmailTag = 103
    private let homesHeaderTag = 200
    private let homeItemsStartTag = 300

    public override init() {
        super.init()
    }

    /// Called by the main app to set up the menu bar
    @objc public func setup(withStatusProvider provider: AnyObject) {
        self.statusProvider = provider

        DispatchQueue.main.async {
            self.createStatusItem()
            self.startUpdateTimer()
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeKit MCP")
            button.image?.isTemplate = true
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // App title
        let titleItem = NSMenuItem(title: "HomeKit MCP", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        if let font = NSFont.boldSystemFont(ofSize: 13) as NSFont? {
            titleItem.attributedTitle = NSAttributedString(
                string: "HomeKit MCP",
                attributes: [.font: font]
            )
        }
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // HomeKit Status
        let homeKitItem = NSMenuItem(title: "HomeKit: Loading...", action: nil, keyEquivalent: "")
        homeKitItem.tag = homeKitStatusTag
        homeKitItem.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
        menu.addItem(homeKitItem)

        // Server Status
        let serverItem = NSMenuItem(title: "Server: Stopped", action: nil, keyEquivalent: "")
        serverItem.tag = serverStatusTag
        serverItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        menu.addItem(serverItem)

        // Relay Status
        let relayItem = NSMenuItem(title: "Relay: Not signed in", action: nil, keyEquivalent: "")
        relayItem.tag = relayStatusTag
        relayItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        menu.addItem(relayItem)

        // User Email
        let userItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        userItem.tag = userEmailTag
        userItem.indentationLevel = 1
        userItem.isEnabled = false
        userItem.isHidden = true
        if let font = NSFont.systemFont(ofSize: 11) as NSFont? {
            userItem.attributedTitle = NSAttributedString(
                string: "",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        menu.addItem(userItem)

        menu.addItem(NSMenuItem.separator())

        // Homes section header
        let homesHeader = NSMenuItem(title: "Homes", action: nil, keyEquivalent: "")
        homesHeader.tag = homesHeaderTag
        homesHeader.isEnabled = false
        if let font = NSFont.systemFont(ofSize: 11) as NSFont? {
            homesHeader.attributedTitle = NSAttributedString(
                string: "HOMES",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        menu.addItem(homesHeader)

        // Placeholder for homes (will be populated dynamically)
        let noHomesItem = NSMenuItem(title: "No homes available", action: nil, keyEquivalent: "")
        noHomesItem.tag = homeItemsStartTag
        noHomesItem.isEnabled = false
        menu.addItem(noHomesItem)

        menu.addItem(NSMenuItem.separator())

        // Open window
        let openItem = NSMenuItem(title: "Open HomeKit MCP...", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HomeKit MCP", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
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
            self.updateMenuWithStatus(
                homeKitReady: homeKitReady,
                serverRunning: serverRunning,
                serverPort: serverPort,
                homeNames: homeNames,
                accessoryCounts: accessoryCounts,
                relayConnected: relayConnected,
                isAuthenticated: isAuthenticated,
                userEmail: userEmail
            )
        }
    }

    private func updateMenuWithStatus(
        homeKitReady: Bool,
        serverRunning: Bool,
        serverPort: Int,
        homeNames: [String],
        accessoryCounts: [Int],
        relayConnected: Bool,
        isAuthenticated: Bool,
        userEmail: String
    ) {
        guard let menu = statusItem?.menu else { return }

        // Update HomeKit status
        if let homeKitItem = menu.item(withTag: homeKitStatusTag) {
            if homeKitReady {
                let totalAccessories = accessoryCounts.reduce(0, +)
                homeKitItem.title = "HomeKit: \(homeNames.count) homes, \(totalAccessories) accessories"
                homeKitItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                homeKitItem.image?.isTemplate = false
            } else {
                homeKitItem.title = "HomeKit: Loading..."
                homeKitItem.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
            }
        }

        // Update Server status
        if let serverItem = menu.item(withTag: serverStatusTag) {
            if serverRunning {
                serverItem.title = "Server: Running on port \(serverPort)"
                serverItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                serverItem.image?.isTemplate = false
            } else {
                serverItem.title = "Server: Stopped"
                serverItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            }
        }

        // Update Relay status
        if let relayItem = menu.item(withTag: relayStatusTag) {
            if isAuthenticated {
                if relayConnected {
                    relayItem.title = "Relay: Connected"
                    relayItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    relayItem.image?.isTemplate = false
                } else {
                    relayItem.title = "Relay: Connecting..."
                    relayItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
                }
            } else {
                relayItem.title = "Relay: Not signed in"
                relayItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            }
        }

        // Update user email
        if let userItem = menu.item(withTag: userEmailTag) {
            if !userEmail.isEmpty {
                userItem.title = userEmail
                userItem.isHidden = false
            } else {
                userItem.isHidden = true
            }
        }

        // Update homes list
        updateHomesList(menu: menu, homeNames: homeNames, accessoryCounts: accessoryCounts)

        // Update menu bar icon
        updateMenuBarIcon(homeKitReady: homeKitReady, serverRunning: serverRunning, relayConnected: relayConnected, isAuthenticated: isAuthenticated)
    }

    private func updateHomesList(menu: NSMenu, homeNames: [String], accessoryCounts: [Int]) {
        // Remove existing home items
        var itemsToRemove: [NSMenuItem] = []
        for item in menu.items {
            if item.tag >= homeItemsStartTag {
                itemsToRemove.append(item)
            }
        }
        for item in itemsToRemove {
            menu.removeItem(item)
        }

        // Find insert index (after homes header)
        guard let homesHeaderIndex = menu.items.firstIndex(where: { $0.tag == homesHeaderTag }) else { return }
        var insertIndex = homesHeaderIndex + 1

        if homeNames.isEmpty {
            let noHomesItem = NSMenuItem(title: "No homes available", action: nil, keyEquivalent: "")
            noHomesItem.tag = homeItemsStartTag
            noHomesItem.isEnabled = false
            menu.insertItem(noHomesItem, at: insertIndex)
        } else {
            for (index, name) in homeNames.enumerated() {
                let accessoryCount = index < accessoryCounts.count ? accessoryCounts[index] : 0
                let homeItem = NSMenuItem(
                    title: "\(name) (\(accessoryCount) accessories)",
                    action: nil,
                    keyEquivalent: ""
                )
                homeItem.tag = homeItemsStartTag + index
                homeItem.image = NSImage(systemSymbolName: index == 0 ? "house.fill" : "house", accessibilityDescription: nil)
                homeItem.indentationLevel = 1
                menu.insertItem(homeItem, at: insertIndex)
                insertIndex += 1
            }
        }
    }

    private func updateMenuBarIcon(homeKitReady: Bool, serverRunning: Bool, relayConnected: Bool, isAuthenticated: Bool) {
        guard let button = statusItem?.button else { return }

        if homeKitReady && serverRunning && relayConnected {
            // All good - green filled house
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeKit MCP - Connected")
            button.contentTintColor = .systemGreen
            button.image?.isTemplate = false
        } else if homeKitReady && isAuthenticated {
            // HomeKit ready, authenticated but not fully connected - orange
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeKit MCP - Connecting")
            button.contentTintColor = .systemOrange
            button.image?.isTemplate = false
        } else if homeKitReady {
            // HomeKit ready but not authenticated - yellow
            button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeKit MCP - Not signed in")
            button.contentTintColor = .systemYellow
            button.image?.isTemplate = false
        } else {
            // Loading/not ready - gray outline
            button.image = NSImage(systemSymbolName: "house", accessibilityDescription: "HomeKit MCP - Loading")
            button.contentTintColor = nil
            button.image?.isTemplate = true
        }
    }

    @objc private func openWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let provider = statusProvider {
            let selector = NSSelectorFromString("showWindow")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
            }
        }

        for window in NSApplication.shared.windows {
            window.makeKeyAndOrderFront(nil)
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

    deinit {
        updateTimer?.invalidate()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
