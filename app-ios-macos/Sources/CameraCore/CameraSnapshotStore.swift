import Foundation

struct RelayCameraSnapshot: Codable, Sendable {
    let jpeg: Data
    let capturedAt: Date
    let width: Int
    let height: Int
    let source: String
    let requestedWidth: Int

    var isValid: Bool {
        !jpeg.isEmpty && jpeg.count <= 5_000_000 && capturedAt.timeIntervalSince1970.isFinite &&
        width > 0 && width <= 8192 && height > 0 && height <= 8192 &&
        (160...1920).contains(requestedWidth) && ["stream", "snapshot"].contains(source)
    }
}

struct CameraCacheSession: Sendable, Equatable {
    let account: UUID?
    let staging: Bool
    let generation: Int

    /// Namespace only, NOT authentication. The cloud still authorizes every
    /// request before routing it. Never write a credential to an image file.
    static func accountID(token: String?) -> UUID? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String else { return nil }
        return UUID(uuidString: subject)
    }
}

/// Latest still only, outside iCloud/backup, serialized off the main actor.
/// A session fence prevents an old capture from writing after sign-out even
/// when actor calls arrive out of order. Failures are disposable cache misses.
actor CameraSnapshotStore {
    private let root: URL
    private var session: CameraCacheSession?

    init(root: URL) { self.root = root }

    private func adopt(_ next: CameraCacheSession) -> Bool {
        if let current = session {
            if next.generation < current.generation { return false }
            if next.generation == current.generation { return next == current }
            if next.account != current.account || next.staging != current.staging {
                try? FileManager.default.removeItem(at: root)
            }
        }
        session = next
        if next.account == nil { try? FileManager.default.removeItem(at: root) }
        return true
    }

    func updateSession(_ next: CameraCacheSession) { _ = adopt(next) }

    private func file(home: UUID, accessory: UUID, session: CameraCacheSession) -> URL? {
        guard let account = session.account else { return nil }
        return root.appendingPathComponent(session.staging ? "staging" : "production")
            .appendingPathComponent(account.uuidString).appendingPathComponent(home.uuidString)
            .appendingPathComponent(accessory.uuidString + ".json")
    }

    func load(home: UUID, accessory: UUID, session: CameraCacheSession) -> RelayCameraSnapshot? {
        guard adopt(session), let file = file(home: home, accessory: accessory, session: session),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 7_000_000, let data = try? Data(contentsOf: file),
              let image = try? JSONDecoder().decode(RelayCameraSnapshot.self, from: data), image.isValid else { return nil }
        return image
    }

    func save(_ image: RelayCameraSnapshot, home: UUID, accessory: UUID, session: CameraCacheSession) {
        guard adopt(session), image.isValid,
              let file = file(home: home, accessory: accessory, session: session) else { return }
        if let old = load(home: home, accessory: accessory, session: session),
           old.capturedAt > image.capturedAt || (old.capturedAt == image.capturedAt && old.width > image.width) { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var directory = root
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try directory.setResourceValues(resourceValues)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(image).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Memory capture still works; never log private image data. */ }
    }
}
