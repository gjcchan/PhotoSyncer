import Foundation

nonisolated struct RemoteFile: Sendable {
    var name: String
    var size: UInt64
}

/// Everything the sync engine needs from a destination, whether it's a folder or an SFTP server.
nonisolated protocol DestinationBackend: AnyObject, Sendable {
    /// Local folder URL (folders only). Used for the Photos-app export fallback.
    var localRoot: URL? { get }
    /// Connects/authenticates and validates the destination. Throws `.destinationUnavailable` if it is offline.
    func connect() async throws
    func isAvailable() async -> Bool
    /// Regular, non-hidden files in the destination folder.
    func list() async throws -> [RemoteFile]
    func freeSpace() async -> Int64?
    /// Writes to a temporary name, verifies size + checksum by reading back, then renames to `name`.
    func upload(local: URL, as name: String, size: UInt64, hash: String, date: Date?) async throws
    func download(name: String, to local: URL) async throws -> Date?
    func hash(of name: String, noCache: Bool) async throws -> String
    /// Removes one file we created earlier (used to replace previews with the real original).
    func delete(name: String) async throws
    func cleanup() async
    func close() async
}

// MARK: - Folder (local disk, USB drive, mounted NAS share)

nonisolated final class FolderBackend: DestinationBackend, @unchecked Sendable {
    private let url: URL
    private let securityScoped: Bool       // false for folders we created ourselves (e.g. inside our SMB mount)
    private var scoped = false

    init(url: URL, securityScoped: Bool = true) {
        self.url = url
        self.securityScoped = securityScoped
    }
    var localRoot: URL? { url }

    func connect() async throws {
        if securityScoped {
            scoped = url.startAccessingSecurityScopedResource()
            guard scoped else { throw SyncError.message("Cannot access this folder. Remove it and add it again.") }
        }
        try validate()
    }

    private func validate() throws {
        do { _ = try url.checkResourceIsReachable() }
        catch { throw SyncError.destinationUnavailable("Folder is not reachable (drive unplugged or share offline?)") }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SyncError.message("Destination is not a folder.")
        }
        if url.path.contains("/.Trash") { throw SyncError.message("Destination folder is in the Trash.") }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw SyncError.message("Destination folder is not writable.")
        }
    }

    func isAvailable() async -> Bool { (try? validate()) != nil }

    func list() async throws -> [RemoteFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
        catch { throw SyncError.destinationUnavailable("Cannot read the folder: \(error.localizedDescription)") }
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { return nil }
            return RemoteFile(name: u.lastPathComponent, size: UInt64(v?.fileSize ?? 0))
        }
    }

    func freeSpace() async -> Int64? {
        if let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free > 0 {
            return free
        }
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?
            .int64Value, free > 0 {
            return free
        }
        return nil   // NAS/server didn't report capacity
    }

    func upload(local: URL, as name: String, size: UInt64, hash: String, date: Date?) async throws {
        let partial = url.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }       // no-op after the rename
        try await VerifiedCopy.copy(from: local, to: partial, expectedHash: hash, expectedSize: size)
        if let date {
            // Some NAS filesystems refuse this; the file itself is fine.
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: partial.path)
        }
        try FileManager.default.moveItem(at: partial, to: url.appendingPathComponent(name))
    }

    func download(name: String, to local: URL) async throws -> Date? {
        let src = url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.copyItem(at: src, to: local)
        return (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func hash(of name: String, noCache: Bool) async throws -> String {
        try await FileHash.sha256(of: url.appendingPathComponent(name), noCache: noCache)
    }

    func delete(name: String) async throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(name))
    }

    func cleanup() async {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for n in items where n.hasPrefix(".photosyncer-export-") || (n.hasPrefix(".") && n.hasSuffix(".partial")) {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(n))
        }
    }

    func close() async {
        if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
    }
}

// MARK: - Shared helpers

/// Gives up on an operation that stops responding instead of hanging the whole sync.
nonisolated func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                          timeoutMessage: String = "The SFTP server stopped responding",
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let dog = Watchdog()
        let task = Task {
            do { let v = try await op(); if dog.finish() { cont.resume(returning: v) } }
            catch { if dog.finish() { cont.resume(throwing: error) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if dog.finish() {
                task.cancel()
                cont.resume(throwing: SyncError.destinationUnavailable(timeoutMessage))
            }
        }
    }
}
