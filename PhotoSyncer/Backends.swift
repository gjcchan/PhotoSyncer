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
    /// Reads the hidden `.photosyncer-id` destination marker if present (nil when absent).
    func readCanary() async throws -> String?
    /// Writes the hidden `.photosyncer-id` destination marker so unmounted/wrong volumes are caught.
    func writeCanary(_ id: String) async throws
    func cleanup() async
    func close() async
}

// MARK: - Folder (local disk, USB drive, mounted NAS share)

nonisolated final class FolderBackend: DestinationBackend, @unchecked Sendable {
    private let url: URL
    private let securityScoped: Bool       // false for folders we created ourselves (e.g. inside our SMB mount)
    private var scoped = false

    init(url: URL, securityScoped: Bool = SandboxCompat.isSandboxed) {
        self.url = url
        self.securityScoped = securityScoped
    }
    var localRoot: URL? { url }

    func connect() async throws {
        if securityScoped {
            scoped = url.startAccessingSecurityScopedResource()
            guard scoped else { throw SyncError.message("Cannot access this folder. Remove it and add it again.") }
        }
        let target = url
        try await BlockingIO.run(timeout: 30, timeoutMessage: "The destination folder stopped responding") {
            try Self.validate(url: target)
        }
    }

    private static func validate(url: URL) throws {
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

    func isAvailable() async -> Bool {
        let target = url
        return (try? await BlockingIO.run(timeout: 15) { try Self.validate(url: target) }) != nil
    }

    func list() async throws -> [RemoteFile] {
        let target = url
        return try await BlockingIO.run(timeout: 300, timeoutMessage: "Listing the destination folder timed out") {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: target, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            } catch {
                throw SyncError.destinationUnavailable("Cannot read the folder: \(error.localizedDescription)")
            }
            return urls.compactMap { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { return nil }
                return RemoteFile(name: u.lastPathComponent, size: UInt64(v?.fileSize ?? 0))
            }
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
        let dir = url
        let token = UUID().uuidString.prefix(8)
        let partial = dir.appendingPathComponent(".\(name).\(token).partial")
        let final = dir.appendingPathComponent(name)
        var renamed = false
        defer {
            if !renamed {
                let path = partial.path
                Task.detached(priority: .utility) { _ = unlink(path) }
            }
        }
        try await VerifiedCopy.copy(from: local, to: partial, expectedHash: hash, expectedSize: size)
        do {
            try await Task.detached {
                let fm = FileManager.default
                if let date {
                    // Some NAS filesystems refuse this; the file itself is fine.
                    try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: partial.path)
                }
                try fm.moveItem(at: partial, to: final)
            }.value
            renamed = true
        } catch {
            let ns = error as NSError
            let isExist = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST))
                || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EEXIST) } ?? false)
            if isExist, (try? await FileHash.sha256(of: final, noCache: true)) == hash {
                return
            }
            throw error
        }
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

    func readCanary() async throws -> String? {
        let target = url.appendingPathComponent(FileNames.canaryName)
        return try await BlockingIO.run(timeout: 15) {
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            let data = try Data(contentsOf: target)
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
    }

    func writeCanary(_ id: String) async throws {
        let dir = url
        try await BlockingIO.run(timeout: 15) {
            let tmp = dir.appendingPathComponent("\(FileNames.canaryName).tmp")
            let final = dir.appendingPathComponent(FileNames.canaryName)
            unlink(tmp.path)
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
                throw SyncError.message("Cannot write destination marker")
            }
            let h = try FileHandle(forWritingTo: tmp)
            do {
                try h.write(contentsOf: Data((id + "\n").utf8))
                if fcntl(h.fileDescriptor, F_FULLFSYNC) == -1 { try? h.synchronize() }
                try h.close()
            } catch {
                try? h.close()
                unlink(tmp.path)
                throw error
            }
            guard Darwin.rename(tmp.path, final.path) == 0 else {
                let err = errno
                unlink(tmp.path)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
        }
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

/// Bounded FIFO pool of reusable async connections/channels (e.g. multiplexed `SFTPClient` subsystem
/// channels over a single authenticated SSH connection).
actor AsyncResourcePool<Resource: Sendable> {
    private var idle: [Resource]
    private var all: [Resource]
    private var closed = false
    private var waiters: [CheckedContinuation<Resource?, Never>] = []
    nonisolated let capacity: Int

    init(_ resources: [Resource]) {
        self.idle = resources
        self.all = resources
        self.capacity = resources.count
    }

    func withResource<T: Sendable>(
        unavailableError: Error = SyncError.destinationUnavailable("Not connected to the SFTP server"),
        _ body: @Sendable (Resource) async throws -> T
    ) async throws -> T {
        guard let res = await checkout() else {
            throw unavailableError
        }
        defer { checkin(res) }
        return try await body(res)
    }

    private func checkout() async -> Resource? {
        if closed || all.isEmpty { return nil }
        if !idle.isEmpty {
            return idle.removeFirst()
        }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func checkin(_ res: Resource) {
        if closed { return }
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume(returning: res)
        } else {
            idle.append(res)
        }
    }

    func drainForClose() -> [Resource] {
        closed = true
        idle.removeAll()
        let owned = all
        all.removeAll()
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume(returning: nil) }
        return owned
    }
}

/// Sliding-window pipelined chunk writer (e.g. keeping 8 × 32 KB `SSH_FXP_WRITE` packets in flight
/// continuously instead of waiting a full network RTT per 32 KB packet).
nonisolated enum PipelinedChunkWriter {
    static func writeAll(
        from handle: FileHandle,
        chunkSize: Int = 32_000,
        windowDepth: Int = 8,
        sendSlice: @escaping @Sendable (UInt64, Data) async throws -> Void
    ) async throws -> UInt64 {
        let step = max(chunkSize, 1)
        let depth = max(windowDepth, 1)
        var nextOffset: UInt64 = 0
        var reachedEOF = false

        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueueNext() throws -> Bool {
                guard !reachedEOF else { return false }
                guard let chunk = try handle.read(upToCount: step), !chunk.isEmpty else {
                    reachedEOF = true
                    return false
                }
                let offset = nextOffset
                nextOffset += UInt64(chunk.count)
                group.addTask {
                    try await sendSlice(offset, chunk)
                }
                return true
            }

            for _ in 0..<depth {
                if !(try enqueueNext()) { break }
            }
            while try await group.next() != nil {
                _ = try enqueueNext()
            }
        }
        return nextOffset
    }
}

