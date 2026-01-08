import UIKit
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published var homeKitManager: HomeKitManager!
    @Published var httpServer: SimpleHTTPServer!
    @Published var connectionManager: ConnectionManager!
    private var menuBarPlugin: AnyObject?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Initialize HomeKit manager
        homeKitManager = HomeKitManager()

        // Initialize and start HTTP server
        httpServer = SimpleHTTPServer(homeKitManager: homeKitManager, port: 5656)
        httpServer.start()

        // Initialize connection manager
        connectionManager = ConnectionManager(homeKitManager: homeKitManager)

        // Load menu bar plugin on Mac
        #if targetEnvironment(macCatalyst)
        loadMenuBarPlugin()
        #endif

        // Try to restore previous session
        Task {
            await connectionManager.restoreSession()
        }

        return true
    }

    // MARK: - Scene Configuration

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // MARK: - Menu Bar Plugin

    #if targetEnvironment(macCatalyst)
    private func loadMenuBarPlugin() {
        // Load the AppKit bundle for menu bar functionality
        guard let pluginURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("MenuBarPlugin.bundle") else {
            print("[Homecast] MenuBarPlugin.bundle not found in PlugIns")
            return
        }

        guard let bundle = Bundle(url: pluginURL), bundle.load() else {
            print("[Homecast] Failed to load MenuBarPlugin bundle")
            return
        }

        guard let pluginClass = bundle.principalClass as? NSObject.Type else {
            print("[Homecast] Failed to get principal class from MenuBarPlugin")
            return
        }

        // Create the plugin instance
        menuBarPlugin = pluginClass.init()

        // Set up the plugin with our status provider and config
        if let plugin = menuBarPlugin {
            let setupSelector = NSSelectorFromString("setupWithStatusProvider:showWindowOnLaunch:")
            if plugin.responds(to: setupSelector) {
                let method = plugin.method(for: setupSelector)
                typealias SetupMethod = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
                let impl = unsafeBitCast(method, to: SetupMethod.self)
                impl(plugin, setupSelector, self, AppConfig.showWindowOnLaunch)
            }
        }

        print("[Homecast] Menu bar plugin loaded successfully")
    }

    // MARK: - Menu Bar Plugin Data Providers

    @objc func isHomeKitReady() -> NSNumber {
        return NSNumber(value: homeKitManager?.isReady ?? false)
    }

    @objc func isServerRunning() -> NSNumber {
        return NSNumber(value: httpServer?.isRunning ?? false)
    }

    @objc func serverPort() -> NSNumber {
        return NSNumber(value: httpServer?.port ?? 0)
    }

    @objc func homeNames() -> [String] {
        return homeKitManager?.homes.map { $0.name } ?? []
    }

    @objc func accessoryCounts() -> [NSNumber] {
        return homeKitManager?.homes.map { NSNumber(value: $0.accessories.count) } ?? []
    }

    @objc func isConnectedToRelay() -> NSNumber {
        return NSNumber(value: connectionManager?.isConnected ?? false)
    }

    @objc func isAuthenticated() -> NSNumber {
        return NSNumber(value: connectionManager?.isAuthenticated ?? false)
    }

    @objc func connectedEmail() -> String {
        return connectionManager?.savedEmail ?? ""
    }

    // Legacy status method (kept for compatibility)
    @objc func currentStatus() -> String {
        if homeKitManager.isReady && httpServer.isRunning {
            return "running"
        } else if homeKitManager.isReady {
            return "ready"
        } else {
            return "loading"
        }
    }

    @objc func showWindow() {
        // Bring the app to front and show window
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
    }

    @objc func quitApp() {
        // Proper app termination
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exit(0)
        }
    }

    @objc func reconnectRelay() {
        Task {
            await connectionManager?.reconnect()
        }
    }

    func showInDock() {
        if let plugin = menuBarPlugin {
            let selector = NSSelectorFromString("showInDock")
            if plugin.responds(to: selector) {
                _ = plugin.perform(selector)
            }
        }
    }

    func hideFromDock() {
        if let plugin = menuBarPlugin {
            let selector = NSSelectorFromString("hideFromDock")
            if plugin.responds(to: selector) {
                _ = plugin.perform(selector)
            }
        }
    }
    #endif
}

// MARK: - Scene Delegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var isFirstLaunch = true

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if targetEnvironment(macCatalyst)
        // Configure window for Mac with toolbar
        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbarStyle = .unified
        }

        // Set window size - allow flexible sizing
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 780, height: 500)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1400, height: 1000)

        // Check if we should show window on first launch
        if SceneDelegate.isFirstLaunch {
            SceneDelegate.isFirstLaunch = false

            if !AppConfig.showWindowOnLaunch {
                // Close the window - app will run in menu bar only
                DispatchQueue.main.async {
                    UIApplication.shared.requestSceneSessionDestruction(
                        session,
                        options: nil,
                        errorHandler: nil
                    )
                }
                return
            }
        }

        // Show in dock when window opens
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.showInDock()
        }
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Window closed - app continues running in menu bar
        print("[Homecast] Window closed - continuing in background")

        #if targetEnvironment(macCatalyst)
        // Hide from dock when window closes
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.hideFromDock()
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        print("[Homecast] Window became active")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        print("[Homecast] Window will resign active")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showMainWindow = Notification.Name("showMainWindow")
}
