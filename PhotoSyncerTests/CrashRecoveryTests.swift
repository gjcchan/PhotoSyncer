import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Testing
@testable import PhotoSyncer

@MainActor
struct CrashRecoveryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSyncerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func ledgerRecoversFromBackupWhenPrimaryCorrupted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = SyncedStore(legacyDestinationID: nil, directory: dir)
            // Initial save creates primary; second save rotates known-good primary to .bak.
            store.markCanaryWritten("dest-a")
            #expect(store.save() == true)

            let parts = [
                Part(hash: "hash-orig", type: 1, size: 4096),
                Part(hash: "hash-edit", type: 5, size: 2048),
            ]
            store.addPlacement("dest-a", hash: "hash-orig", name: "IMG_0001.HEIC", size: 4096)
            store.addPlacement("dest-a", hash: "hash-edit", name: "IMG_0001-edited.jpg", size: 2048)
            store.recordSynced(
                id: "asset-1",
                entry: Entry(parts: parts, verified: true, modifiedAt: t0),
                fingerprint: "IMG_0001.HEIC|1700000000|4032x3024|0"
            )
            store.queueDelete("asset-1")
            #expect(store.save() == true)
            // Save one more time so .bak holds the populated state.
            store.noteDuplicate()
            #expect(store.save() == true)
        }

        // Simulate a kernel panic / disk fault leaving the primary ledger corrupt.
        let primary = dir.appendingPathComponent("synced-ledger-v4.json")
        try Data("{truncated-json".utf8).write(to: primary)

        let recovered = SyncedStore(legacyDestinationID: nil, directory: dir)
        #expect(recovered.needsRebuild == false)
        #expect(recovered.entry("asset-1")?.verified == true)
        #expect(recovered.isComplete("asset-1", dest: "dest-a") == true)
        #expect(recovered.expectedSize("hash-orig") == 4096)
        #expect(recovered.expectedSize("hash-edit") == 2048)
        #expect(recovered.hasCanary("dest-a") == true)
        #expect(recovered.pendingDelete.contains("asset-1") == true)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("synced-ledger-v4.json.corrupt-") })
    }

    @Test func ledgerQuarantinesAndFlagsRebuildWhenBothCorrupted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = SyncedStore(legacyDestinationID: nil, directory: dir)
            store.addPlacement("dest-a", hash: "h1", name: "IMG_1.JPG", size: 100)
            #expect(store.save() == true)
            #expect(store.save() == true)
        }

        try Data("bad-primary".utf8).write(to: dir.appendingPathComponent("synced-ledger-v4.json"))
        try Data("bad-backup".utf8).write(to: dir.appendingPathComponent("synced-ledger-v4.json.bak"))

        let rebuilt = SyncedStore(legacyDestinationID: nil, directory: dir)
        #expect(rebuilt.needsRebuild == true)
        #expect(rebuilt.placementCount("dest-a") == 0)
    }

    @Test func missingPlacementsDetectsTruncatedAndZeroByteFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SyncedStore(legacyDestinationID: nil, directory: dir)
        store.addPlacement("dest-1", hash: "h1", name: "IMG_1.JPG", size: 1_000)
        store.addPlacement("dest-1", hash: "h2", name: "IMG_2.MOV", size: 50_000)
        store.addPlacement("dest-1", hash: "h3", name: "IMG_3.HEIC", size: 8_000)
        store.addPlacement("dest-1", hash: "h4", name: "IMG_4.PNG", size: 2_000)

        let existing: Set<String> = [
            FileNames.key("IMG_1.JPG"),
            FileNames.key("IMG_2.MOV"),
            FileNames.key("IMG_3.HEIC"),
        ]
        let sizes: [String: UInt64] = [
            FileNames.key("IMG_1.JPG"): 1_000,   // intact
            FileNames.key("IMG_2.MOV"): 0,       // 0-byte crash stub
            FileNames.key("IMG_3.HEIC"): 3_200,  // truncated / modified
        ]

        let result = store.missingPlacements(dest: "dest-1", existing: existing, sizes: sizes)
        #expect(result.total == 4)
        #expect(Set(result.missing) == Set(["h2", "h3", "h4"]))
        #expect(result.zeroByteKeys == [FileNames.key("IMG_2.MOV")])
    }

    @Test func postSyncEditTrackingDetectsNewEditsWithoutBreakingLegacyEntries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SyncedStore(legacyDestinationID: nil, directory: dir)
        store.recordSynced(
            id: "modern",
            entry: Entry(parts: [Part(hash: "h-mod", type: 1, size: 512)], verified: true, modifiedAt: t0),
            fingerprint: nil
        )
        store.recordSynced(
            id: "legacy-upgraded",
            entry: Entry(parts: [Part(hash: "h-leg", type: 1)], verified: true, modifiedAt: nil),
            fingerprint: nil
        )

        // Sub-second rounding jitter does not trigger re-export.
        #expect(store.needsEditRefresh("modern", modifiedAt: t0.addingTimeInterval(0.4)) == false)
        // Real edit advancing modificationDate triggers re-export.
        #expect(store.needsEditRefresh("modern", modifiedAt: t0.addingTimeInterval(5.0)) == true)
        // Metadata-only fast-path updates modifiedAt cleanly.
        let t1 = t0.addingTimeInterval(5.0)
        store.updateModifiedAt(id: "modern", modifiedAt: t1)
        #expect(store.needsEditRefresh("modern", modifiedAt: t1) == false)

        // Upgraded entries with nil modifiedAt are not needlessly re-downloaded unless flagged.
        #expect(store.needsEditRefresh("legacy-upgraded", modifiedAt: t1) == false)
        store.markNeedsEditSync("legacy-upgraded")
        #expect(store.needsEditRefresh("legacy-upgraded", modifiedAt: nil) == true)
    }

    @Test func folderBackendAtomicUploadPartialCleanupAndCanary() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest", isDirectory: true)
        let stageDir = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let backend = FolderBackend(url: destDir, securityScoped: false)
        try await backend.connect()

        // Write canary and plant crash leftovers (.partial and .photosyncer-export-*).
        try await backend.writeCanary("dest-uuid-123")
        try Data("half".utf8).write(to: destDir.appendingPathComponent(".IMG_0001.JPG.partial"))
        let leftoverExport = destDir.appendingPathComponent(".photosyncer-export-999", isDirectory: true)
        try FileManager.default.createDirectory(at: leftoverExport, withIntermediateDirectories: true)
        try Data("tmp".utf8).write(to: leftoverExport.appendingPathComponent("IMG_0001.JPG"))

        await backend.cleanup()
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent(".IMG_0001.JPG.partial").path) == false)
        #expect(FileManager.default.fileExists(atPath: leftoverExport.path) == false)
        #expect(try await backend.readCanary() == "dest-uuid-123")

        // Perform a full verified upload and verify uncached read-back + idempotency on existing file.
        let payload = Data(repeating: 0xAB, count: 65_536)
        let expectedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let stagedFile = stageDir.appendingPathComponent("staged.bin")
        try payload.write(to: stagedFile)

        try await backend.upload(local: stagedFile, as: "IMG_0001.JPG", size: UInt64(payload.count), hash: expectedHash, date: nil)
        // Re-uploading the exact same content when target already exists succeeds idempotently.
        try await backend.upload(local: stagedFile, as: "IMG_0001.JPG", size: UInt64(payload.count), hash: expectedHash, date: nil)

        let listing = try await backend.list()
        #expect(listing.count == 1)
        #expect(listing.first?.name == "IMG_0001.JPG")
        #expect(listing.first?.size == UInt64(payload.count))
        #expect(try await backend.hash(of: "IMG_0001.JPG", noCache: true) == expectedHash)

        // Flip one byte on disk to simulate silent bit-rot and verify uncached hash catches it.
        var corrupted = payload
        corrupted[100] ^= 0xFF
        try corrupted.write(to: destDir.appendingPathComponent("IMG_0001.JPG"))
        #expect(try await backend.hash(of: "IMG_0001.JPG", noCache: true) != expectedHash)
        await backend.close()
    }

    @Test func instanceLockEnforcesMutualExclusionAndReleasesCleanly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lock1 = InstanceLock(directory: dir)
        let lock2 = InstanceLock(directory: dir)
        #expect(lock1.acquire(retryTimeout: 0) == true)
        #expect(lock2.acquire(retryTimeout: 0.05) == false)

        lock1.release()
        #expect(lock2.acquire(retryTimeout: 0) == true)
        lock2.release()
    }

    @Test func rollingPlacementSliceWrapsDeterministicCursor() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SyncedStore(legacyDestinationID: nil, directory: dir)
        for i in 1...5 {
            store.addPlacement("dest-1", hash: "h\(i)", name: "IMG_000\(i).JPG", size: 100)
        }
        let s1 = store.placementSlice(dest: "dest-1", offset: 0, count: 3)
        #expect(s1.slice.count == 3)
        #expect(s1.nextOffset == 3)

        let s2 = store.placementSlice(dest: "dest-1", offset: s1.nextOffset, count: 3)
        #expect(s2.slice.count == 3)
        #expect(s2.nextOffset == 1)

        let visited = Set((s1.slice + s2.slice).map(\.hash))
        #expect(visited == Set(["h1", "h2", "h3", "h4", "h5"]))
    }

    @Test func destinationNameBookPreventsInFlightCollisionsAndRollsBackFailures() {
        var book = DestinationNameBook(listing: [RemoteFile(name: "Existing.JPG", size: 4096)])

        // Committed file cannot be reserved; can be locked once for adoption inspection.
        #expect(book.reserve("existing.jpg") == false)
        #expect(book.lockExistingForInspection("EXISTING.jpg") == true)
        #expect(book.unreservedExisting("Existing.JPG") == nil)   // locked while inspecting
        book.releaseReservation("EXISTING.jpg")
        #expect(book.unreservedExisting("Existing.JPG")?.size == 4096)

        // Worker 1 reserves IMG_1234.HEIC; Worker 2 (case-different) is blocked while in flight.
        #expect(book.reserve("IMG_1234.HEIC") == true)
        #expect(book.isOccupied("img_1234.heic") == true)
        #expect(book.reserve("img_1234.heic") == false)

        // Upload failure releases reservation so retry can claim IMG_1234.HEIC cleanly.
        book.releaseReservation("IMG_1234.HEIC")
        #expect(book.isOccupied("IMG_1234.HEIC") == false)
        #expect(book.reserve("IMG_1234.HEIC") == true)

        // Commit moves file from reservedNames into committed names.
        book.commitFile(name: "IMG_1234.HEIC", size: 8192)
        #expect(book.reservedNames.isEmpty)
        #expect(book.names.contains(FileNames.key("IMG_1234.HEIC")))
        #expect(book.sizes[FileNames.key("IMG_1234.HEIC")] == 8192)
    }

    @Test func syncPipelineGateEnforcesByteBudgetAndAllowsOversizedVideoSolo() async {
        // Max 4 workers, 150-byte budget -> 50-byte items cap at 3 concurrent; 600-byte video runs solo (1).
        let gate = SyncPipelineGate(maxWorkers: 4, maxInFlightBytes: 150)

        nonisolated final class PeakRecorder: @unchecked Sendable {
            private let lock = NSLock()
            var maxCount = 0
            var soloVideoObservedCount = 0
            func observe(count: Int, isOversized: Bool) {
                lock.lock()
                if count > maxCount { maxCount = count }
                if isOversized && count > soloVideoObservedCount { soloVideoObservedCount = count }
                lock.unlock()
            }
        }
        let recorder = PeakRecorder()

        await withTaskGroup(of: Void.self) { group in
            let costs: [Int64] = [50, 50, 50, 50, 600, 50, 50, 50]
            for cost in costs {
                group.addTask {
                    await gate.acquire(bytes: cost)
                    let cur = await gate.inFlightCount
                    recorder.observe(count: cur, isOversized: cost > 150)
                    try? await Task.sleep(for: .milliseconds(25))
                    await gate.release(bytes: cost)
                }
            }
        }

        #expect(recorder.maxCount <= 3)
        #expect(recorder.soloVideoObservedCount == 1)
        #expect(await gate.inFlightCount == 0)
        #expect(await gate.inFlightBytes == 0)
    }

    @Test func folderBackendHandlesConcurrentParallelUploadsCleanly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destDir = root.appendingPathComponent("dest", isDirectory: true)
        let stageDir = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let backend = FolderBackend(url: destDir, securityScoped: false)
        try await backend.connect()

        var inputs: [(staged: URL, target: String, size: UInt64, hash: String)] = []
        for i in 0..<8 {
            let data = Data((0..<(32_768 + i * 512)).map { UInt8(($0 + i) & 0xFF) })
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let staged = stageDir.appendingPathComponent("in-\(i).bin")
            try data.write(to: staged)
            inputs.append((staged, "IMG_000\(i).JPG", UInt64(data.count), hash))
        }
        // Also duplicate item 0 so two tasks race on the exact same target filename with identical content.
        inputs.append(inputs[0])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in inputs {
                group.addTask {
                    try await backend.upload(
                        local: item.staged,
                        as: item.target,
                        size: item.size,
                        hash: item.hash,
                        date: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                }
            }
            try await group.waitForAll()
        }

        let listing = try await backend.list()
        #expect(listing.count == 8)
        for item in inputs.dropLast() {
            #expect(try await backend.hash(of: item.target, noCache: true) == item.hash)
        }
        // Ensure zero hidden `.partial` files remain after concurrent uploads.
        let allEntries = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        #expect(allEntries.contains { $0.hasSuffix(".partial") } == false)
        await backend.close()
    }

    @Test func sftpPipelinedReaderWriterReassemblesOutOfOrderAndShortReads() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 200,123 bytes (non-multiple of 32,000) to exercise full slots, tail slot, short reads, and out-of-order replies.
        let original = Data((0..<200_123).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let expectedHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let srcURL = dir.appendingPathComponent("source.bin")
        try original.write(to: srcURL)

        nonisolated final class SimulatedRemoteBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: Data
            init(size: Int) { storage = Data(count: size) }
            func write(_ slice: Data, at offset: Int) {
                lock.lock()
                storage.replaceSubrange(offset ..< (offset + slice.count), with: slice)
                lock.unlock()
            }
            func shortRead(from offset: Int, maxLen: Int) -> Data {
                lock.lock(); defer { lock.unlock() }
                guard offset < storage.count else { return Data() }
                // Cap each read at 11,111 bytes to simulate SFTP servers returning short reads.
                let end = min(storage.count, offset + min(maxLen, 11_111))
                return Data(storage[offset..<end])
            }
        }

        let remote = SimulatedRemoteBuffer(size: original.count)
        let inHandle = try FileHandle(forReadingFrom: srcURL)
        defer { try? inHandle.close() }

        let written = try await PipelinedChunkWriter.writeAll(
            from: inHandle,
            chunkSize: 32_000,
            windowDepth: 8
        ) { offset, slice in
            // Reverse-skew delay so higher offsets finish before lower offsets (out-of-order completion).
            let delayMs = Int((7 - ((offset / 32_000) % 8)) * 2)
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            remote.write(slice, at: Int(offset))
        }
        #expect(written == UInt64(original.count))

        var hasher = SHA256()
        let readBackBytes = try await PipelinedChunkReader.readOrdered(
            totalSize: UInt64(original.count),
            chunkSize: 32_000,
            windowDepth: 8,
            fetchChunk: { offset, length in
                let delayMs = Int((7 - ((offset / 32_000) % 8)) * 2)
                if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                return remote.shortRead(from: Int(offset), maxLen: Int(length))
            },
            onOrderedChunk: { chunk in
                hasher.update(data: chunk)
            }
        )
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(readBackBytes == UInt64(original.count))
        #expect(actualHash == expectedHash)
    }

    @Test func asyncResourcePoolBoundsConcurrencyAndDrainsCleanly() async throws {
        let pool = AsyncResourcePool([0, 1, 2])
        #expect(pool.capacity == 3)

        nonisolated final class ConcurrencyTracker: @unchecked Sendable {
            private let lock = NSLock()
            var active = 0
            var peak = 0
            func enter() {
                lock.lock()
                active += 1
                if active > peak { peak = active }
                lock.unlock()
            }
            func leave() {
                lock.lock()
                active -= 1
                lock.unlock()
            }
        }
        let tracker = ConcurrencyTracker()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<9 {
                group.addTask {
                    try await pool.withResource { ch in
                        tracker.enter()
                        try? await Task.sleep(for: .milliseconds(15))
                        tracker.leave()
                        return ch
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(tracker.peak <= 3)

        let drained = await pool.drainForClose()
        #expect(drained.sorted() == [0, 1, 2])

        var threwAfterClose = false
        do {
            _ = try await pool.withResource { $0 }
        } catch {
            threwAfterClose = true
        }
        #expect(threwAfterClose == true)
    }

    @Test func smbWizardEndpointAndNetFSShareEnumerationParsing() throws {
        // Plain host, host:port, smb:// URL with user/share/subfolders, and Windows UNC path.
        #expect(SMBServerEndpoint.parse("   ") == nil)
        #expect(SMBServerEndpoint.parse("nas.local") == SMBServerEndpoint(
            host: "nas.local", port: 445, usernameHint: nil, shareHint: nil, subfolderHint: []
        ))
        #expect(SMBServerEndpoint.parse("192.168.1.20:10445") == SMBServerEndpoint(
            host: "192.168.1.20", port: 10445, usernameHint: nil, shareHint: nil, subfolderHint: []
        ))
        #expect(SMBServerEndpoint.parse("smb://alice@synology.local/Media/Photos/2026") == SMBServerEndpoint(
            host: "synology.local", port: 445, usernameHint: "alice", shareHint: "Media", subfolderHint: ["Photos", "2026"]
        ))
        #expect(SMBServerEndpoint.parse("\\\\192.168.1.50\\Backups\\iPhone") == SMBServerEndpoint(
            host: "192.168.1.50", port: 445, usernameHint: nil, shareHint: "Backups", subfolderHint: ["iPhone"]
        ))

        // Domain/username normalization & live smb.bundle NetFS URL construction.
        #expect(SMBBackend.normalizeNetFSUsername("alice") == "alice")
        #expect(SMBBackend.normalizeNetFSUsername("  WORKGROUP\\alice  ") == "WORKGROUP;alice")
        #expect(SMBBackend.normalizeNetFSUsername("CORP;bob") == "CORP;bob")

        let serverURL = try SMBBackend.buildNetFSServerURL(
            host: "192.168.68.53",
            port: 445,
            share: "icloud",
            guest: false,
            username: "WORKGROUP\\alice",
            password: "p@ss:w/rd#1"
        )
        #expect(serverURL.scheme?.lowercased() == "smb")
        #expect(serverURL.host == "192.168.68.53")
        #expect(serverURL.path == "/icloud")
        #expect(serverURL.absoluteString.contains("WORKGROUP;alice:"))

        // Verify -128 (userCanceledErr) and EPERM are not misreported as wrong credentials.
        let canceledMsg = SMBBackend.mapMountError(-128, host: "192.168.68.53", share: "icloud").localizedDescription
        #expect(canceledMsg.contains("login failed") == false)

        // Verify POSIX directory-only scanner skips regular files, hidden entries, and file symlinks.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSyncerSubdirScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for name in ["2025", "2026", "Family", ".hiddenDir"] {
            try FileManager.default.createDirectory(
                at: tempRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        for i in 0..<500 {
            FileManager.default.createFile(
                atPath: tempRoot.appendingPathComponent("IMG_\(i).JPG").path,
                contents: Data()
            )
        }
        let scannedDirs = try SMBBackend.listSubdirectories(at: tempRoot)
        #expect(scannedDirs == ["2025", "2026", "Family"])

        let boundedScan = try SMBBackend.scanSubdirectories(at: tempRoot, maxNonDirectoryEntries: 100)
        #expect(boundedScan.stoppedEarlyDueToManyFiles == true)

        // NetFS EnumerateShares dictionary filtering (excludes IPC$ and PrinterShare; handles $ hidden shares).
        let rawShares: [String: Any] = [
            "IPC$": ["IsHidden": true],
            "OfficePrinter": ["PrinterShare": true],
            "ADMIN$": ["IsHidden": true],
            "Photos$": [:] as [String: Any],
            "media": ["DisplayName": "Media Library"],
            "Backups": [:] as [String: Any],
        ]
        let visibleOnly = SMBBackend.parseEnumeratedShares(rawShares, includeHidden: false)
        #expect(visibleOnly.map(\.name) == ["Backups", "media"])
        #expect(visibleOnly.map(\.displayName) == ["Backups", "Media Library"])

        let withHidden = SMBBackend.parseEnumeratedShares(rawShares, includeHidden: true)
        #expect(withHidden.map(\.name) == ["ADMIN$", "Backups", "media", "Photos$"])
        #expect(withHidden.contains { $0.name == "IPC$" } == false)
        #expect(withHidden.contains { $0.name == "OfficePrinter" } == false)
    }

    @Test func sftpWizardEndpointAndPathNavigation() {
        #expect(SFTPServerEndpoint.parse("  ") == nil)
        #expect(SFTPServerEndpoint.parse("http://nas.local") == nil)
        #expect(SFTPServerEndpoint.parse("nas.local") == SFTPServerEndpoint(
            host: "nas.local", port: 22, usernameHint: nil, pathHint: nil
        ))
        #expect(SFTPServerEndpoint.parse("192.168.1.20:2222") == SFTPServerEndpoint(
            host: "192.168.1.20", port: 2222, usernameHint: nil, pathHint: nil
        ))
        #expect(SFTPServerEndpoint.parse("alice@synology.local:/volume1/Photos/2026") == SFTPServerEndpoint(
            host: "synology.local", port: 22, usernameHint: "alice", pathHint: "/volume1/Photos/2026"
        ))
        #expect(SFTPServerEndpoint.parse("alice@synology.local:~/Backups") == SFTPServerEndpoint(
            host: "synology.local", port: 22, usernameHint: "alice", pathHint: "~/Backups"
        ))
        #expect(SFTPServerEndpoint.parse("sftp://bob@10.0.0.5:2022/mnt/media") == SFTPServerEndpoint(
            host: "10.0.0.5", port: 2022, usernameHint: "bob", pathHint: "/mnt/media"
        ))

        #expect(SFTPPath.normalize("///volume1//Photos/../Backups/.//") == "/volume1/Backups")
        #expect(SFTPPath.normalize("/../../..") == "/")
        #expect(SFTPPath.resolve("~/iPhone", relativeTo: "/var", homePath: "/home/alice") == "/home/alice/iPhone")
        #expect(SFTPPath.resolve("2026/Trips", relativeTo: "/home/alice/Photos", homePath: "/home/alice") == "/home/alice/Photos/2026/Trips")
        #expect(SFTPPath.parent(of: "/home/alice") == "/home")
        #expect(SFTPPath.parent(of: "/home") == "/")
        #expect(SFTPPath.parent(of: "/") == nil)
        #expect(SFTPPath.breadcrumbs(for: "/volume1/Photos").map(\.fullPath) == ["/", "/volume1", "/volume1/Photos"])
    }

    @Test func deleteBudgetBatchRecalculationAcrossBudgetAndStyleChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let gb: Int64 = 1_000_000_000
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let store = SyncedStore(legacyDestinationID: nil, directory: dir)
        // p1..p6 are verified 10 GB assets (60 GB total); u0 is an older unverified asset (40 GB) -> 100 GB library.
        store.recordSynced(
            id: "u0",
            entry: Entry(parts: [Part(hash: "hu0", type: 1, size: UInt64(40 * gb))], verified: false),
            fingerprint: nil
        )
        for i in 1...6 {
            let id = "p\(i)"
            store.recordSynced(
                id: id,
                entry: Entry(parts: [Part(hash: "h\(i)", type: 1, size: UInt64(10 * gb))], verified: true),
                fingerprint: "fp-\(i)"
            )
        }

        let measured: [LibraryItem] = [
            LibraryItem(id: "u0", date: t0, bytes: 40 * gb),
            LibraryItem(id: "p1", date: t0.addingTimeInterval(10), bytes: 10 * gb),
            LibraryItem(id: "p2", date: t0.addingTimeInterval(20), bytes: 10 * gb),
            LibraryItem(id: "p3", date: t0.addingTimeInterval(30), bytes: 10 * gb),
            LibraryItem(id: "p4", date: t0.addingTimeInterval(40), bytes: 10 * gb),
            LibraryItem(id: "p5", date: t0.addingTimeInterval(50), bytes: 10 * gb),
            LibraryItem(id: "p6", date: t0.addingTimeInterval(60), bytes: 10 * gb),
        ]
        let totalBytes: Int64 = 100 * gb

        // 1. `.justSynced`: p1..p2 were synced before deletion was enabled; p3..p6 synced after enabling deletion.
        store.addJustSyncedCandidates(["u0", "p3", "p4", "p5", "p6"])
        #expect(store.justSyncedCandidates == ["p3", "p4", "p5", "p6"])

        // Initial 60 GB budget (40 GB excess) queues p3..p6 (never retroactive p1..p2 or unverified u0).
        let b60 = store.recalculateDeleteQueue(
            deleteStyle: .justSynced, budgetEnabled: true, budgetGB: 60,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(b60 == DeleteBatchPlan(queuedIDs: ["p3", "p4", "p5", "p6"], queuedBytes: 40 * gb, excessBytes: 40 * gb))
        #expect(store.pendingDelete == ["p3", "p4", "p5", "p6"])

        // 2. Raising budget to 85 GB (15 GB excess) immediately trims batch to oldest 2 candidates (20 GB >= 15 GB).
        store.clearDeleteQueue(clearCandidates: false)
        let b85 = store.recalculateDeleteQueue(
            deleteStyle: .justSynced, budgetEnabled: true, budgetGB: 85,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(b85 == DeleteBatchPlan(queuedIDs: ["p3", "p4"], queuedBytes: 20 * gb, excessBytes: 15 * gb))
        #expect(store.pendingDelete == ["p3", "p4"])
        #expect(store.justSyncedCandidates == ["p3", "p4", "p5", "p6"])
        #expect(store.save())

        // Reload from disk and raise budget to 110 GB (within budget -> 0 queued, candidates still preserved).
        let reloaded = SyncedStore(legacyDestinationID: nil, directory: dir)
        reloaded.clearDeleteQueue(clearCandidates: false)
        let b110 = reloaded.recalculateDeleteQueue(
            deleteStyle: .justSynced, budgetEnabled: true, budgetGB: 110,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(b110 == DeleteBatchPlan(queuedIDs: [], queuedBytes: 0, excessBytes: 0))
        #expect(reloaded.pendingDelete.isEmpty)
        #expect(reloaded.justSyncedCandidates == ["p3", "p4", "p5", "p6"])

        // 3. Lowering budget to 75 GB (25 GB excess) restores 30 GB (p3..p5) from preserved candidates.
        let b75 = reloaded.recalculateDeleteQueue(
            deleteStyle: .justSynced, budgetEnabled: true, budgetGB: 75,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(b75 == DeleteBatchPlan(queuedIDs: ["p3", "p4", "p5"], queuedBytes: 30 * gb, excessBytes: 25 * gb))
        #expect(reloaded.pendingDelete == ["p3", "p4", "p5"])

        // 4. Turning budget off under `.justSynced` queues all live verified session candidates (p3..p6).
        let noBudget = reloaded.recalculateDeleteQueue(
            deleteStyle: .justSynced, budgetEnabled: false, budgetGB: 75,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(noBudget == DeleteBatchPlan(queuedIDs: ["p3", "p4", "p5", "p6"], queuedBytes: 40 * gb, excessBytes: 0))

        // 5. Switching to `.oldest` at 75 GB budget (25 GB excess) queues retroactive oldest verified items (p1..p3), skipping unverified u0.
        let oldest75 = reloaded.recalculateDeleteQueue(
            deleteStyle: .oldest, budgetEnabled: true, budgetGB: 75,
            measuredItems: measured, totalBytes: totalBytes
        )
        #expect(oldest75 == DeleteBatchPlan(queuedIDs: ["p1", "p2", "p3"], queuedBytes: 30 * gb, excessBytes: 25 * gb))
        #expect(reloaded.pendingDelete == ["p1", "p2", "p3"])

        // 6. Dequeuing deleted items removes them from both pendingDelete and justSyncedCandidates; disabling deletion clears all.
        reloaded.dequeueDelete(["p3"])
        #expect(!reloaded.pendingDelete.contains("p3"))
        #expect(!reloaded.justSyncedCandidates.contains("p3"))
        reloaded.clearDeleteQueue(clearCandidates: true)
        #expect(reloaded.pendingDelete.isEmpty)
        #expect(reloaded.justSyncedCandidates.isEmpty)
    }

    @Test func videoInspectorValidatesMovWithAndWithoutExtension() async throws {
        #expect(VideoInspector.stagingExtension(
            originalFilename: "IMG_0019.MOV",
            uniformTypeIdentifier: "com.apple.quicktime-movie"
        ) == "mov")
        #expect(VideoInspector.stagingExtension(
            originalFilename: "IMG_0019",
            uniformTypeIdentifier: "com.apple.quicktime-movie"
        ) == "mov")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let movURL = dir.appendingPathComponent("paired-\(UUID().uuidString).mov")
        let noExtURL = dir.appendingPathComponent(UUID().uuidString)
        let corruptURL = dir.appendingPathComponent("corrupt-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
        if let pb {
            _ = adaptor.append(pb, withPresentationTime: .zero)
            _ = adaptor.append(pb, withPresentationTime: CMTime(value: 1, timescale: 1))
        }
        input.markAsFinished()
        await writer.finishWriting()

        try FileManager.default.copyItem(at: movURL, to: noExtURL)
        try Data("not a valid video".utf8).write(to: corruptURL)

        // Valid QuickTime `.mov` succeeds both with `.mov` extension and on an extensionless UUID staging file.
        try await VideoInspector.validateVideoFile(
            at: movURL,
            declaredUTI: "com.apple.quicktime-movie",
            fallbackFilename: "IMG_0019.MOV"
        )
        try await VideoInspector.validateVideoFile(
            at: noExtURL,
            declaredUTI: "com.apple.quicktime-movie",
            fallbackFilename: "IMG_0019.MOV"
        )

        // Corrupt file and truncated-duration file are still rejected.
        var rejectedCorrupt = false
        do {
            try await VideoInspector.validateVideoFile(at: corruptURL, declaredUTI: "com.apple.quicktime-movie")
        } catch {
            rejectedCorrupt = true
        }
        #expect(rejectedCorrupt)

        var rejectedTruncated = false
        do {
            try await VideoInspector.validateVideoFile(
                at: movURL,
                declaredUTI: "com.apple.quicktime-movie",
                expectedDuration: 10.0
            )
        } catch {
            rejectedTruncated = true
        }
        #expect(rejectedTruncated)

        // Spurious "Paused" non-cloud failures from earlier builds are stripped on load.
        let store = SyncedStore(legacyDestinationID: nil, directory: dir)
        store.recordFailure(id: "paused-item", name: "IMG_0030.MOV", message: "Paused", cloud: false)
        store.recordFailure(id: "real-fail", name: "IMG_0031.MOV", message: "Disk error", cloud: false)
        #expect(store.save())
        let reloaded = SyncedStore(legacyDestinationID: nil, directory: dir)
        #expect(!reloaded.isFailing("paused-item"))
        #expect(reloaded.isFailing("real-fail"))
    }

    @Test func sftpServerSideHashCommandQuotingParsingAndLiveShellExecution() throws {
        // Rejects empty, NUL, CR, LF strings so multi-line injection is impossible.
        #expect(SFTPRemoteHash.shellQuote("") == nil)
        #expect(SFTPRemoteHash.shellQuote("bad\nname") == nil)
        #expect(SFTPRemoteHash.shellQuote("bad\rname") == nil)
        #expect(SFTPRemoteHash.shellQuote("bad\0name") == nil)

        // Parses all 4 remote digest output formats and rejects malformed output.
        let d = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        let lower = d.lowercased()
        #expect(SFTPRemoteHash.parseDigest("\(lower)  -\n") == lower)
        #expect(SFTPRemoteHash.parseDigest("\(lower) *-\n") == lower)
        #expect(SFTPRemoteHash.parseDigest("\(d)\n") == lower)
        #expect(SFTPRemoteHash.parseDigest("(stdin)= \(lower)\n") == lower)
        #expect(SFTPRemoteHash.parseDigest("SHA2-256(stdin)= \(d)\n") == lower)
        #expect(SFTPRemoteHash.parseDigest("not-a-digest") == nil)
        #expect(SFTPRemoteHash.parseDigest("\(lower)\nextra-line") == nil)

        #expect(SFTPRemoteHash.parseProbeOutput("shasum\n\(lower)  -\n")?.tool == .shasum)
        #expect(SFTPRemoteHash.parseProbeOutput("openssl\nSHA2-256(stdin)= \(lower)\n")?.digest == lower)
        #expect(SFTPRemoteHash.parseProbeOutput("unknownTool\n\(lower)\n") == nil)

        // Candidate base directories include SFTP realpath and Synology `/volume1` mapping.
        #expect(SFTPRemoteHash.candidateExecBases(sftpRealBase: "/Photos/2026", configuredBase: "Photos/2026")
            == ["/Photos/2026", "/volume1/Photos/2026"])
        #expect(SFTPRemoteHash.candidateExecBases(sftpRealBase: "/volume2/Media", configuredBase: "/volume2/Media")
            == ["/volume2/Media"])

        // End-to-end execution through real POSIX `/bin/sh` with hostile filename characters.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trickyName = "-Bob's $HOME `echo NO` \"clip\" (2026).MOV"
        let trickyFile = dir.appendingPathComponent(trickyName)
        var payload = Data(repeating: 0x5A, count: 10_000)
        payload.replaceSubrange(0..<8, with: Data("PhotoSyn".utf8))
        try payload.write(to: trickyFile)

        let expectedFull = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let expectedPrefix = SHA256.hash(data: payload.prefix(4096)).map { String(format: "%02x", $0) }.joined()

        func runSh(_ command: String) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        let probeCmd = try #require(SFTPRemoteHash.buildProbeCommand(samplePath: trickyFile.path, prefixByteCount: 4096))
        let probeOut = try runSh(probeCmd)
        let parsedProbe = try #require(SFTPRemoteHash.parseProbeOutput(probeOut))
        #expect(parsedProbe.digest == expectedPrefix)

        let hashCmd = try #require(SFTPRemoteHash.buildHashCommand(tool: parsedProbe.tool, path: trickyFile.path))
        let hashOut = try runSh(hashCmd)
        #expect(SFTPRemoteHash.parseDigest(hashOut) == expectedFull)

        let opensslCmd = try #require(SFTPRemoteHash.buildHashCommand(tool: .openssl, path: trickyFile.path))
        let opensslOut = try runSh(opensslCmd)
        #expect(SFTPRemoteHash.parseDigest(opensslOut) == expectedFull)
    }

    @Test func destinationVerificationProgressAndCancelTransitions() {
        var state = DestinationVerificationState()
        #expect(!state.isActive)
        #expect(state.fractionCompleted == nil)
        #expect(state.menuStatusText == nil)

        state.phase = .connecting(destinationName: "NAS", index: 1, totalDestinations: 2)
        #expect(state.isActive)
        #expect(state.menuStatusText == "Connecting to NAS (1/2) for verification…")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        state.phase = .running(
            destinationName: "NAS",
            currentFile: "IMG_0019.MOV",
            processedFiles: 750,
            totalFiles: 3_000,
            intactFiles: 749,
            damagedFiles: 1,
            startedAt: t0,
            canceling: false
        )
        #expect(state.isActive)
        #expect(!state.isCanceling)
        #expect(state.fractionCompleted == 0.25)
        #expect(state.percentInt == 25)
        #expect(state.menuStatusText == "Verifying NAS · 750/3000 (25%)")

        state.markCanceling()
        #expect(state.isActive)
        #expect(state.isCanceling)
        #expect(state.menuStatusText == "Canceling verification…")

        state.phase = .canceled(
            processedFiles: 750,
            totalFiles: 3_000,
            intactFiles: 749,
            damagedFiles: 1,
            finishedAt: t0.addingTimeInterval(10)
        )
        #expect(!state.isActive)
        #expect(!state.isCanceling)
        #expect(state.menuStatusText == nil)

        state.phase = .completed(
            intactFiles: 3_000,
            damagedFiles: 0,
            unreachableDestinations: [],
            finishedAt: t0.addingTimeInterval(60)
        )
        #expect(!state.isActive)
    }
}
