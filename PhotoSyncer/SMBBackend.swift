import Foundation
import Darwin
import Combine
import NetFS
import NetFS.NetFSPlugin

@_silgen_name("__getdirentries64")
private nonisolated func sys_getdirentries64(
    _ fd: Int32,
    _ buf: UnsafeMutableRawPointer,
    _ bufSize: Int,
    _ basep: UnsafeMutablePointer<__darwin_off_t>
) -> Int

// MARK: - SMB Endpoint & Share Discovery Models

/// Parses flexible user server inputs ("nas.local", "192.168.1.20:445", "smb://user@nas.local/Photos/2026",
/// or "\\nas.local\Photos") just like macOS Finder's Connect to Server (`⌘K`) dialog.
nonisolated struct SMBServerEndpoint: Equatable, Sendable {
    var host: String
    var port: Int
    var usernameHint: String?
    var shareHint: String?
    var subfolderHint: [String]

    static func parse(_ rawInput: String, defaultPort: Int = Destination.defaultSMBPort) -> SMBServerEndpoint? {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Convert Windows UNC paths (`\\server\share\sub`) into `smb://server/share/sub`.
        if text.hasPrefix("\\\\") {
            let trimmed = text.drop { $0 == "\\" }
            text = "smb://" + trimmed.replacingOccurrences(of: "\\", with: "/")
        }

        let fallbackPort = defaultPort > 0 ? defaultPort : Destination.defaultSMBPort
        if !text.contains("://") {
            // Bare host, host:port, IPv6 `[::1]:445`, or `host/share/sub`.
            text = "smb://" + text
        }

        guard let comps = URLComponents(string: text),
              let rawHost = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            return nil
        }

        let resolvedPort = comps.port ?? fallbackPort
        let userHint = (comps.user?.isEmpty == false) ? comps.user : nil
        let pathParts = comps.path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        let shareHint = pathParts.first
        let subHint = pathParts.count > 1 ? Array(pathParts.dropFirst()) : []
        return SMBServerEndpoint(
            host: rawHost,
            port: resolvedPort,
            usernameHint: userHint,
            shareHint: shareHint,
            subfolderHint: subHint
        )
    }
}

/// One share returned by `NetFSMountInterface_V1.EnumerateShares`.
nonisolated struct SMBShareInfo: Identifiable, Hashable, Sendable {
    var name: String
    var displayName: String
    var isHidden: Bool
    var isPrinter: Bool

    var id: String { name }
}

// MARK: - Mount Gate

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

/// Allows swift Task cancellation or timeout to abort an in-flight `NetFS` `OpenSession`/`EnumerateShares` call.
private nonisolated final class CancelableNetFSSession: @unchecked Sendable {
    private let lock = NSLock()
    private var vtbl: UnsafeMutablePointer<NetFSMountInterface_V1>?
    private var session: UnsafeMutableRawPointer?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func attach(vtbl: UnsafeMutablePointer<NetFSMountInterface_V1>, session: UnsafeMutableRawPointer) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.vtbl = vtbl
            self.session = session
            return true
        }
    }

    func detach() {
        lock.withLock {
            vtbl = nil
            session = nil
        }
    }

    func cancel() {
        let pair: (UnsafeMutablePointer<NetFSMountInterface_V1>, UnsafeMutableRawPointer)? = lock.withLock {
            cancelled = true
            guard let v = vtbl, let s = session else { return nil }
            return (v, s)
        }
        if let (v, s) = pair {
            _ = v.pointee.Cancel(s)
        }
    }
}

/// Tracks open `SMBBrowseSession` IDs so background orphan cleanup never unmounts a live wizard session.
private nonisolated final class ActiveBrowseRegistry: @unchecked Sendable {
    static let shared = ActiveBrowseRegistry()
    private let lock = NSLock()
    private var activeIDs = Set<String>()

    func register(_ id: String) {
        _ = lock.withLock { activeIDs.insert(id) }
    }

    func unregister(_ id: String) {
        _ = lock.withLock { activeIDs.remove(id) }
    }

    func isActiveDirectoryName(_ dirName: String, extraActiveIDs: Set<String>) -> Bool {
        lock.withLock {
            if extraActiveIDs.contains(dirName) { return true }
            return activeIDs.contains { id in dirName == id || dirName.hasPrefix("\(id)-") }
        }
    }
}

/// Retains `smb.bundle`'s `CFPlugIn` and `NetFSMountInterface_V1` for the lifetime of the process
/// (matching `NetFS.framework`), preventing `CFPlugIn` from `dlclose`-unloading `smb.bundle` between calls.
private nonisolated final class LoadedSMBPlugin: @unchecked Sendable {
    static let shared = LoadedSMBPlugin()

    private let lock = NSLock()
    private var retainedPlugin: CFPlugIn?
    private var rawInterfaceObject: LPVOID?
    private var cachedVTable: UnsafeMutablePointer<NetFSMountInterface_V1>?

    func vtable() throws -> (UnsafeMutablePointer<NetFSMountInterface_V1>, LPVOID) {
        try lock.withLock {
            if let vtbl = cachedVTable, let raw = rawInterfaceObject {
                return (vtbl, raw)
            }
            let pluginPaths = [
                "/System/Library/Filesystems/NetFSPlugins/smb.bundle",
                "/Library/Filesystems/NetFSPlugins/smb.bundle",
            ]
            guard let bundlePath = pluginPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  let plugin = CFPlugInCreate(nil, URL(fileURLWithPath: bundlePath) as CFURL),
                  let netfsType = CFUUIDGetConstantUUIDWithBytes(
                      nil, 0x02, 0xfe, 0x7d, 0x14, 0x4e, 0x91, 0x48, 0x1e, 0x94, 0x6c, 0xce, 0x23, 0x3c, 0x79, 0x8c, 0xc0),
                  let ifaceUUID = CFUUIDGetConstantUUIDWithBytes(
                      nil, 0x8f, 0x34, 0xb6, 0xc4, 0xf2, 0xe4, 0x4e, 0xcd, 0x86, 0x25, 0xe5, 0x66, 0x58, 0x11, 0xde, 0x37),
                  let factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(netfsType, plugin) as? [CFUUID],
                  let factoryID = factories.first,
                  let unknownPtr = CFPlugInInstanceCreate(nil, factoryID, netfsType) else {
                throw SyncError.message("macOS's SMB client plugin could not be loaded.")
            }

            let iunknown = unknownPtr.assumingMemoryBound(to: UnsafeMutablePointer<IUnknownVTbl>.self)
            var rawObj: LPVOID?
            let hr = iunknown.pointee.pointee.QueryInterface(unknownPtr, CFUUIDGetUUIDBytes(ifaceUUID), &rawObj)
            _ = iunknown.pointee.pointee.Release(unknownPtr)
            guard hr == 0, let rawObj else {
                throw SyncError.message("macOS's SMB client interface is unavailable (HRESULT \(hr)).")
            }

            let vtbl = rawObj.assumingMemoryBound(to: UnsafeMutablePointer<NetFSMountInterface_V1>.self).pointee
            retainedPlugin = plugin
            rawInterfaceObject = rawObj
            cachedVTable = vtbl
            return (vtbl, rawObj)
        }
    }
}

// MARK: - SMB Backend

