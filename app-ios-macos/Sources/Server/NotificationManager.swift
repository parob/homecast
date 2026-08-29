import Foundation
import UIKit
import UserNotifications

/// Manages local and remote push notifications for Homecast.
///
/// Local notifications: shown immediately when the relay's automation engine fires a Notify action.
/// Remote notifications: APNs token registration for receiving push from the cloud server.
///
/// Built for every platform the app ships on. Nothing here is Mac-specific —
/// `UNUserNotificationCenter` and `UIApplication.registerForRemoteNotifications`
/// are the same on iPhone and iPad, and the web app reaches all of it through
/// the `notification.*` methods on the `window.homekit` bridge, which iOS has
/// too. This file is compiled into the app target only (SDKROOT iphoneos), so
/// the unconditional `import UIKit` above is safe — unlike HomeKitBridge.swift,
/// it is not also built into the macOS-SDK MenuBarPlugin.
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var isAuthorized = false
    @Published private(set) var apnsToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    /// Request notification permission. Call on first automation Notify or from settings.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            isAuthorized = granted
            if granted {
                registerForRemoteNotifications()
            }
            return granted
        } catch {
            Log.error("permission request failed: \(error.localizedDescription)", category: "push")
            return false
        }
    }

    /// Check current authorization status.
    ///
    /// Re-registers when permission is already granted. AppDelegate calls this at
    /// launch, so a returning user's APNs token is warm before the web app asks
    /// for it — otherwise the first `getAPNsToken` after every cold start answers
    /// nil and the caller pays several rounds of its backoff poll waiting for a
    /// token the OS would have handed over immediately.
    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
        // Authorised-but-no-token and denied are the same silence from the web
        // app's side — it only ever sees `getAPNsToken` answer nil. Recording
        // the status here is what separates them afterwards, and only the
        // unauthorised case is worth shipping (WARN+ is what LogShipper posts).
        if isAuthorized {
            Log.info("notifications authorized", category: "push")
            registerForRemoteNotifications()
        } else {
            Log.warning(
                "notifications not authorized (status=\(settings.authorizationStatus.rawValue)) — no APNs token will be minted",
                category: "push"
            )
        }
    }

    // MARK: - Local Notifications (Relay → macOS banner)

    /// Show a local notification immediately. Called when the automation engine fires a Notify action.
    func showLocalNotification(
        title: String?,
        message: String,
        data: [String: Any]? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title ?? "Homecast"
        content.body = message
        content.sound = .default

        if let data = data {
            content.userInfo = data
        }

        // An icon is optional, and getting one must never be a reason a
        // notification doesn't appear. A built-in slug renders locally and costs
        // nothing; a URL costs a bounded download, after which we post either
        // way. The caller isn't kept waiting for it — HomeKitBridge has already
        // returned by the time this resolves.
        if let icon = data?["icon"] as? String, !icon.isEmpty {
            Task {
                let iconColor = data?["iconColor"] as? String
                if let staged = await NotificationIcon.stage(icon, color: iconColor),
                   let attachment = try? UNNotificationAttachment(identifier: "icon", url: staged, options: nil) {
                    // The system MOVES the staged file into its own attachment
                    // store, so the path is single-use by design.
                    content.attachments = [attachment]
                }
                Self.post(content)
            }
        } else {
            Self.post(content)
        }
    }

    private static func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(
            identifier: "homecast-notify-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[NotificationManager] Failed to show notification: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Remote Notifications (APNs)

    /// Register for APNs remote notifications.
    private func registerForRemoteNotifications() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called from AppDelegate when APNs token is received.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        apnsToken = tokenString
        Log.info("APNs token minted \(tokenString.prefix(16))…", category: "push")
        // The web app will read this token via the JS bridge and register it with the server
    }

    /// Called from AppDelegate when APNs registration fails.
    ///
    /// Shipped rather than NSLog'd, because this is the only place the reason
    /// exists. Without it the failure is invisible off-device: the web app sees
    /// `getAPNsToken` answer nil, gives up, and the server carries on pushing to
    /// whatever token was registered last — accepted by APNs, delivered nowhere.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        Log.error("APNs registration failed: \(error.localizedDescription)", category: "push")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification taps.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Notification icons

/// Turns a Notify action's icon into a file on disk, ready to attach.
///
/// Deliberately outside `NotificationManager`, which is `@MainActor`: rendering
/// and downloading have no business on the main thread, and static state reached
/// from a nonisolated context is an error under Swift 6.
private enum NotificationIcon {

