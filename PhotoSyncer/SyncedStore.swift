import Foundation

/// One piece of content belonging to an asset (original, edited render, Live Photo video…).
struct Part: Codable, Hashable {
    var hash: String      // SHA-256 of the content
    var type: Int         // PHAssetResourceType raw value
    var size: UInt64?     // Expected byte length (nil on older ledger entries)
}

struct Entry: Codable {
    var parts: [Part] = []
    /// true only when every part was exported + hashed by this app. Unverified entries
    /// (migrated, or matched by fingerprint) are never eligible for iCloud deletion.
    var verified = true
    /// Synced by an old version that recorded no content hashes: trusted as done everywhere.
    var legacy: Bool?
    /// Asset modificationDate when `parts` were exported (nil on entries from older versions).
    var modifiedAt: Date?
}

struct Failure: Codable {
    var name: String
    var attempts: Int
    var message: String
    var retryAt: Date
    var cloud: Bool?      // true = original only in iCloud ("waiting"), not a hard failure
    var parked: Bool?     // true = gave up auto-retrying; only a manual retry brings it back
}

/// Persistent ledger, content-addressed per destination:
/// an asset is fully synced to a destination when every one of its part hashes has a file there.
/// That makes recovery simple: lose a file at one destination and only that destination re-syncs.
final class SyncedStore {
    /// The preview we saved for an asset whose original isn't available yet.
    struct Preview: Codable {
        static let currentVersion = 3
        var hash: String
        var version: Int?
    }

    private struct Ledger: Codable {
        var entries: [String: Entry] = [:]                      // Photos asset id -> parts
        var placements: [String: [String: String]] = [:]        // destination key -> [hash: file name]
        var fingerprints: [String: [Part]] = [:]                // survives Photos-ID changes
        var failures: [String: Failure] = [:]
        var pendingDelete: Set<String> = []
        var needsRebuild = false
        var duplicates: Int?
        var extraNames: [String: Set<String>] = [:]             // other names of already-known content, per destination
        var previews: [String: Preview] = [:]                   // asset id -> preview saved while the original is missing
        var retiredPreviews: [String: String] = [:]             // preview hash -> asset id, awaiting removal where the original now exists
        var hashSizes: [String: UInt64] = [:]                   // content hash -> expected byte size
        var canaryWritten: Set<String> = []                     // destination keys with `.photosyncer-id` written

        enum CodingKeys: String, CodingKey {
            case entries, placements, fingerprints, failures, pendingDelete, needsRebuild, duplicates
            case extraNames, previews, retiredPreviews, hashSizes, canaryWritten
        }

        init() {}