/// An SMB share, connected with macOS's own SMB client (the one Finder uses) and then used like a folder.
///
/// The share is mounted by NetFS at a private mount point inside the app's support container, so no extra
/// entitlement is needed beyond outgoing network access. Everything after the mount (staging, the
/// `.partial` → final rename, checksum read-back with `F_NOCACHE`, listing, deleting) reuses `FolderBackend`,
/// so SMB gets the same verification as a local or USB folder.
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
    private var activeMountRoot: URL?
    private var ownsActiveMount = false
    private var folder: FolderBackend?

    /// NetFS gives up on an unreachable server by itself after about a minute; this is only a safety net.
    private static let mountTimeout: TimeInterval = 90
    private static let enumerateTimeout: TimeInterval = 25

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

    static var browseMountsRoot: URL {
        let base = SandboxCompat.appSupportDirectory
            .appendingPathComponent("BrowseMounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }

    static func cleanupMount(key: String) async {
        await MountGate.shared.withKey(key) {
            let dir = mountsRoot.appendingPathComponent(key, isDirectory: true)
            await unmountAndRemoveDirectory(dir)
        }
    }

    fileprivate static func isManagedMountDirectory(_ dir: URL) -> Bool {
        let path = dir.resolvingSymlinksInPath().path
        let mRoot = mountsRoot.path + "/"
        let bRoot = browseMountsRoot.path + "/"
        return path.hasPrefix(mRoot) || path.hasPrefix(bRoot)
    }

    fileprivate static func unmountAndRemoveDirectory(_ dir: URL) async {
        guard isManagedMountDirectory(dir) else { return }
        let resolved = dir.resolvingSymlinksInPath()
        if isSMBMount(resolved) {
            _ = try? await withTimeout(30, timeoutMessage: "Unmounting timed out") {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    FileManager.default.unmountVolume(at: resolved, options: [.withoutUI]) { _ in cont.resume() }
                }
            }
        }
        if !isSMBMount(resolved) {
            try? FileManager.default.removeItem(at: resolved)
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

    /// Cleans up any leftover wizard browse mounts from an earlier crash or force-quit.
    static func cleanupStaleBrowseMounts(keeping activeBrowseIDs: Set<String> = []) async {
        let root = browseMountsRoot
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in entries where !ActiveBrowseRegistry.shared.isActiveDirectoryName(dir.lastPathComponent, extraActiveIDs: activeBrowseIDs) {
            await MountGate.shared.withKey("browse:\(dir.lastPathComponent)") {
                await unmountAndRemoveDirectory(dir)
            }
        }
    }

    // MARK: Share Enumeration (macOS NetFS smb.bundle)

    /// Pure parser for the `CFDictionary` returned by `NetFSMountInterface_V1.EnumerateShares`.
    static func parseEnumeratedShares(_ rawDict: [String: Any], includeHidden: Bool = true) -> [SMBShareInfo] {
        var result: [SMBShareInfo] = []
        for (rawName, value) in rawDict {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Never surface SMB's administrative IPC$ pipe as a file destination.
            if trimmed.uppercased() == "IPC$" { continue }

            let attrs = value as? [String: Any]
            let isPrinter = (attrs?[kNetFSPrinterShareKey as String] as? Bool) == true
            if isPrinter { continue }

            let flaggedHidden = (attrs?[kNetFSIsHiddenKey as String] as? Bool) == true
            let dollarHidden = trimmed.hasSuffix("$")
            let hidden = flaggedHidden || dollarHidden
            if hidden && !includeHidden { continue }

            let display = (attrs?[kNetFSDisplayNameKey as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = (display?.isEmpty == false) ? display! : trimmed
            result.append(SMBShareInfo(name: trimmed, displayName: shown, isHidden: hidden, isPrinter: false))
        }
        return result.sorted {
            let cmp = $0.displayName.localizedStandardCompare($1.displayName)
            return cmp == .orderedSame ? ($0.name < $1.name) : (cmp == .orderedAscending)
        }
    }

    struct ShareDiscoveryResult: Sendable {
        var shares: [SMBShareInfo]
        var enumerationUnsupported: Bool
    }

    /// Connects to an SMB server via macOS's `smb.bundle` NetFS plugin and enumerates available shares
    /// without mounting anything or exposing credentials in command-line arguments.
    static func discoverShares(host rawHost: String,
                               port: Int = Destination.defaultSMBPort,
                               guest: Bool,
                               username: String,
                               password: String) async throws -> ShareDiscoveryResult {
        let cleanHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw SyncError.message("Enter the SMB server's hostname or IP address.")
        }
        if !guest && username.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SyncError.message("Enter a username, or choose Guest.")
        }

        let cancelBox = CancelableNetFSSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShareDiscoveryResult, Error>) in
                let dog = Watchdog()
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try Self.enumerateSharesSync(
                            host: cleanHost,
                            port: port,
                            guest: guest,
                            username: username,
                            password: password,
                            cancelBox: cancelBox
                        )
                        if dog.finish() { cont.resume(returning: result) }
                    } catch {
                        if dog.finish() { cont.resume(throwing: error) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.enumerateTimeout) {
                    if dog.finish() {
                        cancelBox.cancel()
                        cont.resume(throwing: SyncError.destinationUnavailable(
                            "Connecting to \(cleanHost) timed out. Check the address, port, and Local Network access."))
                    }
                }
            }
        } onCancel: {
            cancelBox.cancel()
        }
    }

    /// Splits optional `DOMAIN\user` or `DOMAIN;user` prefixes and formats NetFS's `DOMAIN;user` string.
    static func splitDomainAndUsername(_ raw: String) -> (domain: String?, user: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sep = trimmed.firstIndex(where: { $0 == "\\" || $0 == ";" }) {
            let domain = String(trimmed[..<sep]).trimmingCharacters(in: .whitespaces)
            let user = String(trimmed[trimmed.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            if !domain.isEmpty && !user.isEmpty {
                return (domain, user)
            }
        }
        return (nil, trimmed)
    }

    /// Normalizes `DOMAIN\user` into NetFS's `DOMAIN;user` format.
    static func normalizeNetFSUsername(_ raw: String) -> String {
        let parts = splitDomainAndUsername(raw)
        if let domain = parts.domain {
            return "\(domain);\(parts.user)"
        }
        return parts.user
    }

    /// Loads `smb.bundle`'s `NetFSMountInterface_V1` and builds a properly escaped `smb://` server or share URL
    /// via NetFS's own `CreateURL` entry point (also used by unit tests to verify COM vtable wiring).
    static func buildNetFSServerURL(host: String,
                                    port: Int,
                                    share: String? = nil,
                                    guest: Bool,
                                    username: String,
                                    password: String) throws -> URL {
        try withSMBNetFSInterface { vtbl, _ in
            try createServerURL(
                vtbl: vtbl,
                host: host,
                port: port,
                share: share,
                guest: guest,
                username: username,
                password: password
            )
        }
    }

    private static func withSMBNetFSInterface<T>(
        _ body: (UnsafeMutablePointer<NetFSMountInterface_V1>, LPVOID) throws -> T
    ) throws -> T {
        let (vtbl, rawObj) = try LoadedSMBPlugin.shared.vtable()
        return try body(vtbl, rawObj)
    }

    /// Kernel `smbfs` briefly returns these codes if a previous SMB session/mount to the same host is
    /// still finishing `SMB2_LOGOFF` / socket teardown when a new `GetServerInfo` / `OpenSession` starts.
    private static func isTransientSMBTeardownError(_ code: Int32) -> Bool {
        switch code {
        case -1, EBUSY, EAGAIN, ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, EIO, EEXIST:
            return true
        default:
            return false
        }
    }

    private static func createServerURL(vtbl: UnsafeMutablePointer<NetFSMountInterface_V1>,
                                        host: String,
                                        port: Int,
                                        share: String? = nil,
                                        guest: Bool,
                                        username: String,
                                        password: String) throws -> URL {
        let split = splitDomainAndUsername(username)
        var urlParams: [String: Any] = [
            kNetFSSchemeKey as String: "smb",
            kNetFSHostKey as String: host,
        ]
        if port > 0 && port != Destination.defaultSMBPort {
            urlParams[kNetFSAlternatePortKey as String] = "\(port)"
        }
        if !guest {
            // `smb.bundle`'s `ParseURL` / `CreateURL` encodes domain-qualified users via `DOMAIN\user`
            // in `kNetFSUserNameKey`, emitting `smb://DOMAIN;user:pass@host/share`.
            let pluginUser = split.domain.map { "\($0)\\\(split.user)" } ?? split.user
            urlParams[kNetFSUserNameKey as String] = pluginUser
            urlParams[kNetFSPasswordKey as String] = password
        }
        if let share, !share.isEmpty {
            urlParams[kNetFSPathKey as String] = share
        }

        var createdURL: Unmanaged<CFURL>?
        let urlRC = vtbl.pointee.CreateURL(urlParams as CFDictionary, &createdURL)
        if urlRC == 0, let cfURL = createdURL?.takeRetainedValue() {
            return cfURL as URL
        }

        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        if port > 0 && port != Destination.defaultSMBPort { comps.port = port }
        if !guest {
            comps.user = normalizeNetFSUsername(username)
            comps.password = password
        }
        if let share, !share.isEmpty {
            comps.path = "/" + share
        }
        guard let fallback = comps.url else {
            throw SyncError.message("The server address “\(host)” isn't valid.")
        }
        return fallback
    }

    private static func enumerateSharesSync(host: String,
                                            port: Int,
                                            guest: Bool,
                                            username: String,
                                            password: String,
                                            cancelBox: CancelableNetFSSession) throws -> ShareDiscoveryResult {
        try withSMBNetFSInterface { vtbl, _ in
            let serverURL = try createServerURL(
                vtbl: vtbl,
                host: host,
                port: port,
                guest: guest,
                username: username,
                password: password
            )

            let openOpts = NSMutableDictionary()
            openOpts[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
            openOpts[kNetFSNoUserPreferencesKey as String] = true
            if guest { openOpts[kNetFSUseGuestKey as String] = true }
            if isLoopback(host) { openOpts[kNetFSAllowLoopbackKey as String] = true }

            let retryBackoffsUs: [useconds_t] = [0, 250_000, 450_000, 750_000, 1_000_000]
            var lastSessionErrorCode: Int32 = -1

            for (attempt, delayUs) in retryBackoffsUs.enumerated() {
                if cancelBox.isCancelled { throw CancellationError() }
                if delayUs > 0 {
                    usleep(delayUs)
                    if cancelBox.isCancelled { throw CancellationError() }
                }

                var session: UnsafeMutableRawPointer?
                let createRC = vtbl.pointee.CreateSessionRef(&session)
                guard createRC == 0, let session else {
                    throw mapMountError(createRC, host: host, share: "", guest: guest, stage: .session)
                }
                defer {
                    cancelBox.detach()
                    _ = vtbl.pointee.CloseSession(session)
                }
                guard cancelBox.attach(vtbl: vtbl, session: session) else {
                    throw CancellationError()
                }

                // Match Apple's `SMBOpenServerEx` sequence:
                // 1) `GetServerInfo` negotiates SMB2/3 server capabilities and auth mechanisms (NTLMSSP/Guest/Kerberos).
                // 2) `OpenSession` MUST NOT set `kNetFSForceNewSessionKey`, because `EnumerateShares` opens `\pipe\srvsvc`
                //    via `DCERPC.framework` (`ncacn_np`), which attaches to a shareable kernel SMB session; marking the
                //    session private forces `smb.bundle` down the legacy SMB1 RAP path (`SMBTransactMailSlot` → -1).
                var serverParms: Unmanaged<CFDictionary>?
                let infoRC = vtbl.pointee.GetServerInfo(serverURL as CFURL, session, openOpts, &serverParms)
                _ = serverParms?.takeRetainedValue()
                if infoRC != 0 {
                    lastSessionErrorCode = infoRC
                    if attempt < retryBackoffsUs.count - 1 && isTransientSMBTeardownError(infoRC) {
                        continue
                    }
                    throw mapMountError(infoRC, host: host, share: "", guest: guest, stage: .session)
                }

                var sessionInfo: Unmanaged<CFDictionary>?
                let openRC = vtbl.pointee.OpenSession(serverURL as CFURL, session, openOpts, &sessionInfo)
                _ = sessionInfo?.takeRetainedValue()
                if openRC != 0 {
                    lastSessionErrorCode = openRC
                    if attempt < retryBackoffsUs.count - 1 && isTransientSMBTeardownError(openRC) {
                        continue
                    }
                    throw mapMountError(openRC, host: host, share: "", guest: guest, stage: .session)
                }

                let enumOpts: [String: Any] = [kNetFSGetAccessRightsKey as String: true]
                var rawSharepoints: Unmanaged<CFDictionary>?
                let enumRC = vtbl.pointee.EnumerateShares(session, enumOpts as CFDictionary, &rawSharepoints)
                if enumRC != 0 {
                    _ = rawSharepoints?.takeRetainedValue()
                    // Retry once or twice if `DCERPC` `\pipe\srvsvc` hit a transient session race (`-1` / `EBUSY`).
                    if attempt < 2 && isTransientSMBTeardownError(enumRC) {
                        continue
                    }
                    // Authentication succeeded (`OpenSession == 0`), but this SMB server genuinely rejected `srvsvc`
                    // share enumeration (e.g. `rpc_server:srvsvc = disabled` or strict IPC$ ACL). Let the wizard
                    // proceed so the user can enter the share name once and still browse its subfolders visually.
                    return ShareDiscoveryResult(shares: [], enumerationUnsupported: true)
                }
                let dict = (rawSharepoints?.takeRetainedValue() as? [String: Any]) ?? [:]
                return ShareDiscoveryResult(
                    shares: parseEnumeratedShares(dict, includeHidden: true),
                    enumerationUnsupported: false
                )
            }

            throw mapMountError(lastSessionErrorCode, host: host, share: "", guest: guest, stage: .session)
        }
    }

    fileprivate struct MountOutcome: Sendable {
        var rootURL: URL
        var ownedByPhotoSyncer: Bool
    }

    /// Mounts a single SMB share directly via `smb.bundle` (`NetFSMountInterface_V1`: `GetServerInfo` →
    /// `OpenSession` → `Mount`) in-process with `MNT_DONTBROWSE` + `SoftMount`.
    ///
    /// Using `smb.bundle` directly instead of `NetFSMountURLSync` avoids `NetAuthSysAgent`'s XPC
    /// `MechTypesSession` (`NAHSelection`), which returns `-128` (`userCanceledErr`) when `kNAUIOptionNoUI`
    /// is combined with an existing SMB session or cached Keychain entry for the same host.
    fileprivate static func mountShare(host rawHost: String,
                                       port: Int,
                                       share rawShare: String,
                                       guest: Bool,
                                       username: String?,
                                       password: String?,
                                       at mountDir: URL,
                                       timeout: TimeInterval = mountTimeout) async throws -> MountOutcome {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = rawShare.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ \t\n"))
        guard !host.isEmpty, !share.isEmpty else {
            throw SyncError.message("The server name or share name isn't valid.")
        }
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        let canonicalMountDir = mountDir.resolvingSymlinksInPath()

        let user = guest ? "" : (username ?? "")
        let pass = guest ? "" : (password ?? "")
        let cancelBox = CancelableNetFSSession()

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MountOutcome, Error>) in
                    let dog = Watchdog()
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let result = try Self.mountShareSync(
                                host: host,
                                port: port,
                                share: share,
                                guest: guest,
                                username: user,
                                password: pass,
                                canonicalMountDir: canonicalMountDir,
                                cancelBox: cancelBox
                            )
                            if dog.finish() { cont.resume(returning: result) }
                        } catch {
                            if dog.finish() { cont.resume(throwing: error) }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if dog.finish() {
                            cancelBox.cancel()
                            cont.resume(throwing: SyncError.destinationUnavailable("The SMB server stopped responding"))
                        }
                    }
                }
            } onCancel: {
                cancelBox.cancel()
            }
        } catch {
            if !Self.isSMBMount(canonicalMountDir) {
                try? FileManager.default.removeItem(at: canonicalMountDir)
            }
            throw error
        }
    }

    private static func mountShareSync(host: String,
                                       port: Int,
                                       share: String,
                                       guest: Bool,
                                       username: String,
                                       password: String,
                                       canonicalMountDir: URL,
                                       cancelBox: CancelableNetFSSession) throws -> MountOutcome {
        if isSMBMount(canonicalMountDir) {
            return MountOutcome(rootURL: canonicalMountDir, ownedByPhotoSyncer: true)
        }

        return try withSMBNetFSInterface { vtbl, _ in
            let serverURL = try createServerURL(
                vtbl: vtbl,
                host: host,
                port: port,
                share: nil,
                guest: guest,
                username: username,
                password: password
            )
            let shareURL = try createServerURL(
                vtbl: vtbl,
                host: host,
                port: port,
                share: share,
                guest: guest,
                username: username,
                password: password
            )

            func attemptMount(forceNewSession: Bool) throws -> (rc: Int32, mountInfo: [String: Any]?) {
                let retryDelaysUs: [useconds_t] = [0, 250_000, 500_000, 800_000]
                var lastErr: Int32 = -1

                for (attempt, delayUs) in retryDelaysUs.enumerated() {
                    if cancelBox.isCancelled { throw CancellationError() }
                    if delayUs > 0 {
                        usleep(delayUs)
                        if cancelBox.isCancelled { throw CancellationError() }
                    }

                    var session: UnsafeMutableRawPointer?
                    let createRC = vtbl.pointee.CreateSessionRef(&session)
                    guard createRC == 0, let session else {
                        throw mapMountError(createRC, host: host, share: share, guest: guest, stage: .session)
                    }
                    defer {
                        cancelBox.detach()
                        _ = vtbl.pointee.CloseSession(session)
                    }
                    guard cancelBox.attach(vtbl: vtbl, session: session) else {
                        throw CancellationError()
                    }

                    let openOpts = NSMutableDictionary()
                    openOpts[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
                    openOpts[kNetFSNoUserPreferencesKey as String] = true
                    if forceNewSession { openOpts[kNetFSForceNewSessionKey as String] = true }
                    if guest { openOpts[kNetFSUseGuestKey as String] = true }
                    if isLoopback(host) { openOpts[kNetFSAllowLoopbackKey as String] = true }

                    var serverParms: Unmanaged<CFDictionary>?
                    let infoRC = vtbl.pointee.GetServerInfo(serverURL as CFURL, session, openOpts, &serverParms)
                    _ = serverParms?.takeRetainedValue()
                    if infoRC != 0 {
                        lastErr = infoRC
                        if attempt < retryDelaysUs.count - 1 && isTransientSMBTeardownError(infoRC) {
                            continue
                        }
                        throw mapMountError(infoRC, host: host, share: share, guest: guest, stage: .session)
                    }

                    var sessionInfo: Unmanaged<CFDictionary>?
                    let openRC = vtbl.pointee.OpenSession(serverURL as CFURL, session, openOpts, &sessionInfo)
                    _ = sessionInfo?.takeRetainedValue()
                    if openRC != 0 {
                        lastErr = openRC
                        if attempt < retryDelaysUs.count - 1 && isTransientSMBTeardownError(openRC) {
                            continue
                        }
                        throw mapMountError(openRC, host: host, share: share, guest: guest, stage: .session)
                    }

                    let mountOpts = NSMutableDictionary()
                    mountOpts[kNetFSSoftMountKey as String] = true
                    mountOpts[kNetFSNoUserPreferencesKey as String] = true
                    mountOpts[kNetFSMountFlagsKey as String] = Int32(MNT_DONTBROWSE)
                    // Disable NTFS Alternate Data Streams probing and Finder change notifications on private
                    // mounts; on Windows SMB shares with 40k+ files this cuts directory traversal by ~4.6x.
                    mountOpts["SMBStreamsMount"] = false
                    mountOpts["SMBNotifyOffMount"] = true
                    if forceNewSession { mountOpts[kNetFSForceNewSessionKey as String] = true }
                    if !guest {
                        mountOpts[kNetFSPasswordKey as String] = password
                    }

                    var rawMountInfo: Unmanaged<CFDictionary>?
                    let mountRC = vtbl.pointee.Mount(
                        session,
                        shareURL as CFURL,
                        canonicalMountDir.path as CFString,
                        mountOpts,
                        &rawMountInfo
                    )
                    let dict = rawMountInfo?.takeRetainedValue() as? [String: Any]
                    if mountRC != 0 && mountRC != EEXIST
                        && attempt < retryDelaysUs.count - 1
                        && isTransientSMBTeardownError(mountRC) {
                        lastErr = mountRC
                        continue
                    }
                    return (mountRC, dict)
                }

                throw mapMountError(lastErr, host: host, share: share, guest: guest, stage: .session)
            }

            let primary = try attemptMount(forceNewSession: false)
            if primary.rc == 0 {
                if isSMBMount(canonicalMountDir) {
                    return MountOutcome(rootURL: canonicalMountDir, ownedByPhotoSyncer: true)
                }
                if let path = extractMountPath(from: primary.mountInfo, share: share) {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    let owned = isManagedMountDirectory(resolved)
                    if !owned { try? FileManager.default.removeItem(at: canonicalMountDir) }
                    return MountOutcome(rootURL: resolved, ownedByPhotoSyncer: owned)
                }
                return MountOutcome(rootURL: canonicalMountDir, ownedByPhotoSyncer: true)
            }

            // `EEXIST` means this exact share is already mounted on this Mac (for example in Finder at `/Volumes/<share>`).
            // Try an isolated private session mount first; if the server restricts duplicate sessions, reuse the existing mount read/write without taking ownership of unmounting it.
            if primary.rc == EEXIST {
                if isSMBMount(canonicalMountDir) {
                    return MountOutcome(rootURL: canonicalMountDir, ownedByPhotoSyncer: true)
                }
                if let forced = try? attemptMount(forceNewSession: true), forced.rc == 0, isSMBMount(canonicalMountDir) {
                    return MountOutcome(rootURL: canonicalMountDir, ownedByPhotoSyncer: true)
                }
                if let existingPath = extractMountPath(from: primary.mountInfo, share: share)
                    ?? findExistingSMBMount(host: host, share: share)?.path {
                    let existingURL = URL(fileURLWithPath: existingPath).resolvingSymlinksInPath()
                    try? FileManager.default.removeItem(at: canonicalMountDir)
                    return MountOutcome(rootURL: existingURL, ownedByPhotoSyncer: isManagedMountDirectory(existingURL))
                }
            }

            throw mapMountError(primary.rc, host: host, share: share, guest: guest, stage: .mount)
        }
    }

    private static func extractMountPath(from mountInfo: [String: Any]?, share: String) -> String? {
        guard let mountInfo else { return nil }
        if let direct = mountInfo[kNetFSMountPathKey as String] as? String, !direct.isEmpty {
            return direct
        }
        if let nested = (mountInfo[share] as? [String: Any])?[kNetFSMountPathKey as String] as? String, !nested.isEmpty {
            return nested
        }
        for (_, val) in mountInfo {
            if let sub = val as? [String: Any],
               let p = sub[kNetFSMountPathKey as String] as? String,
               !p.isEmpty {
                return p
            }
        }
        return nil
    }

    private static func findExistingSMBMount(host: String, share: String) -> URL? {
        var mntbuf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard let mntbuf, count > 0 else { return nil }
        for i in 0..<Int(count) {
            var fs = mntbuf[i]
            let fstype = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            guard fstype == "smbfs" else { continue }
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let on = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if let comps = URLComponents(string: "smb:" + from),
               let mntHost = comps.host,
               mntHost.caseInsensitiveCompare(host) == .orderedSame {
                let mntShare = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if mntShare.caseInsensitiveCompare(share) == .orderedSame {
                    return URL(fileURLWithPath: on).resolvingSymlinksInPath()
                }
            }
        }
        return nil
    }

    // MARK: Connection
    func connect() async throws {
        try await MountGate.shared.withKey(key) {
            let components = try Self.subfolderComponents(self.subfolder)
            let canonicalDir = self.mountDir.resolvingSymlinksInPath()
            let reused = Self.isSMBMount(canonicalDir)              // left over from a crash or a failed unmount
            let outcome = reused
                ? MountOutcome(rootURL: canonicalDir, ownedByPhotoSyncer: true)
                : try await self.mount()
            self.activeMountRoot = outcome.rootURL
            self.ownsActiveMount = outcome.ownedByPhotoSyncer
            do {
                try await self.open(root: outcome.rootURL, components: components)
            } catch {
                // A leftover mount whose server has gone away: drop it and mount afresh, once.
                if reused, case SyncError.destinationUnavailable = error {
                    await self.unmountQuietly(outcome.rootURL)
                    let fresh = try await self.mount()
                    self.activeMountRoot = fresh.rootURL
                    self.ownsActiveMount = fresh.ownedByPhotoSyncer
                    do { try await self.open(root: fresh.rootURL, components: components) }
                    catch {
                        if fresh.ownedByPhotoSyncer { await self.unmountQuietly(fresh.rootURL) }
                        self.activeMountRoot = nil
                        self.ownsActiveMount = false
                        throw error
                    }
                    return
                }
                if outcome.ownedByPhotoSyncer {
                    await self.unmountQuietly(outcome.rootURL)
                }
                self.activeMountRoot = nil
                self.ownsActiveMount = false
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

    private func mount() async throws -> MountOutcome {
        try await Self.mountShare(
            host: host,
            port: port,
            share: share,
            guest: user == nil,
            username: user,
            password: password,
            at: mountDir,
            timeout: Self.mountTimeout
        )
    }

    // MARK: Errors
    enum FailureStage: Sendable {
        case session
        case mount
    }

    /// NetFS returns a positive errno or a negative OSStatus (see NetFS.h).
    static func mapMountError(_ code: Int32,
                              host: String,
                              share: String,
                              guest: Bool = false,
                              stage: FailureStage = .session) -> Error {
        switch code {
        case EAUTH, EACCES, -5999, -5045, -5046:
            if guest {
                return SyncError.message("\(host) doesn't allow guest access. Choose Registered User and sign in.")
            }
            if stage == .mount && !share.isEmpty {
                return SyncError.message("Connected to \(host), but the server denied access to shared folder “\(share)” for this account (error \(code)).")
            }
            if share.isEmpty {
                return SyncError.message("SMB login failed – check your username and password for \(host).")
            }
            return SyncError.message("SMB login failed – check the username and password, and that this account may use “\(share)”.")
        case EPERM:
            if stage == .mount && !share.isEmpty {
                return SyncError.message("macOS wasn't permitted to mount “\(share)” from \(host) (EPERM).")
            }
            return SyncError.message("Connection to \(host) was blocked by local permissions (EPERM).")
        case -128:
            return SyncError.message("Connection to \(host) was canceled or interrupted (OSStatus -128).")
        case ENOENT, -6003, -5998:
            if share.isEmpty {
                return SyncError.message("Connected to \(host), but no shared folders are available for this account.")
            }
            return SyncError.message("The share “\(share)” was not found on \(host).")
        case -5997:
            return SyncError.message("\(host) uses a login method macOS's SMB client doesn't support.")
        case -5996:
            return SyncError.message("\(host) uses an SMB version macOS's SMB client doesn't support.")
        case -6004:
            return SyncError.message("\(host) doesn't allow guest access. Choose Registered User and sign in.")
        case ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN, ENOTCONN, ECONNRESET, ENXIO, EIO:
            return SyncError.destinationUnavailable("Cannot reach \(host) (\(String(cString: strerror(code)))).")
        default:
            let detail = code > 0 ? "\(String(cString: strerror(code))) (\(code))" : "OSStatus \(code)"
            if stage == .mount && !share.isEmpty {
                return SyncError.message("Could not open share “\(share)” on \(host): \(detail).")
            }
            return SyncError.message("Could not connect to \(host): \(detail).")
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

    /// Thread-safe cancellation flag for aborting an in-flight `readdir` scan immediately when the
    /// user switches folders, clicks Add, or closes the wizard.
    fileprivate final class DirectoryScanToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    struct SubdirectoryScanResult: Sendable, Equatable {
        var directories: [String]
        var stoppedEarlyDueToManyFiles: Bool
    }

    /// Scans non-hidden immediate subdirectories inside `directoryURL` using raw 64 KB `__getdirentries64` buffers.
    ///
    /// Unlike `opendir`/`readdir` (which on XNU `smbfs` can buffer tens of thousands of entries before returning),
    /// `__getdirentries64` reads one 64 KB SMB2 `QUERY_DIRECTORY` batch at a time and can stop + `close(fd)`
    /// immediately once `maxNonDirectoryEntries` regular files are encountered so 40,000-file photo shares never stall.
    static func scanSubdirectories(
        at directoryURL: URL,
        maxNonDirectoryEntries: Int? = nil,
        shouldCancel: () -> Bool = { false },
        onBatch: (([String]) -> Void)? = nil
    ) throws -> SubdirectoryScanResult {
        let dirPath = directoryURL.path
        let fd = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(err))
            ])
        }
        let bufSize = 65_536
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer {
            buf.deallocate()
            Darwin.close(fd)
        }

        var basep: __darwin_off_t = 0
        var dirs: [String] = []
        var nonDirCount = 0
        var stoppedEarly = false
        var lastReportedCount = 0
        var lastReportTime = DispatchTime.now().uptimeNanoseconds

        outer: while true {
            if shouldCancel() {
                throw CancellationError()
            }
            errno = 0
            let bytesRead = sys_getdirentries64(fd, buf, bufSize, &basep)
            if bytesRead < 0 {
                let err = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                    NSLocalizedDescriptionKey: String(cString: strerror(err))
                ])
            }
            if bytesRead == 0 {
                break
            }

            var offset = 0
            while offset < bytesRead {
                let entryPtr = buf.advanced(by: offset).assumingMemoryBound(to: dirent.self)
                let reclen = Int(entryPtr.pointee.d_reclen)
                if reclen <= 0 { break }
                offset += reclen

                // Skip `.`, `..`, and hidden files (`.DS_Store`, `._*`, `.partial`) in place before String allocation.
                if entryPtr.pointee.d_name.0 == CChar(UInt8(ascii: ".")) {
                    continue
                }

                let dtype = Int32(entryPtr.pointee.d_type)
                if dtype != DT_DIR && dtype != DT_UNKNOWN && dtype != DT_LNK {
                    nonDirCount &+= 1
                    continue
                }

                let nameLen = Int(entryPtr.pointee.d_namlen)
                let name: String = withUnsafePointer(to: &entryPtr.pointee.d_name) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: CChar.self, capacity: nameLen + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name.isEmpty { continue }

                let isDir: Bool
                if dtype == DT_DIR {
                    isDir = true
                } else {
                    var st = stat()
                    isDir = (fstatat(fd, name, &st, 0) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
                }
                if isDir {
                    dirs.append(name)
                } else {
                    nonDirCount &+= 1
                }
            }

            if let onBatch {
                let now = DispatchTime.now().uptimeNanoseconds
                if dirs.count != lastReportedCount && (now - lastReportTime) >= 200_000_000 {
                    lastReportedCount = dirs.count
                    lastReportTime = now
                    let snapshot = dirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    onBatch(snapshot)
                }
            }

            if let cap = maxNonDirectoryEntries, nonDirCount >= cap {
                stoppedEarly = true
                break outer
            }
        }

        dirs.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return SubdirectoryScanResult(directories: dirs, stoppedEarlyDueToManyFiles: stoppedEarly)
    }

    static func listSubdirectories(
        at directoryURL: URL,
        shouldCancel: () -> Bool = { false },
        onBatch: (([String]) -> Void)? = nil
    ) throws -> [String] {
        try scanSubdirectories(
            at: directoryURL,
            maxNonDirectoryEntries: nil,
            shouldCancel: shouldCancel,
            onBatch: onBatch
        ).directories
    }

    // MARK: Helpers
    fileprivate static func isLoopback(_ host: String) -> Bool {
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
        guard Self.isManagedMountDirectory(url) else { return }
        let resolved = url.resolvingSymlinksInPath()
        guard Self.isSMBMount(resolved) else { return }
        _ = try? await withTimeout(30, timeoutMessage: "Unmounting timed out") {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                FileManager.default.unmountVolume(at: resolved, options: [.withoutUI]) { _ in cont.resume() }
            }
        }
    }

    private func backend() throws -> FolderBackend {
        guard let folder else { throw SyncError.destinationUnavailable("Not connected to the SMB share") }
        return folder
    }

    // MARK: DestinationBackend
    func isAvailable() async -> Bool {
        guard let folder, let root = activeMountRoot, Self.isSMBMount(root) else { return false }
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
            let target = self.activeMountRoot ?? self.mountDir
            let owned = self.ownsActiveMount
            self.activeMountRoot = nil
            self.ownsActiveMount = false
            if owned {
                await self.unmountQuietly(target)
            }
            let canonicalDir = self.mountDir.resolvingSymlinksInPath()
            if !Self.isSMBMount(canonicalDir) {
                try? FileManager.default.removeItem(at: canonicalDir)
            }
        }
    }
}

