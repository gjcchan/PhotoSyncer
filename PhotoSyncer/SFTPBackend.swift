import Foundation
import Combine
import CryptoKit
import Citadel
import NIOCore
import NIOSSH

// MARK: - SFTP

/// Trust on first use: remembers the host key the server presents so it can be pinned.
nonisolated final class TOFUValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    var captured: String? { lock.lock(); defer { lock.unlock() }; return key }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.lock(); key = String(openSSHPublicKey: hostKey); lock.unlock()
        validationCompletePromise.succeed(())
    }
}

nonisolated enum HostKey {
    /// "SHA256:abc…" fingerprint, as shown by `ssh-keygen -l`.
    static func fingerprint(_ openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSHKey }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}

/// `SFTPFile` mutates `isActive` only inside `close()`, while `read` and `<= 32_000`-byte `write`
/// submit directly onto `SFTPClient`'s thread-safe NIO `EventLoop` with atomic request IDs.
private nonisolated struct PipelinedSFTPFile: @unchecked Sendable {
    let file: SFTPFile
}

private nonisolated final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

nonisolated final class SFTPBackend: DestinationBackend, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let base: String
    private let allowCreateBase: Bool
    private let pinnedKey: String?
    private let onNewHostKey: @Sendable (String) -> Void

    /// Max SFTP packet slice size safe for `swift-nio-ssh` framing, paired with an 8-packet (256 KB)
    /// per-file sliding window and up to 4 multiplexed SFTP channels over 1 SSH connection.
    private static let packetSliceBytes = 32_000
    private static let pipelineDepth = 8
    private static let targetChannels = 4

    private let stateLock = NSLock()
    private var ssh: SSHClient?
    private var pool: AsyncResourcePool<SFTPClient>?
    /// Strict SFTP v3 servers reject Citadel's rename (it always sends a v5-style flags field).
    /// Once we see that, files are written under their final name directly, guarded by a marker.
    private let renameUnsupported = AtomicFlag()

    var localRoot: URL? { nil }

    init(dest: Destination, password: String, allowCreateBase: Bool = true,
         onNewHostKey: @escaping @Sendable (String) -> Void) {
        host = dest.host; port = dest.port; username = dest.username
        self.password = password
        base = dest.remotePath.trimmingCharacters(in: .whitespaces)
        self.allowCreateBase = allowCreateBase
        pinnedKey = dest.trustedHostKey
        self.onNewHostKey = onNewHostKey
    }

    private var currentPool: AsyncResourcePool<SFTPClient>? {
        stateLock.withLock { pool }
    }

    private func setSession(ssh client: SSHClient, pool createdPool: AsyncResourcePool<SFTPClient>) {
        stateLock.withLock {
            ssh = client
            pool = createdPool
        }
    }

    private func takeSession() -> (AsyncResourcePool<SFTPClient>?, SSHClient?) {
        stateLock.withLock {
            let p = pool
            let c = ssh
            pool = nil
            ssh = nil
            return (p, c)
        }
    }

    private func withChannel<T: Sendable>(_ op: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        guard let p = currentPool else {
            throw SyncError.destinationUnavailable("Not connected to the SFTP server")
        }
        return try await p.withResource(op)
    }

    // MARK: Connection
    func connect() async throws {
        let tofu = TOFUValidator()
        let validator: SSHHostKeyValidator
        if let pinned = pinnedKey {
            guard let key = try? NIOSSHPublicKey(openSSHPublicKey: pinned) else {
                throw SyncError.message("The pinned SFTP host key is invalid. Forget it in Settings and reconnect.")
            }
            validator = .trustedKeys([key])
        } else {
            validator = .custom(tofu)
        }
        let user = username, pw = password
        var settings = SSHClientSettings(host: host, port: port,
                                         authenticationMethod: { .passwordBased(username: user, password: pw) },
                                         hostKeyValidator: validator)
        settings.connectTimeout = .seconds(20)

        let client: SSHClient
        let primarySFTP: SFTPClient
        do {
            let c = try await SSHClient.connect(to: settings)
            client = c
            do {
                primarySFTP = try await withTimeout(30) { try await c.openSFTP() }
            } catch {
                try? await c.close()
                throw error
            }
        } catch {
            throw Self.map(error, pinned: pinnedKey != nil)
        }
        if let captured = tofu.captured { onNewHostKey(captured) }

        do {
            try await ensureBase(using: primarySFTP)
        } catch {
            try? await withTimeout(5) { try await primarySFTP.close() }
            try? await withTimeout(5) { try await client.close() }
            throw error
        }

        // Open up to `targetChannels` multiplexed SFTP subsystem channels over the single SSH session
        // (OpenSSH defaults to MaxSessions = 10; if a server caps MaxSessions lower, fall back cleanly).
        var channels: [SFTPClient] = [primarySFTP]
        for _ in 1..<Self.targetChannels {
            if let extra = try? await withTimeout(8, { try await client.openSFTP() }) {
                channels.append(extra)
            } else {
                break
            }
        }

        setSession(ssh: client, pool: AsyncResourcePool(channels))
    }

    fileprivate static func map(_ error: Error, pinned: Bool) -> Error {
        if error is SyncError { return error }
        if let status = error as? SFTPMessage.Status {
            let detail = status.message.isEmpty ? String(describing: status.errorCode) : status.message
            return SyncError.message("The SFTP server reported an error: \(detail)")
        }
        let text = String(describing: error).lowercased()
        if text.contains("authentication") {
            return SyncError.message("SFTP login failed – check the username and password.")
        }
        if pinned && (text.contains("hostkey") || text.contains("host key") || text.contains("validat")) {
            return SyncError.message("The SFTP server's host key does not match the pinned key (the server changed, or someone is intercepting the connection). Forget the host key in Settings if you trust the change.")
        }
        return SyncError.destinationUnavailable("SFTP server unreachable: \(error.localizedDescription)")
    }

    private func path(_ name: String) -> String {
        base.isEmpty ? name : (base.hasSuffix("/") ? base + name : base + "/" + name)
    }

    private var listPath: String { base.isEmpty ? "." : base }

    private func ensureBase(using sftp: SFTPClient) async throws {
        guard !base.isEmpty, base != "/" else { return }
        if !allowCreateBase {
            let target = base
            guard (try? await withTimeout(30) { try await sftp.getAttributes(at: target) }) != nil else {
                throw SyncError.destinationUnavailable(
                    "Remote folder \(target) is missing on \(host) (backing volume unmounted on the server?)")
            }
            return
        }
        var cur = base.hasPrefix("/") ? "/" : ""
        for comp in base.split(separator: "/") {
            cur = (cur.isEmpty || cur == "/") ? cur + comp : cur + "/" + comp
            let p = cur
            if (try? await withTimeout(30) { try await sftp.getAttributes(at: p) }) == nil {
                do { try await withTimeout(30) { try await sftp.createDirectory(atPath: p) } }
                catch { throw SyncError.message("Cannot create the remote folder \(p): \(error.localizedDescription)") }
            }
        }
    }

    func isAvailable() async -> Bool {
        let p = listPath
        return (try? await withChannel { sftp in
            guard sftp.isActive else { throw SyncError.destinationUnavailable("SFTP channel inactive") }
            _ = try await withTimeout(15) { try await sftp.getAttributes(at: p) }
            return true
        }) == true
    }

    // MARK: Listing
    private func rawList(using sftp: SFTPClient) async throws -> [RemoteFile] {
        let p = listPath
        let names: [SFTPMessage.Name]
        do { names = try await withTimeout(60) { try await sftp.listDirectory(atPath: p) } }
        catch { throw Self.map(error, pinned: pinnedKey != nil) }
        var seen = Set<String>()
        var out: [RemoteFile] = []
        for n in names {
            for c in n.components where c.filename != "." && c.filename != ".." {
                let isRegular = c.longname.first == "-" || ((c.attributes.permissions ?? 0) & 0o170000) == 0o100000
                guard isRegular, seen.insert(c.filename).inserted else { continue }
                out.append(RemoteFile(name: c.filename, size: c.attributes.size ?? 0))
            }
        }
        return out
    }

    func list() async throws -> [RemoteFile] {
        try await withChannel { sftp in
            try await self.rawList(using: sftp).filter { !$0.name.hasPrefix(".") }
        }
    }

    func freeSpace() async -> Int64? { nil }     // not available over plain SFTP

    // MARK: Pipelined Transfer & Verification
    /// Streams `local` to `remote` using an 8 × 32 KB pipelined write window, then reads every byte
    /// back with an 8 × 32 KB pipelined read window to prove size + SHA-256 on the server.
    private func writeAndVerify(using sftp: SFTPClient, local: URL, to remote: String, size: UInt64, hash: String) async throws {
        var openHandle: SFTPFile?
        do {
            let f = try await withTimeout(30) { try await sftp.openFile(filePath: remote, flags: [.write, .create, .truncate]) }
            openHandle = f
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }

            let sendableFile = PipelinedSFTPFile(file: f)
            let written = try await PipelinedChunkWriter.writeAll(
                from: input,
                chunkSize: Self.packetSliceBytes,
                windowDepth: Self.pipelineDepth
            ) { offset, sliceData in
                let buf = ByteBuffer(bytes: sliceData)
                try await withTimeout(120) { try await sendableFile.file.write(buf, at: offset) }
            }
            try await withTimeout(30) { try await f.close() }
            openHandle = nil

            guard written == size else {
                throw SyncError.message("Copy verification failed: size mismatch on the SFTP server")
            }
            let (readHash, readSize) = try await remoteHashAndSize(using: sftp, remotePath: remote, knownSize: size)
            guard readSize == size else {
                throw SyncError.message("Copy verification failed: size mismatch on the SFTP server")
            }
            guard readHash == hash else {
                throw SyncError.message("Copy verification failed: checksum mismatch on the SFTP server")
            }
        } catch {
            if let openHandle { try? await withTimeout(5) { try await openHandle.close() } }
            throw error
        }
    }

    private func removeQuietly(using sftp: SFTPClient, _ remote: String) async {
        guard sftp.isActive else { return }
        try? await withTimeout(30) { try await sftp.remove(at: remote) }
    }

    func upload(local: URL, as name: String, size: UInt64, hash: String, date: Date?) async throws {
        try await withChannel { sftp in
            try await self.uploadOnChannel(sftp: sftp, local: local, as: name, size: size, hash: hash)
        }
    }

    private func uploadOnChannel(sftp: SFTPClient, local: URL, as name: String, size: UInt64, hash: String) async throws {
        let final = path(name)

        if !renameUnsupported.value {
            let token = UUID().uuidString.prefix(8)
            let partial = path(".\(name).\(token).partial")
            var renamed = false
            do {
                try await writeAndVerify(using: sftp, local: local, to: partial, size: size, hash: hash)
                do {
                    try await withTimeout(30) { try await sftp.rename(at: partial, to: final) }
                    renamed = true
                    return
                } catch is SFTPMessage.Status {
                    if (try? await withTimeout(30) { try await sftp.getAttributes(at: final) }) != nil {
                        let matches = (try? await remoteHashAndSize(using: sftp, remotePath: final, knownSize: size).hash) == hash
                        await removeQuietly(using: sftp, partial)
                        if matches { return }
                        throw SyncError.message("\(name) already exists on the SFTP server")
                    }
                    renameUnsupported.value = true            // fall through to direct mode below
                }
            } catch {
                if !renamed { await removeQuietly(using: sftp, partial) }
                throw Self.map(error, pinned: pinnedKey != nil)
            }
            if !renamed { await removeQuietly(using: sftp, partial) }
        }

        // Direct mode (strict SFTP v3 servers without rename). Never overwrite something already there unless its checksum matches.
        let marker = path(".\(name).inflight")
        if (try? await withTimeout(30) { try await sftp.getAttributes(at: marker) }) != nil {
            await removeQuietly(using: sftp, final)
            await removeQuietly(using: sftp, marker)
        }
        if (try? await withTimeout(30) { try await sftp.getAttributes(at: final) }) != nil {
            if (try? await remoteHashAndSize(using: sftp, remotePath: final, knownSize: size).hash) == hash { return }
            throw SyncError.message("\(name) already exists on the SFTP server")
        }
        do {
            let m = try await withTimeout(30) { try await sftp.openFile(filePath: marker, flags: [.write, .create, .truncate]) }
            try await withTimeout(30) { try await m.close() }
            try await writeAndVerify(using: sftp, local: local, to: final, size: size, hash: hash)
            await removeQuietly(using: sftp, marker)
        } catch {
            await removeQuietly(using: sftp, final)
            await removeQuietly(using: sftp, marker)
            throw Self.map(error, pinned: pinnedKey != nil)
        }
    }

    private func remoteHashAndSize(using sftp: SFTPClient, remotePath: String, knownSize: UInt64?) async throws -> (hash: String, size: UInt64) {
        let resolvedSize: UInt64?
        if let knownSize {
            resolvedSize = knownSize
        } else {
            resolvedSize = (try? await withTimeout(30) { try await sftp.getAttributes(at: remotePath) })?.size
        }

        let f = try await withTimeout(30) { try await sftp.openFile(filePath: remotePath, flags: .read) }
        do {
            var hasher = SHA256()
            var totalBytes: UInt64 = 0

            if let fileSize = resolvedSize {
                if fileSize > 0 {
                    let sendableFile = PipelinedSFTPFile(file: f)
                    totalBytes = try await PipelinedChunkReader.readOrdered(
                        totalSize: fileSize,
                        chunkSize: UInt32(Self.packetSliceBytes),
                        windowDepth: Self.pipelineDepth,
                        fetchChunk: { offset, length in
                            let buf = try await withTimeout(120) {
                                try await sendableFile.file.read(from: offset, length: length)
                            }
                            return Data(buf.readableBytesView)
                        },
                        onOrderedChunk: { chunk in
                            hasher.update(data: chunk)
                        }
                    )
                }
            } else {
                var offset: UInt64 = 0
                while true {
                    let at = offset
                    let buf = try await withTimeout(120) {
                        try await f.read(from: at, length: UInt32(Self.packetSliceBytes))
                    }
                    if buf.readableBytes == 0 { break }
                    hasher.update(data: Data(buf.readableBytesView))
                    offset += UInt64(buf.readableBytes)
                }
                totalBytes = offset
            }

            try? await withTimeout(15) { try await f.close() }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (hex, totalBytes)
        } catch {
            try? await withTimeout(5) { try await f.close() }
            throw Self.map(error, pinned: pinnedKey != nil)
        }
    }

    func hash(of name: String, noCache: Bool) async throws -> String {
        try await withChannel { sftp in
            (try await self.remoteHashAndSize(using: sftp, remotePath: self.path(name), knownSize: nil)).hash
        }
    }

    func download(name: String, to local: URL) async throws -> Date? {
        try await withChannel { sftp in
            try await self.downloadOnChannel(sftp: sftp, name: name, to: local)
        }
    }

    private func downloadOnChannel(sftp: SFTPClient, name: String, to local: URL) async throws -> Date? {
        let remote = path(name)
        try? FileManager.default.removeItem(at: local)
        guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
            throw SyncError.message("Cannot create a local staging file")
        }
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }

        let knownSize = (try? await withTimeout(30) { try await sftp.getAttributes(at: remote) })?.size
        let f = try await withTimeout(30) { try await sftp.openFile(filePath: remote, flags: .read) }
        do {
            if let fileSize = knownSize {
                if fileSize > 0 {
                    let sendableFile = PipelinedSFTPFile(file: f)
                    _ = try await PipelinedChunkReader.readOrdered(
                        totalSize: fileSize,
                        chunkSize: UInt32(Self.packetSliceBytes),
                        windowDepth: Self.pipelineDepth,
                        fetchChunk: { offset, length in
                            let buf = try await withTimeout(120) {
                                try await sendableFile.file.read(from: offset, length: length)
                            }
                            return Data(buf.readableBytesView)
                        },
                        onOrderedChunk: { chunk in
                            try out.write(contentsOf: chunk)
                        }
                    )
                }
            } else {
                var offset: UInt64 = 0
                while true {
                    let at = offset
                    let buf = try await withTimeout(120) {
                        try await f.read(from: at, length: UInt32(Self.packetSliceBytes))
                    }
                    if buf.readableBytes == 0 { break }
                    try out.write(contentsOf: Data(buf.readableBytesView))
                    offset += UInt64(buf.readableBytes)
                }
            }
            try? await withTimeout(15) { try await f.close() }
        } catch {
            try? await withTimeout(5) { try await f.close() }
            throw Self.map(error, pinned: pinnedKey != nil)
        }
        return nil
    }

    func delete(name: String) async throws {
        let p = path(name)
        try await withChannel { sftp in
            do { try await withTimeout(30) { try await sftp.remove(at: p) } }
            catch { throw Self.map(error, pinned: self.pinnedKey != nil) }
        }
    }

    func readCanary() async throws -> String? {
        let p = path(FileNames.canaryName)
        return try await withChannel { sftp in
            guard (try? await withTimeout(15) { try await sftp.getAttributes(at: p) }) != nil else { return nil }
            let f = try await withTimeout(15) { try await sftp.openFile(filePath: p, flags: .read) }
            do {
                let buf = try await withTimeout(15) { try await f.read(from: 0, length: 256) }
                try? await withTimeout(5) { try await f.close() }
                let text = String(data: Data(buf.readableBytesView), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (text?.isEmpty == false) ? text : nil
            } catch {
                try? await withTimeout(5) { try await f.close() }
                throw Self.map(error, pinned: self.pinnedKey != nil)
            }
        }
    }

    func writeCanary(_ id: String) async throws {
        let p = path(FileNames.canaryName)
        try await withChannel { sftp in
            let f = try await withTimeout(15) { try await sftp.openFile(filePath: p, flags: [.write, .create, .truncate]) }
            do {
                let buffer = ByteBuffer(bytes: Array((id + "\n").utf8))
                try await withTimeout(15) { try await f.write(buffer, at: 0) }
                try await withTimeout(15) { try await f.close() }
            } catch {
                try? await withTimeout(5) { try await f.close() }
                throw Self.map(error, pinned: self.pinnedKey != nil)
            }
        }
    }

    func cleanup() async {
        guard let p = currentPool else { return }
        _ = try? await p.withResource { sftp in
            guard let all = try? await self.rawList(using: sftp) else { return }
            for f in all where f.name.hasPrefix(".") {
                if f.name.hasSuffix(".partial") {
                    await self.removeQuietly(using: sftp, self.path(f.name))
                } else if f.name.hasSuffix(".inflight") {
                    // An upload was interrupted: its half-written target must not be mistaken for a real file.
                    let target = String(f.name.dropFirst().dropLast(".inflight".count))
                    await self.removeQuietly(using: sftp, self.path(target))
                    await self.removeQuietly(using: sftp, self.path(f.name))
                }
            }
        }
    }

    func close() async {
        let (activePool, sshClient) = takeSession()

        if let activePool {
            let channels = await activePool.drainForClose()
            for ch in channels {
                _ = try? await withTimeout(5, timeoutMessage: "SFTP close timed out") { try await ch.close() }
            }
        }
        if let sshClient {
            _ = try? await withTimeout(5, timeoutMessage: "SSH close timed out") { try await sshClient.close() }
        }
    }
}