        /// Every field is optional on disk, so adding a field never invalidates an existing ledger.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
            placements = try c.decodeIfPresent([String: [String: String]].self, forKey: .placements) ?? [:]
            fingerprints = try c.decodeIfPresent([String: [Part]].self, forKey: .fingerprints) ?? [:]
            failures = try c.decodeIfPresent([String: Failure].self, forKey: .failures) ?? [:]
            pendingDelete = try c.decodeIfPresent(Set<String>.self, forKey: .pendingDelete) ?? []
            needsRebuild = try c.decodeIfPresent(Bool.self, forKey: .needsRebuild) ?? false
            duplicates = try c.decodeIfPresent(Int.self, forKey: .duplicates)
            extraNames = try c.decodeIfPresent([String: Set<String>].self, forKey: .extraNames) ?? [:]
            previews = try c.decodeIfPresent([String: Preview].self, forKey: .previews) ?? [:]
            retiredPreviews = try c.decodeIfPresent([String: String].self, forKey: .retiredPreviews) ?? [:]
            hashSizes = try c.decodeIfPresent([String: UInt64].self, forKey: .hashSizes) ?? [:]
            canaryWritten = try c.decodeIfPresent(Set<String>.self, forKey: .canaryWritten) ?? []
        }
    }

    private var ledger = Ledger()
    private let url: URL
    private let backupURL: URL
    private let log = EventLog.shared
    private(set) var saveError: String?

    // MARK: Load / migrate
    /// `legacyDestinationID`: the single destination older versions used; their files map onto it.
    init(legacyDestinationID: String?, directory: URL? = nil) {
        let dir = directory ?? SandboxCompat.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("synced-ledger-v4.json")
        backupURL = dir.appendingPathComponent("synced-ledger-v4.json.bak")
        let fm = FileManager.default
        try? fm.removeItem(at: url.appendingPathExtension("tmp"))
        try? fm.removeItem(at: backupURL.appendingPathExtension("tmp"))
        let v3 = dir.appendingPathComponent("synced-ledger-v3.json")
        let v2 = dir.appendingPathComponent("synced-ledger-v2.json")
        let v1 = dir.appendingPathComponent("synced-ledger.json")
        let v0 = dir.appendingPathComponent("synced-assets.json")

        if fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(Ledger.self, from: data) {
                ledger = l
            } else if let bakData = try? Data(contentsOf: backupURL),
                      let l = try? JSONDecoder().decode(Ledger.self, from: bakData) {
                let bad = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
                try? fm.moveItem(at: url, to: bad)
                log.warning("Ledger unreadable (moved to \(bad.lastPathComponent)); recovered from backup ledger.")
                ledger = l
                save()
            } else {
                quarantine(url)
            }
        } else if fm.fileExists(atPath: backupURL.path) {
            if let bakData = try? Data(contentsOf: backupURL),
               let l = try? JSONDecoder().decode(Ledger.self, from: bakData) {
                log.warning("Primary ledger missing; recovered from backup ledger.")
                ledger = l
                save()
            } else {
                quarantine(backupURL)
            }
        } else if fm.fileExists(atPath: v3.path) {
            migrateV3(v3, dest: legacyDestinationID)
        } else if fm.fileExists(atPath: v2.path) {
            migrateV2(v2, dest: legacyDestinationID)
        } else if let data = try? Data(contentsOf: v1) {
            struct V1: Decodable { var ids: Set<String> }
            if let l = try? JSONDecoder().decode(V1.self, from: data) {
                for id in l.ids { ledger.entries[id] = Entry(parts: [], verified: false, legacy: true) }
            }
        } else if let data = try? Data(contentsOf: v0), let ids = try? JSONDecoder().decode([String].self, from: data) {
            for id in ids { ledger.entries[id] = Entry(parts: [], verified: false, legacy: true) }
        }
    }

    /// Corrupt ledger: keep the bad file for inspection and rebuild knowledge from the files
    /// already in the destinations (see SyncEngine.rebuildIndex).
    private func quarantine(_ file: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        let dest = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).corrupt-\(ts)")
        try? FileManager.default.moveItem(at: file, to: dest)
        if file != backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
            let bakDest = backupURL.deletingLastPathComponent()
                .appendingPathComponent("\(backupURL.lastPathComponent).corrupt-\(ts)")
            try? FileManager.default.moveItem(at: backupURL, to: bakDest)
        }
        log.error("Ledger unreadable; moved to \(dest.lastPathComponent). Will rebuild index.")
        ledger = Ledger()
        ledger.needsRebuild = true
        save()
    }

    private func migrateV3(_ file: URL, dest: String?) {
        struct File3: Decodable { var name: String; var hash: String; var type: Int }
        struct Entry3: Decodable { var files: [File3]; var verified: Bool }
        struct V3: Decodable {
            var entries: [String: Entry3]
            var hashIndex: [String: String]
            var fingerprints: [String: [File3]]
            var failures: [String: Failure]
            var pendingDelete: Set<String>
            var needsRebuild: Bool
            var duplicates: Int?
        }
        guard let data = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(V3.self, from: data) else {
            quarantine(file); return
        }
        for (id, e) in l.entries {
            if e.files.isEmpty {
                ledger.entries[id] = Entry(parts: [], verified: false, legacy: true)
            } else {
                ledger.entries[id] = Entry(parts: e.files.map { Part(hash: $0.hash, type: $0.type) }, verified: e.verified)
                if let dest { for f in e.files { ledger.placements[dest, default: [:]][f.hash] = f.name } }
            }
        }
        if let dest { for (h, n) in l.hashIndex { ledger.placements[dest, default: [:]][h] = n } }
        for (fp, files) in l.fingerprints { ledger.fingerprints[fp] = files.map { Part(hash: $0.hash, type: $0.type) } }
        ledger.failures = l.failures
        ledger.pendingDelete = l.pendingDelete
        ledger.needsRebuild = l.needsRebuild
        ledger.duplicates = l.duplicates
        save()
    }

    private func migrateV2(_ file: URL, dest: String?) {
        struct V2: Decodable {
            struct E: Decodable { var hash: String?; var file: String? }
            var entries: [String: E]
        }
        guard let data = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(V2.self, from: data) else {
            quarantine(file); return
        }
        for (id, e) in l.entries {
            if let h = e.hash, let f = e.file {
                ledger.entries[id] = Entry(parts: [Part(hash: h, type: 0)], verified: false)
                if let dest { ledger.placements[dest, default: [:]][h] = f }
            } else {
                ledger.entries[id] = Entry(parts: [], verified: false, legacy: true)
            }
        }
        save()   // pending deletions intentionally dropped: unverified items are never deleted
    }

    // MARK: Queries
    var needsRebuild: Bool { get { ledger.needsRebuild } set { ledger.needsRebuild = newValue } }
    var duplicateCount: Int { ledger.duplicates ?? 0 }
    func noteDuplicate() { ledger.duplicates = (ledger.duplicates ?? 0) + 1 }
    var pendingDelete: Set<String> { ledger.pendingDelete }
    var failureCount: Int { ledger.failures.values.filter { $0.cloud != true }.count }
    /// iCloud-waiting items that are still being retried automatically.
    var cloudWaitingCount: Int { ledger.failures.values.filter { $0.cloud == true && $0.parked != true }.count }
    var parkedCount: Int { ledger.failures.values.filter { $0.parked == true }.count }
    var parkedIDs: Set<String> { Set(ledger.failures.filter { $0.value.parked == true }.keys) }
    var nextRetryAt: Date? { ledger.failures.values.filter { $0.parked != true }.map(\.retryAt).min() }
    var cloudWaitingIDs: Set<String> {
        Set(ledger.failures.filter { $0.value.cloud == true && $0.value.parked != true }.keys)
    }
    /// Waiting items that haven't had many attempts yet: worth retrying immediately after a sync.
    var freshCloudWaitingIDs: Set<String> {
        Set(ledger.failures.filter {
            $0.value.cloud == true && $0.value.parked != true && $0.value.attempts <= Self.cloudFastAttempts
        }.keys)
    }
    var nextCloudRetryAt: Date? {
        ledger.failures.values.filter { $0.cloud == true && $0.parked != true }.map(\.retryAt).min()
    }
    func isFailing(_ id: String) -> Bool { ledger.failures[id] != nil }
    var failureList: [Failure] { ledger.failures.values.sorted { $0.name < $1.name } }
    /// All failures with their asset ids, sorted by file name.
    var failureEntries: [(id: String, failure: Failure)] {
        ledger.failures.map { (id: $0.key, failure: $0.value) }.sorted { $0.failure.name < $1.failure.name }
    }
    func entry(_ id: String) -> Entry? { ledger.entries[id] }
    func fingerprint(_ fp: String) -> [Part]? { ledger.fingerprints[fp] }

    func backedOffIDs(now: Date = Date()) -> Set<String> {
        Set(ledger.failures.filter { $0.value.retryAt > now }.keys)
    }

    // MARK: Per-destination knowledge
    func placement(_ dest: String, hash: String) -> String? { ledger.placements[dest]?[hash] }
    func placementCount(_ dest: String) -> Int { ledger.placements[dest]?.count ?? 0 }
    func hashes(in dest: String) -> Set<String> { Set(ledger.placements[dest]?.keys.map { $0 } ?? []) }
    func knownNames(_ dest: String) -> Set<String> {
        Set(ledger.placements[dest]?.values.map(FileNames.key) ?? []).union(ledger.extraNames[dest] ?? [])
    }
    func addKnownName(_ dest: String, _ name: String) { ledger.extraNames[dest, default: []].insert(FileNames.key(name)) }
    /// Content worth mirroring between destinations (retired previews are being removed, not copied).
    var allHashes: Set<String> {
        Set(ledger.placements.values.flatMap { $0.keys }).subtracting(ledger.retiredPreviews.keys)
    }
    func anyPlacement(_ hash: String) -> Bool { ledger.placements.values.contains { $0[hash] != nil } }

    // MARK: Previews
    func preview(_ id: String) -> Preview? { ledger.previews[id] }
    func isLivePreview(_ hash: String) -> Bool { ledger.previews.values.contains { $0.hash == hash } }
    var retiredPreviews: [String: String] { ledger.retiredPreviews }
    func clearRetired(_ hash: String) { ledger.retiredPreviews[hash] = nil }
    func setPreview(_ id: String, hash: String, version: Int = Preview.currentVersion) {
        if let old = ledger.previews[id], old.hash != hash { ledger.retiredPreviews[old.hash] = id }
        ledger.retiredPreviews[hash] = nil                       // a re-used preview is live again
        ledger.previews[id] = Preview(hash: hash, version: version)
    }
    func addPlacement(_ dest: String, hash: String, name: String, size: UInt64? = nil) {
        ledger.placements[dest, default: [:]][hash] = name
        if let size, size > 0 { ledger.hashSizes[hash] = size }
    }
    func removeDestination(_ dest: String) {
        ledger.placements[dest] = nil
        ledger.extraNames[dest] = nil
        ledger.canaryWritten.remove(dest)
    }
    func expectedSize(_ hash: String) -> UInt64? { ledger.hashSizes[hash] }
    func hasCanary(_ dest: String) -> Bool { ledger.canaryWritten.contains(dest) }
    func markCanaryWritten(_ dest: String) { ledger.canaryWritten.insert(dest) }

    /// Recorded modification timestamps for synced non-legacy entries (used to detect post-sync edits).
    var syncedModifiedDates: [String: Date] {
        var out: [String: Date] = [:]
        for (id, e) in ledger.entries where e.legacy != true {
            if let m = e.modifiedAt { out[id] = m }
        }
        return out
    }

    func needsEditRefresh(_ id: String, modifiedAt: Date?) -> Bool {
        guard let e = ledger.entries[id], e.legacy != true, let syncedMod = e.modifiedAt else { return false }
        if syncedMod == .distantPast { return true }
        guard let mod = modifiedAt else { return false }
        return mod.timeIntervalSince(syncedMod) > 1.0
    }

    func updateModifiedAt(id: String, modifiedAt: Date?) {
        ledger.entries[id]?.modifiedAt = modifiedAt
    }

    func markNeedsEditSync(_ id: String) {
        guard ledger.entries[id] != nil else { return }
        ledger.entries[id]?.modifiedAt = .distantPast
    }

    /// Is every part of this asset present at `dest`? (Legacy entries count as done everywhere.)
    func isComplete(_ id: String, dest: String) -> Bool {
        guard let e = ledger.entries[id] else { return false }
        if e.legacy == true || e.parts.isEmpty { return true }
        guard let p = ledger.placements[dest] else { return false }
        return e.parts.allSatisfy { p[$0.hash] != nil }
    }

    func isComplete(_ id: String, dests: [String]) -> Bool {
        !dests.isEmpty && dests.allSatisfy { isComplete(id, dest: $0) }
    }

    /// Assets that need nothing more from any of `dests`.
    func completeIDs(for dests: [String]) -> Set<String> {
        guard !dests.isEmpty else { return [] }
        return Set(ledger.entries.keys.filter { isComplete($0, dests: dests) })
    }

    /// File names for each part at `dest`, or nil if any is missing.
    func fileNames(for id: String, dest: String) -> [(part: Part, name: String)]? {
        guard let e = ledger.entries[id], let p = ledger.placements[dest] else { return nil }
        var out: [(Part, String)] = []
        for part in e.parts {
            guard let n = p[part.hash] else { return nil }
            out.append((part, n))
        }
        return out
    }

    // MARK: Mutations
    func recordSynced(id: String, entry: Entry, fingerprint: String?) {
        ledger.entries[id] = entry
        for part in entry.parts {
            if let sz = part.size, sz > 0 { ledger.hashSizes[part.hash] = sz }
        }
        if let p = ledger.previews[id] {                         // the real original is here: retire the preview
            ledger.retiredPreviews[p.hash] = id
            ledger.previews[id] = nil
        }
        ledger.failures[id] = nil
        if let fp = fingerprint, entry.verified { ledger.fingerprints[fp] = entry.parts }
    }

    func queueDelete(_ id: String) { ledger.pendingDelete.insert(id) }
    func dequeueDelete<S: Sequence>(_ ids: S) where S.Element == String { ledger.pendingDelete.subtract(ids) }
    func clearDeleteQueue() { ledger.pendingDelete.removeAll() }

    /// iCloud-waiting items are retried every 5 minutes for their first few attempts (a download in
    /// progress usually resolves quickly). If it keeps failing the cause is not transient, so they
    /// back off: 15 min, 30 min, 1 h … capped at 6 h. Hard failures back off 15 min … 12 h.
    static let cloudRetryInterval: TimeInterval = 5 * 60
    static let cloudFastAttempts = 3
    func recordFailure(id: String, name: String, message: String, cloud: Bool = false, parkAfter: Int = 50) {
        let attempts = (ledger.failures[id]?.attempts ?? 0) + 1
        let delay: TimeInterval
        if cloud {
            delay = attempts <= Self.cloudFastAttempts
                ? Self.cloudRetryInterval
                : min(Self.cloudRetryInterval * 3 * pow(2, Double(attempts - Self.cloudFastAttempts - 1)), 6 * 3600)
        } else {
            delay = min(15 * 60 * pow(2, Double(attempts - 1)), 12 * 3600)
        }
        let park = cloud && attempts >= parkAfter
        ledger.failures[id] = Failure(name: name, attempts: attempts, message: message,
                                      retryAt: park ? .distantFuture : Date().addingTimeInterval(delay),
                                      cloud: cloud, parked: park ? true : nil)
    }

    /// Brings parked items back into the normal retry flow with a fresh attempt budget.
    /// `ids == nil` means every parked item. Returns how many were released.
    @discardableResult
    func unpark(_ ids: Set<String>?) -> Int {
        var n = 0
        for (id, f) in ledger.failures where f.parked == true && (ids?.contains(id) ?? true) {
            ledger.failures[id]?.parked = nil
            ledger.failures[id]?.attempts = 0
            ledger.failures[id]?.retryAt = .distantPast
            n += 1
        }
        return n
    }

    /// The attempt limit changed: park items already over it, release parked ones now under it.
    func reevaluateParking(limit: Int) {
        for (id, f) in ledger.failures where f.cloud == true {
            if f.parked != true, f.attempts >= limit {
                ledger.failures[id]?.parked = true
                ledger.failures[id]?.retryAt = .distantFuture
            } else if f.parked == true, f.attempts < limit {
                ledger.failures[id]?.parked = nil
                ledger.failures[id]?.retryAt = Date().addingTimeInterval(Self.cloudRetryInterval)
            }
        }
    }

    func pruneFailures(keeping live: Set<String>) {
        ledger.failures = ledger.failures.filter { live.contains($0.key) }
    }

    /// After a destination catch-up (mirroring) an asset may be complete everywhere: drop its failure.
    func clearCompletedFailures(dests: [String]) {
        for id in Array(ledger.failures.keys) where isComplete(id, dests: dests) { ledger.failures[id] = nil }
    }

    /// Placements at `dest` whose file is gone or no longer matches its recorded byte size.
    /// `zeroByteKeys` lists normalized names of files that shrank to 0 bytes (truncation stubs).
    func missingPlacements(dest: String, existing: Set<String>,
                           sizes: [String: UInt64] = [:]) -> (missing: [String], zeroByteKeys: [String], total: Int) {
        guard let p = ledger.placements[dest] else { return ([], [], 0) }
        var missing: [String] = []
        var zeroByteKeys: [String] = []
        for (hash, name) in p {
            let k = FileNames.key(name)
            guard existing.contains(k) else {
                missing.append(hash)
                continue
            }
            if !sizes.isEmpty, let expected = ledger.hashSizes[hash], expected > 0,
               let actual = sizes[k], actual != expected {
                missing.append(hash)
                if actual == 0 { zeroByteKeys.append(k) }
            }
        }
        return (missing, zeroByteKeys, p.count)
    }

    /// Deterministic slice of placements at `dest` for rolling background checksum scrubbing.
    func placementSlice(dest: String, offset: Int, count: Int) -> (slice: [(hash: String, name: String)], nextOffset: Int) {
        guard let p = ledger.placements[dest], !p.isEmpty, count > 0 else { return ([], 0) }
        let sorted = p.sorted { $0.value < $1.value }
        let start = ((offset % sorted.count) + sorted.count) % sorted.count
        var out: [(hash: String, name: String)] = []
        let n = min(count, sorted.count)
        for i in 0..<n {
            let item = sorted[(start + i) % sorted.count]
            out.append((hash: item.key, name: item.value))
        }
        return (out, (start + n) % sorted.count)
    }

    func allPlacements(dest: String) -> [(hash: String, name: String)] {
        (ledger.placements[dest] ?? [:]).map { (hash: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    /// Forget those placements so the affected assets re-sync to this destination only.
    func dropPlacements(dest: String, hashes: [String]) {
        for h in hashes { ledger.placements[dest]?[h] = nil }
    }

    /// True when every part is already present at `dest` (used for fingerprint matches).
    func hasAll(_ parts: [Part], dest: String) -> Bool {
        guard let p = ledger.placements[dest] else { return false }
        return !parts.isEmpty && parts.allSatisfy { p[$0.hash] != nil }
    }

    /// Wipe all ledger state (every version, plus quarantined files) and flag an index rebuild.
    func resetAll() {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasPrefix("synced-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
        ledger = Ledger()
        ledger.needsRebuild = true      // re-learn existing destination files by checksum
        save()
    }

    // MARK: Persistence
    @discardableResult
    func save() -> Bool {
        let fm = FileManager.default
        let tmp = url.appendingPathExtension("tmp")
        do {
            let data = try JSONEncoder().encode(ledger)
            unlink(tmp.path)
            guard fm.createFile(atPath: tmp.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let h = try FileHandle(forWritingTo: tmp)
            do {
                try h.write(contentsOf: data)
                if fcntl(h.fileDescriptor, F_FULLFSYNC) == -1 { try? h.synchronize() }
                try h.close()
            } catch {
                try? h.close()
                throw error
            }

            // Keep the previous valid generation as .bak before replacing the primary ledger.
            if fm.fileExists(atPath: url.path),
               ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) > 2 {
                let bakTmp = backupURL.appendingPathExtension("tmp")
                unlink(bakTmp.path)
                if link(url.path, bakTmp.path) == 0 || ((try? fm.copyItem(at: url, to: bakTmp)) != nil) {
                    _ = Darwin.rename(bakTmp.path, backupURL.path)
                } else {
                    unlink(bakTmp.path)
                }
            }

            guard Darwin.rename(tmp.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let dirFD = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
            if dirFD >= 0 {
                _ = fsync(dirFD)
                Darwin.close(dirFD)
            }
            saveError = nil
            return true
        } catch {
            unlink(tmp.path)
            saveError = error.localizedDescription
            log.error("Ledger save failed: \(error.localizedDescription)")
            return false
        }
    }
}