// MARK: - Interactive Wizard Browse Session

/// Drives the macOS Connect-to-Server style SMB wizard: authenticates & enumerates shares on the server,
/// mounts the selected share privately (`MNT_DONTBROWSE`) to let the user browse or create subfolders
/// visually, verifies write access, and cleans up its temporary mount when dismissed.
@MainActor
final class SMBBrowseSession: ObservableObject {
    @Published private(set) var connectedHost = ""
    @Published private(set) var connectedPort = Destination.defaultSMBPort
    @Published private(set) var connectedGuest = false
    @Published private(set) var connectedUsername = ""
    private var connectedPassword = ""

    @Published private(set) var allShares: [SMBShareInfo] = []
    @Published private(set) var enumerationUnsupported = false
    @Published var showHiddenShares = false
    @Published private(set) var selectedShare: String?
    @Published private(set) var pathComponents: [String] = []
    @Published private(set) var subfolders: [String] = []
    @Published private(set) var isWritable = false
    @Published private(set) var isMountedReady = false
    @Published private(set) var isScanningSubfolders = false
    @Published private(set) var hasScannedCurrentFolder = false
    @Published private(set) var scanStoppedDueToManyFiles = false

    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingShare = false
    @Published var errorMessage: String?

    private let browseID = UUID().uuidString
    private var mountedShareName: String?
    private var mountedRootURL: URL?
    private var ownsMountedRoot = false
    private var userCancelledConnect = false
    private var connectTask: Task<Bool, Never>?
    private var loadTask: Task<Void, Never>?
    private var subfolderScanTask: Task<Void, Never>?
    private var activeScanToken: SMBBackend.DirectoryScanToken?

