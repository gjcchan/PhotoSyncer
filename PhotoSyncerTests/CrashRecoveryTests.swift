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
}