/// Sliding-window pipelined chunk reader that keeps `windowDepth` (`8` × 32 KB) read requests in flight
/// concurrently while delivering bytes to `onOrderedChunk` (e.g. `SHA256` or `FileHandle`) in strict
/// sequential offset order with bounded memory (`<= windowDepth * chunkSize`).
nonisolated enum PipelinedChunkReader {
    static func readOrdered(
        totalSize: UInt64,
        chunkSize: UInt32 = 32_000,
        windowDepth: Int = 8,
        fetchChunk: @escaping @Sendable (UInt64, UInt32) async throws -> Data,
        onOrderedChunk: (Data) throws -> Void
    ) async throws -> UInt64 {
        guard totalSize > 0 else { return 0 }
        let step = UInt64(max(chunkSize, 1))
        let depth = max(windowDepth, 1)
        let totalSlots = Int((totalSize + step - 1) / step)

        var nextToLaunch = 0
        var nextToEmit = 0
        var ready: [Int: Data] = [:]
        var hitEarlyEOF = false
        var totalDelivered: UInt64 = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            func launchSlot() {
                guard !hitEarlyEOF, nextToLaunch < totalSlots else { return }
                let slot = nextToLaunch
                nextToLaunch += 1
                let start = UInt64(slot) * step
                let want = UInt32(min(step, totalSize - start))

                group.addTask {
                    var collected = Data()
                    collected.reserveCapacity(Int(want))
                    var curOffset = start
                    var remaining = want
                    while remaining > 0 {
                        let part = try await fetchChunk(curOffset, remaining)
                        if part.isEmpty { break }
                        collected.append(part)
                        let got = UInt32(min(part.count, Int(remaining)))
                        curOffset += UInt64(got)
                        remaining -= got
                    }
                    return (slot, collected)
                }
            }

            for _ in 0..<min(depth, totalSlots) {
                launchSlot()
            }

            while let (slot, data) = try await group.next() {
                ready[slot] = data
                while let chunk = ready.removeValue(forKey: nextToEmit) {
                    if !chunk.isEmpty {
                        try onOrderedChunk(chunk)
                        totalDelivered += UInt64(chunk.count)
                    }
                    let expectedSlotLen = Int(min(step, totalSize - UInt64(nextToEmit) * step))
                    if chunk.count < expectedSlotLen {
                        hitEarlyEOF = true
                    }
                    nextToEmit += 1
                    if hitEarlyEOF { break }
                }
                if !hitEarlyEOF {
                    launchSlot()
                }
            }
        }
        return totalDelivered
    }
}

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