    init() {
        ActiveBrowseRegistry.shared.register(browseID)
    }

    deinit {
        ActiveBrowseRegistry.shared.unregister(browseID)
    }

    var hasHiddenShares: Bool {
        allShares.contains(where: \.isHidden)
    }

    var visibleShares: [SMBShareInfo] {
        showHiddenShares ? allShares : allShares.filter { !$0.isHidden || $0.name == selectedShare }
    }

    var relativeFolderPath: String {
        pathComponents.joined(separator: "/")
    }

    var defaultDestinationName: String {
        guard let share = selectedShare else { return connectedHost }
        if let deepest = pathComponents.last {
            return "\(connectedHost)/\(share)/\(deepest)"
        }
        return "\(connectedHost)/\(share)"
    }

    var targetPreviewURLString: String {
        guard let share = selectedShare else { return "smb://\(connectedHost)" }
        let portPart = connectedPort == Destination.defaultSMBPort ? "" : ":\(connectedPort)"
        let sub = pathComponents.isEmpty ? "" : "/" + pathComponents.joined(separator: "/")
        return "smb://\(connectedHost)\(portPart)/\(share)\(sub)"
    }

    func cancelConnect() {
        userCancelledConnect = true
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
    }

    func connect(serverInput: String,
                 port: Int,
                 guest: Bool,
                 username: String,
                 password: String) async -> Bool {
        guard !isConnecting else { return false }
        guard let endpoint = SMBServerEndpoint.parse(serverInput, defaultPort: port) else {
            errorMessage = "Enter a valid server hostname or IP address (for example, nas.local or 192.168.1.20)."
            return false
        }
        let resolvedUser = guest ? "" : (username.trimmingCharacters(in: .whitespaces).isEmpty
            ? (endpoint.usernameHint ?? "")
            : username.trimmingCharacters(in: .whitespaces))
        if !guest && resolvedUser.isEmpty {
            errorMessage = "Enter your username for \(endpoint.host), or choose Guest."
            return false
        }

        userCancelledConnect = false
        errorMessage = nil
        isConnecting = true
        let task = Task<Bool, Never> { @MainActor in
            do {
                let discovery = try await SMBBackend.discoverShares(
                    host: endpoint.host,
                    port: endpoint.port,
                    guest: guest,
                    username: resolvedUser,
                    password: password
                )
                var discovered = discovery.shares
                // If the user pasted `smb://server/HiddenOrUnbrowsableShare`, include it even if `browseable = no`.
                if let hinted = endpoint.shareHint,
                   !discovered.contains(where: { $0.name.caseInsensitiveCompare(hinted) == .orderedSame }) {
                    discovered.insert(
                        SMBShareInfo(name: hinted, displayName: hinted, isHidden: hinted.hasSuffix("$"), isPrinter: false),
                        at: 0
                    )
                }

                self.connectedHost = endpoint.host
                self.connectedPort = endpoint.port
                self.connectedGuest = guest
                self.connectedUsername = resolvedUser
                self.connectedPassword = guest ? "" : password
                self.allShares = discovered
                self.enumerationUnsupported = discovery.enumerationUnsupported
                self.selectedShare = nil
                self.pathComponents = []
                self.subfolders = []
                self.isMountedReady = false
                self.isConnecting = false

                // Auto-select hinted share (if any) or first visible share.
                let preferredShare: String? = {
                    if let hinted = endpoint.shareHint,
                       let match = discovered.first(where: { $0.name.caseInsensitiveCompare(hinted) == .orderedSame }) {
                        return match.name
                    }
                    return self.visibleShares.first?.name ?? discovered.first?.name
                }()
                if let first = preferredShare {
                    if discovered.first(where: { $0.name == first })?.isHidden == true {
                        self.showHiddenShares = true
                    }
                    let subpathHint = endpoint.subfolderHint
                    Task { @MainActor in
                        await self.selectShare(first, initialSubpath: subpathHint)
                    }
                }
                return true
            } catch is CancellationError {
                self.isConnecting = false
                if !self.userCancelledConnect {
                    self.errorMessage = "Connection to \(endpoint.host) was interrupted. Click Connect to try again."
                }
                return false
            } catch {
                self.isConnecting = false
                let msg = error.localizedDescription.isEmpty
                    ? "Could not connect to \(endpoint.host)."
                    : error.localizedDescription
                self.errorMessage = msg
                EventLog.shared.error("SMB wizard connect to \(endpoint.host) failed: \(msg)")
                return false
            }
        }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func cancelSubfolderScan() {
        activeScanToken?.cancel()
        activeScanToken = nil
        subfolderScanTask?.cancel()
        subfolderScanTask = nil
        isScanningSubfolders = false
    }

    func selectShare(_ shareName: String, initialSubpath: [String] = []) async {
        loadTask?.cancel()
        cancelSubfolderScan()
        selectedShare = shareName
        pathComponents = []
        subfolders = []
        isWritable = false
        isMountedReady = false
        errorMessage = nil
        isLoadingShare = true

        let host = connectedHost
        let port = connectedPort
        let guest = connectedGuest
        let user = connectedUsername
        let pass = connectedPassword
        let id = browseID

        let task = Task { @MainActor in
            await unmountCurrentShare()
            let dir = SMBBackend.browseMountsRoot.appendingPathComponent("\(id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            do {
                let outcome = try await MountGate.shared.withKey("browse:\(dir.lastPathComponent)") {
                    try await SMBBackend.mountShare(
                        host: host,
                        port: port,
                        share: shareName,
                        guest: guest,
                        username: user,
                        password: pass,
                        at: dir,
                        timeout: 30
                    )
                }
                if Task.isCancelled || self.selectedShare != shareName {
                    if outcome.ownedByPhotoSyncer {
                        await MountGate.shared.withKey("browse:\(dir.lastPathComponent)") {
                            await SMBBackend.unmountAndRemoveDirectory(outcome.rootURL)
                        }
                    }
                    return
                }
                self.mountedShareName = shareName
                self.mountedRootURL = outcome.rootURL
                self.ownsMountedRoot = outcome.ownedByPhotoSyncer
                // Walk as far into `initialSubpath` as actually exists on the share.
                var validSubpath: [String] = []
                var probeURL = outcome.rootURL
                for part in initialSubpath {
                    let next = probeURL.appendingPathComponent(part, isDirectory: true)
                    if (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        validSubpath.append(part)
                        probeURL = next
                    } else {
                        break
                    }
                }
                self.pathComponents = validSubpath
                // Do not auto-enumerate 30,000+ files on initial share selection: verify the folder itself via
                // `stat` + `access` (~25ms) so selecting the share (like macOS Connect to Server) is instant.
                await self.refreshCurrentDirectory(scanMode: .none)
            } catch {
                if !Task.isCancelled, self.selectedShare == shareName {
                    self.errorMessage = error.localizedDescription
                    self.isLoadingShare = false
                }
            }
        }
        loadTask = task
        await task.value
    }

    func addManualShare(_ rawName: String) async {
        let clean = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ \t\n"))
        guard !clean.isEmpty else { return }
        if !allShares.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            allShares.append(SMBShareInfo(name: clean, displayName: clean, isHidden: clean.hasSuffix("$"), isPrinter: false))
            allShares.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        if clean.hasSuffix("$") { showHiddenShares = true }
        let canonical = allShares.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }?.name ?? clean
        await selectShare(canonical)
    }