    /// Slug → SF Symbol, mirroring `notificationIcons.ts` in the web app.
    ///
    /// The web app rasterises the same set to PNGs, because APNs and Android can
    /// only be handed a URL. Here there is no network involved, so the symbol is
    /// drawn on the spot — and both paths end up looking alike because both put
    /// a white glyph on the same blue tile.
    ///
    /// A slug missing from this map is not an error. A relay running an older
    /// build than the automation that made it should still show a notification
    /// with an icon, so unknown slugs fall back to a bell rather than to nothing.
    static let symbolForSlug: [String: String] = [
        // Devices
        "light": "lightbulb.fill",
        "switch": "power",
        "outlet": "powerplug.fill",
        "thermostat": "thermometer.medium",
        "fan": "fan.fill",
        "air": "wind",
        "humidity": "humidity.fill",
        "blinds": "blinds.horizontal.closed",
        "garage": "door.garage.closed",
        "camera": "video.fill",
        "doorbell": "bell.badge.fill",
        "speaker": "hifispeaker.fill",
        "irrigation": "drop.circle.fill",
        // Status
        "notification": "bell.fill",
        "alert": "exclamationmark.triangle.fill",
        "success": "checkmark.circle.fill",
        "error": "xmark.circle.fill",
        "info": "info.circle.fill",
        "motion": "figure.walk.motion",
        "leak": "drop.fill",
        "smoke": "flame.fill",
        "siren": "light.beacon.max.fill",
        "offline": "wifi.slash",
        "battery": "battery.25",
        "energy": "bolt.fill",
        // Home and time
        "home": "house.fill",
        "door": "door.left.hand.closed",
        "door-open": "door.left.hand.open",
        "lock": "lock.fill",
        "unlock": "lock.open.fill",
        "security": "shield.fill",
        "key": "key.fill",
        "person": "person.fill",
        "schedule": "clock.fill",
        "day": "sun.max.fill",
        "night": "moon.fill",
    ]

    /// Tile gradients, mirroring NOTIFICATION_ICON_COLORS in the web app so the
    /// banner drawn here and the PNG fetched on a phone are the same colour.
    /// An unknown name falls back to the default rather than to no icon.
    static let gradientForColor: [String: (UIColor, UIColor)] = [
        "blue": (UIColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1),
                 UIColor(red: 0.146, green: 0.388, blue: 0.922, alpha: 1)),
        "red": (UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1),
                UIColor(red: 0.863, green: 0.149, blue: 0.149, alpha: 1)),
        "amber": (UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1),
                  UIColor(red: 0.851, green: 0.467, blue: 0.024, alpha: 1)),
        "green": (UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1),
                  UIColor(red: 0.086, green: 0.639, blue: 0.290, alpha: 1)),
        "teal": (UIColor(red: 0.078, green: 0.722, blue: 0.651, alpha: 1),
                 UIColor(red: 0.051, green: 0.596, blue: 0.533, alpha: 1)),
        "purple": (UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1),
                   UIColor(red: 0.576, green: 0.200, blue: 0.918, alpha: 1)),
        "pink": (UIColor(red: 0.925, green: 0.282, blue: 0.600, alpha: 1),
                 UIColor(red: 0.859, green: 0.153, blue: 0.467, alpha: 1)),
        "slate": (UIColor(red: 0.392, green: 0.455, blue: 0.545, alpha: 1),
                  UIColor(red: 0.278, green: 0.333, blue: 0.412, alpha: 1)),
    ]

    static let defaultColor = "blue"

    static let fallbackSymbol = "bell.fill"
    static let tileSize: CGFloat = 256
    static let downloadTimeout: TimeInterval = 5
    static let maxBytes = 2 * 1024 * 1024

    /// Write the icon to a temp file, or nil if it can't be had. Never throws:
    /// an icon is decoration, and no failure here should cost a notification.
    static func stage(_ icon: String, color: String?) async -> URL? {
        if icon.lowercased().hasPrefix("https://") {
            // A custom image is the author's own; there is nothing to recolour.
            return await download(icon)
        }
        return renderTile(symbolForSlug[icon] ?? fallbackSymbol, color: color)
    }

    /// Draw an SF Symbol as a white glyph on the brand tile, matching the PNGs.
    private static func renderTile(_ symbolName: String, color: String?) -> URL? {
        let size = tileSize
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
        // A symbol name can be unavailable on an older OS than the one the map
        // was written against, which reads as nil rather than as a crash.
        let symbol = UIImage(systemName: symbolName, withConfiguration: config)
            ?? UIImage(systemName: fallbackSymbol, withConfiguration: config)
        guard let symbol else { return nil }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.22).addClip()

            let stops = gradientForColor[color ?? defaultColor]
                ?? gradientForColor[defaultColor]!
            let colors = [stops.0.cgColor, stops.1.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
            ) {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size, y: size), options: []
                )
            }

            let glyph = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
            let box = glyph.size
            glyph.draw(in: CGRect(
                x: (size - box.width) / 2,
                y: (size - box.height) / 2,
                width: box.width,
                height: box.height
            ))
        }

        guard let png = image.pngData() else { return nil }
        return writeTemp(png, ext: "png")
    }

    /// Fetch a caller-supplied icon URL. Bounded on time, size and type: this
    /// runs on the relay Mac and an automation can point it anywhere.
    private static func download(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = downloadTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

            let mime = (http.mimeType ?? "").lowercased()
            guard mime.hasPrefix("image/") else {
                NSLog("[NotificationIcon] Not an image (%@)", mime)
                return nil
            }
            guard data.count <= maxBytes else {
                NSLog("[NotificationIcon] Too large (%d bytes)", data.count)
                return nil
            }

            // UNNotificationAttachment infers the type from the file extension,
            // so give it one it recognises rather than whatever the URL ended in.
            let ext: String
            if mime.contains("png") { ext = "png" }
            else if mime.contains("gif") { ext = "gif" }
            else { ext = "jpg" }

            return writeTemp(data, ext: ext)
        } catch {
            NSLog("[NotificationIcon] Download failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func writeTemp(_ data: Data, ext: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("homecast-notification-icons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            return url
        } catch {
            NSLog("[NotificationIcon] Could not stage icon: %@", error.localizedDescription)
            return nil
        }
    }
}
