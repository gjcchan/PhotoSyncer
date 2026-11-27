import SwiftUI
import Combine
import Photos
import AVFoundation
import ServiceManagement
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A destination that is connected for the duration of one sync run.
private final class DestRuntime {
    let dest: Destination
    let backend: DestinationBackend
    var listing: [RemoteFile]
    var nameBook: DestinationNameBook
    let hashGate = InFlightHashGate()
    var unavailable = false                // went offline / was skipped during this run

    private var cachedFreeBytes: Int64?
    private var freeSpaceKnown: Bool?
    private var inFlightReservedBytes: Int64 = 0
    private var probesCountdown = 0

    var key: String { dest.key }
    var name: String { dest.name }
    var names: Set<String> { nameBook.names }
    var actualNames: [String: String] { nameBook.actualNames }
    var sizes: [String: UInt64] { nameBook.sizes }

    init(dest: Destination, backend: DestinationBackend, listing: [RemoteFile]) {
        self.dest = dest
        self.backend = backend
        self.listing = listing
        self.nameBook = DestinationNameBook(listing: listing)
    }

    func recordFile(name: String, size: UInt64) {
        nameBook.commitFile(name: name, size: size)
    }

    func releaseReservation(name: String) {
        nameBook.releaseReservation(name)
    }

    func removeFile(name: String) {
        nameBook.removeFile(name: name)
    }

    /// Checks destination capacity (caching `freeSpace()` across up to 25 uploads while healthy so SMB
    /// isn't hit with `statfs` on every single photo, switching to per-item checks below 1 GB free)
    /// and reserves `estimatedBytes` across concurrent workers.
    func reserveSpace(estimatedBytes: Int64) async -> Bool {
        let needed = max(estimatedBytes, 0)
        let reserveMargin: Int64 = 200_000_000
        let lowSpaceThreshold: Int64 = 1_000_000_000
        let shouldProbe = freeSpaceKnown == nil
            || probesCountdown <= 0
            || (cachedFreeBytes.map { ($0 - inFlightReservedBytes) < needed + lowSpaceThreshold } ?? false)
        if shouldProbe {
            if let fresh = await backend.freeSpace() {
                cachedFreeBytes = fresh
                freeSpaceKnown = true
            } else {
                cachedFreeBytes = nil
                freeSpaceKnown = false
            }
            probesCountdown = 25
        } else {
            probesCountdown -= 1
        }
        if let free = cachedFreeBytes, (free - inFlightReservedBytes) < needed + reserveMargin {
            return false
        }
        inFlightReservedBytes += needed
        return true
    }

    func settleSpace(reservedBytes: Int64, writtenBytes: Int64) {
        inFlightReservedBytes = max(0, inFlightReservedBytes - max(reservedBytes, 0))
        if let free = cachedFreeBytes, writtenBytes > 0 {
            cachedFreeBytes = max(0, free - writtenBytes)
        }
    }
}

/// Tracks hashes placed during a single asset's export so Live Photo / edit parts of the same asset
/// aren't miscounted as library duplicates, without sharing mutable state across concurrent workers.
private final class AttemptTracker {
    var markers = Set<String>()
}

/// One failed / iCloud-waiting item, as shown in Settings › Activity (or › Failed once parked).
struct AttentionItem: Identifiable, Hashable {
    let id: String
    let name: String
    let message: String
    let cloud: Bool
    let attempts: Int
    let retryAt: Date
    let parked: Bool
}

/// A resource downloaded from Photos to local staging, hashed and ready to be placed.
private struct StagedFile {
    let url: URL
    let size: UInt64
    let hash: String
}

@MainActor
final class SyncEngine: ObservableObject {
    static let chunkSize = 10
    static let localReserveBytes: Int64 = 500_000_000        // keep at least 500 MB free on the startup disk
    /// Photos resources we export, in priority order (primary first).
    nonisolated private static let exportOrder: [PHAssetResourceType] =
        [.photo, .video, .fullSizePhoto, .fullSizeVideo, .alternatePhoto, .pairedVideo, .fullSizePairedVideo]