    enum SubfolderScanMode {
        case none
        case quickBounded
        case exhaustive
    }

    func openSubfolder(_ folder: String) async {
        guard isMountedReady else { return }
        pathComponents.append(folder)
        await refreshCurrentDirectory(scanMode: .quickBounded)
    }

    /// Jumps directly into a relative subfolder path (e.g. `"Photos/2026"`) using pure `stat` lookups
    /// (~10ms per path component) without enumerating any sibling files in the parent folder.
    func openSubfolderPath(_ rawRelativePath: String) async -> Bool {
        guard isMountedReady, let base = currentMountedDirectoryURL() else { return false }
        let parts: [String]
        do {
            parts = try SMBBackend.subfolderComponents(rawRelativePath)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard !parts.isEmpty else { return false }

        var probe = base
        for part in parts {
            probe.appendPathComponent(part, isDirectory: true)
        }
        let targetPath = probe.path
        errorMessage = nil
        isLoadingShare = true
        do {
            try await BlockingIO.run(timeout: 15, timeoutMessage: "Opening subfolder timed out") {
                var st = stat()
                guard stat(targetPath, &st) == 0 else {
                    throw SyncError.message("Subfolder “\(parts.joined(separator: "/"))” was not found.")
                }
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    throw SyncError.message("“\(parts.joined(separator: "/"))” is a file, not a folder.")
                }
            }
            pathComponents.append(contentsOf: parts)
            await refreshCurrentDirectory(scanMode: .none)
            return true
        } catch {
            isLoadingShare = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func navigateToDepth(_ depth: Int) async {
        guard isMountedReady else { return }
        let clamped = min(max(depth, 0), pathComponents.count)
        guard clamped != pathComponents.count else { return }
        pathComponents = Array(pathComponents.prefix(clamped))
        await refreshCurrentDirectory(scanMode: .none)
    }

    func createSubfolder(named rawName: String) async -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains("\\") {
            errorMessage = "Folder names cannot contain “/”, “\\”, or “..”."
            return false
        }
        guard let currentDir = currentMountedDirectoryURL() else { return false }
        let newDir = currentDir.appendingPathComponent(trimmed, isDirectory: true)
        errorMessage = nil
        isLoadingShare = true
        do {
            try await BlockingIO.run(timeout: 15, timeoutMessage: "Creating the folder timed out") {
                try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: false)
            }
            pathComponents.append(trimmed)
            await refreshCurrentDirectory(scanMode: .none)
            hasScannedCurrentFolder = true
            return true
        } catch {
            isLoadingShare = false
            errorMessage = "Could not create folder “\(trimmed)”: \(error.localizedDescription)"
            return false
        }
    }