// MARK: - Interactive SFTP Wizard Browse Session

struct SFTPLocationShortcut: Identifiable, Hashable, Sendable {
    var id: String { path }
    var title: String
    var path: String
    var systemImage: String
}

/// Drives the Connect-to-Server style SFTP wizard: authenticates over SSH (capturing the server's
/// OpenSSH host key for TOFU pinning), resolves the user's home directory via `SSH_FXP_REALPATH`,
/// validates folders in single-packet `SSH_FXP_STAT` checks (~15ms without listing 30,000+ files),
/// and browses or creates remote folders over the live encrypted SFTP session.
@MainActor
final class SFTPBrowseSession: ObservableObject {
    @Published private(set) var connectedHost = ""
    @Published private(set) var connectedPort = Destination.defaultSFTPPort
    @Published private(set) var connectedUsername = ""
    private var connectedPassword = ""
    @Published private(set) var connectedHostKey = ""
    @Published private(set) var hostKeyFingerprint = ""

    @Published private(set) var homePath = "/"
    @Published private(set) var customLocations: [String] = []
    @Published private(set) var currentPath = "/"
    @Published private(set) var subfolders: [String] = []
    @Published private(set) var hasHiddenSubfolders = false
    @Published var showHiddenFolders = false {
        didSet {
            if showHiddenFolders != oldValue && hasScannedCurrentFolder {
                applySubfolderFilter()
            }
        }
    }