    // MARK: Published state
    @Published var isSyncing = false
    @Published var done = 0
    @Published var total = 0
    @Published var phase: String?
    @Published var lastError: String?
    @Published var lastSync: Date? { didSet { defaults.set(lastSync, forKey: "lastSync") } }
    @Published var destinations: [Destination] {
        didSet { saveDestinations() }
    }
    @Published var destStatus: [String: String] = [:]          // destination key -> human readable state
    @Published var savePreviews: Bool {
        didSet { defaults.set(savePreviews, forKey: "savePreviews") }
    }
    @Published var mirrorEnabled: Bool {
        didSet { defaults.set(mirrorEnabled, forKey: "mirrorEnabled") }
    }
    @Published var destinationProblem: String?
    @Published var launchAtLogin = false
    @Published var loginItemNeedsApproval = false
    @Published var failedCount = 0
    @Published var attentionItems: [AttentionItem] = []          // still retried automatically
    @Published var parkedItems: [AttentionItem] = []             // gave up: manual retry only
    @Published var parkedCount = 0
    @Published var parkAfterAttempts: Int {
        didSet {
            let clamped = min(max(parkAfterAttempts, 1), 1000)
            if clamped != parkAfterAttempts { parkAfterAttempts = clamped; return }
            defaults.set(parkAfterAttempts, forKey: "parkAfterAttempts")
            store.reevaluateParking(limit: parkAfterAttempts)
            store.save()
            refreshCounts()
        }
    }
    @Published var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: "paused") }
    }
    @Published var waitingForDestination = false
    @Published var duplicatesFound = 0
    @Published var cloudWaitingCount = 0
    @Published var needsAutomationSettings = false
    @Published var pendingDeleteCount = 0
    @Published var pendingDeleteBytes: Int64 = 0
    @Published var needsPhotosSettings = false
    @Published var needsConfirmReconcile = false
    @Published var deferredReason: String?
    /// Set when iCloud refuses to hand over originals for (nearly) everything: retrying won't help.
    @Published var cloudDiagnosis: String?

    @Published var scheduleMode: SyncScheduleMode {
        didSet {
            guard scheduleMode != oldValue else { return }
            defaults.set(scheduleMode.rawValue, forKey: "scheduleMode")
            scheduleChangedAt = Date()
            runBackoffUntil = .distantPast
        }
    }
    @Published var interval: SyncInterval {
        didSet {
            guard interval != oldValue else { return }
            defaults.set(interval.rawValue, forKey: "interval")
            runBackoffUntil = .distantPast
        }
    }
    @Published var dailySyncMinutes: Int {
        didSet {
            let clamped = DailySchedule.clampMinutes(dailySyncMinutes)
            if clamped != dailySyncMinutes { dailySyncMinutes = clamped; return }
            guard dailySyncMinutes != oldValue else { return }
            defaults.set(dailySyncMinutes, forKey: "dailySyncMinutes")
            scheduleChangedAt = Date()
            runBackoffUntil = .distantPast
        }
    }
    @Published var dailyCatchUpIfMissed: Bool {
        didSet {
            guard dailyCatchUpIfMissed != oldValue else { return }
            defaults.set(dailyCatchUpIfMissed, forKey: "dailyCatchUpIfMissed")
        }
    }
    @Published var deleteStyle: DeleteStyle {
        didSet {
            guard deleteStyle != oldValue else { return }
            defaults.set(deleteStyle.rawValue, forKey: "deleteStyle")
            if deleteStyle == .oldest && !budgetEnabled {
                suppressPolicyRecalc = true
                budgetEnabled = true       // "oldest" is only meaningful with a budget
                suppressPolicyRecalc = false
            }
            deletePolicyChanged(previousStyle: oldValue)
        }
    }
    @Published var budgetEnabled: Bool {
        didSet {
            guard budgetEnabled != oldValue else { return }
            if !budgetEnabled && deleteStyle == .oldest {
                suppressPolicyRecalc = true
                budgetEnabled = true
                suppressPolicyRecalc = false
                return
            }
            defaults.set(budgetEnabled, forKey: "budgetEnabled")
            if !suppressPolicyRecalc {
                deletePolicyChanged(previousStyle: deleteStyle)
            }
        }
    }
    @Published var budgetGB: Int {
        didSet {
            let clamped = min(max(budgetGB, 1), 100_000)
            if clamped != budgetGB { budgetGB = clamped; return }
            guard budgetGB != oldValue else { return }
            defaults.set(budgetGB, forKey: "budgetGB")
            deletePolicyChanged(previousStyle: deleteStyle)
        }
    }
    @Published var libraryBytes: Int64 = 0
    @Published var libraryMeasuredAt: Date?
    @Published var holdDeletions: Bool {
        didSet {
            defaults.set(holdDeletions, forKey: "holdDeletions")
            if shouldAutoProcessDeletions { deleteRetryAt = .distantPast }
        }
    }
    @Published var holdThresholdEnabled: Bool {
        didSet {
            defaults.set(holdThresholdEnabled, forKey: "holdThresholdEnabled")
            if shouldAutoProcessDeletions { deleteRetryAt = .distantPast }
        }
    }
    @Published var holdThresholdGB: Int {
        didSet {
            let clamped = min(max(holdThresholdGB, 1), 10_000)
            if clamped != holdThresholdGB { holdThresholdGB = clamped; return }
            defaults.set(holdThresholdGB, forKey: "holdThresholdGB")
            if shouldAutoProcessDeletions { deleteRetryAt = .distantPast }
        }
    }
    @Published var deleteAfterSync: Bool {
        didSet {
            guard deleteAfterSync != oldValue else { return }
            defaults.set(deleteAfterSync, forKey: "deleteAfterSync")
            if !deleteAfterSync {           // turning it off must cancel anything already queued or recalculating
                deleteRecalcGeneration &+= 1
                deleteRecalcTask?.cancel()
                deleteRecalcTask = nil
                needsDeleteRecalc = false
                store.clearDeleteQueue(clearCandidates: true)
                pendingDeleteBytes = 0
                defaults.set(0, forKey: "pendingDeleteBytes")
                store.save()
                surfaceSaveError()
                refreshCounts()
            } else if deleteStyle == .oldest {
                scheduleDeleteQueueRecalculation()
            }
        }
    }

    // MARK: Private state
    private let defaults = UserDefaults.standard
    private let log = EventLog.shared
    private let instanceLock = InstanceLock()
    private let legacyDestinationID: String?
    private lazy var store = SyncedStore(legacyDestinationID: legacyDestinationID)
    private let network = NetworkMonitor()
    private var active: [DestRuntime] = []               // destinations connected for the current run
    private var activeTask: Task<Void, Never>?           // running sync or manual deletion task
    private var suppressPolicyRecalc = false
    private var deleteRecalcTask: Task<Void, Never>?
    private var deleteRecalcGeneration: UInt64 = 0
    private var needsDeleteRecalc = false
    private var isTerminating = false                    // app quit / logout / OS restart in progress
    private var isTicking = false                        // prevents overlapping async reachability probes
    private var scrubOffsets: [String: Int] = [:]        // per-destination rolling checksum scrub cursor
    private var schedulerTask: Task<Void, Never>?
    let cloudClock = CloudCountdown()
    let autoConfirm = DeleteAutoConfirmController()
    let wakeScheduler = SystemWakeScheduler()
    private var wakeAssertion: PowerAssertion?
    private var wakeSettleTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var lastClockTick = Date.distantPast
    private var photosFallbackBlockedUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var inFlightLocalBytes: Int64 = 0       // staged bytes reserved across concurrent workers
    private var sleepPause = false                  // set while the Mac sleeps / is waking up
    private var wakeSettleUntil = Date.distantPast  // give USB drives + Wi-Fi time to return after wake
    /// A run was cut short (sleep, pause, drive removed): sync again soon even if the interval hasn't elapsed.
    private var needsResume: Bool {
        get { defaults.bool(forKey: "needsResume") }
        set { defaults.set(newValue, forKey: "needsResume") }
    }
    private var runBackoffUntil = Date.distantPast
    private var photosFallbackFailures = 0       // circuit breaker for the Photos-app route
    private var previewsSaved = 0                // previews written during the current run
    private var deleteRetryAt: Date {
        get { defaults.object(forKey: "deleteRetryAt") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "deleteRetryAt") }
    }
    private var scheduleChangedAt: Date? {
        get { defaults.object(forKey: "scheduleChangedAt") as? Date }
        set { defaults.set(newValue, forKey: "scheduleChangedAt") }
    }

    var dailySyncDate: Date {
        get {
            Calendar.current.date(
                bySettingHour: dailySyncMinutes / 60,
                minute: dailySyncMinutes % 60,
                second: 0,
                of: Date()
            ) ?? Date()
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            let mins = DailySchedule.clampMinutes((comps.hour ?? 3) * 60 + (comps.minute ?? 0))
            if mins != dailySyncMinutes { dailySyncMinutes = mins }
        }
    }

    var dailyScheduleSummary: String {
        let now = Date()
        guard let next = DailySchedule.nextOccurrence(after: now, targetMinutes: dailySyncMinutes) else {
            return "Syncs once a day at \(dailySyncDate.formatted(date: .omitted, time: .shortened))."
        }
        let dayLabel = Calendar.current.isDateInToday(next) ? "Today" : "Tomorrow"
        let timeStr = next.formatted(date: .omitted, time: .shortened)
        let wakeConfigured = wakeScheduler.wakeEnabled && wakeScheduler.isConfigured(forSyncMinutes: dailySyncMinutes)
        if dailyCatchUpIfMissed {
            if wakeConfigured {
                return "Next scheduled sync: \(dayLabel) at \(timeStr) (Mac wakes at \(wakeScheduler.formattedWakeTime(forSyncMinutes: dailySyncMinutes)))."
            }
            return "Next scheduled sync: \(dayLabel) at \(timeStr)."
        }
        let endMin = DailySchedule.clampMinutes(dailySyncMinutes + DailySchedule.windowMinutes)
        let endStr = (Calendar.current.date(bySettingHour: endMin / 60, minute: endMin % 60, second: 0, of: now) ?? now)
            .formatted(date: .omitted, time: .shortened)
        if wakeConfigured {
            return "Next scheduled sync: \(dayLabel) between \(timeStr) and \(endStr) (Mac wakes at \(wakeScheduler.formattedWakeTime(forSyncMinutes: dailySyncMinutes)))."
        }
        return "Next scheduled sync: \(dayLabel) between \(timeStr) and \(endStr) (skipped if Mac is asleep)."
    }

    var installWarning: String? {
        Bundle.main.bundlePath.hasPrefix("/Applications")
            ? nil : "Move PhotoSyncer to /Applications for reliable launch at login"
    }

    var enabledDestinations: [Destination] { destinations.filter(\.enabled) }

    var statusText: String {
        if isPaused {
            return isSyncing ? "Pausing… finishing current item"
                             : (total > 0 && done < total ? "Paused at \(done)/\(total)" : "Paused")
        }
        if waitingForDestination { return "Waiting for a destination to come online…" }
        if isSyncing {
            if let phase { return phase }
            return total == 0 ? "Checking for new photos…" : "\(done)/\(total) syncing"
        }
        if let deferredReason { return deferredReason }
        if enabledDestinations.isEmpty { return destinations.isEmpty ? "No destination – add one in Settings" : "All destinations are disabled" }
        if let lastSync {
            return "Up to date · last sync \(lastSync.formatted(date: .omitted, time: .shortened))"
        }
        return "Idle"
    }

    var cloudWaitingText: String? {
        cloudWaitingCount > 0 ? "\(cloudWaitingCount) waiting for iCloud download" : nil
    }

    var failureText: String? {
        failedCount > 0 ? "\(failedCount) failed – retrying automatically" : nil
    }

    var pendingDeleteSummary: String {
        guard pendingDeleteCount > 0, pendingDeleteBytes > 0 else { return "\(pendingDeleteCount)" }
        let size = ByteCountFormatter.string(fromByteCount: pendingDeleteBytes, countStyle: .file)
        return "\(pendingDeleteCount) (\(size))"
    }

    /// Whether a scheduled/automatic sync should submit the deletion queue to macOS right now.
    var shouldAutoProcessDeletions: Bool {
        guard deleteAfterSync, !store.pendingDelete.isEmpty else { return false }
        guard autoConfirm.allowsScheduledDeletion() else { return false }
        if !holdDeletions { return true }
        guard holdThresholdEnabled else { return false }
        return pendingDeleteBytes >= Int64(holdThresholdGB) * 1_000_000_000
    }

    func resetDeleteRetry() { deleteRetryAt = .distantPast }

    // MARK: Init
    init() {
        scheduleMode = SyncScheduleMode(rawValue: defaults.string(forKey: "scheduleMode") ?? "") ?? .interval
        interval = SyncInterval(rawValue: defaults.integer(forKey: "interval")) ?? .h1
        if defaults.object(forKey: "dailySyncMinutes") != nil {
            dailySyncMinutes = DailySchedule.clampMinutes(defaults.integer(forKey: "dailySyncMinutes"))
        } else {
            dailySyncMinutes = DailySchedule.defaultMinutes
        }
        if defaults.object(forKey: "dailyCatchUpIfMissed") != nil {
            dailyCatchUpIfMissed = defaults.bool(forKey: "dailyCatchUpIfMissed")
        } else {
            dailyCatchUpIfMissed = true
        }
        deleteAfterSync = defaults.bool(forKey: "deleteAfterSync")
        let style = DeleteStyle(rawValue: defaults.string(forKey: "deleteStyle") ?? "") ?? .justSynced
        let savedBudget = defaults.integer(forKey: "budgetGB")
        deleteStyle = style
        budgetGB = savedBudget > 0 ? savedBudget : 50
        budgetEnabled = defaults.bool(forKey: "budgetEnabled") || style == .oldest
        holdDeletions = defaults.bool(forKey: "holdDeletions")
        holdThresholdEnabled = defaults.bool(forKey: "holdThresholdEnabled")
        let savedHoldGB = defaults.integer(forKey: "holdThresholdGB")
        holdThresholdGB = savedHoldGB > 0 ? min(savedHoldGB, 10_000) : 5
        libraryBytes = Int64(defaults.integer(forKey: "libraryBytes"))
        libraryMeasuredAt = defaults.object(forKey: "libraryMeasuredAt") as? Date
        pendingDeleteBytes = Int64(defaults.integer(forKey: "pendingDeleteBytes"))
        lastSync = defaults.object(forKey: "lastSync") as? Date
        isPaused = defaults.bool(forKey: "paused")          // pause survives restarts / login launch
        mirrorEnabled = defaults.bool(forKey: "mirrorEnabled")
        savePreviews = defaults.bool(forKey: "savePreviews")
        let savedLimit = defaults.integer(forKey: "parkAfterAttempts")
        parkAfterAttempts = savedLimit > 0 ? min(savedLimit, 1000) : 50

        // Destinations: an older single-folder install becomes the first destination.
        var loaded = (defaults.data(forKey: "destinations")
            .flatMap { try? JSONDecoder().decode([Destination].self, from: $0) }) ?? []
        let migrated = Destination.migrateLegacy(defaults: defaults)
        if loaded.isEmpty, let migrated { loaded = [migrated] }
        destinations = loaded
        legacyDestinationID = migrated?.key ?? loaded.first(where: { $0.kind == .folder })?.key

        // Single instance: kernel-enforced advisory lock prevents two processes from racing on the ledger.
        let me = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
            .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        if !instanceLock.acquire(retryTimeout: others.isEmpty ? 1.5 : 0.4) {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSyncer-previews"))
        saveDestinations()
        Destination.clearLegacy(defaults: defaults)       // safe now: the list is persisted
        for d in loaded { destStatus[d.key] = d.enabled ? "Not checked yet" : "Disabled" }
        if deleteAfterSync && deleteStyle == .justSynced && !store.pendingDelete.isEmpty {
            store.addJustSyncedCandidates(store.pendingDelete)
        }
        if store.pendingDelete.isEmpty {
            pendingDeleteBytes = 0
        } else if pendingDeleteBytes == 0 {
            Task { [weak self] in await self?.updatePendingDeleteBytes() }
        }
        refreshCounts()

        if !defaults.bool(forKey: "didFirstLaunch") {
            defaults.set(true, forKey: "didFirstLaunch")
            setLaunchAtLogin(true)
        }
        refreshLoginItem()

        let nc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
                let vol = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated { self?.volumeEvent(mounted: true, volume: vol) }
            },
            nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
                let vol = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated { self?.volumeEvent(mounted: false, volume: vol) }
            },
            nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillPowerOff() }
            },
        ]
        startScheduler()
        startClock()
    }

    // MARK: iCloud retry countdown
    /// Text after the count, e.g. "5:00" until the next retry, or why there is no countdown.
    private func updateCloudClock() {
        let n = store.cloudWaitingCount
        guard n > 0 else { cloudClock.update(count: 0, suffix: ""); return }
        let suffix: String
        if isPaused { suffix = "paused" }
        else if waitingForDestination { suffix = "waiting for destination" }
        else if isSyncing { suffix = "retrying…" }
        else if let next = store.nextCloudRetryAt {
            let secs = Int(next.timeIntervalSinceNow.rounded(.up))
            if secs > 0 { suffix = CloudCountdown.format(secs) }
            else if deferredReason != nil { suffix = "deferred" }
            else { suffix = "retrying…" }
        } else { suffix = "retrying…" }
        cloudClock.update(count: n, suffix: suffix)
    }

    /// Once a second: refresh the countdown, and kick the scheduler the moment a retry is due
    /// (the regular scheduler only wakes once a minute).
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.updateCloudClock()
                if !self.isSyncing, !self.isPaused, let next = self.store.nextCloudRetryAt, next <= Date(),
                   Date().timeIntervalSince(self.lastClockTick) > 15 {
                    self.lastClockTick = Date()
                    await self.tick()
                }
            }
        }
    }

    // MARK: Scheduling
    private func startScheduler() {
        let initialKeep = isSyncing
            ? Set(enabledDestinations.filter { $0.kind == .smb }.map(\.key))
            : Set<String>()
        Task.detached(priority: .utility) {
            await SMBBackend.cleanupOrphanedMounts(keeping: initialKeep)
            await SMBBackend.cleanupStaleBrowseMounts()
        }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        guard !isTicking, !isSyncing, !isPaused, !sleepPause, !isTerminating, Date() >= wakeSettleUntil else { return }
        isTicking = true
        defer { isTicking = false }
        let now = Date()
        if let ls = lastSync, ls > now { lastSync = now }          // clock moved backwards
        let enabled = enabledDestinations
        guard !enabled.isEmpty else { return }

        var due: Bool
        switch scheduleMode {
        case .interval:
            due = lastSync.map { now.timeIntervalSince($0) >= interval.seconds } ?? true
        case .daily:
            due = DailySchedule.isDailySyncDue(
                now: now,
                lastSync: lastSync,
                scheduleChangedAt: scheduleChangedAt,
                targetMinutes: dailySyncMinutes,
                catchUpIfMissed: dailyCatchUpIfMissed
            )
        }
        if needsResume { due = true }                               // an earlier run was cut short
        if waitingForDestination {
            var anyReachable = false
            for d in enabled {
                if await maybeReachable(d) { anyReachable = true; break }
            }
            guard anyReachable else { return }                      // non-blocking check, once a minute
            setWaiting(false, "A destination is back; resuming")
            runBackoffUntil = .distantPast
            due = true
        }
        if let r = store.nextRetryAt, now >= r { due = true }       // failed items are due again
        if shouldAutoProcessDeletions, now >= deleteRetryAt { due = true }
        guard due, now >= runBackoffUntil else { return }

        if ProcessInfo.processInfo.isLowPowerModeEnabled { deferredReason = "Waiting (Low Power Mode)"; return }
        if let reason = network.blockReason { deferredReason = reason; return }
        deferredReason = nil
        startSync()
    }

    // MARK: Sleep / wake / drives / termination
    private func systemWillSleep() {
        sleepPause = true      // the run stops after the current item instead of fighting the sleep
        wakeSettleTask?.cancel()
        wakeSettleTask = nil
        wakeAssertion?.release()
        wakeAssertion = nil
        if isSyncing { log.info("System going to sleep; sync will pause after the current item") }
    }

    private func systemWillPowerOff() {
        guard !isTerminating else { return }
        isTerminating = true
        wakeSettleTask?.cancel()
        wakeSettleTask = nil
        wakeAssertion?.release()
        wakeAssertion = nil
        if isSyncing {
            needsResume = true
            store.save()
            log.info("System shutting down or restarting; stopping sync cleanly")
        }
    }

    var hasActiveWork: Bool { isSyncing || activeTask != nil }

    func flushForTermination() {
        isTerminating = true
        schedulerTask?.cancel()
        clockTask?.cancel()
        wakeSettleTask?.cancel()
        wakeSettleTask = nil
        wakeAssertion?.release()
        wakeAssertion = nil
        store.save()
        instanceLock.release()
    }

    /// Cooperatively stops any in-flight sync/delete run, saves the ledger, and closes backends
    /// (disconnecting SFTP and unmounting private SMB shares) within a short bounded deadline.
    func prepareForTermination() async {
        isTerminating = true
        schedulerTask?.cancel()
        clockTask?.cancel()
        wakeSettleTask?.cancel()
        wakeSettleTask = nil
        wakeAssertion?.release()
        wakeAssertion = nil

        if !isSyncing, activeTask == nil {
            store.save()
            instanceLock.release()
            return
        }

        needsResume = true
        store.save()
        log.info("Shutting down; finishing current operation and closing connections…")

        if let task = activeTask {
            let finishedGracefully = await Self.waitForTask(task, timeout: 2.5)
            if !finishedGracefully {
                task.cancel()
                _ = await Self.waitForTask(task, timeout: 1.5)
            }
        }

        store.save()
        let leftover = active
        active = []
        if !leftover.isEmpty {
            _ = await Self.withDeadline(1.5) {
                for rt in leftover { await rt.backend.close() }
            }
        }
        instanceLock.release()
    }

    nonisolated private static func waitForTask(_ task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let dog = Watchdog()
            Task.detached {
                await task.value
                if dog.finish() { cont.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if dog.finish() { cont.resume(returning: false) }
            }
        }
    }

    nonisolated private static func withDeadline(_ timeout: TimeInterval,
                                                 _ op: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let dog = Watchdog()
            Task {
                await op()
                if dog.finish() { cont.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if dog.finish() { cont.resume(returning: false) }
            }
        }
    }

    private func systemDidWake() {
        wakeSettleTask?.cancel()
        wakeAssertion?.release()
        // Hold NetworkClientActive immediately so an RTC timer / Dark Wake does not go back to sleep
        // during the 30 s drive/Wi-Fi settle or in the final seconds before the scheduled sync minute.
        let assertion = PowerAssertion(
            name: "PhotoSyncer post-wake settle",
            details: "Waiting for drives and network before scheduled sync",
            timeout: 180
        )
        wakeAssertion = assertion
        wakeSettleUntil = Date().addingTimeInterval(30)
        log.info("System woke; waiting 30 s for drives and network before syncing")

        wakeSettleTask = Task { [weak self] in
            defer {
                assertion.release()
                if let self, self.wakeAssertion === assertion {
                    self.wakeAssertion = nil
                }
            }
            try? await Task.sleep(for: .seconds(31))
            guard let self, !Task.isCancelled, !self.isTerminating else { return }
            self.sleepPause = false
            self.runBackoffUntil = .distantPast        // a pre-sleep backoff no longer applies
            await self.tick()

            // When macOS woke 1 minute early for a daily scheduled sync (e.g. 2:59 AM for 3:00 AM),
            // bridge the remaining seconds until the exact sync minute arrives before releasing wakeAssertion.
            if !self.isSyncing,
               !self.isPaused,
               !self.isTerminating,
               !self.sleepPause,
               self.scheduleMode == .daily,
               let next = DailySchedule.nextOccurrence(after: Date(), targetMinutes: self.dailySyncMinutes) {
                let delay = next.timeIntervalSinceNow
                if delay > 0 && delay <= 120 {
                    try? await Task.sleep(for: .seconds(delay + 0.5))
                    guard !Task.isCancelled, !self.isTerminating, !self.sleepPause else { return }
                    await self.tick()
                }
            }

            // If Wi-Fi / DHCP is still finishing association right after wake, give it one extra 15 s check.
            if !self.isSyncing,
               self.deferredReason != nil,
               !Task.isCancelled,
               !self.isTerminating,
               !self.sleepPause {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, !self.isTerminating, !self.sleepPause else { return }
                await self.tick()
            }
        }
    }

    private func volumeEvent(mounted: Bool, volume: URL?) {
        if mounted {
            let hasWaiting = destStatus.values.contains { $0.hasPrefix("Waiting") }
            guard waitingForDestination || hasWaiting else { return }
            Task { [weak self] in                       // let the volume finish mounting
                try? await Task.sleep(for: .seconds(3))
                await self?.tick()
            }
        } else if let vol = volume {
            for d in enabledDestinations where d.kind == .folder {
                if let url = folderURL(d), url.path.hasPrefix(vol.path) {
                    log.warning("Volume \(vol.lastPathComponent) holding \(d.name) was unmounted")
                    if !isSyncing { setDestStatus(d, "Waiting: drive was disconnected") }
                }
            }
            // if syncing, the in-flight item fails and that destination is marked unavailable
        }
    }

    private func setWaiting(_ on: Bool, _ message: String) {
        guard waitingForDestination != on else { return }   // log transitions only, not every poll
        waitingForDestination = on
        if on { log.warning("Waiting for destinations: \(message)") } else { log.info(message) }
    }

    // MARK: Launch at login
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
            log.error("Login item: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let s = SMAppService.mainApp.status
        launchAtLogin = (s == .enabled || s == .requiresApproval)
        loginItemNeedsApproval = (s == .requiresApproval)
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func openPhotos() { openPhotosApp() }

    func openAutomationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(u)
        }
    }

    func openPhotosPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Destinations
    private func saveDestinations() {
        if let data = try? JSONEncoder().encode(destinations) { defaults.set(data, forKey: "destinations") }
    }

    func setDestStatus(_ d: Destination, _ status: String) {
        destStatus[d.key] = status
        let bad = destinations.filter { $0.enabled && (destStatus[$0.key] ?? "").hasPrefix("Error") }
        destinationProblem = bad.isEmpty ? nil : "\(bad.map(\.name).joined(separator: ", ")): needs attention (Settings › Destinations)"
    }

    /// Lets the user pick a folder (local disk, USB drive, or a mounted NAS share).
    func addFolderDestination() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to copy photos into"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if destinations.contains(where: { $0.kind == .folder && folderURL($0)?.standardizedFileURL == url.standardizedFileURL }) {
            lastError = "That folder is already a destination."
            return
        }
        do {
            let bookmark = try SandboxCompat.createBookmark(for: url)
            let d = Destination(name: url.lastPathComponent, kind: .folder, bookmark: bookmark)
            destinations.append(d)
            destStatus[d.key] = "Not checked yet"
            destinationAdded(d)
        } catch {
            lastError = "Could not save folder: \(error.localizedDescription)"
        }
    }

    func addSFTPDestination(_ d: Destination, password: String) {
        let status = Keychain.setPassword(password, account: d.key)
        guard status == errSecSuccess else {
            lastError = "Could not store the SFTP password in the Keychain (error \(status))."
            log.error("Keychain write failed for \(d.name): \(status)")
            return
        }
        destinations.append(d)
        destStatus[d.key] = "Not checked yet"
        destinationAdded(d)
    }

    func addSMBDestination(_ d: Destination, password: String) {
        if d.guest != true {
            let status = Keychain.setPassword(password, account: d.key)
            guard status == errSecSuccess else {
                lastError = "Could not store the SMB password in the Keychain (error \(status))."
                log.error("Keychain write failed for \(d.name): \(status)")
                return
            }
        }
        destinations.append(d)
        destStatus[d.key] = "Not checked yet"
        destinationAdded(d)
    }

    private func destinationAdded(_ d: Destination) {
        log.info("Destination added: \(d.name) (\(d.summary))")
        needsConfirmReconcile = false
        runBackoffUntil = .distantPast
        lastError = nil
        scheduleChangedAt = nil
        lastSync = nil                      // triggers a sync that brings the new destination up to date
    }

    func removeDestination(_ id: UUID) {
        guard !isSyncing else { lastError = "Wait for the current sync to finish before removing a destination."; return }
        guard let d = destinations.first(where: { $0.id == id }) else { return }
        if d.kind == .smb {
            let key = d.key
            Task { await SMBBackend.cleanupMount(key: key) }
        }
        Keychain.delete(account: d.key)
        store.removeDestination(d.key)
        store.save()
        destinations.removeAll { $0.id == id }
        destStatus[d.key] = nil
        if enabledDestinations.isEmpty { setWaiting(false, "No destination left to wait for") }
        log.warning("Destination removed: \(d.name). Files already copied there were not deleted.")
        refreshCounts()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[i].enabled = on
        destStatus[destinations[i].key] = on ? "Not checked yet" : "Disabled"
        log.info("\(on ? "Enabled" : "Disabled") destination \(destinations[i].name)")
        if on { lastSync = nil }            // catch the re-enabled destination up
        if enabledDestinations.isEmpty { setWaiting(false, "No enabled destination left to wait for") }
    }

    func forgetHostKey(_ id: UUID) {
        guard let i = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[i].trustedHostKey = nil
        log.warning("Forgot the pinned host key for \(destinations[i].name); it will be pinned again on next connect")
    }

    fileprivate func pinHostKey(_ destKey: String, _ key: String) {
        guard let i = destinations.firstIndex(where: { $0.key == destKey }), destinations[i].trustedHostKey == nil else { return }
        destinations[i].trustedHostKey = key
        log.info("Pinned SFTP host key for \(destinations[i].name): \(HostKey.fingerprint(key))")
    }

    /// Used by the "Add SFTP" form: connects once and reports the server's host key fingerprint.
    func testSFTP(_ d: Destination, password: String) async -> Result<(key: String, files: Int), Error> {
        let box = KeyBox()
        let backend = SFTPBackend(dest: d, password: password) { box.set($0) }
        do {
            try await backend.connect()
            let files = try await backend.list().count
            await backend.close()
            return .success((box.value ?? d.trustedHostKey ?? "", files))
        } catch {
            await backend.close()
            return .failure(error)
        }
    }

    /// Used by the "Add SMB" form: mounts the share once, lists the folder, and unmounts again.
    func testSMB(_ d: Destination, password: String) async -> Result<Int, Error> {
        let backend = SMBBackend(dest: d, password: password)
        do {
            try await backend.connect()
            let files = try await backend.list().count
            await backend.close()
            return .success(files)
        } catch {
            await backend.close()
            return .failure(error)
        }
    }

    private func folderURL(_ d: Destination) -> URL? {
        guard let data = d.bookmark, let r = try? SandboxCompat.resolveBookmark(data) else { return nil }
        if let fresh = r.refreshedBookmark, let i = destinations.firstIndex(where: { $0.id == d.id }) {
            destinations[i].bookmark = fresh
        }
        return r.url
    }

    /// Non-blocking reachability check used only to decide whether a retry is worth attempting.
    private func maybeReachable(_ d: Destination) async -> Bool {
        guard d.kind == .folder else { return true }                // SFTP / SMB: just try (network permitting)
        guard let url = folderURL(d) else { return false }
        return ((try? await BlockingIO.run(timeout: 5) {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return (try? url.checkResourceIsReachable()) == true
        }) ?? false)
    }

    private func makeBackend(_ d: Destination, allowCreateBase: Bool = true) throws -> DestinationBackend {
        switch d.kind {
        case .folder:
            guard let data = d.bookmark else {
                throw SyncError.message("The folder reference is missing. Remove this destination and add it again.")
            }
            do {
                let r = try SandboxCompat.resolveBookmark(data)
                if let fresh = r.refreshedBookmark, let i = destinations.firstIndex(where: { $0.id == d.id }) {
                    destinations[i].bookmark = fresh
                }
                return FolderBackend(url: r.url)
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) {
                    throw SyncError.destinationUnavailable("Volume is not mounted (drive unplugged or share offline?)")
                }
                throw SyncError.message("The folder reference is no longer valid. Remove this destination and add it again.")
            }
        case .sftp:
            let pw: String
            switch Keychain.lookupPassword(account: d.key) {
            case .success(let p): pw = p
            case .locked(let status):
                throw SyncError.destinationUnavailable("Keychain is locked (error \(status)); waiting for unlock")
            case .notFound:
                throw SyncError.message("The SFTP password is missing from the Keychain. Remove this destination and add it again.")
            case .failure(let status):
                throw SyncError.message("Could not read the SFTP password from the Keychain (error \(status)).")
            }
            let key = d.key
            return SFTPBackend(dest: d, password: pw, allowCreateBase: allowCreateBase) { [weak self] hostKey in
                Task { @MainActor [weak self] in self?.pinHostKey(key, hostKey) }
            }
        case .smb:
            let guest = d.guest == true
            let pw: String?
            if guest {
                pw = nil
            } else {
                switch Keychain.lookupPassword(account: d.key) {
                case .success(let p): pw = p
                case .locked(let status):
                    throw SyncError.destinationUnavailable("Keychain is locked (error \(status)); waiting for unlock")
                case .notFound:
                    throw SyncError.message("The SMB password is missing from the Keychain. Remove this destination and add it again.")
                case .failure(let status):
                    throw SyncError.message("Could not read the SMB password from the Keychain (error \(status)).")
                }
            }
            return SMBBackend(dest: d, password: pw, allowCreateBase: allowCreateBase)
        }
    }

    // MARK: Entry points
    /// Manual sync: also retries backed-off failures and pending iCloud deletions right now.
    func syncNow() {
        guard !isSyncing, !isPaused else { return }
        if enabledDestinations.isEmpty {
            if destinations.isEmpty { addFolderDestination() }      // first-run convenience
            guard !enabledDestinations.isEmpty else {
                lastError = "No destination is enabled. Add one in Settings › Destinations."
                return
            }
        }
        runBackoffUntil = .distantPast
        deleteRetryAt = .distantPast
        startSync(includeBackedOff: true)
    }

    func retryFailed() { syncNow() }

    /// Counts live library items that are already verified in the ledger, present on every enabled
    /// destination, and not yet in the deletion queue (without prompting for Photos access).
    func countQueueableAlreadySynced() async -> Int {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return 0 }
        let enabledKeys = enabledDestinations.map(\.key)
        let liveIDs = await Task.detached { Self.allLibraryIDs() }.value
        var count = 0
        for id in liveIDs {
            guard store.entry(id)?.verified == true, !store.pendingDelete.contains(id) else { continue }
            guard enabledKeys.isEmpty || store.isComplete(id, dests: enabledKeys) else { continue }
            count += 1
        }
        return count
    }

    /// Queues all live library items that are already verified in the ledger and present on every
    /// enabled destination (useful when enabling deletion or hold-queue after items were already synced).
    func queueAlreadySynced() {
        guard deleteAfterSync, !isSyncing else { return }
        let enabledKeys = enabledDestinations.map(\.key)
        Task {
            do {
                try await ensurePhotosAccess(requestIfNeeded: true)
            } catch {
                lastError = error.localizedDescription
                if case SyncError.permission = error { needsPhotosSettings = true }
                return
            }
            let liveIDs = await Task.detached { Self.allLibraryIDs() }.value
            var candidates: [String] = []
            for id in liveIDs {
                guard store.isVerifiedForQueue(id) else { continue }
                guard enabledKeys.isEmpty || store.isComplete(id, dests: enabledKeys) else { continue }
                if !store.justSyncedCandidates.contains(id) || !store.pendingDelete.contains(id) {
                    candidates.append(id)
                }
            }
            guard !candidates.isEmpty else {
                log.info("No additional already-synced verified items in Photos to queue")
                return
            }
            store.addJustSyncedCandidates(candidates)
            if budgetEnabled {
                let m = await Task.detached { Self.measureLibrary() }.value
                if m.sizeKnown {
                    libraryBytes = m.total
                    libraryMeasuredAt = Date()
                    defaults.set(Int(m.total), forKey: "libraryBytes")
                    defaults.set(libraryMeasuredAt, forKey: "libraryMeasuredAt")
                    let batch = store.recalculateDeleteQueue(
                        deleteStyle: deleteStyle,
                        budgetEnabled: budgetEnabled,
                        budgetGB: budgetGB,
                        measuredItems: m.items,
                        totalBytes: m.total
                    )
                    pendingDeleteBytes = batch.queuedBytes
                    defaults.set(Int(batch.queuedBytes), forKey: "pendingDeleteBytes")
                    log.info("Added \(candidates.count) already-synced item(s) to candidate pool; \(batch.queuedIDs.count) item(s) queued to match \(budgetGB) GB budget")
                } else {
                    log.warning("Could not determine the iCloud library size; will queue budget excess on next sync")
                }
            } else {
                var added = 0
                for id in candidates where !store.pendingDelete.contains(id) {
                    store.queueDelete(id)
                    added += 1
                }
                await updatePendingDeleteBytes()
                log.info("Queued \(added) already-synced verified item(s) for iCloud deletion")
            }
            store.save()
            surfaceSaveError()
            refreshCounts()
            if shouldAutoProcessDeletions { deleteRetryAt = .distantPast }
        }
    }

    /// Manually verifies every queued item across all enabled destinations and prompts macOS to delete them.
    func deleteQueuedNow() {
        guard !isSyncing, !isTerminating else { lastError = "A sync is running. Try again when it finishes."; return }
        guard !store.pendingDelete.isEmpty else { return }
        let enabled = enabledDestinations
        guard !enabled.isEmpty else {
            lastError = "No destination is enabled. Enable your destination(s) so copies can be verified before deleting."
            return
        }
        isSyncing = true
        phase = "Verifying copies before iCloud delete…"
        lastError = nil
        needsPhotosSettings = false
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Deleting synced photos from iCloud")
        let powerAssertion = PowerAssertion(name: "PhotoSyncer deleting verified iCloud items", timeout: 7200)

        activeTask = Task {
            do {
                try await ensurePhotosAccess(requestIfNeeded: true)
                var rts: [DestRuntime] = []
                for d in enabled {
                    if isTerminating || Task.isCancelled { break }
                    var backend: DestinationBackend?
                    do {
                        let b = try makeBackend(d, allowCreateBase: false)
                        backend = b
                        setDestStatus(d, "Connecting…")
                        try await b.connect()
                        let files = try await b.list()
                        rts.append(DestRuntime(dest: d, backend: b, listing: files))
                        setDestStatus(d, "Connected · \(files.count) files")
                    } catch SyncError.destinationUnavailable(let m) {
                        if let backend { await backend.close() }
                        setDestStatus(d, "Waiting: \(m)")
                        log.warning("\(d.name): \(m)")
                    } catch {
                        if let backend { await backend.close() }
                        setDestStatus(d, "Error: \(error.localizedDescription)")
                        log.error("\(d.name): \(ErrorInfo.describe(error))")
                    }
                }
                active = rts
                if !isTerminating, !Task.isCancelled {
                    if rts.count == enabled.count {
                        deleteRetryAt = .distantPast
                        await processDeleteQueue(manual: true)
                        await updatePendingDeleteBytes()
                        store.save()
                        surfaceSaveError()
                        for rt in rts where !rt.unavailable { setDestStatus(rt.dest, "Up to date") }
                    } else {
                        lastError = "Cannot delete from iCloud yet: every enabled destination must be online so copies can be verified."
                    }
                }
            } catch {
                lastError = error.localizedDescription
                if case SyncError.permission = error { needsPhotosSettings = true }
            }
            let finished = active
            active = []
            for rt in finished { await rt.backend.close() }
            powerAssertion.release()
            ProcessInfo.processInfo.endActivity(activity)
            isSyncing = false
            phase = nil
            activeTask = nil
            refreshCounts()
            if needsDeleteRecalc && deleteAfterSync {
                scheduleDeleteQueueRecalculation()
            }
        }
    }

    /// Re-reads and checksum-verifies every recorded file across all enabled destinations on demand.
    func verifyDestinationsNow() {
        guard !isSyncing, !isTerminating else { lastError = "A sync is running. Try again when it finishes."; return }
        let enabled = enabledDestinations
        guard !enabled.isEmpty else {
            lastError = "No destination is enabled. Add or enable one in Settings › Destinations."
            return
        }
        isSyncing = true
        phase = "Connecting to destinations for verification…"
        lastError = nil
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Verifying destination files")
        let powerAssertion = PowerAssertion(name: "PhotoSyncer verifying destination files", timeout: 7200)

        activeTask = Task {
            var checked = 0
            var damaged = 0
            var rts: [DestRuntime] = []
            for d in enabled {
                if isTerminating || Task.isCancelled { break }
                var backend: DestinationBackend?
                do {
                    let b = try makeBackend(d, allowCreateBase: false)
                    backend = b
                    setDestStatus(d, "Connecting…")
                    try await b.connect()
                    let files = try await b.list()
                    rts.append(DestRuntime(dest: d, backend: b, listing: files))
                    setDestStatus(d, "Connected · \(files.count) files")
                } catch SyncError.destinationUnavailable(let m) {
                    if let backend { await backend.close() }
                    setDestStatus(d, "Waiting: \(m)")
                    log.warning("\(d.name): \(m)")
                } catch {
                    if let backend { await backend.close() }
                    setDestStatus(d, "Error: \(error.localizedDescription)")
                    log.error("\(d.name): \(ErrorInfo.describe(error))")
                }
            }
            active = rts

            for rt in rts where !rt.unavailable {
                let items = store.allPlacements(dest: rt.key)
                for (i, item) in items.enumerated() {
                    if isPaused || sleepPause || isTerminating || Task.isCancelled { break }
                    phase = "Verifying \(rt.name) (\(i + 1)/\(items.count))…"
                    let k = FileNames.key(item.name)
                    guard rt.names.contains(k) else {
                        store.dropPlacements(dest: rt.key, hashes: [item.hash])
                        damaged += 1
                        log.warning("\(rt.name): \(item.name) is missing; queued for restore")
                        continue
                    }
                    do {
                        let actual = try await rt.backend.hash(of: rt.actualNames[k] ?? item.name, noCache: true)
                        checked += 1
                        if actual != item.hash {
                            store.dropPlacements(dest: rt.key, hashes: [item.hash])
                            damaged += 1
                            log.error("\(rt.name): \(item.name) failed checksum verification; queued for restore")
                        }
                    } catch SyncError.destinationUnavailable(let m) {
                        markUnavailable(rt, m)
                        break
                    } catch {
                        damaged += 1
                        store.dropPlacements(dest: rt.key, hashes: [item.hash])
                        log.error("\(rt.name): could not read \(item.name) (\(error.localizedDescription)); queued for restore")
                    }
                }
                if !rt.unavailable { setDestStatus(rt.dest, "Verified · \(checked) OK") }
            }

            if damaged > 0 {
                needsResume = true
                store.save()
                surfaceSaveError()
                log.warning("Destination verification finished: \(checked) intact, \(damaged) missing or corrupted (will restore on next sync)")
                lastError = "\(damaged) file(s) were missing or corrupted and will be restored automatically."
            } else if !rts.isEmpty {
                log.info("Destination verification finished: all \(checked) file(s) passed uncached SHA-256 verification")
            }

            let finished = active
            active = []
            for rt in finished { await rt.backend.close() }
            powerAssertion.release()
            ProcessInfo.processInfo.endActivity(activity)
            isSyncing = false
            phase = nil
            activeTask = nil
            refreshCounts()
            if needsDeleteRecalc && deleteAfterSync {
                scheduleDeleteQueueRecalculation()
            }
        }
    }

    // MARK: Parked items (stopped auto-retrying)
    /// Retries parked items right now. `ids == nil` retries all of them.
    func retryParked(_ ids: Set<String>?) {
        guard !isSyncing else { lastError = "A sync is running. Try again when it finishes."; return }
        guard !isPaused else { lastError = "Sync is paused. Resume it to retry."; return }
        let n = store.unpark(ids)
        guard n > 0 else { return }
        store.save()
        refreshCounts()
        log.info("Retrying \(n) item(s) that had stopped auto-retrying")
        syncNow()
    }

    /// Opens the best local version Photos has of an item (works even if the preview feature is off).
    func openPreview(_ id: String) {
        let name = (parkedItems + attentionItems).first { $0.id == id }?.name ?? "photo"
        Task {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                lastError = "\(name) is no longer in your Photos library."
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSyncer-previews", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let preview = await LocalPreview.write(for: asset, to: tmp) else {
                lastError = "Photos has no local preview for \(name)."
                return
            }
            let base = (name as NSString).deletingPathExtension
            let url = dir.appendingPathComponent(FileNames.sanitize("\(base)-preview.\(preview.ext)"))
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                NSWorkspace.shared.open(url)
            } catch {
                lastError = "Could not open the preview: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Pause / resume
    /// Stops after the item currently in flight (a download can't be safely cut mid-way),
    /// saves the ledger and keeps scheduled syncs off until resumed. Persists across restarts.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        deferredReason = nil
        log.info(isSyncing ? "Pause requested; finishing the current item" : "Sync paused by user")
    }

    /// Continues immediately where the ledger left off (already-synced items are skipped).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        log.info("Sync resumed by user")
        guard !isSyncing else { return }                    // pause hadn't taken effect yet: run just continues
        guard !enabledDestinations.isEmpty else { return }
        runBackoffUntil = .distantPast
        startSync()
    }

    private func pauseCheck() throws {
        guard isPaused || sleepPause || isTerminating || Task.isCancelled else { return }
        store.save()
        refreshCounts()
        throw SyncError.paused
    }

    // MARK: Reset
    /// Purge logs + ledger, then rebuild from scratch. Requires explicit confirmation.
    /// Files already in the destinations are never deleted.
    func confirmAndReset() {
        guard !isSyncing else {
            let a = NSAlert()
            a.messageText = "A sync is in progress"
            a.informativeText = "Wait for the current sync to finish, then try again."
            a.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Purge all logs and sync history, and rebuild?"
        alert.informativeText = """
        This will:
        • Delete all logs and the sync ledger (history of what was copied, failures and pending iCloud deletions).
        • Re-scan your entire Photos library and re-download every original from iCloud, which can take a long time and a lot of bandwidth.
        • Rebuild the index by checksumming files already in your destinations (SFTP files must be downloaded to be checksummed), so identical files are not duplicated.

        Risks:
        • If "Delete from iCloud After Sync" is ON, the rebuild will queue the whole library for deletion from iCloud once copies are verified on every destination. Turn it off first if unsure.
        • Edited or renamed files in a destination can no longer be matched and may be copied again.
        • This cannot be undone.

        Files already in your destinations are NOT deleted.
        """
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"                       // safe default
        let confirm = alert.addButton(withTitle: "Purge & Rebuild")
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        log.clear()
        store.resetAll()
        for k in ["lastSync", "deleteRetryAt", "forceReconcile", "pendingDeleteBytes", "scheduleChangedAt"] { defaults.removeObject(forKey: k) }
        pendingDeleteBytes = 0
        lastSync = nil
        runBackoffUntil = .distantPast
        lastError = nil
        needsConfirmReconcile = false
        needsPhotosSettings = false
        refreshCounts()
        log.warning("Logs and ledger purged by user; starting full rebuild")
        syncNow()
    }

    /// User confirmed that missing files should be re-downloaded.
    func confirmReconcile() {
        defaults.set(true, forKey: "forceReconcile")
        syncNow()
    }

    private func startSync(includeBackedOff: Bool = false) {
        guard !isSyncing, !isTerminating, !enabledDestinations.isEmpty else { return }
        deleteRecalcGeneration &+= 1
        deleteRecalcTask?.cancel()
        deleteRecalcTask = nil
        isSyncing = true; done = 0; total = 0; phase = nil; lastError = nil; needsPhotosSettings = false
        needsAutomationSettings = false; photosFallbackFailures = 0; previewsSaved = 0
        let force = defaults.bool(forKey: "forceReconcile")
        // Keep the Mac awake (including across RTC Dark Wake) and un-throttled while syncing.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Syncing photos")
        let powerAssertion = PowerAssertion(name: "PhotoSyncer syncing photos", timeout: 7200)

        activeTask = Task {
            do {
                try await run(includeBackedOff: includeBackedOff, forceReconcile: force)
                lastSync = Date()
                needsResume = false
                setWaiting(false, "Destinations are available")
            } catch SyncError.paused {
                lastError = nil
                needsResume = true
                let msg = isTerminating
                    ? "Sync stopped for app quit/restart (\(done)/\(total) processed); will resume on next launch"
                    : (isPaused ? "Sync paused (\(done)/\(total) processed this run)"
                                : "Sync interrupted by sleep (\(done)/\(total) processed); will resume after wake")
                log.info(msg)
            } catch SyncError.destinationUnavailable(let m) {
                lastError = nil
                needsResume = true                      // keep the unfinished work due
                setWaiting(true, m)                     // poll cheaply; no failures, no 15-minute backoff
            } catch {
                lastError = error.localizedDescription
                log.error("Run failed: \(error.localizedDescription)")
                if case SyncError.permission = error { needsPhotosSettings = true }
                if case SyncError.diskFull = error { runBackoffUntil = Date().addingTimeInterval(3600) }
                else if case SyncError.localDiskFull = error { runBackoffUntil = Date().addingTimeInterval(3600) }
                else { runBackoffUntil = Date().addingTimeInterval(15 * 60) }  // don't spin
            }
            let finished = active
            active = []
            for rt in finished { await rt.backend.close() }
            powerAssertion.release()
            ProcessInfo.processInfo.endActivity(activity)
            isSyncing = false
            phase = nil
            activeTask = nil
            refreshCounts()
            if needsDeleteRecalc && deleteAfterSync {
                scheduleDeleteQueueRecalculation()
            }
        }
    }

    /// A changed deletion policy must never act on a queue built under the old one; immediately
    /// suspends any stale batch and recalculates a new batch matching the updated policy/budget.
    private func deletePolicyChanged(previousStyle: DeleteStyle) {
        if previousStyle == .justSynced && !store.pendingDelete.isEmpty {
            store.addJustSyncedCandidates(store.pendingDelete)
        }
        store.clearDeleteQueue(clearCandidates: false)
        pendingDeleteBytes = 0
        defaults.set(0, forKey: "pendingDeleteBytes")
        store.save()
        surfaceSaveError()
        refreshCounts()
        log.info("Delete policy changed: \(deleteStyle.label), budget \(budgetEnabled ? "\(budgetGB) GB" : "off")")
        if deleteAfterSync {
            scheduleDeleteQueueRecalculation()
        }
    }

    private func scheduleDeleteQueueRecalculation() {
        deleteRecalcGeneration &+= 1
        let gen = deleteRecalcGeneration
        deleteRecalcTask?.cancel()
        deleteRecalcTask = nil

        guard deleteAfterSync, !isTerminating else {
            needsDeleteRecalc = false
            return
        }
        if isSyncing {
            needsDeleteRecalc = true
            return
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            needsDeleteRecalc = false
            return
        }

        needsDeleteRecalc = false
        deleteRecalcTask = Task { @MainActor [weak self] in
            let m = await Task.detached { Self.measureLibrary() }.value
            guard let self,
                  !Task.isCancelled,
                  self.deleteRecalcGeneration == gen,
                  self.deleteAfterSync,
                  !self.isSyncing,
                  !self.isTerminating else { return }

            self.deleteRecalcTask = nil

            if self.budgetEnabled && !m.sizeKnown {
                self.log.warning("Could not determine the iCloud library size; deletion queue kept empty until next sync")
                return
            }

            if m.sizeKnown {
                self.libraryBytes = m.total
                self.libraryMeasuredAt = Date()
                self.defaults.set(Int(m.total), forKey: "libraryBytes")
                self.defaults.set(self.libraryMeasuredAt, forKey: "libraryMeasuredAt")
            }

            let batch = self.store.recalculateDeleteQueue(
                deleteStyle: self.deleteStyle,
                budgetEnabled: self.budgetEnabled,
                budgetGB: self.budgetGB,
                measuredItems: m.items,
                totalBytes: m.total
            )
            if batch.queuedBytes > 0 || m.sizeKnown {
                self.pendingDeleteBytes = batch.queuedBytes
                self.defaults.set(Int(batch.queuedBytes), forKey: "pendingDeleteBytes")
            } else {
                await self.updatePendingDeleteBytes()
            }
            self.store.save()
            self.surfaceSaveError()
            self.refreshCounts()

            let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            if self.budgetEnabled {
                if batch.excessBytes <= 0 {
                    self.log.info("Recalculated deletion queue: iCloud library is \(fmt(m.total)), within the \(self.budgetGB) GB budget; 0 items queued")
                } else {
                    self.log.info("Recalculated deletion queue for \(self.budgetGB) GB budget (\(self.deleteStyle.label)): \(batch.queuedIDs.count) item(s) (\(fmt(batch.queuedBytes))) queued")
                }
            } else {
                self.log.info("Recalculated deletion queue (\(self.deleteStyle.label), no budget): \(batch.queuedIDs.count) item(s) (\(fmt(self.pendingDeleteBytes))) queued")
            }

            if self.shouldAutoProcessDeletions {
                self.deleteRetryAt = .distantPast
            }
        }
    }

    private func refreshCounts() {
        failedCount = store.failureCount
        updateCloudClock()
        duplicatesFound = store.duplicateCount
        cloudWaitingCount = store.cloudWaitingCount
        pendingDeleteCount = store.pendingDelete.count
        let all = store.failureEntries.map { e in
            AttentionItem(id: e.id, name: e.failure.name, message: e.failure.message, cloud: e.failure.cloud == true,
                          attempts: e.failure.attempts, retryAt: e.failure.retryAt, parked: e.failure.parked == true)
        }
        attentionItems = all.filter { !$0.parked }
        parkedItems = all.filter(\.parked)
        parkedCount = parkedItems.count
    }

    private func surfaceSaveError() {
        if let e = store.saveError { lastError = "Could not save sync ledger: \(e)" }
    }

    private func saveLedgerOrThrow() throws {
        if !store.save() {
            surfaceSaveError()
            throw SyncError.message("Could not save sync ledger: \(store.saveError ?? "disk write failed")")
        }
    }

    // MARK: Run
    private func markUnavailable(_ rt: DestRuntime, _ message: String) {
        guard !rt.unavailable else { return }
        rt.unavailable = true
        setDestStatus(rt.dest, "Waiting: \(message)")
        log.warning("\(rt.name) became unavailable: \(message)")
    }

    private func run(includeBackedOff: Bool, forceReconcile: Bool) async throws {
        let enabled = enabledDestinations
        guard !enabled.isEmpty else {
            throw SyncError.message("No destination is enabled. Add one in Settings › Destinations.")
        }
        let deleteAfter = deleteAfterSync
        log.info("Sync started (\(enabled.count) destination(s): \(enabled.map(\.name).joined(separator: ", ")); delete after sync: \(deleteAfter ? "on" : "off"))")
        try await ensurePhotosAccess(requestIfNeeded: true)

        // 1. Connect every enabled destination. Unreachable ones are skipped and catch up later.
        var rts: [DestRuntime] = []
        var hardError: Error?
        for d in enabled {
            if isPaused || sleepPause || isTerminating || Task.isCancelled {
                for rt in rts { await rt.backend.close() }
                try pauseCheck()
            }
            var backend: DestinationBackend?
            do {
                let allowCreate = forceReconcile || store.placementCount(d.key) == 0
                let b = try makeBackend(d, allowCreateBase: allowCreate)
                backend = b
                setDestStatus(d, "Connecting…")
                try await b.connect()
                let files = try await b.list()
                rts.append(DestRuntime(dest: d, backend: b, listing: files))
                setDestStatus(d, "Connected · \(files.count) files")
            } catch SyncError.destinationUnavailable(let m) {
                if let backend { await backend.close() }
                setDestStatus(d, "Waiting: \(m)")
                log.warning("\(d.name): \(m)")
            } catch {
                if let backend { await backend.close() }
                setDestStatus(d, "Error: \(error.localizedDescription)")
                log.error("\(d.name): \(ErrorInfo.describe(error))")
                hardError = error
            }
        }
        active = rts
        if rts.isEmpty { throw hardError ?? SyncError.destinationUnavailable("No destination is reachable") }

        // 2. Self-heal local state.
        inFlightLocalBytes = 0
        cleanStaging()
        for rt in rts { await rt.backend.cleanup() }
        if store.needsRebuild {
            await rebuildIndex(rts)
            try pauseCheck()
        }

        // A destination that suddenly lost many files or its identity marker may be unplugged/emptied: don't touch the ledger for it.
        var blocked = false
        for rt in rts {
            do {
                if let marker = try await rt.backend.readCanary() {
                    if marker != rt.key {
                        rt.unavailable = true
                        let msg = "Folder identity marker belongs to a different destination – check mounted volumes."
                        setDestStatus(rt.dest, "Error: \(msg)")
                        log.error("\(rt.name): \(msg)")
                        continue
                    }
                    if !store.hasCanary(rt.key) { store.markCanaryWritten(rt.key) }
                } else if !forceReconcile, store.hasCanary(rt.key), store.placementCount(rt.key) > 0, rt.names.isEmpty {
                    blocked = true
                    rt.unavailable = true
                    let msg = "Destination folder is empty and its identity marker is missing – the backing volume may be unmounted. Nothing was changed."
                    setDestStatus(rt.dest, "Error: \(msg)")
                    log.error("\(rt.name): \(msg)")
                    continue
                }
            } catch SyncError.destinationUnavailable(let m) {
                markUnavailable(rt, m)
                continue
            } catch {
                log.warning("\(rt.name): could not read destination marker: \(error.localizedDescription)")
            }

            let r = store.missingPlacements(dest: rt.key, existing: rt.names, sizes: rt.sizes)
            if !forceReconcile, r.total >= 5, Double(r.missing.count) > Double(r.total) * 0.2 {
                blocked = true
                rt.unavailable = true
                let msg = "\(r.missing.count) of \(r.total) synced files are missing or damaged – it may be unavailable or was emptied. Nothing was changed."
                setDestStatus(rt.dest, "Error: \(msg)")
                log.error("\(rt.name): \(msg)")
                continue
            }
            for zk in r.zeroByteKeys {
                if let actual = rt.actualNames[zk] {
                    try? await rt.backend.delete(name: actual)
                    rt.removeFile(name: actual)
                    log.warning("\(rt.name): removed 0-byte truncated file \(actual); will restore")
                }
            }
            store.dropPlacements(dest: rt.key, hashes: r.missing)
            if !r.missing.isEmpty {
                log.warning("\(rt.name): \(r.missing.count) previously synced file(s) are missing or truncated; they will be restored")
            }
            if !store.hasCanary(rt.key) || forceReconcile {
                if (try? await rt.backend.writeCanary(rt.key)) != nil {
                    store.markCanaryWritten(rt.key)
                }
            }
        }
        needsConfirmReconcile = blocked
        if forceReconcile { defaults.set(false, forKey: "forceReconcile") }
        try saveLedgerOrThrow()
        guard rts.contains(where: { !$0.unavailable }) else {
            throw SyncError.message("Every reachable destination looks emptied or unavailable. Check them, or choose “Re-sync Missing Files”.")
        }

        await purgeRetiredPreviews()

        // 3. Fill gaps from the other destinations first (cheap, and works without iCloud).
        try await mirror(rts)

        // 4. Scan the library off the main thread.
        phase = "Checking for new photos…"
        let known = store.completeIDs(for: rts.filter { !$0.unavailable }.map(\.key))
        let modDates = store.syncedModifiedDates
        let skip = includeBackedOff ? store.parkedIDs : store.backedOffIDs()      // parked items only ever retry manually
        let scan = await Task.detached { Self.scanLibrary(known: known, modifiedDates: modDates, skip: skip) }.value
        store.pruneFailures(keeping: scan.live)
        phase = nil
        total = scan.pending.count
        log.info("Found \(scan.pending.count) item(s) to sync")
        var syncedCount = 0
        var failedThisRun = 0
        var cloudThisRun = 0
        var syncedIDs: [String] = []
        refreshCounts()

        // 5. Sync with a bounded, byte-budgeted sliding window (4 concurrent workers across Folder, SMB,
        //    and pooled-channel SFTP, capped at 512 MB of in-flight staged data so large videos run solo),
        //    checkpointing the ledger every 10 completed items.
        var attempted = Set<String>()
        func processAll(_ list: [String]) async throws {
            guard !list.isEmpty else { return }
            let workerLimit = SyncPipelineGate.defaultMaxWorkers
            let pipelineGate = SyncPipelineGate(
                maxWorkers: workerLimit,
                maxInFlightBytes: SyncPipelineGate.defaultMaxInFlightBytes
            )

            let fetchPageSize = 64
            var prefetched: [String: PHAsset] = [:]
            var prefetchedUpTo = 0
            func assetForIndex(_ idx: Int) -> PHAsset? {
                if idx >= prefetchedUpTo {
                    prefetched.removeAll(keepingCapacity: true)
                    let end = min(idx + fetchPageSize, list.count)
                    let pageIDs = Array(list[idx ..< end])
                    PHAsset.fetchAssets(withLocalIdentifiers: pageIDs, options: nil)
                        .enumerateObjects { a, _, _ in prefetched[a.localIdentifier] = a }
                    prefetchedUpTo = end
                }
                return prefetched[list[idx]]
            }

            try await ensurePhotosAccess(requestIfNeeded: false)
            for rt in rts where !rt.unavailable {
                if !(await rt.backend.isAvailable()) { markUnavailable(rt, "connection lost") }
            }
            if rts.allSatisfy(\.unavailable) {
                throw SyncError.destinationUnavailable("All destinations became unavailable")
            }

            var nextIndex = 0
            var inFlightTasks = 0
            var completedSinceCheckpoint = 0
            var fatalError: Error?

            await withTaskGroup(of: (String, Result<ItemOutcome, Error>).self) { group in
                @MainActor func fillWindow() {
                    while fatalError == nil, nextIndex < list.count, inFlightTasks < workerLimit {
                        if isPaused || sleepPause || isTerminating || Task.isCancelled {
                            fatalError = SyncError.paused
                            break
                        }
                        let id = list[nextIndex]
                        let asset = assetForIndex(nextIndex)
                        let estBytes = asset.map(Self.estimatedBytes) ?? 50_000_000
                        nextIndex += 1
                        inFlightTasks += 1

                        group.addTask { @MainActor in
                            await pipelineGate.acquire(bytes: estBytes)
                            do {
                                try self.pauseCheck()
                                let outcome = try await self.syncOne(id: id, asset: asset)
                                await pipelineGate.release(bytes: estBytes)
                                return (id, .success(outcome))
                            } catch {
                                await pipelineGate.release(bytes: estBytes)
                                return (id, .failure(error))
                            }
                        }
                    }
                }

                fillWindow()

                while let (finishedID, result) = await group.next() {
                    inFlightTasks -= 1
                    switch result {
                    case .success(let outcome):
                        done += 1
                        attempted.insert(finishedID)
                        completedSinceCheckpoint += 1
                        switch outcome {
                        case .synced: syncedCount += 1; syncedIDs.append(finishedID)
                        case .failed: failedThisRun += 1
                        case .waitingForCloud: cloudThisRun += 1
                        case .vanished: break
                        }
                    case .failure(let err):
                        if fatalError == nil {
                            fatalError = err
                        } else if case SyncError.paused = fatalError!, !(err is CancellationError) {
                            if case SyncError.paused = err {} else { fatalError = err }
                        }
                        if isTerminating || Task.isCancelled {
                            group.cancelAll()
                        }
                    }

                    if fatalError == nil && completedSinceCheckpoint >= Self.chunkSize {
                        completedSinceCheckpoint = 0
                        await purgeRetiredPreviews()
                        do {
                            try saveLedgerOrThrow()
                            refreshCounts()
                            try await ensurePhotosAccess(requestIfNeeded: false)
                        } catch {
                            fatalError = error
                        }
                        if fatalError == nil {
                            for rt in rts where !rt.unavailable {
                                if !(await rt.backend.isAvailable()) { markUnavailable(rt, "connection lost") }
                            }
                            if rts.allSatisfy(\.unavailable) {
                                fatalError = SyncError.destinationUnavailable("All destinations became unavailable")
                            }
                        }
                    }

                    fillWindow()
                }
            }

            await purgeRetiredPreviews()
            if let fatalError {
                store.save()
                refreshCounts()
                throw fatalError
            }
            try saveLedgerOrThrow()
            refreshCounts()
        }
        try await processAll(scan.pending)

        // 5b. Sync complete: immediately retry items still waiting for iCloud that this pass
        //     skipped (their 5-minute timer hadn't elapsed). One extra pass per run, never a loop.
        try pauseCheck()
        let retryIDs = store.freshCloudWaitingIDs.subtracting(attempted).intersection(scan.live).sorted()
        if !retryIDs.isEmpty {
            total += retryIDs.count
            log.info("Sync complete; retrying \(retryIDs.count) item(s) waiting for iCloud download now")
            try await processAll(retryIDs)
        }

        // If nothing at all could be downloaded, this is a Photos/iCloud problem, not a transient one.
        if cloudThisRun >= 20 && syncedCount == 0 {
            let n = store.cloudWaitingCount
            cloudDiagnosis = "Photos can't download \(n) originals: iCloud refuses the download. Waiting won't fix this – see Settings › Activity."
            log.error("\(n) photo(s) can't be downloaded: macOS Photos reports that iCloud failed to deliver the originals (PhotoKit error -1, nothing local). Check iCloud Photos status in Photos and on your iPhone; retries are backing off.")
        } else if syncedCount > 0 || store.cloudWaitingCount < 20 {
            cloudDiagnosis = nil
        }

        // 6. Bring destinations level again (a destination that failed mid-item catches up from the others).
        try await mirror(rts)
        await purgeRetiredPreviews()
        await scrubSample(rts)

        // 7. Delete from iCloud (verified on EVERY destination, persisted queue).
        try pauseCheck()
        if deleteAfterSync {
            await planDeletions(syncedThisRun: syncedIDs)
            try saveLedgerOrThrow()
            refreshCounts()
            try pauseCheck()
            if shouldAutoProcessDeletions {
                await processDeleteQueue(manual: false)
                await updatePendingDeleteBytes()
                refreshCounts()
            } else if !store.pendingDelete.isEmpty {
                let sz = pendingDeleteBytes > 0
                    ? " (\(ByteCountFormatter.string(fromByteCount: pendingDeleteBytes, countStyle: .file)))" : ""
                if let scheduled = autoConfirm.deferredScheduleDescription {
                    log.info("Holding \(store.pendingDelete.count) item(s)\(sz) in deletion queue until \(scheduled)")
                } else if holdThresholdEnabled {
                    log.info("Holding \(store.pendingDelete.count) item(s)\(sz) in deletion queue until it reaches \(holdThresholdGB) GB (or manual delete)")
                } else {
                    log.info("Holding \(store.pendingDelete.count) item(s)\(sz) in deletion queue until manually triggered from the menu")
                }
            }
        }
        try saveLedgerOrThrow()
        for rt in rts where !rt.unavailable { setDestStatus(rt.dest, "Up to date") }
        if previewsSaved > 0 { log.info("Saved \(previewsSaved) preview(s) of photos whose originals aren't available yet") }
        let summary = "Sync finished: \(syncedCount) synced, \(failedThisRun) failed, \(cloudThisRun) waiting for iCloud, \(store.failureCount + store.cloudWaitingCount) total awaiting retry"
        if failedThisRun > 0 || cloudThisRun > 0 { log.warning(summary) } else { log.info(summary) }
    }

    nonisolated private static func libraryFetchOptions() -> PHFetchOptions {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.includeAssetSourceTypes = [.typeUserLibrary]   // shared-album items can't be deleted/owned
        return opts
    }

    nonisolated private static func allLibraryIDs() -> [String] {
        var ids: [String] = []
        PHAsset.fetchAssets(with: libraryFetchOptions()).enumerateObjects { a, _, _ in
            ids.append(a.localIdentifier)
        }
        return ids
    }

    nonisolated private static func scanLibrary(known: Set<String>, modifiedDates: [String: Date], skip: Set<String>)
        -> (pending: [String], live: Set<String>) {
        var pending: [String] = []
        var live = Set<String>()
        PHAsset.fetchAssets(with: libraryFetchOptions()).enumerateObjects { a, _, _ in
            let id = a.localIdentifier
            live.insert(id)
            guard !skip.contains(id) else { return }
            if !known.contains(id) {
                pending.append(id)
            } else if let syncedMod = modifiedDates[id] {
                if syncedMod == .distantPast {
                    pending.append(id)
                } else if let curMod = a.modificationDate, curMod.timeIntervalSince(syncedMod) > 1.0 {
                    pending.append(id)
                }
            }
        }
        return (pending, live)
    }

    private func ensurePhotosAccess(requestIfNeeded: Bool) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined && requestIfNeeded {
            NSApp.activate(ignoringOtherApps: true)
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized: return
        case .limited:
            throw SyncError.permission("Photos access is limited to selected photos. Allow full access in System Settings › Privacy & Security › Photos.")
        default:
            throw SyncError.permission("Photos access denied. Enable it in System Settings › Privacy & Security › Photos.")
        }
    }

    // MARK: Local housekeeping
    private var stagingDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSyncer-staging", isDirectory: true)
    }

    private func cleanStaging() {
        try? FileManager.default.removeItem(at: stagingDir)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    }

    nonisolated private static func localFreeSpace(at dir: URL) -> Int64? {
        if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free > 0 {
            return free
        }
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: dir.path)[.systemFreeSize] as? NSNumber)?
            .int64Value, free > 0 {
            return free
        }
        return nil
    }

    private func ensureLocalSpace(needed: Int64) throws {
        let appSupport = SandboxCompat.appSupportDirectory
        let stagingParent = stagingDir.deletingLastPathComponent()
        let required = inFlightLocalBytes + max(needed, 0) + Self.localReserveBytes
        for dir in [appSupport, stagingParent] {
            if let free = Self.localFreeSpace(at: dir), free < required {
                throw SyncError.localDiskFull
            }
        }
    }

    private func reserveLocalSpace(needed: Int64) throws {
        let clamped = max(needed, 0)
        try ensureLocalSpace(needed: clamped)
        inFlightLocalBytes += clamped
    }

    private func releaseLocalSpace(needed: Int64) {
        inFlightLocalBytes = max(0, inFlightLocalBytes - max(needed, 0))
    }

    /// Verifies a small rolling slice (up to 3 files per local/SMB destination per run) with `F_NOCACHE`
    /// to catch silent media corruption early.
    private func scrubSample(_ rts: [DestRuntime]) async {
        var droppedAny = false
        for rt in rts where !rt.unavailable && rt.dest.kind != .sftp {
            let offset = scrubOffsets[rt.key] ?? 0
            let (slice, next) = store.placementSlice(dest: rt.key, offset: offset, count: 3)
            guard !slice.isEmpty else { continue }
            scrubOffsets[rt.key] = next
            for item in slice {
                if isPaused || sleepPause || isTerminating || Task.isCancelled { return }
                let k = FileNames.key(item.name)
                guard rt.names.contains(k) else { continue }
                do {
                    let actual = try await rt.backend.hash(of: rt.actualNames[k] ?? item.name, noCache: true)
                    if actual != item.hash {
                        store.dropPlacements(dest: rt.key, hashes: [item.hash])
                        droppedAny = true
                        log.error("Integrity check failed for \(item.name) at \(rt.name) (checksum mismatch); queued for restore")
                    }
                } catch SyncError.destinationUnavailable(let m) {
                    markUnavailable(rt, m)
                    break
                } catch {
                    log.warning("Could not verify \(item.name) at \(rt.name): \(error.localizedDescription)")
                }
            }
        }
        if droppedAny { store.save() }
    }

    /// After a corrupt ledger: learn what's already in each destination so nothing is duplicated.
    private func rebuildIndex(_ rts: [DestRuntime]) async {
        for rt in rts where !rt.unavailable {
            let alreadyKnown = store.knownNames(rt.key)
            var n = 0
            for f in rt.listing {
                if isPaused || sleepPause || isTerminating || Task.isCancelled {
                    store.save()
                    phase = nil
                    return
                }
                n += 1
                if alreadyKnown.contains(FileNames.key(f.name)) { continue }
                phase = "Rebuilding index: \(rt.name) (\(n)/\(rt.listing.count))…"
                if let h = try? await rt.backend.hash(of: f.name, noCache: false) {
                    if store.placement(rt.key, hash: h) == nil { store.addPlacement(rt.key, hash: h, name: f.name, size: f.size) }
                    else { store.addKnownName(rt.key, f.name) }
                }
                if n % 10 == 0 { store.save() }
            }
        }
        store.needsRebuild = false
        store.save()
        phase = nil
    }

    // MARK: Destination ↔ destination sync (eventual consistency)
    /// Copies every file that exists in one destination but not in another. Copy-only: a file the
    /// user deletes from one destination is restored from another; nothing is ever deleted.
    /// Content is matched by SHA-256, never by name, so renamed/duplicated files can't ping-pong.
    private func mirror(_ rts: [DestRuntime]) async throws {
        let live = rts.filter { !$0.unavailable }
        guard mirrorEnabled, live.count >= 2 else { return }
        defer { phase = nil }

        // A. Learn files this ledger has never seen (added by hand, by older versions, …).
        for rt in live {
            let known = store.knownNames(rt.key)
            let unknown = rt.listing.filter { !known.contains(FileNames.key($0.name)) }
            guard !unknown.isEmpty else { continue }
            log.info("Indexing \(unknown.count) unfamiliar file(s) in \(rt.name)")
            for (i, f) in unknown.enumerated() {
                try pauseCheck()
                phase = "Indexing \(rt.name) (\(i + 1)/\(unknown.count))…"
                do {
                    let h = try await rt.backend.hash(of: f.name, noCache: false)
                    if store.placement(rt.key, hash: h) == nil { store.addPlacement(rt.key, hash: h, name: f.name, size: f.size) }
                    else { store.addKnownName(rt.key, f.name) }       // same content under another name: leave it alone
                } catch SyncError.destinationUnavailable(let m) {
                    markUnavailable(rt, m); break
                } catch {
                    log.warning("Could not index \(f.name) in \(rt.name): \(error.localizedDescription)")
                }
                if (i + 1) % 10 == 0 { store.save() }
            }
            store.save()
        }

        // B. Copy what each destination is missing from a destination that has it.
        var copied = 0
        var failed = 0
        let all = store.allHashes
        for dst in live where !dst.unavailable {
            let missing = all.subtracting(store.hashes(in: dst.key)).sorted()
            guard !missing.isEmpty else { continue }
            log.info("Syncing \(missing.count) file(s) into \(dst.name)")
            var consecutiveFailures = 0
            for (i, hash) in missing.enumerated() {
                try pauseCheck()
                guard !dst.unavailable, consecutiveFailures < 5 else { break }
                let sources = live.filter { !$0.unavailable && $0.key != dst.key && store.placement($0.key, hash: hash) != nil }
                guard !sources.isEmpty else { continue }
                phase = "Syncing destinations → \(dst.name) (\(i + 1)/\(missing.count))…"
                var success = false
                for src in sources {
                    guard let srcName = store.placement(src.key, hash: hash) else { continue }
                    do {
                        try await copyBetween(src, dst, name: srcName, hash: hash)
                        success = true
                        break
                    } catch SyncError.destinationUnavailable(let m) {
                        if await src.backend.isAvailable() { markUnavailable(dst, m) } else { markUnavailable(src, m) }
                        if dst.unavailable { break }
                    } catch {
                        log.error("Copy \(srcName): \(src.name) → \(dst.name) failed: \(error.localizedDescription)")
                    }
                }
                if success { copied += 1; consecutiveFailures = 0 } else { failed += 1; consecutiveFailures += 1 }
                if copied > 0 && copied % 10 == 0 { store.save() }
            }
        }
        store.clearCompletedFailures(dests: live.filter { !$0.unavailable }.map(\.key))
        store.save()
        refreshCounts()
        if copied > 0 || failed > 0 {
            let msg = "Destination sync: copied \(copied) file(s), \(failed) failed"
            if failed > 0 { log.warning(msg) } else { log.info(msg) }
        }
    }

    /// Download from `src`, prove the bytes still match their checksum (catches a corrupted source),
    /// then upload with the same verification as any other copy.
    private func copyBetween(_ src: DestRuntime, _ dst: DestRuntime, name: String, hash: String) async throws {
        let expected = Int64(store.expectedSize(hash) ?? 50_000_000)
        try ensureLocalSpace(needed: expected)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }

        let date = try await src.backend.download(name: name, to: staged)
        guard let size = FileHash.size(of: staged), size > 0 else {
            throw SyncError.message("\(name) in \(src.name) is empty or unreadable")
        }
        guard try await FileHash.sha256(of: staged) == hash else {
            throw SyncError.message("\(name) in \(src.name) no longer matches its checksum (corrupted or modified)")
        }
        let resolved = try await resolveAndReserveTargetName(
            name, stamp: Int(date?.timeIntervalSince1970 ?? 0),
            size: size, hash: hash, in: dst)
        if !resolved.alreadyPresent {
            do {
                try await dst.backend.upload(local: staged, as: resolved.name, size: size, hash: hash, date: date)
                dst.recordFile(name: resolved.name, size: size)
            } catch {
                dst.releaseReservation(name: resolved.name)
                throw error
            }
        }
        store.addPlacement(dst.key, hash: hash, name: resolved.name, size: size)
    }

    // MARK: Export
    nonisolated private static func isDiskFull(_ error: Error) -> Bool {
        if case SyncError.diskFull = error { return true }
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
            || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC))
    }

    /// Up to 3 attempts (2s, 4s backoff). Only destinations still missing the asset (or needing an edit refresh) are retried.
    private func exportWithRetry(id: String, asset: PHAsset, tracker: AttemptTracker) async throws {
        var lastErr: Error = SyncError.message("Unknown error")
        for attempt in 1...3 {
            try pauseCheck()
            let editRefresh = store.needsEditRefresh(id, modifiedAt: asset.modificationDate)
            let targets = active.filter { !$0.unavailable && (editRefresh || !store.isComplete(id, dest: $0.key)) }
            if targets.isEmpty {
                if store.entry(id) != nil { return }                           // finished on every reachable destination
                throw SyncError.destinationUnavailable("All destinations became unavailable")
            }
            do { try await export(id: id, asset: asset, targets: targets, tracker: tracker); return }
            catch SyncError.paused { throw SyncError.paused }
            catch SyncError.diskFull { throw SyncError.diskFull }
            catch SyncError.localDiskFull { throw SyncError.localDiskFull }
            catch {
                if case SyncError.cloudOnly = error { throw error }       // retrying won't help
                if case SyncError.destinationUnavailable = error { throw error }
                if Self.isDiskFull(error) { throw SyncError.diskFull }
                try pauseCheck()
                lastErr = error
                if attempt < 3 { try? await Task.sleep(for: .seconds(Double(1 << attempt))) }
            }
        }
        throw lastErr
    }

    nonisolated private static func exportPlan(_ resources: [PHAssetResource]) -> [PHAssetResource] {
        resources
            .filter { exportOrder.contains($0.type) }
            .sorted { (exportOrder.firstIndex(of: $0.type) ?? 99) < (exportOrder.firstIndex(of: $1.type) ?? 99) }
    }

    nonisolated private static func fingerprint(_ a: PHAsset, _ r: PHAssetResource) -> String {
        "\(r.originalFilename)|\(Int(a.creationDate?.timeIntervalSince1970 ?? 0))|\(a.pixelWidth)x\(a.pixelHeight)|\(Int(a.duration))"
    }

    /// Exports every media resource of the asset (original, edited render, RAW/JPEG pair,
    /// Live Photo video) to every target destination so nothing is lost if the asset is later
    /// deleted from iCloud. Each resource is downloaded and hashed ONCE, then placed on each target.
    private func export(id: String, asset: PHAsset, targets: [DestRuntime], tracker: AttemptTracker) async throws {
        let plan = Self.exportPlan(PHAssetResource.assetResources(for: asset))
        guard let primary = plan.first else { throw SyncError.message("No exportable resource") }
        // Never treat an edited render as the original: the original resource must exist.
        let originalType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard primary.type == originalType else {
            throw SyncError.message("No original resource available (only \(primary.type.rawValue) found); will retry")
        }
        let hasEdits = plan.contains { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }

        // Metadata-only modificationDate bump (e.g. Favorited or album change) on an unedited item:
        // update the recorded timestamp without re-downloading originals from iCloud.
        if let existing = store.entry(id), existing.verified, !hasEdits,
           Set(plan.map { $0.type.rawValue }) == Set(existing.parts.map(\.type)),
           targets.allSatisfy({ store.isComplete(id, dest: $0.key) }) {
            store.updateModifiedAt(id: id, modifiedAt: asset.modificationDate)
            return
        }

        if hasEdits { log.info("\(primary.originalFilename) has edits: saving the original plus an '-edited' copy") }

        // Photos IDs can change (library restore, new Mac). If this exact item is already at every
        // target, skip the download – but never auto-delete it, since it isn't hash-verified.
        let fp = Self.fingerprint(asset, primary)
        if !hasEdits, let parts = store.fingerprint(fp), targets.allSatisfy({ store.hasAll(parts, dest: $0.key) }) {
            recordDuplicate("Duplicate skipped: \(primary.originalFilename) is already in the destination(s) (Photos ID changed)")
            store.recordSynced(id: id, entry: Entry(parts: parts, verified: false, modifiedAt: asset.modificationDate), fingerprint: nil)
            return
        }

        let estimated = Self.estimatedBytes(asset)
        try reserveLocalSpace(needed: estimated)
        defer { releaseLocalSpace(needed: estimated) }

        // Destinations that can't hold this asset are skipped for it (and reported), not run-fatal.
        var failed: [(DestRuntime, Error)] = []
        var remaining: [DestRuntime] = []
        var reservedSpaceOn: [DestRuntime] = []
        var writtenBytesByDest: [String: Int64] = [:]
        defer {
            for rt in reservedSpaceOn {
                rt.settleSpace(reservedBytes: estimated, writtenBytes: writtenBytesByDest[rt.key] ?? 0)
            }
        }
        for rt in targets {
            if await rt.reserveSpace(estimatedBytes: estimated) {
                remaining.append(rt)
                reservedSpaceOn.append(rt)
            } else {
                failed.append((rt, SyncError.diskFull))
            }
        }
        if remaining.isEmpty { throw SyncError.diskFull }

        let exportFolder = active.first(where: { !$0.unavailable && $0.backend.localRoot != nil })?.backend.localRoot
        let base = (primary.originalFilename as NSString).deletingPathExtension
        var parts: [Part] = []
        for (i, res) in plan.enumerated() {
            try pauseCheck()
            // Immutable original parts already placed on every target need not be re-downloaded when syncing new edits.
            let isImmutableOriginal = (res.type == .photo || res.type == .video
                || res.type == .alternatePhoto || res.type == .pairedVideo)
            if isImmutableOriginal,
               let existing = store.entry(id), existing.verified,
               let prevPart = existing.parts.first(where: { $0.type == res.type.rawValue }),
               remaining.allSatisfy({ rt in
                   guard let placedName = store.placement(rt.key, hash: prevPart.hash) else { return false }
                   return rt.names.contains(FileNames.key(placedName))
               }) {
                parts.append(prevPart)
                continue
            }

            let staged = try await stageResource(res, asset: asset, isPrimary: i == 0, hasEdits: hasEdits, exportFolder: exportFolder)
            defer { try? FileManager.default.removeItem(at: staged.url) }
            parts.append(Part(hash: staged.hash, type: res.type.rawValue, size: staged.size))

            let liveTargets = remaining.filter { !$0.unavailable }
            if liveTargets.count <= 1 {
                for rt in liveTargets {
                    do {
                        let uploaded = try await place(
                            staged, res: res, asset: asset, primaryBase: base,
                            isPrimary: i == 0, tracker: tracker, on: rt)
                        if uploaded { writtenBytesByDest[rt.key, default: 0] += Int64(staged.size) }
                    } catch {
                        if !(await rt.backend.isAvailable()) {
                            markUnavailable(rt, "connection lost during copy")
                        } else {
                            failed.append((rt, error))
                            log.error("\(rt.name): \(res.originalFilename) failed: \(ErrorInfo.describe(error))")
                        }
                        remaining.removeAll { $0 === rt }
                    }
                }
            } else {
                await withTaskGroup(of: (DestRuntime, Result<Bool, Error>).self) { destGroup in
                    for rt in liveTargets {
                        destGroup.addTask { @MainActor in
                            do {
                                let uploaded = try await self.place(
                                    staged, res: res, asset: asset, primaryBase: base,
                                    isPrimary: i == 0, tracker: tracker, on: rt)
                                return (rt, .success(uploaded))
                            } catch {
                                return (rt, .failure(error))
                            }
                        }
                    }
                    while let (rt, resOutcome) = await destGroup.next() {
                        switch resOutcome {
                        case .success(let uploaded):
                            if uploaded { writtenBytesByDest[rt.key, default: 0] += Int64(staged.size) }
                        case .failure(let error):
                            if !(await rt.backend.isAvailable()) {
                                markUnavailable(rt, "connection lost during copy")
                            } else {
                                failed.append((rt, error))
                                log.error("\(rt.name): \(res.originalFilename) failed: \(ErrorInfo.describe(error))")
                            }
                            remaining.removeAll { $0 === rt }
                        }
                    }
                }
            }
        }
        if remaining.isEmpty && failed.isEmpty && targets.allSatisfy(\.unavailable) {
            throw SyncError.destinationUnavailable("Destination became unavailable during sync")
        }
        // Record what was learned even if some destinations failed: they retry on their own.
        store.recordSynced(id: id, entry: Entry(parts: parts, verified: true, modifiedAt: asset.modificationDate), fingerprint: fp)
        if !failed.isEmpty {
            if failed.count == targets.count && failed.allSatisfy({ Self.isDiskFull($0.1) }) { throw SyncError.diskFull }
            throw SyncError.message(failed.map { "\($0.0.name): \($0.1.localizedDescription)" }.joined(separator: "; "))
        }
    }

    nonisolated private static func estimatedBytes(_ asset: PHAsset) -> Int64 {
        asset.mediaType == .video ? Int64(asset.duration * 8_000_000) : 50_000_000
    }

    /// Photos exports the original into a hidden folder inside a folder destination (it can write there),
    /// then we move it to local staging so it goes through the normal hash/verify/copy pipeline.
    private func stageViaPhotosApp(_ asset: PHAsset, to staged: URL, folder root: URL) async throws {
        let folder = root.appendingPathComponent(".photosyncer-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await PhotosApp.exportOriginal(localIdentifier: asset.localIdentifier, into: folder)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: file, to: staged)
    }

    private func openPhotosApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Photos.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    private func recordDuplicate(_ message: String) {
        store.noteDuplicate()
        duplicatesFound = store.duplicateCount
        log.info(message)
    }

    /// Download from Photos into local staging (never straight onto a destination), validate it is
    /// the real full-resolution original, and hash it.
    private func stageResource(_ res: PHAssetResource, asset: PHAsset, isPrimary: Bool, hasEdits: Bool,
                               exportFolder: URL?) async throws -> StagedFile {
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent(UUID().uuidString)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: staged) } }

        do {
            if let note = try await ResourceWriter.write(res, asset: asset, to: staged) {
                log.warning("\(res.originalFilename): \(note)")
            }
        } catch SyncError.cloudOnly(let details) {
            // PhotoKit can't fetch it. Ask the Photos app itself (forces its own iCloud download).
            guard isPrimary, let exportFolder, photosFallbackFailures < 3, Date() >= photosFallbackBlockedUntil else {
                throw SyncError.cloudOnly(details)
            }
            do {
                try await stageViaPhotosApp(asset, to: staged, folder: exportFolder)
                photosFallbackFailures = 0
                log.warning("\(res.originalFilename): PhotoKit could not download it; got the original through the Photos app")
            } catch {
                photosFallbackFailures += 1
                if photosFallbackFailures >= 3 {
                    photosFallbackBlockedUntil = Date().addingTimeInterval(30 * 60)
                    log.warning("Photos-app download route paused for 30 minutes after 3 failures in a row")
                }
                if case SyncError.automationDenied = error { needsAutomationSettings = true }
                throw SyncError.cloudOnly("\(details) | Photos app: \(error.localizedDescription)")
            }
        }
        let isImage = res.contentType.conforms(to: .image) || (isPrimary && asset.mediaType == .image)
        let isVideo = !isImage && (res.contentType.conforms(to: .audiovisualContent) || (isPrimary && asset.mediaType == .video))
        let declaredUTI = res.uniformTypeIdentifier
        let expectedW = asset.pixelWidth
        let expectedH = asset.pixelHeight

        if isImage {
            try await Task.detached {
                guard let sz = FileHash.size(of: staged), sz > 0 else {
                    throw SyncError.message("Downloaded file is empty")
                }
                try Self.verifyImage(
                    staged, declaredUTI: declaredUTI,
                    expectedWidth: expectedW, expectedHeight: expectedH,
                    isPrimary: isPrimary, hasEdits: hasEdits)
            }.value
        } else {
            guard let sz = FileHash.size(of: staged), sz > 0 else {
                throw SyncError.message("Downloaded file is empty")
            }
            if isVideo {
                try await Self.verifyVideo(staged, asset: asset, isPrimary: isPrimary, hasEdits: hasEdits)
            }
        }
        let (hash, size) = try await FileHash.sha256AndSize(of: staged)   // checksum + exact byte size of the true original
        guard size > 0 else { throw SyncError.message("Downloaded file is empty") }
        success = true
        return StagedFile(url: staged, size: size, hash: hash)
    }

    /// Put one staged file on one destination: dedupe by content (including against concurrent workers),
    /// else atomically reserve a collision-free filename and perform a verified upload.
    /// Returns `true` when new bytes were written to `rt`.
    private func place(_ staged: StagedFile, res: PHAssetResource, asset: PHAsset, primaryBase: String,
                       isPrimary: Bool, tracker: AttemptTracker, on rt: DestRuntime) async throws -> Bool {
        let marker = "\(rt.key):\(staged.hash)"
        _ = await rt.hashGate.waitIfInFlight(key: staged.hash)
        if let existing = store.placement(rt.key, hash: staged.hash),
           rt.names.contains(FileNames.key(existing)),
           rt.sizes[FileNames.key(existing)].map({ $0 == staged.size }) ?? true {
            if !tracker.markers.contains(marker) {      // a file we just wrote for this asset isn't a duplicate
                recordDuplicate("Duplicate skipped at \(rt.name): \(res.originalFilename) is identical to \(existing)")
            }
            return false
        }
        rt.hashGate.begin(key: staged.hash)
        defer { rt.hashGate.end(key: staged.hash) }

        let preferred = Self.targetName(res, primaryBase: primaryBase, isPrimary: isPrimary)
        let resolved = try await resolveAndReserveTargetName(
            preferred, stamp: Int(asset.creationDate?.timeIntervalSince1970 ?? 0),
            size: staged.size, hash: staged.hash, in: rt)
        var wroteBytes = false
        if !resolved.alreadyPresent {
            do {
                try await rt.backend.upload(local: staged.url, as: resolved.name, size: staged.size, hash: staged.hash, date: asset.creationDate)
                rt.recordFile(name: resolved.name, size: staged.size)
                wroteBytes = true
            } catch {
                rt.releaseReservation(name: resolved.name)
                throw error
            }
        } else {
            log.info("Adopted existing verified file \(resolved.name) at \(rt.name)")
        }
        store.addPlacement(rt.key, hash: staged.hash, name: resolved.name, size: staged.size)
        tracker.markers.insert(marker)
        return wroteBytes
    }

    /// Proves a staged image decodes, matches its declared format, and (when it is the primary
    /// resource of an unedited asset) matches the library's full pixel dimensions.
    nonisolated private static func verifyImage(_ url: URL, declaredUTI: String,
                                                expectedWidth: Int, expectedHeight: Int,
                                                isPrimary: Bool, hasEdits: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw SyncError.message("Exported image cannot be decoded (corrupt or incomplete)")
        }
        if let actual = CGImageSourceGetType(src).flatMap({ UTType($0 as String) }),
           let declared = UTType(declaredUTI),
           !actual.conforms(to: declared) && !declared.conforms(to: actual) {
            throw SyncError.message("Exported format \(actual.identifier) differs from declared \(declared.identifier)")
        }
        guard isPrimary, !hasEdits,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              expectedWidth > 0, expectedHeight > 0 else { return }
        // Orientation may swap width/height, so compare as an unordered pair.
        let same = (w == expectedWidth && h == expectedHeight) || (w == expectedHeight && h == expectedWidth)
        if !same {
            throw SyncError.message("Exported image is \(w)×\(h) but the original is \(expectedWidth)×\(expectedHeight) – not full resolution")
        }
    }

    /// Proves a staged video container is playable, carries a valid video track, and wasn't truncated.
    nonisolated private static func verifyVideo(_ url: URL, asset: PHAsset, isPrimary: Bool, hasEdits: Bool) async throws {
        let av = AVURLAsset(url: url)
        let playable = (try? await av.load(.isPlayable)) ?? false
        guard playable else {
            throw SyncError.message("Exported video cannot be played (corrupt or truncated)")
        }
        let tracks = (try? await av.loadTracks(withMediaType: .video)) ?? []
        guard let track = tracks.first else {
            throw SyncError.message("Exported video contains no video track")
        }
        if let size = try? await track.load(.naturalSize), size.width <= 0 || size.height <= 0 {
            throw SyncError.message("Exported video has invalid frame dimensions")
        }
        let dur = (try? await av.load(.duration)) ?? .zero
        guard dur.isNumeric, dur.seconds > 0 else {
            throw SyncError.message("Exported video has invalid or zero duration")
        }
        if isPrimary, !hasEdits, !asset.mediaSubtypes.contains(.videoHighFrameRate), asset.duration > 2.0 {
            if dur.seconds < asset.duration * 0.8 {
                throw SyncError.message(
                    String(format: "Exported video is %.1f s but expected %.1f s (truncated)", dur.seconds, asset.duration))
            }
        }
    }

    nonisolated private static func targetName(_ res: PHAssetResource, primaryBase: String, isPrimary: Bool) -> String {
        let clean = FileNames.sanitize(res.originalFilename)
        if isPrimary { return clean }
        if res.type == .fullSizePhoto || res.type == .fullSizeVideo {
            let ext = (clean as NSString).pathExtension
            return FileNames.sanitize("\(primaryBase)-edited" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        return clean
    }

    /// Picks and atomically reserves a destination filename that doesn't collide (case-insensitively) with
    /// committed or in-flight files, while adopting an already-present byte-identical file (e.g. from an
    /// earlier run interrupted before the ledger was saved) instead of duplicating it under a `_<stamp>` suffix.
    /// When `alreadyPresent == false`, the returned `name` is reserved in `rt.nameBook` and MUST be committed
    /// via `rt.recordFile` or released via `rt.releaseReservation`.
    private func resolveAndReserveTargetName(_ name: String, stamp: Int, size: UInt64, hash: String,
                                             in rt: DestRuntime) async throws -> (name: String, alreadyPresent: Bool) {
        func tryClaimOrAdopt(_ candidate: String) async throws -> (name: String, alreadyPresent: Bool)? {
            if rt.nameBook.reserve(candidate) {
                return (candidate, false)
            }
            guard let existing = rt.nameBook.unreservedExisting(candidate) else {
                return nil
            }
            guard existing.size == size else {
                return nil
            }
            guard rt.nameBook.lockExistingForInspection(candidate) else {
                return nil
            }
            defer { rt.nameBook.releaseReservation(candidate) }
            do {
                if try await rt.backend.hash(of: existing.actualName, noCache: true) == hash {
                    return (existing.actualName, true)
                }
            } catch SyncError.destinationUnavailable(let m) {
                throw SyncError.destinationUnavailable(m)
            } catch {
                // Unreadable foreign file under that name: treat as occupied and pick a unique suffix.
            }
            return nil
        }

        if let claimed = try await tryClaimOrAdopt(name) {
            return claimed
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func candidate(_ suffix: String) -> String {
            let n = "\(base)_\(stamp)\(suffix)"
            return ext.isEmpty ? n : "\(n).\(ext)"
        }
        var result = candidate("")
        var n = 1
        while true {
            if let claimed = try await tryClaimOrAdopt(result) {
                return claimed
            }
            result = candidate("_\(n)")
            n += 1
        }
    }

    // MARK: Previews (best local version while the original is unavailable)
    /// Saves "<name>-preview.<ext>" (raw local derivative, metadata-enriched image, or compressed local video)
    /// to every reachable destination. Tracked apart from real originals: never counts as synced and never
    /// makes an item eligible for iCloud deletion.
    private func savePreview(id: String, asset: PHAsset, fileName: String) async -> LocalPreview.Result? {
        let targets = active.filter { !$0.unavailable }
        guard savePreviews, !targets.isEmpty else { return nil }
        if let p = store.preview(id),
           p.version == SyncedStore.Preview.currentVersion,
           targets.allSatisfy({ store.placement($0.key, hash: p.hash) != nil }) {
            let ext = targets.compactMap { store.placement($0.key, hash: p.hash) }
                .first.map { ($0 as NSString).pathExtension.lowercased() } ?? "png"
            let cleanExt = ext.isEmpty ? "png" : ext
            return LocalPreview.Result(ext: cleanExt, isVideo: ["mp4", "mov", "m4v"].contains(cleanExt))
        }

        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let preview = await LocalPreview.write(for: asset, to: staged),
              let size = FileHash.size(of: staged), size > 0,
              let hash = try? await FileHash.sha256(of: staged) else {
            log.debug("No local preview available for \(fileName)")
            return nil
        }

        let base = (fileName as NSString).deletingPathExtension
        var saved = false
        var uploadedNew = false
        for rt in targets {
            if let existing = store.placement(rt.key, hash: hash), rt.names.contains(FileNames.key(existing)) {
                saved = true; continue
            }
            let preferred = FileNames.sanitize("\(base)-preview.\(preview.ext)")
            do {
                _ = await rt.hashGate.waitIfInFlight(key: hash)
                if let existing = store.placement(rt.key, hash: hash), rt.names.contains(FileNames.key(existing)) {
                    saved = true; continue
                }
                rt.hashGate.begin(key: hash)
                defer { rt.hashGate.end(key: hash) }

                let resolved = try await resolveAndReserveTargetName(
                    preferred, stamp: Int(asset.creationDate?.timeIntervalSince1970 ?? 0),
                    size: size, hash: hash, in: rt)
                if !resolved.alreadyPresent {
                    do {
                        try await rt.backend.upload(local: staged, as: resolved.name, size: size, hash: hash, date: asset.creationDate)
                        rt.recordFile(name: resolved.name, size: size)
                        uploadedNew = true
                    } catch {
                        rt.releaseReservation(name: resolved.name)
                        throw error
                    }
                }
                store.addPlacement(rt.key, hash: hash, name: resolved.name, size: size)
                saved = true
            } catch {
                log.warning("Could not save a preview of \(fileName) to \(rt.name): \(error.localizedDescription)")
            }
        }
        if saved { store.setPreview(id, hash: hash) }       // retires any older, lower-fidelity preview hash
        if uploadedNew { previewsSaved += 1 }
        return saved ? preview : nil
    }

    /// Removes retired previews from each destination once that destination holds either the verified
    /// full original or a newer replacement preview, and only if the file still hashes to what we wrote.
    private func purgeRetiredPreviews() async {
        let retired = store.retiredPreviews
        guard !retired.isEmpty else { return }
        var removed = 0
        for (hash, assetID) in retired {
            if store.isLivePreview(hash) { store.clearRetired(hash); continue }
            for rt in active where !rt.unavailable {
                guard let name = store.placement(rt.key, hash: hash) else { continue }
                let hasOriginal = store.isComplete(assetID, dest: rt.key)
                let hasNewerPreview = store.preview(assetID).map {
                    $0.hash != hash && store.placement(rt.key, hash: $0.hash) != nil
                } ?? false
                guard hasOriginal || hasNewerPreview else { continue }              // no replacement here yet: keep it
                do {
                    if rt.names.contains(FileNames.key(name)),
                       try await rt.backend.hash(of: name, noCache: false) == hash { // never delete something that isn't our preview
                        try await rt.backend.delete(name: name)
                        removed += 1
                    }
                    store.dropPlacements(dest: rt.key, hashes: [hash])
                    rt.removeFile(name: name)
                } catch {
                    log.warning("Could not remove preview \(name) from \(rt.name): \(error.localizedDescription)")
                }
            }
            if !store.anyPlacement(hash) { store.clearRetired(hash) }               // fully cleaned up everywhere
        }
        if removed > 0 {
            log.info("Removed \(removed) superseded preview file(s)")
            store.save()
        }
    }

    // MARK: One item
    private enum ItemOutcome { case synced, failed, waitingForCloud, vanished }

    /// Syncs one asset to every destination that still needs it and does the ledger bookkeeping.
    /// Counts update live. Throws only for run-level problems.
    private func syncOne(id: String, asset: PHAsset?) async throws -> ItemOutcome {
        guard let asset else { return .vanished }                   // vanished from the library
        let wasTracked = store.isFailing(id)
        let tracker = AttemptTracker()
        do {
            try await exportWithRetry(id: id, asset: asset, tracker: tracker)
            if wasTracked && !store.isFailing(id) { refreshCounts() }   // live decrease
            return .synced
        } catch SyncError.diskFull {
            store.save()
            throw SyncError.diskFull                                // every destination is full: stop the run
        } catch SyncError.localDiskFull {
            store.save()
            throw SyncError.localDiskFull                           // startup disk is low: stop the run
        } catch SyncError.cloudOnly(let details) {
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? id
            let preview = await savePreview(id: id, asset: asset, fileName: name)
            let msg: String
            if let preview {
                msg = preview.isVideo ? "Waiting for iCloud download – video preview saved"
                                      : "Waiting for iCloud download – preview saved"
            } else {
                msg = "Waiting for iCloud download"
            }
            store.recordFailure(id: id, name: name, message: msg, cloud: true, parkAfter: parkAfterAttempts)
            if store.parkedIDs.contains(id) {
                log.warning("\(name): \(parkAfterAttempts) attempts failed; no longer retried automatically (Settings › Failed)")
            }
            log.warning("Waiting for iCloud: \(name) – \(details)")
            if !wasTracked { refreshCounts() }
            return .waitingForCloud
        } catch {
            // If every destination vanished, the item isn't at fault: stop the run so nothing is wrongly marked failed.
            if active.allSatisfy(\.unavailable) {
                store.save()
                throw SyncError.destinationUnavailable("Destination became unavailable during sync")
            }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? id
            store.recordFailure(id: id, name: name, message: error.localizedDescription)
            log.error("Failed \(name): \(ErrorInfo.describe(error))")
            refreshCounts()
            return .failed
        }
    }

    // MARK: Deletion planning (style + data budget)
    nonisolated private static func measureLibrary() -> (items: [LibraryItem], total: Int64, sizeKnown: Bool) {
        // PhotoKit has no public file-size API; PHAssetResource exposes `fileSize` (checked before use).
        let sel = NSSelectorFromString("fileSize")
        var items: [LibraryItem] = []
        var total: Int64 = 0
        PHAsset.fetchAssets(with: libraryFetchOptions()).enumerateObjects { a, _, _ in
            var bytes: Int64 = 0
            var missingSize = false
            for r in PHAssetResource.assetResources(for: a) where exportOrder.contains(r.type) {
                if r.responds(to: sel), let n = r.value(forKey: "fileSize") as? NSNumber, n.int64Value > 0 {
                    bytes += n.int64Value
                } else {
                    missingSize = true
                }
            }
            if bytes == 0 && missingSize {
                bytes = estimatedBytes(a)
            }
            total += bytes
            items.append(LibraryItem(id: a.localIdentifier, date: a.creationDate ?? .distantPast, bytes: bytes))
        }
        return (items, total, items.isEmpty || total > 0)
    }

    nonisolated private static func measureAssets(_ ids: Set<String>) -> Int64 {
        guard !ids.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return 0 }
        let sel = NSSelectorFromString("fileSize")
        var total: Int64 = 0
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil).enumerateObjects { a, _, _ in
            for r in PHAssetResource.assetResources(for: a) where exportOrder.contains(r.type) {
                if r.responds(to: sel), let n = r.value(forKey: "fileSize") as? NSNumber {
                    total += n.int64Value
                }
            }
        }
        return total
    }

    private func updatePendingDeleteBytes(measured: [LibraryItem]? = nil) async {
        let queued = store.pendingDelete
        guard !queued.isEmpty else {
            pendingDeleteBytes = 0
            defaults.set(0, forKey: "pendingDeleteBytes")
            return
        }
        var bytes: Int64 = 0
        if let measured {
            let byID = Dictionary(uniqueKeysWithValues: measured.map { ($0.id, $0.bytes) })
            bytes = queued.reduce(0) { $0 + (byID[$1] ?? 0) }
        } else {
            bytes = await Task.detached { Self.measureAssets(queued) }.value
        }
        if bytes == 0, let rt = active.first(where: { !$0.unavailable }) {
            for id in queued {
                if let files = store.fileNames(for: id, dest: rt.key) {
                    for f in files { bytes += Int64(rt.sizes[FileNames.key(f.name)] ?? 0) }
                }
            }
        }
        pendingDeleteBytes = bytes
        defaults.set(Int(bytes), forKey: "pendingDeleteBytes")
    }

    /// Decides which synced assets to queue for deletion. Never deletes when sizes are unknown.
    /// - Just synced, no budget: everything synced this run (plus anything still queued).
    /// - Just synced + budget: those same files, only while the library is over budget.
    /// - Oldest (budget required): oldest verified files until the library is back under budget.
    /// Whatever is queued is only deleted once it is verified on EVERY enabled destination.
    private func planDeletions(syncedThisRun: [String]) async {
        needsDeleteRecalc = false
        if deleteStyle == .justSynced && !store.pendingDelete.isEmpty {
            store.addJustSyncedCandidates(store.pendingDelete)
        }
        store.addJustSyncedCandidates(syncedThisRun)

        if deleteStyle == .justSynced && !budgetEnabled {
            for id in store.justSyncedCandidates where store.isVerifiedForQueue(id) {
                store.queueDelete(id)
            }
            await updatePendingDeleteBytes()
            return
        }

        phase = "Measuring iCloud library size…"
        let m = await Task.detached { Self.measureLibrary() }.value
        phase = nil

        guard m.sizeKnown else {
            log.warning("Could not determine the iCloud library size; skipping deletion this run")
            return
        }
        libraryBytes = m.total
        libraryMeasuredAt = Date()
        defaults.set(Int(m.total), forKey: "libraryBytes")
        defaults.set(libraryMeasuredAt, forKey: "libraryMeasuredAt")

        let batch = store.recalculateDeleteQueue(
            deleteStyle: deleteStyle,
            budgetEnabled: budgetEnabled,
            budgetGB: budgetGB,
            measuredItems: m.items,
            totalBytes: m.total
        )
        await updatePendingDeleteBytes(measured: m.items)

        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        guard batch.excessBytes > 0 else {
            log.info("iCloud library is \(fmt(m.total)), within the \(budgetGB) GB budget; nothing to delete")
            return
        }
        log.info("iCloud library \(fmt(m.total)) is over the \(budgetGB) GB budget by \(fmt(batch.excessBytes)); queued \(batch.queuedIDs.count) item(s) (\(fmt(batch.queuedBytes))) for deletion")
        if batch.queuedBytes < batch.excessBytes {
            log.warning("Only \(fmt(batch.queuedBytes)) can be freed from verified synced items; the library will stay over budget")
        }
    }

    // MARK: iCloud deletion
    /// Deletes only assets that are on EVERY enabled destination, whose files there re-hash to the
    /// recorded value, that are fully exported (Live/edited/RAW parts), and not freshly modified.
    private func processDeleteQueue(manual: Bool = false) async {
        let queued = store.pendingDelete
        guard !queued.isEmpty else { return }

        // Every enabled destination must be online so each copy can be re-verified.
        let enabledKeys = enabledDestinations.map(\.key)
        let online = active.filter { !$0.unavailable }
        guard online.count == enabledKeys.count, Set(online.map(\.key)) == Set(enabledKeys) else {
            log.info("iCloud deletion is waiting: not every enabled destination is reachable")
            deleteRetryAt = Date().addingTimeInterval(15 * 60)
            return
        }

        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: Array(queued), options: nil)
            .enumerateObjects { a, _, _ in assets[a.localIdentifier] = a }
        store.dequeueDelete(queued.subtracting(assets.keys))        // already gone from the library

        let cutoff = Date().addingTimeInterval(-10 * 60)
        var toDelete: [PHAsset] = []
        var checked = 0
        for (id, asset) in assets {
            if isTerminating || Task.isCancelled || !deleteAfterSync {
                phase = nil
                return
            }
            guard store.pendingDelete.contains(id) else { continue }     // policy/budget changed mid-verification
            checked += 1
            phase = "Verifying copies before iCloud delete (\(checked)/\(assets.count))…"
            guard let entry = store.entry(id), entry.verified, !entry.parts.isEmpty else {
                store.dequeueDelete([id]); continue                 // unverifiable → never delete
            }
            guard store.isComplete(id, dests: enabledKeys) else { continue }   // a destination still lacks it: stays queued
            if !manual {
                let newest = max(asset.creationDate ?? .distantPast, asset.modificationDate ?? .distantPast)
                if newest > cutoff { continue }                      // too fresh, stays queued
            }

            if store.needsEditRefresh(id, modifiedAt: asset.modificationDate) {
                continue                                            // edited since last sync: wait until new edit is synced
            }

            let needed = Set(Self.exportPlan(PHAssetResource.assetResources(for: asset)).map { $0.type.rawValue })
            if !needed.isSubset(of: Set(entry.parts.map(\.type))) {
                store.markNeedsEditSync(id)                         // legacy entry gained edits: re-sync on next run
                continue
            }

            // Re-read every copy from every destination (no cache) – proves the bytes are still intact.
            var intact = true
            outer: for rt in online {
                guard let files = store.fileNames(for: id, dest: rt.key) else { intact = false; break }
                for f in files {
                    if (try? await rt.backend.hash(of: f.name, noCache: true)) != f.part.hash {
                        intact = false
                        store.dropPlacements(dest: rt.key, hashes: [f.part.hash])   // re-sync that destination
                        log.error("Copy of \(f.name) at \(rt.name) failed verification; it will be restored")
                        break outer
                    }
                }
            }
            if intact { toDelete.append(asset) }
        }
        phase = nil
        toDelete = toDelete.filter { deleteAfterSync && store.pendingDelete.contains($0.localIdentifier) }

        if !toDelete.isEmpty {
            do {
                if manual && !autoConfirm.willAutoConfirm { NSApp.activate(ignoringOtherApps: true) }
                // macOS shows its own confirmation prompt (auto-confirmed only when explicitly enabled).
                try await autoConfirm.performDeletion(expectedCount: toDelete.count) {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
                    }
                }
                store.dequeueDelete(toDelete.map(\.localIdentifier))
                store.save()
                surfaceSaveError()
                log.info("Deleted \(toDelete.count) item(s) from iCloud after verifying copies on \(online.count) destination(s)")
            } catch {
                let cancelled = (error as? PHPhotosError)?.code == .userCancelled
                // Don't nag: wait longer after the user declines the prompt.
                deleteRetryAt = Date().addingTimeInterval(cancelled ? 6 * 3600 : 3600)
                if cancelled {
                    log.warning(shouldAutoProcessDeletions
                        ? "iCloud delete cancelled by user; will ask again in 6 hours"
                        : "iCloud delete cancelled by user; items remain held in the deletion queue")
                }
                if !cancelled { lastError = "Delete from iCloud pending (will retry): \(error.localizedDescription)" }
                if !cancelled { log.error("Delete from iCloud failed: \(error.localizedDescription)") }
                return
            }
        }
        // Anything still queued (fresh items) is re-checked in an hour, not every minute.
        if !store.pendingDelete.isEmpty { deleteRetryAt = Date().addingTimeInterval(3600) }
    }
}

/// Captures the host key the server presents during a test connection.
nonisolated final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    func set(_ k: String) { lock.lock(); key = k; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return key }
}
