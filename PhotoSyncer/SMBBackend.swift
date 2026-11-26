import Foundation
import NetFS

// MARK: - SMB

/// Serializes mount/unmount operations per destination key so startup orphan cleanup
/// and an active sync can never race on the same mount directory.
private actor MountGate {
    static let shared = MountGate()
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withKey<T: Sendable>(_ key: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        while busy.contains(key) {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        busy.insert(key)
        defer {
            busy.remove(key)
            let list = waiters.removeValue(forKey: key) ?? []
            for w in list { w.resume() }
        }
        return try await body()
    }
}

/// An SMB share, connected with macOS's own SMB client (the one Finder uses) and then used like a folder.
///
/// The share is mounted by NetFS at a private mount point inside the app's sandbox container, so no extra
/// entitlement is needed beyond outgoing network access. Everything after the mount (staging, the
/// `.partial` → final rename, checksum read-back with `F_NOCACHE`, listing, deleting) reuses `FolderBackend`,
/// so SMB gets exactly the same verification as a local or USB folder.
nonisolated final class SMBBackend: DestinationBackend, @unchecked Sendable {
    private let key: String
    private let host: String
    private let port: Int
    private let share: String
    private let user: String?            // nil = guest
    private let password: String?
    private let subfolder: String
    private let allowCreateBase: Bool
    private let mountDir: URL
    private var folder: FolderBackend?

    /// NetFS gives up on an unreachable server by itself after about a minute; this is only a safety net.
    private static let mountTimeout: TimeInterval = 90

    init(dest: Destination, password: String?, allowCreateBase: Bool = true) {
        let guest = dest.guest == true
        key = dest.key
        host = dest.host.trimmingCharacters(in: .whitespaces)
        port = dest.port
        share = (dest.share ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        user = guest ? nil : dest.username
        self.password = guest ? nil : password
        subfolder = dest.remotePath
        self.allowCreateBase = allowCreateBase
        mountDir = Self.mountsRoot.appendingPathComponent(dest.key, isDirectory: true)
    }

    /// Lives inside our container, which Photos.app can't write to, so the Photos-app export fallback skips it.
    var localRoot: URL? { nil }

    static var mountsRoot: URL {
        let base = SandboxCompat.appSupportDirectory
            .appendingPathComponent("Mounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }

    static func cleanupMount(key: String) async {
        await MountGate.shared.withKey(key) {
            let dir = mountsRoot.appendingPathComponent(key, isDirectory: true)
            if isSMBMount(dir) {
                _ = try? await withTimeout(30, timeoutMessage: "Unmounting timed out") {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        FileManager.default.unmountVolume(at: dir, options: [.withoutUI]) { _ in cont.resume() }
                    }
                }
            }
            if !isSMBMount(dir) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// Unmounts and removes any leftover mount directories from a previous crash that aren't in active use.
    static func cleanupOrphanedMounts(keeping activeKeys: Set<String>) async {
        let root = mountsRoot
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in entries where !activeKeys.contains(dir.lastPathComponent) {
            await cleanupMount(key: dir.lastPathComponent)
        }
    }

    // MARK: Connection
    func connect() async throws {
        try await MountGate.shared.withKey(key) {
            let components = try Self.subfolderComponents(self.subfolder)
            let reused = Self.isSMBMount(self.mountDir)             // left over from a crash or a failed unmount
            let root = reused ? self.mountDir : try await self.mount()
            do {
                try await self.open(root: root, components: components)
            } catch {
                // A leftover mount whose server has gone away: drop it and mount afresh, once.
                if reused, case SyncError.destinationUnavailable = error {
                    await self.unmountQuietly(root)
                    let fresh = try await self.mount()
                    do { try await self.open(root: fresh, components: components) }
                    catch { await self.unmountQuietly(fresh); throw error }
                    return
                }
                await self.unmountQuietly(root)
                throw error
            }
        }
    }

    private func open(root: URL, components: [String]) async throws {
        var base = root
        for c in components { base.appendPathComponent(c, isDirectory: true) }
        if (try? base.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            guard allowCreateBase else {
                throw SyncError.destinationUnavailable(
                    "Folder “\(components.joined(separator: "/"))” is missing on the SMB share (backing volume unmounted on \(host)?)")
            }
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                throw Self.mapFileError(error, doing: "create the folder “\(components.joined(separator: "/"))” on the share")
            }
        }
        let f = FolderBackend(url: base, securityScoped: false)
        do { try await f.connect() }
        catch SyncError.destinationUnavailable {
            throw SyncError.destinationUnavailable("The SMB share is not reachable (server offline or network down?)")
        }
        folder = f
    }

    private func mount() async throws -> URL {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host
        if port != Destination.defaultSMBPort { c.port = port }
        c.path = "/" + share
        guard !host.isEmpty, !share.isEmpty, let url = c.url else {
            throw SyncError.message("The server name or share name isn't valid.")
        }
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        let dir = mountDir, user = user, password = password, loopback = Self.isLoopback(host)
        let outcome: (code: Int32, path: String?) = try await withTimeout(
            Self.mountTimeout, timeoutMessage: "The SMB server stopped responding"
        ) {
            await Task.detached(priority: .utility) {
                let open = NSMutableDictionary()
                open[kNAUIOptionKey as String] = kNAUIOptionNoUI as String       // never pop up a login dialog
                // Always authenticate for real. Otherwise macOS may silently reuse a login it still has for this
                // server, which would make a wrong password in "Test Connection" look like it worked.
                open[kNetFSForceNewSessionKey as String] = true
                if user == nil { open[kNetFSUseGuestKey as String] = true }
                if loopback { open[kNetFSAllowLoopbackKey as String] = true }
                let mount = NSMutableDictionary()
                mount[kNetFSMountAtMountDirKey as String] = true                 // mount exactly at `dir`
                mount[kNetFSSoftMountKey as String] = true                       // fail instead of hanging when the server drops
                mount[kNetFSMountFlagsKey as String] = Int(MNT_DONTBROWSE)       // keep it out of Finder
                var points: Unmanaged<CFArray>?
                let rc = NetFSMountURLSync(url as CFURL, dir as CFURL,
                                           user.map { $0 as CFString }, password.map { $0 as CFString },
                                           open as CFMutableDictionary, mount as CFMutableDictionary, &points)
                let first = (points?.takeRetainedValue() as? [String])?.first
                return (rc, first)
            }.value
        }

        switch outcome.code {
        case 0:
            return URL(fileURLWithPath: outcome.path ?? dir.path)
        case EEXIST where Self.isSMBMount(dir):
            return dir
        default:
            if !Self.isSMBMount(dir) { try? FileManager.default.removeItem(at: dir) }
            throw Self.mapMountError(outcome.code, host: host, share: share)
        }
    }

    // MARK: Errors
    /// NetFS returns a positive errno or a negative OSStatus (see NetFS.h).
    private static func mapMountError(_ code: Int32, host: String, share: String) -> Error {
        switch code {
        case EAUTH, EACCES, EPERM, -5999, -5045, -5046, -128:
            return SyncError.message("SMB login failed – check the username and password, and that this account may use “\(share)”.")
        case ENOENT, -6003, -5998:
            return SyncError.message("The share “\(share)” was not found on \(host).")
        case -5997:
            return SyncError.message("\(host) uses a login method macOS's SMB client doesn't support.")
        case -5996:
            return SyncError.message("\(host) uses an SMB version macOS's SMB client doesn't support.")
        case -6004:
            return SyncError.message("\(host) doesn't allow guest access to “\(share)”. Turn off “Connect as guest” and sign in.")
        case ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN, ENOTCONN, ECONNRESET, ENXIO, EIO:
            return SyncError.destinationUnavailable("Cannot reach \(host) (\(String(cString: strerror(code)))).")
        default:
            let detail = code > 0 ? String(cString: strerror(code)) : "OSStatus \(code)"
            return SyncError.message("Could not connect to the SMB share: \(detail).")
        }
    }

    /// Errors from touching the mounted volume. Connection-type failures mean the share went away.
    private static func mapFileError(_ error: Error, doing what: String) -> Error {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
            ?? (ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil)
        if let p = posix, [ETIMEDOUT, ENOTCONN, ECONNRESET, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ENXIO, EIO].contains(p) {
            return SyncError.destinationUnavailable("The SMB share stopped responding.")
        }
        return SyncError.message("Cannot \(what): \(error.localizedDescription)")
    }

    // MARK: Helpers
    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// The folder inside the share, split into safe path components (no escaping out of the share).
    static func subfolderComponents(_ path: String) throws -> [String] {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.contains(where: { $0 == "." || $0 == ".." }) {
            throw SyncError.message("The folder can't contain “.” or “..”.")
        }
        return parts
    }

    /// Is `url` currently a mounted SMB volume?
    static func isSMBMount(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard type == "smbfs" else { return false }
        let on = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: on).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }

    private func unmountQuietly(_ url: URL) async {
        guard Self.isSMBMount(url) else { return }
        _ = try? await withTimeout(30, timeoutMessage: "Unmounting timed out") {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                FileManager.default.unmountVolume(at: url, options: [.withoutUI]) { _ in cont.resume() }
            }
        }
    }

    private func backend() throws -> FolderBackend {
        guard let folder else { throw SyncError.destinationUnavailable("Not connected to the SMB share") }
        return folder
    }

    // MARK: DestinationBackend
    func isAvailable() async -> Bool {
        guard let folder, Self.isSMBMount(mountDir) else { return false }
        return await folder.isAvailable()
    }

    func list() async throws -> [RemoteFile] { try await backend().list() }

    func freeSpace() async -> Int64? { await folder?.freeSpace() }

    func upload(local: URL, as name: String, size: UInt64, hash: String, date: Date?) async throws {
        try await backend().upload(local: local, as: name, size: size, hash: hash, date: date)
    }

    func download(name: String, to local: URL) async throws -> Date? {
        try await backend().download(name: name, to: local)
    }

    func hash(of name: String, noCache: Bool) async throws -> String {
        try await backend().hash(of: name, noCache: noCache)
    }

    func delete(name: String) async throws { try await backend().delete(name: name) }

    func readCanary() async throws -> String? { try await backend().readCanary() }

    func writeCanary(_ id: String) async throws { try await backend().writeCanary(id) }

    func cleanup() async { await folder?.cleanup() }

    func close() async {
        await MountGate.shared.withKey(key) {
            await self.folder?.close()
            self.folder = nil
            await self.unmountQuietly(self.mountDir)
            if !Self.isSMBMount(self.mountDir) {
                try? FileManager.default.removeItem(at: self.mountDir)
            }
        }
    }
}