    @Published private(set) var isWritable = true
    @Published private(set) var isReady = false
    @Published private(set) var hasScannedCurrentFolder = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingFolder = false
    @Published private(set) var isScanningSubfolders = false
    @Published var errorMessage: String?

    private var allDiscoveredSubfolders: [String] = []
    private var sshClient: SSHClient?
    private var controlSFTP: SFTPClient?
    private var activeScanChannel: SFTPClient?
    private var userCancelledConnect = false
    private var connectTask: Task<Bool, Never>?
    private var navTask: Task<Bool, Never>?
    private var scanTask: Task<Void, Never>?

    var sidebarLocations: [SFTPLocationShortcut] {
        var items: [SFTPLocationShortcut] = [
            SFTPLocationShortcut(title: "Home", path: homePath, systemImage: "house")
        ]
        if homePath != "/" {
            items.append(SFTPLocationShortcut(title: "Server Root (/)", path: "/", systemImage: "internaldrive"))
        }
        for custom in customLocations where custom != homePath && custom != "/" {
            let label = URL(fileURLWithPath: custom).lastPathComponent
            items.append(SFTPLocationShortcut(
                title: label.isEmpty ? custom : label,
                path: custom,
                systemImage: "folder"
            ))
        }
        return items
    }

    var breadcrumbs: [(label: String, fullPath: String)] {
        SFTPPath.breadcrumbs(for: currentPath)
    }

