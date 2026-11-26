import Foundation
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
}