    private func currentMountedDirectoryURL() -> URL? {
        guard let root = mountedRootURL else { return nil }
        var cur = root
        for part in pathComponents {
            cur.appendPathComponent(part, isDirectory: true)
        }
        return cur
    }

    func loadSubfolders(exhaustive: Bool = false) {
        guard isMountedReady, let targetURL = currentMountedDirectoryURL() else { return }
        startSubfolderScan(at: targetURL, mode: exhaustive ? .exhaustive : .quickBounded)
    }

    func refreshCurrentDirectory(scanMode: SubfolderScanMode = .quickBounded) async {
        cancelSubfolderScan()
        guard let targetURL = currentMountedDirectoryURL() else {
            isLoadingShare = false
            isMountedReady = false
            return
        }
        subfolders = []
        hasScannedCurrentFolder = false
        scanStoppedDueToManyFiles = false
        isLoadingShare = true
        errorMessage = nil

        // Validate only the directory itself (`stat` + `access`), without touching child files (~25ms).
        do {
            let dirPath = targetURL.path
            let writable: Bool = try await BlockingIO.run(
                timeout: 15,
                timeoutMessage: "Checking the SMB folder timed out"
            ) {
                var st = stat()
                guard stat(dirPath, &st) == 0 else {
                    let err = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                        NSLocalizedDescriptionKey: String(cString: strerror(err))
                    ])
                }
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    throw SyncError.message("The selected path is not a folder.")
                }
                return access(dirPath, W_OK) == 0
            }
            isWritable = writable
            isMountedReady = true
            isLoadingShare = false
            if !writable {
                errorMessage = "This folder is read-only for \(connectedGuest ? "Guest" : connectedUsername). Choose or open a writable folder."
            }
        } catch {
            isMountedReady = false
            isLoadingShare = false
            errorMessage = "Could not open folder: \(error.localizedDescription)"
            return
        }

        if scanMode != .none {
            startSubfolderScan(at: targetURL, mode: scanMode)
        }
    }

    private func startSubfolderScan(at targetURL: URL, mode: SubfolderScanMode) {
        cancelSubfolderScan()
        let maxFiles: Int? = (mode == .quickBounded) ? 800 : nil
        let token = SMBBackend.DirectoryScanToken()
        activeScanToken = token
        isScanningSubfolders = true
        scanStoppedDueToManyFiles = false

        subfolderScanTask = Task { @MainActor [weak self] in
            do {
                let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SMBBackend.SubdirectoryScanResult, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let res = try SMBBackend.scanSubdirectories(
                                at: targetURL,
                                maxNonDirectoryEntries: maxFiles,
                                shouldCancel: { token.isCancelled },
                                onBatch: { batch in
                                    guard !token.isCancelled else { return }
                                    Task { @MainActor [weak self] in
                                        guard let self, !token.isCancelled else { return }
                                        self.subfolders = batch
                                    }
                                }
                            )
                            cont.resume(returning: res)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                guard let self, !token.isCancelled else { return }
                self.subfolders = result.directories
                self.hasScannedCurrentFolder = true
                self.scanStoppedDueToManyFiles = result.stoppedEarlyDueToManyFiles
                self.isScanningSubfolders = false
            } catch is CancellationError {
                guard let self, self.activeScanToken === token else { return }
                self.isScanningSubfolders = false
            } catch {
                guard let self, !token.isCancelled else { return }
                self.isScanningSubfolders = false
                if self.errorMessage == nil {
                    self.errorMessage = "Could not list subfolders: \(error.localizedDescription)"
                }
            }
        }
    }

    func buildDestination(customName: String) -> (destination: Destination, password: String)? {
        guard let share = selectedShare, isMountedReady, isWritable else { return nil }
        let trimmedCustom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedCustom.isEmpty ? defaultDestinationName : trimmedCustom
        let dest = Destination(
            name: finalName,
            kind: .smb,
            host: connectedHost,
            port: connectedPort,
            username: connectedGuest ? "" : connectedUsername,
            remotePath: relativeFolderPath,
            share: share,
            guest: connectedGuest ? true : nil
        )
        return (dest, connectedPassword)
    }

    private func unmountCurrentShare() async {
        guard let root = mountedRootURL else { return }
        let owned = ownsMountedRoot
        mountedRootURL = nil
        mountedShareName = nil
        ownsMountedRoot = false
        isMountedReady = false
        guard owned else { return }
        await MountGate.shared.withKey("browse:\(root.lastPathComponent)") {
            await SMBBackend.unmountAndRemoveDirectory(root)
        }
    }

    func resetToServerStep() async {
        loadTask?.cancel()
        loadTask = nil
        cancelSubfolderScan()
        await unmountCurrentShare()
        allShares = []
        enumerationUnsupported = false
        selectedShare = nil
        pathComponents = []
        subfolders = []
        hasScannedCurrentFolder = false
        scanStoppedDueToManyFiles = false
        isWritable = false
        errorMessage = nil
    }

    func cleanup() async {
        userCancelledConnect = true
        ActiveBrowseRegistry.shared.unregister(browseID)
        connectTask?.cancel()
        loadTask?.cancel()
        cancelSubfolderScan()
        await unmountCurrentShare()
    }
}
