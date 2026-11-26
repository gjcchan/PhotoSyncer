import Foundation
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

    private static func map(_ error: Error, pinned: Bool) -> Error {
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