// MARK: - SFTP Endpoint & Path Helpers

/// Parses flexible SFTP server inputs ("nas.local", "192.168.1.20:2222", "alice@nas.local:/volume1/Photos",
/// "alice@nas.local:~/Photos", or "sftp://alice@nas.local:2222/Photos") for the SFTP Connect-to-Server wizard.
nonisolated struct SFTPServerEndpoint: Equatable, Sendable {
    var host: String
    var port: Int
    var usernameHint: String?
    var pathHint: String?

    static func parse(_ rawInput: String, defaultPort: Int = Destination.defaultSFTPPort) -> SFTPServerEndpoint? {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let fallbackPort = (1...65_535).contains(defaultPort) ? defaultPort : Destination.defaultSFTPPort
        var scpPathHint: String?

        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard scheme == "sftp" || scheme == "ssh" else { return nil }
        } else {
            // Handle SCP-style `user@host:/remote/path` or `host:~/photos` without confusing `host:2222` or IPv6 `[::1]:2222`.
            let searchStart: String.Index
            if let closeBracket = text.firstIndex(of: "]") {
                searchStart = text.index(after: closeBracket)
            } else {
                searchStart = text.startIndex
            }
            if searchStart < text.endIndex,
               let colon = text[searchStart...].firstIndex(of: ":") {
                let afterColon = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                let isNumericPort = !afterColon.isEmpty && afterColon.allSatisfy(\.isNumber)
                if !isNumericPort {
                    if !afterColon.isEmpty {
                        scpPathHint = afterColon
                    }
                    text = String(text[..<colon])
                }
            }
            text = "sftp://" + text
        }

        guard let comps = URLComponents(string: text),
              let rawHost = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            return nil
        }

        if let p = comps.port, !(1...65_535).contains(p) {
            return nil
        }
        let resolvedPort = comps.port ?? fallbackPort
        let userHint = (comps.user?.isEmpty == false) ? comps.user : nil
        let urlPath = comps.path.trimmingCharacters(in: .whitespaces)
        let resolvedPathHint: String?
        if let scpPathHint {
            resolvedPathHint = scpPathHint
        } else if !urlPath.isEmpty {
            resolvedPathHint = urlPath
        } else {
            resolvedPathHint = nil
        }

        return SFTPServerEndpoint(
            host: rawHost,
            port: resolvedPort,
            usernameHint: userHint,
            pathHint: resolvedPathHint
        )
    }
}

/// Pure POSIX-style SFTP path manipulation (SFTP wire paths always use forward slashes `/`).
nonisolated enum SFTPPath {
    static func normalize(_ raw: String) -> String {
        let unified = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        var stack: [String] = []
        for part in unified.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(part))
            }
        }
        return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    static func join(_ base: String, _ child: String) -> String {
        let trimmedChild = child.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if trimmedChild.hasPrefix("/") {
            return normalize(trimmedChild)
        }
        let cleanBase = normalize(base)
        if cleanBase == "/" {
            return normalize("/" + trimmedChild)
        }
        return normalize(cleanBase + "/" + trimmedChild)
    }

    static func resolve(_ input: String, relativeTo currentPath: String, homePath: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if trimmed.isEmpty || trimmed == "." {
            return normalize(currentPath)
        }
        if trimmed == "~" {
            return normalize(homePath)
        }
        if trimmed.hasPrefix("~/") {
            return join(homePath, String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("/") {
            return normalize(trimmed)
        }
        return join(currentPath, trimmed)
    }

    static func parent(of path: String) -> String? {
        let norm = normalize(path)
        guard norm != "/" else { return nil }
        guard let slash = norm.lastIndex(of: "/") else { return nil }
        if slash == norm.startIndex { return "/" }
        return String(norm[..<slash])
    }

    static func breadcrumbs(for path: String) -> [(label: String, fullPath: String)] {
        let norm = normalize(path)
        var crumbs: [(label: String, fullPath: String)] = [("/", "/")]
        guard norm != "/" else { return crumbs }
        var running = ""
        for comp in norm.split(separator: "/") {
            let name = String(comp)
            running += "/" + name
            crumbs.append((name, running))
        }
        return crumbs
    }
}
