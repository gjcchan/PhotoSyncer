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

nonisolated final class SFTPBackend: DestinationBackend, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let base: String
    private let pinnedKey: String?
    private let onNewHostKey: @Sendable (String) -> Void
    /// Bigger reads can stall inside swift-nio-ssh (the same limit Citadel works around for writes).
    private static let readChunk: UInt32 = 32_000
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    var localRoot: URL? { nil }

    init(dest: Destination, password: String, onNewHostKey: @escaping @Sendable (String) -> Void) {
        host = dest.host; port = dest.port; username = dest.username
        self.password = password
        base = dest.remotePath.trimmingCharacters(in: .whitespaces)
        pinnedKey = dest.trustedHostKey
        self.onNewHostKey = onNewHostKey
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
        do {
            let client = try await SSHClient.connect(to: settings)
            ssh = client
            sftp = try await withTimeout(30) { try await client.openSFTP() }
        } catch {
            throw Self.map(error, pinned: pinnedKey != nil)
        }
        if let captured = tofu.captured { onNewHostKey(captured) }
        try await ensureBase()
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

    private func client() throws -> SFTPClient {
        guard let sftp else { throw SyncError.destinationUnavailable("Not connected to the SFTP server") }
        return sftp
    }

    private func ensureBase() async throws {
        let sftp = try client()
        guard !base.isEmpty, base != "/" else { return }
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
        guard let sftp, sftp.isActive else { return false }
        let p = listPath
        return (try? await withTimeout(15) { try await sftp.getAttributes(at: p) }) != nil
    }

    // MARK: Listing
    private func rawList() async throws -> [RemoteFile] {
        let sftp = try client()
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
        try await rawList().filter { !$0.name.hasPrefix(".") }
    }

    func freeSpace() async -> Int64? { nil }     // not available over plain SFTP

    // MARK: Transfer
    /// Streams `local` to `remote`, then proves the server stored exactly those bytes.
    private func writeAndVerify(local: URL, to remote: String, size: UInt64, hash: String) async throws {
        let sftp = try client()
        var file: SFTPFile?
        do {
            let f = try await withTimeout(30) { try await sftp.openFile(filePath: remote, flags: [.write, .create, .truncate]) }
            file = f
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }
            var offset: UInt64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                let buffer = ByteBuffer(bytes: chunk)
                let at = offset
                try await withTimeout(120) { try await f.write(buffer, at: at) }
                offset += UInt64(chunk.count)
            }
            try await withTimeout(30) { try await f.close() }
            file = nil

            let remoteSize = try await withTimeout(30) { try await sftp.getAttributes(at: remote) }.size
            guard remoteSize == size else { throw SyncError.message("Copy verification failed: size mismatch on the SFTP server") }
            guard try await remoteHash(remote) == hash else {
                throw SyncError.message("Copy verification failed: checksum mismatch on the SFTP server")
            }
        } catch {
            if let file { try? await file.close() }
            throw error
        }
    }

    private func removeQuietly(_ remote: String) async {
        guard let sftp else { return }
        try? await withTimeout(30) { try await sftp.remove(at: remote) }
    }

    /// Strict SFTP v3 servers reject Citadel's rename (it always sends a v5-style flags field).
    /// Once we see that, files are written under their final name directly, guarded by a marker.
    private var renameUnsupported = false

    func upload(local: URL, as name: String, size: UInt64, hash: String, date: Date?) async throws {
        let sftp = try client()
        let final = path(name)

        if !renameUnsupported {
            let partial = path(".\(UUID().uuidString).partial")
            do {
                try await writeAndVerify(local: local, to: partial, size: size, hash: hash)
                do {
                    try await withTimeout(30) { try await sftp.rename(at: partial, to: final) }
                    return
                } catch is SFTPMessage.Status {
                    renameUnsupported = true            // fall through to direct mode below
                }
            } catch {
                await removeQuietly(partial)
                throw Self.map(error, pinned: pinnedKey != nil)
            }
            await removeQuietly(partial)
        }

        // Direct mode. Never overwrite something that is already there.
        if (try? await withTimeout(30) { try await sftp.getAttributes(at: final) }) != nil {
            throw SyncError.message("\(name) already exists on the SFTP server")
        }
        let marker = path(".\(name).inflight")
        do {
            let m = try await withTimeout(30) { try await sftp.openFile(filePath: marker, flags: [.write, .create, .truncate]) }
            try await withTimeout(30) { try await m.close() }
            try await writeAndVerify(local: local, to: final, size: size, hash: hash)
            await removeQuietly(marker)
        } catch {
            await removeQuietly(final)
            await removeQuietly(marker)
            throw Self.map(error, pinned: pinnedKey != nil)
        }
    }

    private func remoteHash(_ remotePath: String) async throws -> String {
        let sftp = try client()
        let f = try await withTimeout(30) { try await sftp.openFile(filePath: remotePath, flags: .read) }
        do {
            var hasher = SHA256()
            var offset: UInt64 = 0
            while true {
                let at = offset
                let buf = try await withTimeout(120) { try await f.read(from: at, length: Self.readChunk) }
                if buf.readableBytes == 0 { break }
                hasher.update(data: Data(buf.readableBytesView))
                offset += UInt64(buf.readableBytes)
            }
            try? await f.close()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? await f.close()
            throw Self.map(error, pinned: pinnedKey != nil)
        }
    }

    func hash(of name: String, noCache: Bool) async throws -> String {
        try await remoteHash(path(name))
    }

    func download(name: String, to local: URL) async throws -> Date? {
        let sftp = try client()
        let remote = path(name)
        try? FileManager.default.removeItem(at: local)
        guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
            throw SyncError.message("Cannot create a local staging file")
        }
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        let f = try await withTimeout(30) { try await sftp.openFile(filePath: remote, flags: .read) }
        do {
            var offset: UInt64 = 0
            while true {
                let at = offset
                let buf = try await withTimeout(120) { try await f.read(from: at, length: Self.readChunk) }
                if buf.readableBytes == 0 { break }
                try out.write(contentsOf: Data(buf.readableBytesView))
                offset += UInt64(buf.readableBytes)
            }
            try? await f.close()
        } catch {
            try? await f.close()
            throw Self.map(error, pinned: pinnedKey != nil)
        }
        return nil
    }

    func delete(name: String) async throws {
        let sftp = try client()
        let p = path(name)
        do { try await withTimeout(30) { try await sftp.remove(at: p) } }
        catch { throw Self.map(error, pinned: pinnedKey != nil) }
    }

    func cleanup() async {
        guard sftp != nil, let all = try? await rawList() else { return }
        for f in all where f.name.hasPrefix(".") {
            if f.name.hasSuffix(".partial") {
                await removeQuietly(path(f.name))
            } else if f.name.hasSuffix(".inflight") {
                // An upload was interrupted: its half-written target must not be mistaken for a real file.
                let target = String(f.name.dropFirst().dropLast(".inflight".count))
                await removeQuietly(path(target))
                await removeQuietly(path(f.name))
            }
        }
    }

    func close() async {
        if let sftp { try? await sftp.close() }
        if let ssh { try? await ssh.close() }
        sftp = nil; ssh = nil
    }
}
