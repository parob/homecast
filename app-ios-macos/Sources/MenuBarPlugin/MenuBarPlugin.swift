import AppKit

// MARK: - Menu Bar Plugin

/// AppKit plugin that creates and manages the menu bar status item.
/// Implements device-specific menu items with real-time HomeKit observation.
@objc(MenuBarPlugin)
public class MenuBarPlugin: NSObject, NSMenuDelegate, MenuBarController {
    private var statusItem: NSStatusItem?
    private var currentMenu: NSMenu?
    private weak var statusProvider: AnyObject?

    // Cache for HomeKit data - loaded async to avoid blocking menu
    private var cachedHomes: [[String: Any]] = []
    private var cachedRooms: [String: [[String: Any]]] = [:] // homeId -> rooms
    private var cachedAccessories: [String: [[String: Any]]] = [:] // "homeId:roomId" -> accessories
    private var cachedScenes: [String: [[String: Any]]] = [:] // homeId -> scenes
    private var cachedGroups: [String: [[String: Any]]] = [:] // homeId -> groups
    private var cachedHomeSummaries: [String: AreaSummaryData] = [:] // homeId -> summary
    private var cachedRoomSummaries: [String: AreaSummaryData] = [:] // "homeId:roomId" -> summary
    private var isLoading = false
    private var hasLoadedOnce = false
    private var lastRefreshTime: Date?
    private let cacheTimeout: TimeInterval = 60.0

    // Currently selected home for flat menu display
    private var selectedHomeId: String?
    private let selectedHomeKey = "MenuBarSelectedHomeId"

    // Cached settings from app-web (visibility, ordering, collections)
    private var cachedSettings: [String: Any]?

    // Cached widget types resolved via WebView JS (accessoryId -> { widgetType, sensorType?, deviceType? })
    private var cachedWidgetTypes: [String: [String: Any]] = [:]

    // Track if menu needs rebuilding (data changed since last build)
    private var menuNeedsRebuild = true
    private var lastMenuBuildTime: Date?

    // Track observed menu item views for real-time updates
    private var observedMenuItems: [String: CharacteristicUpdatable] = [:]

    // Track which accessory IDs belong to which group for live updates
    private var accessoryToGroupMap: [String: String] = [:]

    // Track reachable member count per group for live reachability updates
    private var groupReachableMembers: [String: Set<String>] = [:]

    // Track if menu is currently open
    private var isMenuOpen = false

    // Event monitor to swallow clicks on submenu items (prevents submenu toggle)
    private var submenuClickMonitor: Any?

    // Relay connection status for menu bar icon badge
    private enum RelayIconStatus: Equatable {
        case unknown       // No data yet - no dot
        case active        // Green dot
        case standby       // Amber dot
        case connecting    // Amber dot
        case disconnected  // Red dot
    }

    private var currentRelayStatus: RelayIconStatus = .unknown
    private var statusDotView: NSView?

    public override init() {
        super.init()
    }

    @objc public func setup(withStatusProvider provider: AnyObject, showWindowOnLaunch: Bool) {
        self.statusProvider = provider

        DispatchQueue.main.async {
            self.createStatusItem()
            self.observeWindowClose()

            if showWindowOnLaunch {
                NSApp.setActivationPolicy(.regular)
            }

            // Pre-fetch data in background so menu opens instantly
            self.refreshCacheInBackground()
        }
    }

    // MARK: - MenuBarController Protocol

    func setCharacteristic(accessoryId: String, type: String, value: Any) {
        guard let provider = statusProvider else { return }

        // Use direct HomeKit control (bypasses WebView)
        let selector = NSSelectorFromString("menuSetCharacteristicDirectWithAccessoryId:characteristicType:value:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, String, Any) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(provider, selector, accessoryId, type, value)
        }

        // Schedule cache refresh after menu closes (don't rebuild while open)
        scheduleDelayedCacheRefresh()
    }

    func setServiceGroupCharacteristic(groupId: String, homeId: String, type: String, value: Any) {
        guard let provider = statusProvider else { return }

        // Use direct HomeKit control (bypasses WebView)
        let selector = NSSelectorFromString("menuSetServiceGroupDirectWithGroupId:homeId:characteristicType:value:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, String, String, Any) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(provider, selector, groupId, homeId, type, value)
        }

        // Schedule cache refresh after menu closes (don't rebuild while open)
        scheduleDelayedCacheRefresh()
    }

    func executeScene(sceneId: String) {
        guard let provider = statusProvider else { return }

        // Use direct HomeKit control (bypasses WebView)
        let selector = NSSelectorFromString("menuExecuteSceneDirectWithSceneId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String) -> Void
            let impl = unsafeBitCast(method, to: Method.self)
            impl(provider, selector, sceneId)
        }

        // Schedule cache refresh after menu closes (don't rebuild while open)
        scheduleDelayedCacheRefresh()
    }

    /// Schedule a cache refresh that waits until menu is closed
    private var pendingCacheRefresh = false

