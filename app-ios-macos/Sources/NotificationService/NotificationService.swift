import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

/// Attaches the icon a Notify automation chose to an incoming push.
///
/// APNs will not fetch an image itself. The server sends `mutable-content: 1`
/// and an `icon_url`, which wakes this extension for a few seconds before the
/// banner is shown; whatever it puts on `bestAttempt` is what the user sees.
///
/// Two rules govern everything here. The system gives us roughly 30 seconds and
/// then shows the notification whether we are finished or not, so the download
/// is bounded well inside that. And a notification without its icon is a far
/// better outcome than no notification at all, so every failure path still calls
/// the content handler with usable content.
class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var task: URLSessionDataTask?

    /// Comfortably inside the system's budget, and short enough that a slow host
    /// costs the notification latency rather than its delivery.
    private static let timeout: TimeInterval = 10
    private static let maxBytes = 5 * 1024 * 1024

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttempt = content

        guard
            let content,
            let urlString = request.content.userInfo["icon_url"] as? String,
            let url = URL(string: urlString),
            url.scheme?.lowercased() == "https"
        else {
            contentHandler(request.content)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = Self.timeout

        task = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, _ in
            guard let self else { return }
            defer { self.deliver() }

            guard
                let data,
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                data.count <= Self.maxBytes,
                let mime = http.mimeType?.lowercased(),
                mime.hasPrefix("image/"),
                let staged = Self.stage(data, mime: mime)
            else { return }

            // The system moves this file into its own store, so it is written
            // fresh per notification and never reused.
            if let attachment = try? UNNotificationAttachment(identifier: "icon", url: staged, options: nil) {
                content.attachments = [attachment]
            } else {
                try? FileManager.default.removeItem(at: staged)
            }
        }
        task?.resume()
    }

    /// Called when the system's time is up. Whatever we have is what ships.
    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        deliver()
    }

    /// Hand back content exactly once, however we got here.
    private func deliver() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    /// UNNotificationAttachment infers the type from the file extension, so give
    /// it one it recognises rather than whatever the URL happened to end in.
    private static func stage(_ data: Data, mime: String) -> URL? {
        let ext: String
        if mime.contains("png") { ext = "png" }
        else if mime.contains("gif") { ext = "gif" }
        else { ext = "jpg" }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("homecast-push-icons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