    var parentPath: String? {
        SFTPPath.parent(of: currentPath)
    }

    var currentFolderDisplayName: String {
        if currentPath == "/" { return "/" }
        let last = URL(fileURLWithPath: currentPath).lastPathComponent
        return last.isEmpty ? currentPath : last
    }

    var defaultDestinationName: String {
        if currentPath == "/" { return connectedHost }
        return "\(connectedHost)/\(currentFolderDisplayName)"
    }

    var targetPreviewURLString: String {
        let portPart = connectedPort == Destination.defaultSFTPPort ? "" : ":\(connectedPort)"
        return "sftp://\(connectedUsername)@\(connectedHost)\(portPart)\(currentPath)"
    }

    func cancelConnect() {
        userCancelledConnect = true
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
    }

    func connect(serverInput: String,
                 port: Int,
                 username: String,
                 password: String) async -> Bool {
        guard !isConnecting else { return false }
        guard let endpoint = SFTPServerEndpoint.parse(serverInput, defaultPort: port) else {
            errorMessage = "Enter a valid server hostname or IP address (for example, nas.local or 192.168.1.20)."
            return false
        }
        let resolvedUser = username.trimmingCharacters(in: .whitespaces).isEmpty
            ? (endpoint.usernameHint ?? "")
            : username.trimmingCharacters(in: .whitespaces)
        if resolvedUser.isEmpty {
            errorMessage = "Enter your SSH username for \(endpoint.host)."
            return false
        }
        if password.isEmpty {
            errorMessage = "Enter your SSH password for \(endpoint.host)."
            return false
        }

        userCancelledConnect = false
        errorMessage = nil
        isConnecting = true

        let task = Task<Bool, Never> { @MainActor in
            await self.closeConnection()
            let tofu = TOFUValidator()
            var settings = SSHClientSettings(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: { .passwordBased(username: resolvedUser, password: password) },
                hostKeyValidator: .custom(tofu)
            )
            settings.connectTimeout = .seconds(20)

            do {
                let ssh = try await SSHClient.connect(to: settings)
                if Task.isCancelled {
                    try? await ssh.close()
                    throw CancellationError()
                }
                let sftp: SFTPClient
                do {
                    sftp = try await withTimeout(25) { try await ssh.openSFTP() }
                } catch {
                    try? await ssh.close()
                    throw error
                }

                let rawHome = (try? await withTimeout(15) { try await sftp.getRealPath(atPath: ".") }) ?? "/"
                let normalizedHome = SFTPPath.normalize(rawHome)
                let capturedKey = tofu.captured ?? ""

                self.sshClient = ssh
                self.controlSFTP = sftp
                self.connectedHost = endpoint.host
                self.connectedPort = endpoint.port
                self.connectedUsername = resolvedUser
                self.connectedPassword = password
                self.connectedHostKey = capturedKey
                self.hostKeyFingerprint = capturedKey.isEmpty ? "Unknown" : HostKey.fingerprint(capturedKey)
                self.homePath = normalizedHome
                self.customLocations = []
                self.currentPath = normalizedHome
                self.allDiscoveredSubfolders = []
                self.subfolders = []
                self.hasHiddenSubfolders = false
                self.hasScannedCurrentFolder = false
                self.isReady = false
                self.isConnecting = false

                let initialTarget: String
                if let hint = endpoint.pathHint {
                    initialTarget = SFTPPath.resolve(hint, relativeTo: normalizedHome, homePath: normalizedHome)
                } else {
                    initialTarget = normalizedHome
                }

                Task { @MainActor in
                    let ok = await self.selectPath(initialTarget, scanSubfolders: false, fallbackToHome: initialTarget != normalizedHome)
                    if ok && initialTarget != normalizedHome && initialTarget != "/" {
                        self.pinCustomLocation(self.currentPath)
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
                let mapped = SFTPBackend.map(error, pinned: false)
                let msg = mapped.localizedDescription.isEmpty
                    ? "Could not connect to \(endpoint.host)."
                    : mapped.localizedDescription
                self.errorMessage = msg
                EventLog.shared.error("SFTP wizard connect to \(endpoint.host) failed: \(msg)")
                return false
            }
        }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func pinCustomLocation(_ path: String) {
        let norm = SFTPPath.normalize(path)
        guard norm != homePath, norm != "/", !customLocations.contains(norm) else { return }
        customLocations.append(norm)
    }

    private func cancelSubfolderScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanningSubfolders = false
        if let ch = activeScanChannel {
            activeScanChannel = nil
            Task.detached(priority: .utility) {
                try? await withTimeout(3) { try await ch.close() }
            }
        }
    }

    @discardableResult
    func selectPath(_ rawTarget: String,
                    scanSubfolders: Bool = false,
                    recordLocation: Bool = false,
                    fallbackToHome: Bool = false) async -> Bool {
        navTask?.cancel()
        cancelSubfolderScan()

        guard let sftp = controlSFTP, sftp.isActive else {
            errorMessage = "The SFTP connection was closed. Click Back and reconnect."
            isReady = false
            isLoadingFolder = false
            return false
        }

        let resolvedTarget = SFTPPath.resolve(rawTarget, relativeTo: currentPath, homePath: homePath)
        errorMessage = nil
        isLoadingFolder = true

        let home = homePath
        let task = Task<Bool, Never> { @MainActor in
            do {
                let verified = try await Self.verifyRemoteDirectory(using: sftp, path: resolvedTarget)
                guard !Task.isCancelled else { return false }
                self.currentPath = verified.canonicalPath
                self.allDiscoveredSubfolders = []
                self.subfolders = []
                self.hasHiddenSubfolders = false
                self.hasScannedCurrentFolder = false
                self.isWritable = verified.writable
                self.isReady = true
                self.isLoadingFolder = false
                if recordLocation {
                    self.pinCustomLocation(verified.canonicalPath)
                }
                if !verified.writable {
                    self.errorMessage = "“\(verified.canonicalPath)” has read-only permissions on the server. Open or create a writable folder."
                }
                if scanSubfolders {
                    self.loadSubfolders()
                }
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                if fallbackToHome && resolvedTarget != home {
                    if let homeCheck = try? await Self.verifyRemoteDirectory(using: sftp, path: home), !Task.isCancelled {
                        self.currentPath = homeCheck.canonicalPath
                        self.allDiscoveredSubfolders = []
                        self.subfolders = []
                        self.hasHiddenSubfolders = false
                        self.hasScannedCurrentFolder = false
                        self.isWritable = homeCheck.writable
                        self.isReady = true
                        self.isLoadingFolder = false
                        self.errorMessage = "Folder “\(resolvedTarget)” wasn't found; opened your home folder instead."
                        return true
                    }
                }
                self.isLoadingFolder = false
                let mapped = SFTPBackend.map(error, pinned: false)
                self.errorMessage = mapped.localizedDescription
                return false
            }
        }
        navTask = task
        return await task.value
    }

    nonisolated private static func verifyRemoteDirectory(
        using sftp: SFTPClient,
        path: String
    ) async throws -> (canonicalPath: String, writable: Bool) {
        let canonicalRaw = try await withTimeout(15, timeoutMessage: "Checking the SFTP folder timed out") {
            try await sftp.getRealPath(atPath: path)
        }
        let canonical = SFTPPath.normalize(canonicalRaw)
        let attrs = try await withTimeout(15, timeoutMessage: "Checking the SFTP folder timed out") {
            try await sftp.getAttributes(at: canonical)
        }
        if let perms = attrs.permissions {
            let ftype = perms & 0o170000
            if ftype != 0 && ftype != 0o040000 {
                throw SyncError.message("“\(canonical)” is a file, not a folder.")
            }
            // Flag as read-only only when POSIX mode explicitly clears every write bit (`chmod a-w`, e.g. 0o555).
            if ftype == 0o040000 && (perms & 0o222) == 0 {
                return (canonical, false)
            }
        }
        return (canonical, true)
    }

    func openSubfolder(_ name: String) async {
        guard isReady else { return }
        let next = SFTPPath.join(currentPath, name)
        _ = await selectPath(next, scanSubfolders: true)
    }

    func navigateUp() async {
        guard isReady, let parent = parentPath else { return }
        _ = await selectPath(parent, scanSubfolders: true)
    }

    func createSubfolder(named rawName: String) async -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains("\\") {
            errorMessage = "Folder names cannot contain “/”, “\\”, or “..”."
            return false
        }
        guard isReady, let sftp = controlSFTP, sftp.isActive else { return false }
        let newPath = SFTPPath.join(currentPath, trimmed)
        errorMessage = nil
        isLoadingFolder = true
        do {
            try await withTimeout(15, timeoutMessage: "Creating the remote folder timed out") {
                try await sftp.createDirectory(atPath: newPath)
            }
            currentPath = newPath
            allDiscoveredSubfolders = []
            subfolders = []
            hasHiddenSubfolders = false
            hasScannedCurrentFolder = true
            isWritable = true
            isReady = true
            isLoadingFolder = false
            return true
        } catch {
            isLoadingFolder = false
            let mapped = SFTPBackend.map(error, pinned: false)
            errorMessage = "Could not create folder “\(trimmed)”: \(mapped.localizedDescription)"
            return false
        }
    }

    func loadSubfolders() {
        guard isReady, let ssh = sshClient, let fallbackSFTP = controlSFTP else { return }
        cancelSubfolderScan()
        let targetPath = currentPath
        isScanningSubfolders = true
        errorMessage = nil

        scanTask = Task { @MainActor [weak self] in
            var dedicatedChannel: SFTPClient?
            do {
                if let opened = try? await withTimeout(6, { try await ssh.openSFTP() }) {
                    dedicatedChannel = opened
                    self?.activeScanChannel = opened
                }
                let channel = dedicatedChannel ?? fallbackSFTP
                let dirs = try await Self.fetchDirectoryNamesOnly(using: channel, atPath: targetPath)
                if let dedicatedChannel {
                    self?.activeScanChannel = nil
                    Task.detached(priority: .utility) {
                        try? await withTimeout(3) { try await dedicatedChannel.close() }
                    }
                }
                guard let self, !Task.isCancelled, self.currentPath == targetPath else { return }
                self.allDiscoveredSubfolders = dirs
                self.hasHiddenSubfolders = dirs.contains { $0.hasPrefix(".") }
                self.applySubfolderFilter()
                self.hasScannedCurrentFolder = true
                self.isScanningSubfolders = false
            } catch is CancellationError {
                self?.isScanningSubfolders = false
            } catch {
                if let dedicatedChannel {
                    self?.activeScanChannel = nil
                    Task.detached(priority: .utility) {
                        try? await withTimeout(3) { try await dedicatedChannel.close() }
                    }
                }
                guard let self, !Task.isCancelled, self.currentPath == targetPath else { return }
                self.isScanningSubfolders = false
                let mapped = SFTPBackend.map(error, pinned: false)
                self.errorMessage = "Could not list subfolders: \(mapped.localizedDescription)"
            }
        }
    }

    private func applySubfolderFilter() {
        let filtered = showHiddenFolders
            ? allDiscoveredSubfolders
            : allDiscoveredSubfolders.filter { !$0.hasPrefix(".") }
        subfolders = filtered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func fetchDirectoryNamesOnly(
        using sftp: SFTPClient,
        atPath targetPath: String
    ) async throws -> [String] {
        let packets = try await withTimeout(90, timeoutMessage: "Listing SFTP subfolders timed out") {
            try await sftp.listDirectory(atPath: targetPath)
        }
        var seen = Set<String>()
        var dirs: [String] = []
        var symlinkCandidates: [String] = []

        for packet in packets {
            if Task.isCancelled { throw CancellationError() }
            for comp in packet.components {
                let name = comp.filename
                if name.isEmpty || name == "." || name == ".." { continue }
                guard seen.insert(name).inserted else { continue }

                let ftype = (comp.attributes.permissions ?? 0) & 0o170000
                let longFirst = comp.longname.first

                if ftype == 0o040000 || longFirst == "d" {
                    dirs.append(name)
                } else if ftype == 0o120000 || longFirst == "l" {
                    if symlinkCandidates.count < 64 {
                        symlinkCandidates.append(name)
                    }
                }
                // Regular files (`0o100000` / `"-"`) are skipped immediately without extra round-trips.
            }
        }

        for linkName in symlinkCandidates {
            if Task.isCancelled { throw CancellationError() }
            let full = SFTPPath.join(targetPath, linkName)
            if let attrs = try? await withTimeout(4, { try await sftp.getAttributes(at: full) }),
               ((attrs.permissions ?? 0) & 0o170000) == 0o040000 {
                dirs.append(linkName)
            }
        }

        return dirs
    }

    func buildDestination(customName: String) -> (destination: Destination, password: String)? {
        guard isReady, isWritable, !connectedHost.isEmpty, !connectedHostKey.isEmpty else { return nil }
        let trimmedCustom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedCustom.isEmpty ? defaultDestinationName : trimmedCustom
        let dest = Destination(
            name: finalName,
            kind: .sftp,
            host: connectedHost,
            port: connectedPort,
            username: connectedUsername,
            remotePath: currentPath,
            trustedHostKey: connectedHostKey
        )
        return (dest, connectedPassword)
    }

    private func closeConnection() async {
        cancelSubfolderScan()
        let sftp = controlSFTP
        let ssh = sshClient
        controlSFTP = nil
        sshClient = nil
        if let sftp {
            _ = try? await withTimeout(3) { try await sftp.close() }
        }
        if let ssh {
            _ = try? await withTimeout(3) { try await ssh.close() }
        }
    }

    func resetToServerStep() async {
        navTask?.cancel()
        navTask = nil
        await closeConnection()
        allDiscoveredSubfolders = []
        subfolders = []
        hasHiddenSubfolders = false
        hasScannedCurrentFolder = false
        isReady = false
        isWritable = true
        errorMessage = nil
    }

    func cleanup() async {
        userCancelledConnect = true
        connectTask?.cancel()
        navTask?.cancel()
        await closeConnection()
    }
}