    private func scheduleDelayedCacheRefresh() {
        pendingCacheRefresh = true

        // If menu is not open, refresh immediately (with small delay for HomeKit to settle)
        if !isMenuOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.pendingCacheRefresh else { return }
                self.pendingCacheRefresh = false
                self.invalidateCache()
            }
        }
        // If menu IS open, the refresh will happen in menuDidClose
    }

    // MARK: - Real-Time State Updates

    /// Called by AppDelegate when HomeKit reports a characteristic change
    @objc public func characteristicDidUpdate(accessoryId: String, characteristicType: String, value: Any) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Update individual accessory item if present
            self.observedMenuItems[accessoryId]?.updateCharacteristic(characteristicType, value: value)

            // Also update any group that contains this accessory
            if let groupId = self.accessoryToGroupMap[accessoryId] {
                self.observedMenuItems[groupId]?.updateCharacteristic(characteristicType, value: value)
            }
        }
    }

    /// Called by AppDelegate when accessory reachability changes
    @objc public func accessoryReachabilityDidUpdate(accessoryId: String, isReachable: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.observedMenuItems[accessoryId]?.updateReachability(isReachable)

            // Update group reachability if this accessory belongs to a group
            if let groupId = self.accessoryToGroupMap[accessoryId] {
                let wasReachable = !(self.groupReachableMembers[groupId]?.isEmpty ?? true)
                if isReachable {
                    self.groupReachableMembers[groupId, default: Set()].insert(accessoryId)
                } else {
                    self.groupReachableMembers[groupId]?.remove(accessoryId)
                }
                let nowReachable = !(self.groupReachableMembers[groupId]?.isEmpty ?? true)
                if wasReachable != nowReachable {
                    self.observedMenuItems[groupId]?.updateReachability(nowReachable)
                }
            }
        }
    }

    // MARK: - Cache Management

    /// Refresh all cached data in background
    private func refreshCacheInBackground() {
        guard !isLoading else { return }
        guard let provider = statusProvider else { return }
        isLoading = true

        // Run async to not block current execution, but HomeKit calls need main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Fetch homes first
            var homes: [[String: Any]] = []
            let homesSelector = NSSelectorFromString("menuGetHomes")
            if provider.responds(to: homesSelector) {
                if let result = provider.perform(homesSelector)?.takeUnretainedValue() as? [[String: Any]] {
                    homes = result
                }
            }

            // Update homes cache immediately so menu shows something
            self.cachedHomes = homes
            if !homes.isEmpty && !self.hasLoadedOnce {
                self.hasLoadedOnce = true
            }

            // Fetch detailed data for each home
            var rooms: [String: [[String: Any]]] = [:]
            var accessories: [String: [[String: Any]]] = [:]
            var scenes: [String: [[String: Any]]] = [:]
            var groups: [String: [[String: Any]]] = [:]
            var allRoomIds: [String] = []

            for home in homes {
                guard let homeId = home["id"] as? String else { continue }

                // Rooms
                if let roomList = self.fetchRooms(homeId: homeId, provider: provider) {
                    rooms[homeId] = roomList
                    for room in roomList {
                        if let roomId = room["id"] as? String {
                            allRoomIds.append(roomId)
                        }
                    }
                }

                // All accessories for the home in one bulk call, grouped by room
                if let allAccList = self.fetchAllAccessories(homeId: homeId, provider: provider) {
                    for acc in allAccList {
                        let roomId = acc["roomId"] as? String ?? ""
                        let key = "\(homeId):\(roomId)"
                        accessories[key, default: []].append(acc)
                    }
                }

                // Scenes
                if let sceneList = self.fetchScenes(homeId: homeId, provider: provider) {
                    scenes[homeId] = sceneList
                }

                // Groups
                if let groupList = self.fetchGroups(homeId: homeId, provider: provider) {
                    groups[homeId] = groupList
                }
            }

            // Update all caches
            self.cachedRooms = rooms
            self.cachedAccessories = accessories
            self.cachedScenes = scenes
            self.cachedGroups = groups

            // Pre-compute summaries for faster menu display
            self.rebuildSummaryCache(homes: homes)

            // Only mark as loaded once if we actually got homes
            if !homes.isEmpty {
                self.hasLoadedOnce = true
                self.lastRefreshTime = Date()
                self.menuNeedsRebuild = true

                // Update the menu if it's open (so "Loading..." disappears)
                if let menu = self.currentMenu {
                    self.menuNeedsUpdate(menu)
                }
            }
            self.isLoading = false

            // Fetch settings and widget types from WebView
            let homeIds = homes.compactMap { $0["id"] as? String }
            self.fetchSettingsFromWebView(homeIds: homeIds, roomIds: allRoomIds, provider: provider)
            self.resolveWidgetTypesViaWebView(provider: provider)
        }
    }

    /// Called by AppDelegate when settings arrive asynchronously.
    /// This ensures the plugin picks up settings even when menuGetSettingsSync
    /// returns nil (first call) or stale data.
    @objc public func settingsDidUpdate(_ settings: NSDictionary) {
        guard let settingsDict = settings as? [String: Any] else { return }
        self.cachedSettings = settingsDict
        self.menuNeedsRebuild = true
        // If menu is currently open, rebuild it with new settings
        if let menu = self.currentMenu, self.isMenuOpen {
            self.menuNeedsUpdate(menu)
        }
    }

    /// Fetch settings from WebView via AppDelegate (async, non-blocking)
    private func fetchSettingsFromWebView(homeIds: [String], roomIds: [String], provider: AnyObject) {
        // First, trigger async prefetch to ensure data is in cache
        let prefetchSelector = NSSelectorFromString("menuPrefetchDataWithHomeIds:roomIds:completion:")
        if provider.responds(to: prefetchSelector) {
            let method = provider.method(for: prefetchSelector)
            typealias PrefetchMethod = @convention(c) (AnyObject, Selector, [String], [String], @escaping () -> Void) -> Void
            let impl = unsafeBitCast(method, to: PrefetchMethod.self)

            impl(provider, prefetchSelector, homeIds, roomIds) { [weak self] in
                // After prefetch completes, fetch the settings
                self?.fetchSettingsSync(homeIds: homeIds, roomIds: roomIds, provider: provider)

                // The prefetch may not have completed within the 0.5s timeout,
                // so room groups might not be in Apollo cache yet.
                // Retry after a delay to pick up data once prefetch network requests finish.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.fetchSettingsSync(homeIds: homeIds, roomIds: roomIds, provider: provider)
                    // Also retry widget type resolution (WebView may not have been ready earlier)
                    if self?.cachedWidgetTypes.isEmpty ?? true {
                        self?.resolveWidgetTypesViaWebView(provider: provider)
                    }
                }
            }
        } else {
            // Fallback: just fetch settings directly (may have stale/missing data)
            fetchSettingsSync(homeIds: homeIds, roomIds: roomIds, provider: provider)
        }
    }

    /// Synchronously fetch settings from WebView
    private func fetchSettingsSync(homeIds: [String], roomIds: [String], provider: AnyObject) {
        let selector = NSSelectorFromString("menuGetSettingsSyncWithHomeIds:roomIds:")
        guard provider.responds(to: selector) else { return }

        let method = provider.method(for: selector)
        typealias SettingsMethod = @convention(c) (AnyObject, Selector, [String], [String]) -> NSDictionary?
        let impl = unsafeBitCast(method, to: SettingsMethod.self)

        if let settings = impl(provider, selector, homeIds, roomIds) as? [String: Any] {
            self.cachedSettings = settings
            self.menuNeedsRebuild = true
            // If menu is open, rebuild it with new data
            if let menu = self.currentMenu, self.isMenuOpen {
                DispatchQueue.main.async {
                    self.menuNeedsUpdate(menu)
                }
            }
        }
    }

    /// Resolve widget types for all cached accessories via WebView JavaScript.
    /// Calls window.menuBarControl.resolveWidgetTypes() with {id, category, serviceTypes}
    /// and caches the results for createMenuItemView() to use.
    private func resolveWidgetTypesViaWebView(provider: AnyObject) {
        // Build payload: [{id, category, serviceTypes}] for all accessories
        var accessoryInputs: [[String: Any]] = []
        for (_, accessories) in cachedAccessories {
            for accessory in accessories {
                guard let accId = accessory["id"] as? String else { continue }
                var input: [String: Any] = ["id": accId]
                if let category = accessory["category"] as? String {
                    input["category"] = category
                }
                if let serviceTypes = accessory["serviceTypes"] as? [String] {
                    input["serviceTypes"] = serviceTypes
                } else {
                    input["serviceTypes"] = [] as [String]
                }
                accessoryInputs.append(input)
            }
        }

        guard !accessoryInputs.isEmpty else { return }

        // Serialize to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: accessoryInputs),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let js = """
            (function() {
                if (window.menuBarControl && window.menuBarControl.resolveWidgetTypes) {
                    try {
                        var result = window.menuBarControl.resolveWidgetTypes(\(jsonStr));
                        return JSON.stringify(result);
                    } catch (e) {
                        console.error('[MenuBar] resolveWidgetTypes failed:', e);
                        return null;
                    }
                } else {
                    return null;
                }
            })();
            """

        let selector = NSSelectorFromString("menuEvaluateJavaScript:completion:")
        guard provider.responds(to: selector) else { return }

        let method = provider.method(for: selector)
        typealias EvalMethod = @convention(c) (AnyObject, Selector, String, @escaping (String?) -> Void) -> Void
        let impl = unsafeBitCast(method, to: EvalMethod.self)

        impl(provider, selector, js) { [weak self] resultStr in
            guard let self = self,
                  let resultStr = resultStr,
                  let resultData = resultStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: [String: Any]] else {
                return
            }
            self.cachedWidgetTypes = parsed
            self.menuNeedsRebuild = true
            print("[MenuBar] Resolved \(parsed.count) widget types via WebView")
            // If menu is currently open, rebuild it with resolved types
            if let menu = self.currentMenu, self.isMenuOpen {
                DispatchQueue.main.async {
                    self.menuNeedsUpdate(menu)
                }
            }
        }
    }

    /// Create the appropriate menu item view based on a resolved widget type string.
    /// Falls back to the existing boolean-flag logic if widgetType is unknown.
    private func createViewForWidgetType(_ widgetType: String, accessory: [String: Any], config: MenuItemConfiguration) -> HighlightingMenuItemView {
        let hasBrightness = accessory["hasBrightness"] as? Bool ?? false
        let hasRGB = accessory["hasRGB"] as? Bool ?? false
        let hasColorTemp = accessory["hasColorTemp"] as? Bool ?? false

        switch widgetType {
        case "lightbulb":
            return LightMenuItem(hasBrightness: hasBrightness, hasRGB: hasRGB, hasColorTemp: hasColorTemp)
        case "switch", "outlet", "fan", "valve", "air_purifier", "humidifier", "irrigation":
            return SwitchMenuItem()
        case "thermostat":
            return ThermostatMenuItem()
        case "lock":
            return LockMenuItem()
        case "garage_door":
            return GarageDoorMenuItem()
        case "window_covering":
            return BlindMenuItem()
        case "security_system":
            return SecuritySystemMenuItem()
        case "smoke_alarm":
            return SmokeAlarmMenuItem()
        case "button", "remote":
            return RemoteMenuItem()
        default:
            // sensor, motion_sensor, multi_sensor, contact_sensor,
            // camera, doorbell, speaker, door_window, info, hidden
            return SensorMenuItem()
        }
    }

    private func fetchRooms(homeId: String, provider: AnyObject) -> [[String: Any]]? {
        let selector = NSSelectorFromString("menuGetRoomsWithHomeId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String) -> [[String: Any]]
            let impl = unsafeBitCast(method, to: Method.self)
            return impl(provider, selector, homeId)
        }
        return nil
    }

    private func fetchAccessories(homeId: String, roomId: String, provider: AnyObject) -> [[String: Any]]? {
        let selector = NSSelectorFromString("menuGetAccessoriesWithHomeId:roomId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String, String) -> [[String: Any]]
            let impl = unsafeBitCast(method, to: Method.self)
            return impl(provider, selector, homeId, roomId)
        }
        return nil
    }

    private func fetchAllAccessories(homeId: String, provider: AnyObject) -> [[String: Any]]? {
        let selector = NSSelectorFromString("menuGetAllAccessoriesWithHomeId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String) -> [[String: Any]]
            let impl = unsafeBitCast(method, to: Method.self)
            return impl(provider, selector, homeId)
        }
        return nil
    }

    private func fetchScenes(homeId: String, provider: AnyObject) -> [[String: Any]]? {
        let selector = NSSelectorFromString("menuGetScenesWithHomeId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String) -> [[String: Any]]
            let impl = unsafeBitCast(method, to: Method.self)
            return impl(provider, selector, homeId)
        }
        return nil
    }

    private func fetchGroups(homeId: String, provider: AnyObject) -> [[String: Any]]? {
        let selector = NSSelectorFromString("menuGetServiceGroupsWithHomeId:")
        if provider.responds(to: selector) {
            let method = provider.method(for: selector)
            typealias Method = @convention(c) (AnyObject, Selector, String) -> [[String: Any]]
            let impl = unsafeBitCast(method, to: Method.self)
            return impl(provider, selector, homeId)
        }
        return nil
    }

    /// Called by AppDelegate when HomeKit reports homes are ready.
    /// Triggers a fresh cache load so data is pre-populated before the user opens the menu.
    @objc public func homeKitDidBecomeReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.hasLoadedOnce {
                self.invalidateCache()
            }
        }
    }

    /// Invalidate cache and trigger background refresh
    func invalidateCache() {
        lastRefreshTime = nil
        refreshCacheInBackground()
    }

    // MARK: - Menu Lifecycle (Observation)

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true

        // Install event monitor to prevent clicks from closing submenus.
        // Returning nil from the monitor swallows the event before menu tracking sees it.
        if submenuClickMonitor == nil {
            submenuClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard self?.isMenuOpen == true,
                      let window = event.window,
                      let contentView = window.contentView else { return event }

                let locationInWindow = event.locationInWindow
                let hitView = contentView.hitTest(locationInWindow)

                // Walk up from hit view to check if it's inside a SubmenuItemView
                var view = hitView
                while let v = view {
                    if v is SubmenuItemView {
                        return nil // Swallow the click
                    }
                    view = v.superview
                }
                return event // Pass through all other clicks
            }
        }

        // Start HomeKit observation when menu opens
        startObservation()

        // Trigger refresh if cache is stale
        let shouldRefresh: Bool
        if let lastRefresh = lastRefreshTime {
            shouldRefresh = Date().timeIntervalSince(lastRefresh) > cacheTimeout
        } else {
            shouldRefresh = !isLoading
        }

        if shouldRefresh {
            refreshCacheInBackground()
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        // Clear menu from status item to prevent click absorption (Mac Catalyst)
        DispatchQueue.main.async { [weak self] in
            if !(self?.isMenuOpen ?? false) {
                self?.statusItem?.menu = nil
            }
        }

        isMenuOpen = false

        if let monitor = submenuClickMonitor {
            NSEvent.removeMonitor(monitor)
            submenuClickMonitor = nil
        }

        // Handle pending cache refresh from control actions
        if pendingCacheRefresh {
            pendingCacheRefresh = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.invalidateCache()
            }
        }

        // Stop HomeKit observation after a delay (in case menu reopens quickly)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            if !self.isMenuOpen {
                self.stopObservation()
                // Clear observed items when menu is definitively closed
                self.observedMenuItems.removeAll()
                self.accessoryToGroupMap.removeAll()
                self.groupReachableMembers.removeAll()
            }
        }
    }

    private func startObservation() {
        guard let provider = statusProvider else { return }

        let selector = NSSelectorFromString("startHomeKitObservation")
        if provider.responds(to: selector) {
            _ = provider.perform(selector)
        }
    }

    private func stopObservation() {
        guard let provider = statusProvider else { return }

        let selector = NSSelectorFromString("stopHomeKitObservation")
        if provider.responds(to: selector) {
            _ = provider.perform(selector)
        }
    }

    // MARK: - Window & Status Item

    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
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
            if let originalImage = NSImage(named: "MenuBarIcon") {
                // Scale to 90% (10% smaller than original)
                let originalSize = originalImage.size
                let scaledWidth = originalSize.width * 0.9
                let scaledHeight = originalSize.height * 0.9

                // 2px up: add padding at bottom to shift icon up
                let verticalOffset: CGFloat = 2.0
                let finalSize = NSSize(width: scaledWidth, height: scaledHeight + verticalOffset)

                let finalImage = NSImage(size: finalSize)
                finalImage.lockFocus()
                originalImage.draw(
                    in: NSRect(x: 0, y: verticalOffset, width: scaledWidth, height: scaledHeight),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                finalImage.unlockFocus()
                finalImage.isTemplate = true

                button.image = finalImage
            } else {
                button.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Homecast")
                button.image?.isTemplate = true
            }

            // Use action-based menu display instead of permanently assigning menu.
            // Permanent assignment causes the status item to absorb all clicks
            // in its area even when the menu is not visible (Mac Catalyst issue).
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = buildMenu()
        menu.delegate = self
        currentMenu = menu
    }

    /// Update the colored status dot overlay on the menu bar icon.
    /// The house icon stays as a native template image (proper dark/light mode).
    /// A small colored NSView dot is overlaid on the button for non-normal states.
    private func updateStatusDot() {
        guard let button = statusItem?.button else { return }

        // Remove existing dot
        statusDotView?.removeFromSuperview()
        statusDotView = nil

        // Only show dot for problem states (not active/unknown)
        guard currentRelayStatus != .unknown && currentRelayStatus != .active else { return }

        let dotColor: NSColor = {
            switch currentRelayStatus {
            case .standby, .connecting: return .systemOrange
            case .disconnected: return .systemRed
            default: return .clear
            }
        }()

        let dotDiameter: CGFloat = 6.0
        let dot = NSView(frame: NSRect(
            x: button.bounds.width - dotDiameter - 1,
            y: 2,
            width: dotDiameter,
            height: dotDiameter
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = dotDiameter / 2

        button.addSubview(dot)
        statusDotView = dot
    }

    /// Called by AppDelegate when WebView reports relay connection status changes.
    @objc public func relayStatusDidChange(connectionState: String, relayStatus: NSNumber?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let newStatus: RelayIconStatus
            switch connectionState {
            case "connected":
                if let relay = relayStatus?.boolValue {
                    newStatus = relay ? .active : .standby
                } else {
                    newStatus = .active
                }
            case "connecting", "reconnecting":
                newStatus = .connecting
            default:
                newStatus = .disconnected
            }

            guard newStatus != self.currentRelayStatus else { return }
            self.currentRelayStatus = newStatus
            self.updateStatusDot()
        }
    }

    @objc private func statusItemClicked() {
        guard let menu = currentMenu, let button = statusItem?.button else { return }
        // Assign menu only while showing — menuDidClose clears it to prevent
        // the Mac Catalyst bug where the status item absorbs clicks permanently.
        statusItem?.menu = menu
        button.performClick(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let placeholder = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        placeholder.tag = 100
        menu.addItem(placeholder)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Homecast", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - NSMenuDelegate

    private let dynamicItemTag = 100

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Skip full rebuild if menu was recently built and data hasn't changed
        if !menuNeedsRebuild, let lastBuild = lastMenuBuildTime, Date().timeIntervalSince(lastBuild) < 5.0 {
            return
        }

        // Clear observed items when rebuilding
        observedMenuItems.removeAll()
        accessoryToGroupMap.removeAll()
        groupReachableMembers.removeAll()

        // Remove all dynamic items (tagged with dynamicItemTag)
        var itemsToRemove: [NSMenuItem] = []
        var insertIndex = 0 // Default: at the top of the menu

        for (index, item) in menu.items.enumerated() {
            if item.tag == dynamicItemTag {
                if itemsToRemove.isEmpty {
                    insertIndex = index // Remember where first dynamic item was
                }
                itemsToRemove.append(item)
            }
        }

        for item in itemsToRemove {
            menu.removeItem(item)
        }

        // Show loading state if we haven't loaded yet
        if !hasLoadedOnce {
            let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            loadingItem.tag = dynamicItemTag
            if isLoading {
                loadingItem.title = "Loading HomeKit..."
            }
            menu.insertItem(loadingItem, at: insertIndex)
            return
        }

        // Show cached data immediately (never block)
        // Use getVisibleOrderedHomes() to respect visibility and ordering settings from app-web
        let visibleHomes = getVisibleOrderedHomes()

        if visibleHomes.isEmpty {
            let emptyItem = NSMenuItem(title: "No homes available", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            emptyItem.tag = dynamicItemTag
            menu.insertItem(emptyItem, at: insertIndex)
        } else {
            var currentIndex = insertIndex

            // Ensure we have a selected home
            if selectedHomeId == nil {
                selectedHomeId = UserDefaults.standard.string(forKey: selectedHomeKey)
            }
            if selectedHomeId == nil || !visibleHomes.contains(where: { ($0["id"] as? String) == selectedHomeId }) {
                // Default to primary home or first home
                selectedHomeId = visibleHomes.first(where: { $0["isPrimary"] as? Bool == true })?["id"] as? String
                    ?? visibleHomes.first?["id"] as? String
            }

            guard let homeId = selectedHomeId,
                  let currentHome = visibleHomes.first(where: { ($0["id"] as? String) == homeId }) else {
                return
            }

            // Home selector (only show if multiple homes)
            if visibleHomes.count > 1 {
                let homeSelectorItem = buildHomeSelectorMenuItem(currentHome: currentHome, allHomes: visibleHomes)
                homeSelectorItem.tag = dynamicItemTag
                menu.insertItem(homeSelectorItem, at: currentIndex)
                currentIndex += 1
            } else {
                // Show home name when only one home
                let homeName = currentHome["name"] as? String ?? "Home"
                let homeNameItem = NSMenuItem(title: homeName, action: nil, keyEquivalent: "")
                homeNameItem.isEnabled = false
                homeNameItem.tag = dynamicItemTag
                menu.insertItem(homeNameItem, at: currentIndex)
                currentIndex += 1
            }

            // Home summary (aggregated sensor data) - use cached data
            if let homeSummaryData = cachedHomeSummaries[homeId], homeSummaryData.hasData {
                let summaryItem = NSMenuItem()
                let summaryView = AreaSummaryView()
                summaryView.configure(with: homeSummaryData)
                summaryItem.view = summaryView
                summaryItem.tag = dynamicItemTag
                menu.insertItem(summaryItem, at: currentIndex)
                currentIndex += 1
            }

            let topSeparator = NSMenuItem.separator()
            topSeparator.tag = dynamicItemTag
            menu.insertItem(topSeparator, at: currentIndex)
            currentIndex += 1

            // Groups section (at top level)
            if let groupsItems = buildGroupsSection(homeId: homeId) {
                for item in groupsItems {
                    item.tag = dynamicItemTag
                    menu.insertItem(item, at: currentIndex)
                    currentIndex += 1
                }
            }

            // Rooms at top level
            let roomItems = buildRoomItems(homeId: homeId)
            for item in roomItems {
                item.tag = dynamicItemTag
                menu.insertItem(item, at: currentIndex)
                currentIndex += 1
            }

            // Collections section (spans all homes, shown at bottom)
            let collectionItems = buildCollectionMenuItems()
            if !collectionItems.isEmpty {
                let separator = NSMenuItem.separator()
                separator.tag = dynamicItemTag
                menu.insertItem(separator, at: currentIndex)
                currentIndex += 1

                for collectionItem in collectionItems {
                    collectionItem.tag = dynamicItemTag
                    menu.insertItem(collectionItem, at: currentIndex)
                    currentIndex += 1
                }
            }
        }

        // Mark menu as built
        menuNeedsRebuild = false
        lastMenuBuildTime = Date()
    }

    // MARK: - Device-Specific Menu Item Factory

    /// Create the appropriate menu item view based on device category and characteristics.
    /// Prefers JS-resolved widget type from WebView when available, falls back to local heuristics.
    private func createMenuItemView(for accessory: [String: Any], homeId: String, roomName: String?) -> NSView {
        var config = MenuItemConfiguration.accessory(accessory, homeId: homeId, roomName: roomName)

        let view: HighlightingMenuItemView

        // Try JS-resolved widget type first (single source of truth, matches web dashboard)
        if let accessoryId = accessory["id"] as? String,
           let resolved = cachedWidgetTypes[accessoryId],
           let widgetType = resolved["widgetType"] as? String {
            config.resolvedWidgetType = widgetType
            view = createViewForWidgetType(widgetType, accessory: accessory, config: config)
        } else {
            // Fallback: local boolean-flag heuristics (used before WebView is ready)
            let category = (accessory["category"] as? String)?.lowercased() ?? ""

            let hasThermostat = accessory["hasThermostat"] as? Bool ?? false
            let isThermostatCategory = category.contains("thermostat") || category.contains("heater") ||
                                       category.contains("cooler") || category.contains("air conditioner") ||
                                       category.contains("hvac")

            let hasSecuritySystem = accessory["hasSecuritySystem"] as? Bool ?? false
            let isSecurityCategory = category.contains("security") || category.contains("alarm")

            let hasBrightness = accessory["hasBrightness"] as? Bool ?? false
            let hasPosition = accessory["hasPosition"] as? Bool ?? false
            let hasRGB = accessory["hasRGB"] as? Bool ?? false
            let hasColorTemp = accessory["hasColorTemp"] as? Bool ?? false
            let hasPower = accessory["hasPower"] as? Bool ?? false

            if hasThermostat || isThermostatCategory {
                view = ThermostatMenuItem()
            } else if hasSecuritySystem || isSecurityCategory {
                view = SecuritySystemMenuItem()
            } else if category.contains("lock") {
                view = LockMenuItem()
            } else if category.contains("garage") {
                view = GarageDoorMenuItem()
            } else if hasPosition {
                view = BlindMenuItem()
            } else if hasBrightness {
                view = LightMenuItem(hasBrightness: true, hasRGB: hasRGB, hasColorTemp: hasColorTemp)
            } else if category.contains("light") {
                view = LightMenuItem(hasBrightness: false, hasRGB: false, hasColorTemp: false)
            } else if category.contains("sensor") || category.contains("motion") ||
                      category.contains("contact") || category.contains("occupancy") ||
                      category.contains("humidity") || category.contains("temperature") {
                view = SensorMenuItem()
            } else if category.contains("camera") || category.contains("video") ||
                      category.contains("doorbell") || category.contains("bridge") ||
                      category.contains("button") || category.contains("programmable") ||
                      category.contains("speaker") {
                view = SensorMenuItem()
            } else if hasPower {
                view = SwitchMenuItem()
            } else {
                view = SensorMenuItem()
            }
        }

        view.configure(with: config)
        view.controller = self

        // Track for real-time updates
        if let accessoryId = config.id {
            observedMenuItems[accessoryId] = view
        }

        return view
    }

    /// Create the appropriate menu item view for a service group.
    /// Uses the specialized widget when all items in the group are the same type.
    private func createGroupMenuItemView(for group: [String: Any], homeId: String, roomName: String?) -> NSView {
        let config = MenuItemConfiguration.group(group, homeId: homeId, roomName: roomName)
        let groupCategory = (group["groupCategory"] as? String)?.lowercased() ?? ""

        let view: HighlightingMenuItemView

        if groupCategory.contains("window") && groupCategory.contains("covering") {
            view = BlindMenuItem()
        } else if groupCategory.contains("light") {
            let hasBrightness = group["hasBrightness"] as? Bool ?? false
            let hasRGB = group["hasRGB"] as? Bool ?? false
            let hasColorTemp = group["hasColorTemp"] as? Bool ?? false
            view = LightMenuItem(hasBrightness: hasBrightness, hasRGB: hasRGB, hasColorTemp: hasColorTemp)
        } else {
            let hasBrightness = group["hasBrightness"] as? Bool ?? false
            let hasPosition = group["hasPosition"] as? Bool ?? false
            view = GroupMenuItem(hasSlider: hasBrightness || hasPosition)
        }

        view.configure(with: config)
        view.controller = self

        // Track for real-time updates
        if let groupId = config.id {
            observedMenuItems[groupId] = view

            // Map all accessory IDs in this group to the group ID for live updates
            // and track initial reachability state per member
            if let accessoryIds = group["accessoryIds"] as? [String] {
                var reachableSet = Set<String>()
                for accId in accessoryIds {
                    accessoryToGroupMap[accId] = groupId
                    // Check if this member is reachable in cached data
                    let isAccReachable = isCachedAccessoryReachable(accId, homeId: homeId)
                    if isAccReachable {
                        reachableSet.insert(accId)
                    }
                }
                groupReachableMembers[groupId] = reachableSet
            }
        }

        return view
    }

    // MARK: - Settings Helpers

    /// Get visible homes filtered by hiddenHomes and ordered by homeOrder
    private func getVisibleOrderedHomes() -> [[String: Any]] {
        guard !cachedHomes.isEmpty else { return [] }

        guard cachedSettings != nil else {
            return cachedHomes
        }

        let hiddenHomes = (cachedSettings?["hiddenHomes"] as? [String]) ?? []
        let homeOrder = (cachedSettings?["homeOrder"] as? [String]) ?? []

        var visibleHomes = cachedHomes.filter { home in
            guard let homeId = home["id"] as? String else { return true }
            return !hiddenHomes.contains(homeId)
        }

        if visibleHomes.isEmpty && !cachedHomes.isEmpty {
            visibleHomes = cachedHomes
        }

        if !homeOrder.isEmpty {
            visibleHomes.sort { home1, home2 in
                let id1 = home1["id"] as? String ?? ""
                let id2 = home2["id"] as? String ?? ""
                let idx1 = homeOrder.firstIndex(of: id1) ?? Int.max
                let idx2 = homeOrder.firstIndex(of: id2) ?? Int.max
                return idx1 < idx2
            }
        } else {
            visibleHomes.sort { home1, home2 in
                let name1 = home1["name"] as? String ?? ""
                let name2 = home2["name"] as? String ?? ""
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        }

        return visibleHomes
    }

    /// Sidebar tree item: either a room or a room group containing rooms
    private enum SidebarItem {
        case room([String: Any])
        case roomGroup(name: String, entityId: String, rooms: [[String: Any]])
    }

    /// Get visible rooms for a home as an ordered sidebar tree (rooms + room groups),
    /// respecting the roomOrder from app-web which interleaves room IDs and room-group-{entityId} entries.
    private func getOrderedSidebarItems(homeId: String) -> [SidebarItem] {
        guard let rooms = cachedRooms[homeId], !rooms.isEmpty else { return [] }

        let homeLayoutsAny = cachedSettings?["homeLayouts"] as? [String: Any]
        let homeLayoutAny = homeLayoutsAny?[homeId] as? [String: Any]
        let hiddenRooms = (homeLayoutAny?["hiddenRooms"] as? [String]) ?? []
        let roomOrder = (homeLayoutAny?["roomOrder"] as? [String]) ?? []

        // Build room groups lookup from settings
        let roomGroupsForHome = getRoomGroups(homeId: homeId)

        // Build normalized room ID lookup (lowercase, no dashes) to handle UUID format differences
        // Room group roomIds may be stored normalized while HomeKit returns them with dashes/mixed case
        func normalizeId(_ id: String) -> String {
            id.lowercased().replacingOccurrences(of: "-", with: "")
        }

        // Build room lookup by normalized ID
        var roomByNormalizedId: [String: [String: Any]] = [:]
        var normalizedToOriginal: [String: String] = [:]
        for room in rooms {
            guard let rid = room["id"] as? String else { continue }
            let nid = normalizeId(rid)
            roomByNormalizedId[nid] = room
            normalizedToOriginal[nid] = rid
        }

        // Build a set of normalized room IDs that belong to a room group
        var roomsInGroups = Set<String>()
        for group in roomGroupsForHome {
            for rid in group.roomIds {
                roomsInGroups.insert(normalizeId(rid))
            }
        }

        // Filter visible rooms (using normalized IDs for hidden check too)
        let hiddenNormalized = Set(hiddenRooms.map { normalizeId($0) })
        let visibleNormalizedIds = Set(rooms.compactMap { $0["id"] as? String }.map { normalizeId($0) }.filter { !hiddenNormalized.contains($0) })

        var result: [SidebarItem] = []
        var placedNormalizedIds = Set<String>()
        var placedGroupEntityIds = Set<String>()

        // Walk roomOrder, placing items in order
        for entry in roomOrder {
            if entry.hasPrefix("room-group-") {
                // Room group entry
                let entityId = String(entry.dropFirst("room-group-".count))
                if let group = roomGroupsForHome.first(where: { $0.entityId == entityId }) {
                    let groupRooms = group.roomIds.compactMap { rid -> [String: Any]? in
                        let nid = normalizeId(rid)
                        guard visibleNormalizedIds.contains(nid), let room = roomByNormalizedId[nid] else { return nil }
                        return room
                    }
                    if !groupRooms.isEmpty {
                        result.append(.roomGroup(name: group.name, entityId: group.entityId, rooms: groupRooms))
                        for room in groupRooms {
                            if let rid = room["id"] as? String { placedNormalizedIds.insert(normalizeId(rid)) }
                        }
                    }
                    placedGroupEntityIds.insert(entityId)
                }
            } else {
                // Regular room entry
                let nid = normalizeId(entry)
                if visibleNormalizedIds.contains(nid), !roomsInGroups.contains(nid), let room = roomByNormalizedId[nid] {
                    result.append(.room(room))
                    placedNormalizedIds.insert(nid)
                }
            }
        }

        // Add any remaining room groups not in roomOrder
        for group in roomGroupsForHome {
            guard !placedGroupEntityIds.contains(group.entityId) else { continue }
            let groupRooms = group.roomIds.compactMap { rid -> [String: Any]? in
                let nid = normalizeId(rid)
                guard visibleNormalizedIds.contains(nid), let room = roomByNormalizedId[nid] else { return nil }
                return room
            }
            if !groupRooms.isEmpty {
                result.append(.roomGroup(name: group.name, entityId: group.entityId, rooms: groupRooms))
                for room in groupRooms {
                    if let rid = room["id"] as? String { placedNormalizedIds.insert(normalizeId(rid)) }
                }
            }
        }

        // Add any remaining visible rooms not yet placed (new rooms not in order or in any group)
        var remainingRooms = rooms.filter { room in
            guard let rid = room["id"] as? String else { return false }
            let nid = normalizeId(rid)
            return visibleNormalizedIds.contains(nid) &&
                   !placedNormalizedIds.contains(nid) &&
                   !roomsInGroups.contains(nid)
        }

        // When no custom order is set, sort remaining rooms alphabetically
        if roomOrder.isEmpty {
            remainingRooms.sort { room1, room2 in
                let name1 = room1["name"] as? String ?? ""
                let name2 = room2["name"] as? String ?? ""
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        }

        for room in remainingRooms {
            result.append(.room(room))
        }

        return result
    }

    /// Parse room groups from cachedSettings for a home
    private struct RoomGroupInfo {
        let id: String
        let entityId: String
        let name: String
        let roomIds: [String]
    }

    private func getRoomGroups(homeId: String) -> [RoomGroupInfo] {
        guard let roomGroupsAny = cachedSettings?["roomGroups"] as? [String: Any],
              let groupsArray = roomGroupsAny[homeId] as? [[String: Any]] else {
            return []
        }
        return groupsArray.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let entityId = dict["entityId"] as? String,
                  let name = dict["name"] as? String,
                  let roomIds = dict["roomIds"] as? [String] else { return nil }
            return RoomGroupInfo(id: id, entityId: entityId, name: name, roomIds: roomIds)
        }
    }

    /// Get visible rooms for a home (flat list, for use in home submenus)
    private func getVisibleOrderedRooms(homeId: String) -> [[String: Any]] {
        let items = getOrderedSidebarItems(homeId: homeId)
        var result: [[String: Any]] = []
        for item in items {
            switch item {
            case .room(let room):
                result.append(room)
            case .roomGroup(_, _, let rooms):
                result.append(contentsOf: rooms)
            }
        }
        return result
    }

    /// Pre-compute summary data for all homes and rooms
    private func rebuildSummaryCache(homes: [[String: Any]]) {
        var homeSummaries: [String: AreaSummaryData] = [:]
        var roomSummaries: [String: AreaSummaryData] = [:]

        for home in homes {
            guard let homeId = home["id"] as? String else { continue }

            var roomSummaryList: [AreaSummaryData] = []

            // Get rooms for this home
            if let rooms = cachedRooms[homeId] {
                for room in rooms {
                    guard let roomId = room["id"] as? String else { continue }
                    let roomName = room["name"] as? String

                    // Get accessories for this room
                    if let accessories = cachedAccessories["\(homeId):\(roomId)"] {
                        // Cache room summary (with room name for tooltips)
                        let roomSummary = aggregateSensorData(for: accessories, roomName: roomName)
                        roomSummaries["\(homeId):\(roomId)"] = roomSummary
                        roomSummaryList.append(roomSummary)
                    }
                }
            }

            // Merge room summaries into home summary (preserves per-room readings)
            var homeSummary = AreaSummaryData()
            for rs in roomSummaryList {
                homeSummary.temperatures.append(contentsOf: rs.temperatures)
                homeSummary.humidities.append(contentsOf: rs.humidities)
                homeSummary.motionActiveCount += rs.motionActiveCount
                homeSummary.motionTotalCount += rs.motionTotalCount
                homeSummary.lockedCount += rs.lockedCount
                homeSummary.unlockedCount += rs.unlockedCount
                homeSummary.jammedCount += rs.jammedCount
                homeSummary.openContactCount += rs.openContactCount
                homeSummary.closedContactCount += rs.closedContactCount
                homeSummary.lowBatteryCount += rs.lowBatteryCount
                homeSummary.temperatureReadings.append(contentsOf: rs.temperatureReadings)
                homeSummary.humidityReadings.append(contentsOf: rs.humidityReadings)
                homeSummary.motionReadings.append(contentsOf: rs.motionReadings)
                homeSummary.lockReadings.append(contentsOf: rs.lockReadings)
                homeSummary.contactReadings.append(contentsOf: rs.contactReadings)
                homeSummary.lowBatteryReadings.append(contentsOf: rs.lowBatteryReadings)
            }
            homeSummaries[homeId] = homeSummary
        }

        cachedHomeSummaries = homeSummaries
        cachedRoomSummaries = roomSummaries
    }

    /// Get all accessories for a home (across all rooms)
    private func getAllAccessoriesForHome(homeId: String) -> [[String: Any]] {
        var allAccessories: [[String: Any]] = []
        let rooms = getVisibleOrderedRooms(homeId: homeId)
        for room in rooms {
            guard let roomId = room["id"] as? String else { continue }
            let roomAccessories = getVisibleOrderedAccessories(homeId: homeId, roomId: roomId)
            allAccessories.append(contentsOf: roomAccessories)
        }
        return allAccessories
    }

    /// Get visible accessories for a room, filtered and ordered by settings
    private func getVisibleOrderedAccessories(homeId: String, roomId: String) -> [[String: Any]] {
        guard let accessories = cachedAccessories["\(homeId):\(roomId)"], !accessories.isEmpty else { return [] }

        // Cast step by step to handle nested dictionaries from JSON
        let roomLayoutsAny = cachedSettings?["roomLayouts"] as? [String: Any]
        let roomLayoutAny = roomLayoutsAny?[roomId] as? [String: Any]
        let hiddenAccessories = (roomLayoutAny?["hiddenAccessories"] as? [String]) ?? []
        let itemOrder = (roomLayoutAny?["itemOrder"] as? [String]) ?? []

        // hideInfoDevices defaults to true (matching web app)
        let hideInfoDevices = (cachedSettings?["hideInfoDevices"] as? Bool) ?? true

        var visibleAccessories = accessories.filter { accessory in
            guard let accId = accessory["id"] as? String else { return true }
            if hiddenAccessories.contains(accId) { return false }
            // Filter info/hidden devices when hideInfoDevices is enabled
            if hideInfoDevices {
                let wt = cachedWidgetTypes[accId]?["widgetType"] as? String
                if wt == "info" || wt == "hidden" { return false }
            }
            return true
        }

        if !itemOrder.isEmpty {
            visibleAccessories.sort { acc1, acc2 in
                let id1 = acc1["id"] as? String ?? ""
                let id2 = acc2["id"] as? String ?? ""
                let idx1 = itemOrder.firstIndex(of: id1) ?? Int.max
                let idx2 = itemOrder.firstIndex(of: id2) ?? Int.max
                return idx1 < idx2
            }
        } else {
            visibleAccessories.sort { acc1, acc2 in
                let id1 = acc1["id"] as? String ?? ""
                let id2 = acc2["id"] as? String ?? ""
                let wt1 = cachedWidgetTypes[id1]?["widgetType"] as? String
                let wt2 = cachedWidgetTypes[id2]?["widgetType"] as? String
                let cat1 = categoryIndex(forWidgetType: wt1)
                let cat2 = categoryIndex(forWidgetType: wt2)
                if cat1 != cat2 { return cat1 < cat2 }
                let name1 = acc1["name"] as? String ?? ""
                let name2 = acc2["name"] as? String ?? ""
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        }

        return visibleAccessories
    }

    /// Map a resolved widgetType to a category sort index matching the web app's CATEGORY_ORDER
    private func categoryIndex(forWidgetType widgetType: String?) -> Int {
        switch widgetType {
        case "lightbulb": return 0          // Lights
        case "switch", "outlet": return 1   // Switches
        case "thermostat", "air_purifier",
             "humidifier": return 2         // Climate
        case "fan": return 3                // Fans
        case "window_covering": return 4    // Blinds & Shades
        case "lock",
             "security_system": return 5    // Security
        case "garage_door",
             "door_window": return 6        // Doors
        case "sensor", "contact_sensor",
             "smoke_alarm", "motion_sensor",
             "multi_sensor": return 7       // Sensors
        case "camera", "doorbell": return 8 // Cameras
        case "speaker": return 9            // Audio
        case "valve",
             "irrigation": return 10        // Water
        case "button", "remote": return 11  // Buttons & Remotes
        case "info", "hidden": return 12    // Bridges & Hubs
        default: return 13                  // Other
        }
    }

    /// Check if a service group is hidden
    private func isGroupHidden(groupId: String, roomId: String?) -> Bool {
        guard let roomId = roomId else { return false }
        let roomLayouts = cachedSettings?["roomLayouts"] as? [String: [String: Any]]
        let roomLayout = roomLayouts?[roomId]
        let hiddenGroups = (roomLayout?["hiddenGroups"] as? [String]) ?? []
        return hiddenGroups.contains(groupId)
    }

    /// Aggregate sensor data from accessories for summary display
    /// Note: Accessory data is flattened (no services array), using direct properties like lockState, currentTemperature
    private func aggregateSensorData(for accessories: [[String: Any]], roomName: String? = nil) -> AreaSummaryData {
        var data = AreaSummaryData()

        for accessory in accessories {
            // Skip unreachable accessories
            guard accessory["isReachable"] as? Bool ?? true else { continue }

            let name = accessory["name"] as? String ?? "Unknown"

            // Temperature (from thermostat or temperature sensor)
            if let temp = accessory["currentTemperature"] as? Double {
                data.temperatures.append(temp)
                data.temperatureReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: temp))
            } else if let temp = accessory["currentTemperature"] as? Int {
                let tempDouble = Double(temp)
                data.temperatures.append(tempDouble)
                data.temperatureReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: tempDouble))
            }

            // Humidity
            if let humidity = accessory["currentRelativeHumidity"] as? Double {
                data.humidities.append(humidity)
                data.humidityReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: humidity))
            } else if let humidity = accessory["currentRelativeHumidity"] as? Int {
                let humidityDouble = Double(humidity)
                data.humidities.append(humidityDouble)
                data.humidityReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: humidityDouble))
            }

            // Locks (0=Unlocked, 1=Locked, 2=Jammed, 3=Unknown)
            if let lockState = accessory["lockState"] as? Int {
                switch lockState {
                case 0: data.unlockedCount += 1
                case 1: data.lockedCount += 1
                case 2: data.jammedCount += 1
                default: break
                }
                data.lockReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: Double(lockState)))
            }

            // Motion sensors
            if let motionDetected = accessory["motionDetected"] as? Bool {
                data.motionTotalCount += 1
                if motionDetected {
                    data.motionActiveCount += 1
                }
                data.motionReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: motionDetected ? 1 : 0))
            }

            // Occupancy sensors (treat same as motion)
            if let occupancyDetected = accessory["occupancyDetected"] as? Bool {
                data.motionTotalCount += 1
                if occupancyDetected {
                    data.motionActiveCount += 1
                }
                data.motionReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: occupancyDetected ? 1 : 0))
            }

            // Contact sensors (0=closed, 1=open)
            if let contactState = accessory["contactState"] as? Int {
                if contactState == 0 {
                    data.closedContactCount += 1
                } else {
                    data.openContactCount += 1
                }
                data.contactReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: Double(contactState)))
            }

            // Low battery
            if let lowBattery = accessory["statusLowBattery"] as? Int, lowBattery == 1 {
                data.lowBatteryCount += 1
                data.lowBatteryReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: 1))
            } else if let lowBattery = accessory["statusLowBattery"] as? Bool, lowBattery {
                data.lowBatteryCount += 1
                data.lowBatteryReadings.append(SensorReading(accessoryName: name, roomName: roomName, value: 1))
            }
        }

        return data
    }

    // MARK: - Menu Building

    /// Build home selector item with dropdown for switching homes
    private func buildHomeSelectorMenuItem(currentHome: [String: Any], allHomes: [[String: Any]]) -> NSMenuItem {
        let name = currentHome["name"] as? String ?? "Home"

        let item = NSMenuItem()
        // Use custom view for consistent spacing
        let icon = homecastHomeIcon()
        item.view = SubmenuItemView(title: name, icon: icon)

        // Submenu to select different homes
        let submenu = NSMenu()
        for home in allHomes {
            let homeName = home["name"] as? String ?? "Home"
            let homeId = home["id"] as? String ?? ""

            let homeItem = NSMenuItem(title: homeName, action: #selector(selectHome(_:)), keyEquivalent: "")
            homeItem.target = self
            homeItem.representedObject = homeId

            if homeId == selectedHomeId {
                homeItem.state = .on
            }

            // Use the Homecast home icon
            if let icon = homecastHomeIcon() {
                homeItem.image = icon
            }

            submenu.addItem(homeItem)
        }

        item.submenu = submenu
        return item
    }

    /// Get the outline Homecast home icon for menu items
    private func homecastHomeIcon() -> NSImage? {
        guard let originalImage = NSImage(named: "MenuBarIconOutline") else {
            return PhosphorIcon.regular("house")
        }

        let targetSize: CGFloat = DS.ControlSize.iconMedium
        let scaledImage = NSImage(size: NSSize(width: targetSize, height: targetSize))
        scaledImage.lockFocus()
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        scaledImage.unlockFocus()
        scaledImage.isTemplate = true

        return scaledImage
    }

    @objc private func selectHome(_ sender: NSMenuItem) {
        guard let homeId = sender.representedObject as? String else { return }
        selectedHomeId = homeId
        UserDefaults.standard.set(homeId, forKey: selectedHomeKey)
        menuNeedsRebuild = true

        // Rebuild menu immediately
        if let menu = currentMenu {
            menuNeedsUpdate(menu)
        }
    }

    /// Build groups section at top level
    private func buildGroupsSection(homeId: String) -> [NSMenuItem]? {
        let allGroups = cachedGroups[homeId] ?? []
        let globalGroups = allGroups.filter { group in
            let groupId = group["id"] as? String ?? ""
            let roomId = group["roomId"] as? String
            return roomId == nil && !isGroupHidden(groupId: groupId, roomId: roomId)
        }

        guard !globalGroups.isEmpty else { return nil }

        var result: [NSMenuItem] = []

        // Header
        let header = NSMenuItem(title: "Groups", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = PhosphorIcon.regular("squares-four") {
            header.image = icon
        }
        result.append(header)

        for group in globalGroups {
            let groupItem = buildGroupMenuItem(group, roomName: nil, homeId: homeId)
            result.append(groupItem)
        }

        result.append(NSMenuItem.separator())

        return result
    }

    /// Build scenes submenu item
    private func buildScenesSubmenuItem(homeId: String) -> NSMenuItem? {
        guard let scenes = cachedScenes[homeId], !scenes.isEmpty else {
            return nil
        }

        let item = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
        if let icon = PhosphorIcon.regular("sparkle") {
            item.image = icon
        }

        let submenu = NSMenu()
        for scene in scenes {
            let sceneItem = buildSceneMenuItem(scene)
            submenu.addItem(sceneItem)
        }

        item.submenu = submenu
        return item
    }

    /// Build room items at top level, including room groups as submenu containers
    private func buildRoomItems(homeId: String) -> [NSMenuItem] {
        var result: [NSMenuItem] = []

        // Get service groups organized by room
        let allGroups = cachedGroups[homeId] ?? []
        var groupsByRoom: [String: [[String: Any]]] = [:]
        var allGroupedAccessoryIds = Set<String>()

        for group in allGroups {
            let groupId = group["id"] as? String ?? ""
            let roomId = group["roomId"] as? String

            if let ids = group["accessoryIds"] as? [String] {
                allGroupedAccessoryIds.formUnion(ids)
            }

            if isGroupHidden(groupId: groupId, roomId: roomId) {
                continue
            }

            if let roomId = roomId {
                groupsByRoom[roomId, default: []].append(group)
            }
        }

        // Build sidebar items (rooms + room groups in order)
        let sidebarItems = getOrderedSidebarItems(homeId: homeId)
        for sidebarItem in sidebarItems {
            switch sidebarItem {
            case .room(let room):
                let roomItem = buildRoomMenuItem(room, homeId: homeId, roomGroups: groupsByRoom, groupedAccessoryIds: allGroupedAccessoryIds)
                result.append(roomItem)

            case .roomGroup(let name, _, let rooms):
                let groupItem = NSMenuItem()
                let groupIcon = PhosphorIcon.regular("squares-four")
                groupItem.view = SubmenuItemView(title: name, icon: groupIcon)

                let groupSubmenu = NSMenu()
                for room in rooms {
                    let roomItem = buildRoomMenuItem(room, homeId: homeId, roomGroups: groupsByRoom, groupedAccessoryIds: allGroupedAccessoryIds)
                    groupSubmenu.addItem(roomItem)
                }
                groupItem.submenu = groupSubmenu
                result.append(groupItem)
            }
        }

        return result
    }

    private func buildHomeMenuItem(_ home: [String: Any]) -> NSMenuItem {
        let name = home["name"] as? String ?? "Home"
        let homeId = home["id"] as? String ?? ""

        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        // Use the Homecast home icon
        if let icon = homecastHomeIcon() {
            item.image = icon
        }

        let submenu = NSMenu()

        // Get service groups and organize by room
        let allGroups = cachedGroups[homeId] ?? []
        var globalGroups: [[String: Any]] = []
        var groupsByRoom: [String: [[String: Any]]] = [:]
        var allGroupedAccessoryIds = Set<String>()

        for group in allGroups {
            let groupId = group["id"] as? String ?? ""
            let roomId = group["roomId"] as? String

            if let ids = group["accessoryIds"] as? [String] {
                allGroupedAccessoryIds.formUnion(ids)
            }

            if isGroupHidden(groupId: groupId, roomId: roomId) {
                continue
            }

            if let roomId = roomId {
                groupsByRoom[roomId, default: []].append(group)
            } else {
                globalGroups.append(group)
            }
        }

        // Global groups section
        if !globalGroups.isEmpty {
            let header = NSMenuItem(title: "Accessory Groups", action: nil, keyEquivalent: "")
            header.isEnabled = false
            if let icon = PhosphorIcon.regular("squares-four") {
                header.image = icon
            }
            submenu.addItem(header)

            for group in globalGroups {
                let groupItem = buildGroupMenuItem(group, roomName: nil, homeId: homeId)
                submenu.addItem(groupItem)
            }

            submenu.addItem(NSMenuItem.separator())
        }

        // Rooms section (with room groups)
        let sidebarItems = getOrderedSidebarItems(homeId: homeId)
        if !sidebarItems.isEmpty {
            for sidebarItem in sidebarItems {
                switch sidebarItem {
                case .room(let room):
                    let roomItem = buildRoomMenuItem(room, homeId: homeId, roomGroups: groupsByRoom, groupedAccessoryIds: allGroupedAccessoryIds)
                    submenu.addItem(roomItem)

                case .roomGroup(let groupName, _, let rooms):
                    let groupItem = NSMenuItem()
                    let groupIcon = PhosphorIcon.regular("squares-four")
                    groupItem.view = SubmenuItemView(title: groupName, icon: groupIcon)

                    let groupSubmenu = NSMenu()
                    for room in rooms {
                        let roomItem = buildRoomMenuItem(room, homeId: homeId, roomGroups: groupsByRoom, groupedAccessoryIds: allGroupedAccessoryIds)
                        groupSubmenu.addItem(roomItem)
                    }
                    groupItem.submenu = groupSubmenu
                    submenu.addItem(groupItem)
                }
            }

            submenu.addItem(NSMenuItem.separator())
        }

        // Scenes section
        if let scenes = cachedScenes[homeId], !scenes.isEmpty {
            let header = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            if let icon = PhosphorIcon.regular("sparkle") {
                header.image = icon
            }
            submenu.addItem(header)

            for scene in scenes {
                let sceneItem = buildSceneMenuItem(scene)
                submenu.addItem(sceneItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func buildRoomMenuItem(_ room: [String: Any], homeId: String, roomGroups: [String: [[String: Any]]], groupedAccessoryIds: Set<String>) -> NSMenuItem {
        let name = room["name"] as? String ?? "Room"
        let roomId = room["id"] as? String ?? ""

        let item = NSMenuItem()
        // Use custom view for consistent spacing
        let icon = PhosphorIcon.iconForRoom(name)
        item.view = SubmenuItemView(title: name, icon: icon)

        let submenu = NSMenu()

        // Get itemOrder for this room to interleave service groups and accessories
        let roomLayoutsAny = cachedSettings?["roomLayouts"] as? [String: Any]
        let roomLayoutAny = roomLayoutsAny?[roomId] as? [String: Any]
        let itemOrder = (roomLayoutAny?["itemOrder"] as? [String]) ?? []

        // Collect service groups for this room
        let serviceGroups = roomGroups[roomId] ?? []
        let groupById = Dictionary(serviceGroups.compactMap { group -> (String, [String: Any])? in
            guard let gid = group["id"] as? String else { return nil }
            return (gid, group)
        }, uniquingKeysWith: { first, _ in first })

        // Collect visible ungrouped accessories
        let visibleAccessories = getVisibleOrderedAccessories(homeId: homeId, roomId: roomId)
        let accessoryById = Dictionary(visibleAccessories.compactMap { acc -> (String, [String: Any])? in
            guard let aid = acc["id"] as? String,
                  !groupedAccessoryIds.contains(aid) else { return nil }
            return (aid, acc)
        }, uniquingKeysWith: { first, _ in first })

        var placedIds = Set<String>()
        var hasItems = false

        if !itemOrder.isEmpty {
            // Walk itemOrder, placing groups (group-{id}) and accessories in order
            for entry in itemOrder {
                if entry.hasPrefix("group-") {
                    let groupId = String(entry.dropFirst("group-".count))
                    if let group = groupById[groupId] {
                        let groupItem = buildGroupMenuItem(group, roomName: name, homeId: homeId)
                        submenu.addItem(groupItem)
                        placedIds.insert(entry)
                        hasItems = true
                    }
                } else {
                    if let accessory = accessoryById[entry] {
                        let accessoryItem = buildAccessoryMenuItem(accessory, roomName: name, homeId: homeId)
                        submenu.addItem(accessoryItem)
                        placedIds.insert(entry)
                        hasItems = true
                    }
                }
            }
        }

        // Add any remaining service groups not in itemOrder
        for group in serviceGroups {
            let groupId = group["id"] as? String ?? ""
            if !placedIds.contains("group-\(groupId)") {
                let groupItem = buildGroupMenuItem(group, roomName: name, homeId: homeId)
                submenu.addItem(groupItem)
                hasItems = true
            }
        }

        // Add any remaining accessories not in itemOrder
        for (accId, accessory) in accessoryById {
            if !placedIds.contains(accId) {
                let accessoryItem = buildAccessoryMenuItem(accessory, roomName: name, homeId: homeId)
                submenu.addItem(accessoryItem)
                hasItems = true
            }
        }

        if !hasItems {
            let emptyItem = NSMenuItem(title: "No accessories", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }

        // Add area summary at the bottom if there's sensor data - use cached data
        if let summaryData = cachedRoomSummaries["\(homeId):\(roomId)"], summaryData.hasData {
            submenu.addItem(NSMenuItem.separator())
            let summaryItem = NSMenuItem()
            let summaryView = AreaSummaryView()
            summaryView.configure(with: summaryData)
            summaryItem.view = summaryView
            submenu.addItem(summaryItem)
        }

        item.submenu = submenu
        return item
    }

    private func buildGroupMenuItem(_ group: [String: Any], roomName: String?, homeId: String) -> NSMenuItem {
        let view = createGroupMenuItemView(for: group, homeId: homeId, roomName: roomName)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func buildAccessoryMenuItem(_ accessory: [String: Any], roomName: String?, homeId: String) -> NSMenuItem {
        let view = createMenuItemView(for: accessory, homeId: homeId, roomName: roomName)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func buildSceneMenuItem(_ scene: [String: Any]) -> NSMenuItem {
        let name = scene["name"] as? String ?? "Scene"
        let sceneId = scene["id"] as? String ?? ""

        let item = NSMenuItem(title: name, action: #selector(executeSceneAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["sceneId": sceneId]

        // Use scene-specific icon based on name
        if let icon = PhosphorIcon.iconForScene(name) {
            item.image = icon
        }

        return item
    }

    /// Build top-level menu items for each collection (spans all homes)
    private func buildCollectionMenuItems() -> [NSMenuItem] {
        guard let collections = cachedSettings?["collections"] as? [[String: Any]],
              !collections.isEmpty else {
            return []
        }

        var result: [NSMenuItem] = []

        for collection in collections {
            guard let collectionId = collection["id"] as? String,
                  let name = collection["name"] as? String else { continue }

            let collectionItem = NSMenuItem()
            let collectionIcon = PhosphorIcon.regular("squares-four")
            collectionItem.view = SubmenuItemView(title: name, icon: collectionIcon)

            let collectionSubmenu = NSMenu()

            // Get collection groups and items
            let groups = collection["groups"] as? [[String: Any]] ?? []
            let items = collection["items"] as? [[String: Any]] ?? []

            // Get item ordering
            let collectionItemOrder = cachedSettings?["collectionItemOrder"] as? [String: [String]]
            let itemOrder = collectionItemOrder?[collectionId] ?? []

            // Sort items by order
            var sortedItems = items
            if !itemOrder.isEmpty {
                sortedItems.sort { item1, item2 in
                    let id1 = (item1["accessoryId"] as? String) ?? (item1["serviceGroupId"] as? String) ?? ""
                    let id2 = (item2["accessoryId"] as? String) ?? (item2["serviceGroupId"] as? String) ?? ""
                    let idx1 = itemOrder.firstIndex(of: id1) ?? Int.max
                    let idx2 = itemOrder.firstIndex(of: id2) ?? Int.max
                    return idx1 < idx2
                }
            }

            // Organize items by group
            var itemsByGroup: [String: [[String: Any]]] = [:]
            var ungroupedItems: [[String: Any]] = []

            for item in sortedItems {
                if let groupId = item["groupId"] as? String, !groupId.isEmpty {
                    itemsByGroup[groupId, default: []].append(item)
                } else {
                    ungroupedItems.append(item)
                }
            }

            // Add collection groups as submenus
            for group in groups {
                guard let groupId = group["id"] as? String,
                      let groupName = group["name"] as? String else { continue }

                let groupItems = itemsByGroup[groupId] ?? []
                guard !groupItems.isEmpty else { continue }

                let groupMenuItem = NSMenuItem()
                let groupIcon = PhosphorIcon.regular("folder")
                groupMenuItem.view = SubmenuItemView(title: groupName, icon: groupIcon)

                let groupSubmenu = NSMenu()
                for collItem in groupItems {
                    if let menuItem = buildCollectionItemMenuItem(collItem) {
                        groupSubmenu.addItem(menuItem)
                    }
                }

                groupMenuItem.submenu = groupSubmenu
                collectionSubmenu.addItem(groupMenuItem)
            }

            // Add separator between groups and ungrouped items if both exist
            if !groups.isEmpty && !ungroupedItems.isEmpty && collectionSubmenu.items.count > 0 {
                collectionSubmenu.addItem(NSMenuItem.separator())
            }

            // Add ungrouped items directly to collection submenu
            for collItem in ungroupedItems {
                if let menuItem = buildCollectionItemMenuItem(collItem) {
                    collectionSubmenu.addItem(menuItem)
                }
            }

            if collectionSubmenu.items.isEmpty {
                let emptyItem = NSMenuItem(title: "No items", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                collectionSubmenu.addItem(emptyItem)
            }

            collectionItem.submenu = collectionSubmenu
            result.append(collectionItem)
        }

        return result
    }

    /// Build a menu item for a collection item (accessory or service group)
    private func buildCollectionItemMenuItem(_ collItem: [String: Any]) -> NSMenuItem? {
        guard let homeId = collItem["homeId"] as? String else { return nil }

        if let accessoryId = collItem["accessoryId"] as? String {
            if let accessory = findAccessoryById(accessoryId, homeId: homeId) {
                return buildAccessoryMenuItem(accessory, roomName: nil, homeId: homeId)
            }
        } else if let groupId = collItem["serviceGroupId"] as? String {
            if let group = findServiceGroupById(groupId, homeId: homeId) {
                return buildGroupMenuItem(group, roomName: nil, homeId: homeId)
            }
        }
        return nil
    }

    /// Find an accessory by ID across all rooms
    private func findAccessoryById(_ accessoryId: String, homeId: String) -> [String: Any]? {
        for (key, accessories) in cachedAccessories {
            if key.hasPrefix(homeId) {
                for accessory in accessories {
                    if (accessory["id"] as? String) == accessoryId {
                        return accessory
                    }
                }
            }
        }
        return nil
    }

    /// Check if a cached accessory is reachable
    private func isCachedAccessoryReachable(_ accessoryId: String, homeId: String) -> Bool {
        for (key, accessories) in cachedAccessories {
            if key.hasPrefix(homeId) {
                for accessory in accessories {
                    if (accessory["id"] as? String) == accessoryId {
                        return accessory["isReachable"] as? Bool ?? true
                    }
                }
            }
        }
        return true // Default to reachable if not found
    }

    /// Find a service group by ID
    private func findServiceGroupById(_ groupId: String, homeId: String) -> [String: Any]? {
        guard let groups = cachedGroups[homeId] else { return nil }
        return groups.first { ($0["id"] as? String) == groupId }
    }

    // MARK: - Actions

    @objc private func executeSceneAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let sceneId = info["sceneId"] as? String else { return }

        executeScene(sceneId: sceneId)
    }

    @objc private func openWindow() {
        showInDock()
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let provider = statusProvider {
            let selector = NSSelectorFromString("showWindow")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
            }
        }

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
        // Suspend the UIKit side first, then terminate
        if let provider = statusProvider {
            let selector = NSSelectorFromString("quitApp")
            if provider.responds(to: selector) {
                _ = provider.perform(selector)
            }
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Dock Visibility

    @objc public func showInDock() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }

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
