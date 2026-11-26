import SwiftUI
import Combine
import AppKit
#if !APP_SANDBOX_YES
import ApplicationServices
import CoreGraphics
#endif

// MARK: - Sandbox / Unsandboxed Runtime Compatibility

/// Isolates sandbox vs. unsandboxed runtime differences (Application Support path and bookmark options)
/// so the rest of the codebase stays identical to `main` for conflict-free rebasing.
nonisolated enum SandboxCompat {
    static let isSandboxed: Bool = {
        #if APP_SANDBOX_YES
        return true
        #else
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #endif
    }()

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = isSandboxed ? base : base.appendingPathComponent("com.gc.PhotoSyncer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: isSandboxed ? [.withSecurityScope] : [])
    }

    static func resolveBookmark(_ data: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        var stale = false
        let opts: URL.BookmarkResolutionOptions = isSandboxed ? [.withSecurityScope] : []
        let url = try URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
        var refreshed: Data?
        if stale {
            if isSandboxed {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    refreshed = try? url.bookmarkData(options: [.withSecurityScope])
                }
            } else {
                refreshed = try? url.bookmarkData(options: [])
            }
        }
        return (url, refreshed)
    }
}

// MARK: - Strict PhotoSyncer Delete Prompt Verifier

/// Snapshot of one candidate alert window inspected via macOS Accessibility.
nonisolated struct DeletePromptCandidate: Sendable {
    var ownerPID: pid_t
    var myPID: pid_t
    var bundleIdentifier: String?
    var executablePath: String?
    var staticTexts: [String]
    var buttonTitles: [String]
}

/// Pure, stateless 5-gate verifier guaranteeing we ONLY ever click PhotoSyncer's own
/// `PHAssetChangeRequest.deleteAssets` confirmation dialog—never Finder, Photos.app, TCC
/// permission dialogs, album/folder prompts, or another app's deletion prompt.
nonisolated enum DeletePromptVerifier {
    private static let forbiddenBundles: Set<String> = [
        "com.apple.finder",
        "com.apple.Photos",
        "com.apple.dock",
        "com.apple.Terminal",
        "com.apple.dt.Xcode",
    ]

    /// Normalizes curly quotes/apostrophes and non-breaking spaces (e.g. `iCloud\u{00A0}Photos`)
    /// and collapses runs of whitespace.
    static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var prevSpace = false
        for ch in text {
            let mapped: Character
            switch ch {
            case "\u{00A0}", "\u{202F}", "\t", "\r", "\n":
                mapped = " "
            case "“", "”", "„", "«", "»":
                mapped = "\""
            case "’", "‘":
                mapped = "'"
            default:
                mapped = ch
            }
            if mapped == " " {
                if !prevSpace { out.append(" ") }
                prevSpace = true
            } else {
                out.append(mapped)
                prevSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Returns the index in `candidate.buttonTitles` of the confirm button to press,
    /// or `nil` if ANY safety check fails.
    static func verify(_ candidate: DeletePromptCandidate,
                       expectedAppName: String,
                       expectedCount: Int) -> Int? {
        guard expectedCount > 0 else { return nil }
        let appName = normalize(expectedAppName).lowercased()
        guard !appName.isEmpty else { return nil }

        // Gate 1: Process isolation — must be a SIP-protected `/System/Library/` alert host,
        // never PhotoSyncer itself, Finder, Photos.app, or a third-party app.
        guard candidate.ownerPID > 0, candidate.ownerPID != candidate.myPID else { return nil }
        if let bid = candidate.bundleIdentifier, forbiddenBundles.contains(bid) { return nil }
        guard let exec = candidate.executablePath, exec.hasPrefix("/System/Library/") else { return nil }

        // Gate 2: Exact quoted client-app attribution (`Allow “PhotoSyncer” to delete …`).
        let combined = normalize(candidate.staticTexts.joined(separator: " ")).lowercased()
        let requiredPrefix = "allow \"\(appName)\" to delete "
        guard combined.contains(requiredPrefix) else { return nil }

        // Gate 3: Asset-only semantics (never albums or folders) + exact batch count match.
        if combined.contains("album") || combined.contains("folder") { return nil }
        guard combined.contains("photo") || combined.contains("video") || combined.contains("item") else {
            return nil
        }

        if expectedCount == 1 {
            let validSingular = [
                "\(requiredPrefix)this photo",
                "\(requiredPrefix)this video",
                "\(requiredPrefix)one item",
                "\(requiredPrefix)1 photo",
                "\(requiredPrefix)1 video",
                "\(requiredPrefix)1 item",
            ]
            guard validSingular.contains(where: { combined.contains($0) }) else { return nil }
        } else {
            let plain = "\(expectedCount)"
            let grouped = normalize(
                NumberFormatter.localizedString(from: NSNumber(value: expectedCount), number: .decimal)
            ).lowercased()
            let matchesPlain = combined.contains("\(requiredPrefix)\(plain) ")
            let matchesGrouped = combined.contains("\(requiredPrefix)\(grouped) ")
            guard matchesPlain || matchesGrouped else { return nil }
        }

        // Gate 4: Exact PhotoKit button pair (`Don't Allow` + a single asset `Delete…` button).
        let normalizedButtons = candidate.buttonTitles.map { normalize($0).lowercased() }
        guard normalizedButtons.contains("don't allow") else { return nil }

        var confirmIndices: [Int] = []
        for (idx, title) in normalizedButtons.enumerated() {
            if isConfirmDeleteButtonTitle(title) {
                confirmIndices.append(idx)
            }
        }
        guard confirmIndices.count == 1 else { return nil }
        return confirmIndices[0]
    }

    private static func isConfirmDeleteButtonTitle(_ title: String) -> Bool {
        if title.contains("album") || title.contains("folder") { return false }
        switch title {
        case "delete",
             "delete photo", "delete video", "delete item",
             "delete this photo", "delete this video", "delete this item":
            return true
        default:
            guard title.hasPrefix("delete ") else { return false }
            return title.hasSuffix(" photos") || title.hasSuffix(" videos") || title.hasSuffix(" items")
        }
    }
}

// MARK: - Scoped Accessibility Watcher (Active ONLY During performChanges)

#if !APP_SANDBOX_YES
private nonisolated enum AXConst {
    static let windows = "AXWindows" as CFString
    static let sheets = "AXSheets" as CFString
    static let children = "AXChildren" as CFString
    static let role = "AXRole" as CFString
    static let title = "AXTitle" as CFString
    static let value = "AXValue" as CFString
    static let description = "AXDescription" as CFString
    static let enabled = "AXEnabled" as CFString
    static let press = "AXPress" as CFString
    static let promptOption = "AXTrustedCheckOptionPrompt"
    static let buttonRole = "AXButton"
    static let staticTextRole = "AXStaticText"
    static let windowOwnerPID = "kCGWindowOwnerPID"
}

private nonisolated final class PromptWatchSession: @unchecked Sendable {
    private let expectedAppName: String
    private let expectedCount: Int
    private let myPID = getpid()
    private let queue = DispatchQueue(label: "PhotoSyncer.autoConfirmAX", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var launchObserver: NSObjectProtocol?
    private var stopped = false
    private var didClick = false
    private let startedAt = Date()
    private static let maxLifetime: TimeInterval = 60

    init(expectedAppName: String, expectedCount: Int) {
        self.expectedAppName = expectedAppName
        self.expectedCount = expectedCount
    }

    func start() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.scanOnce() }
        }

        queue.async {
            guard !self.stopped else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(40), leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.scanOnce() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        if let obs = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            launchObserver = nil
        }
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func scanOnce() {
        guard !stopped, !didClick else { return }
        if Date().timeIntervalSince(startedAt) > Self.maxLifetime {
            stopped = true
            timer?.cancel()
            timer = nil
            return
        }
        guard AXIsProcessTrusted() else { return }

        for pid in candidatePIDs() {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let execPath = app.executableURL?.path
            guard let execPath, execPath.hasPrefix("/System/Library/") else { continue }
            let bundleID = app.bundleIdentifier

            let axApp = AXUIElementCreateApplication(pid)
            guard let windows = Self.copyElements(axApp, attribute: AXConst.windows) else { continue }
            for window in windows {
                var texts: [String] = []
                var buttons: [(title: String, element: AXUIElement)] = []
                if let winTitle = Self.copyString(window, attribute: AXConst.title), !winTitle.isEmpty {
                    texts.append(winTitle)
                }
                var visited = 0
                Self.collectContents(of: window, depth: 0, visited: &visited, texts: &texts, buttons: &buttons)

                let candidate = DeletePromptCandidate(
                    ownerPID: pid,
                    myPID: myPID,
                    bundleIdentifier: bundleID,
                    executablePath: execPath,
                    staticTexts: texts,
                    buttonTitles: buttons.map(\.title)
                )
                guard let buttonIdx = DeletePromptVerifier.verify(
                    candidate,
                    expectedAppName: expectedAppName,
                    expectedCount: expectedCount
                ) else { continue }

                if AXUIElementPerformAction(buttons[buttonIdx].element, AXConst.press) == .success {
                    didClick = true
                    stopped = true
                    timer?.cancel()
                    timer = nil
                    let count = expectedCount
                    Task { @MainActor in
                        EventLog.shared.info("Auto-confirmed macOS delete prompt for \(count) verified item(s)")
                    }
                    return
                }
            }
        }
    }

    private func candidatePIDs() -> Set<pid_t> {
        var pids = Set<pid_t>()
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in infoList {
                if let n = entry[AXConst.windowOwnerPID] as? NSNumber {
                    let pid = pid_t(n.int32Value)
                    if pid > 0, pid != myPID { pids.insert(pid) }
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0, pid != myPID else { continue }
            if let bid = app.bundleIdentifier,
               bid == "com.apple.UserNotificationCenter" || bid == "com.apple.CoreServicesUIAgent" {
                pids.insert(pid)
            }
        }
        return pids
    }

    private static func collectContents(of element: AXUIElement,
                                        depth: Int,
                                        visited: inout Int,
                                        texts: inout [String],
                                        buttons: inout [(title: String, element: AXUIElement)]) {
        guard depth <= 6, visited < 120 else { return }
        visited += 1

        let role = copyString(element, attribute: AXConst.role) ?? ""
        if role == AXConst.staticTextRole {
            if let val = copyString(element, attribute: AXConst.value), !val.isEmpty {
                texts.append(val)
            } else if let title = copyString(element, attribute: AXConst.title), !title.isEmpty {
                texts.append(title)
            }
            return
        }
        if role == AXConst.buttonRole {
            if copyBool(element, attribute: AXConst.enabled) == false { return }
            let title = copyString(element, attribute: AXConst.title)
                ?? copyString(element, attribute: AXConst.description)
                ?? ""
            if !title.isEmpty {
                buttons.append((title: title, element: element))
            }
            return
        }

        if let sheets = copyElements(element, attribute: AXConst.sheets) {
            for sheet in sheets {
                collectContents(of: sheet, depth: depth + 1, visited: &visited, texts: &texts, buttons: &buttons)
            }
        }
        if let children = copyElements(element, attribute: AXConst.children) {
            for child in children {
                collectContents(of: child, depth: depth + 1, visited: &visited, texts: &texts, buttons: &buttons)
            }
        }
    }

    private static func copyElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &out) == .success,
              let array = out as? [AXUIElement] else { return nil }
        return array
    }

    private static func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &out) == .success else { return nil }
        return out as? String
    }

    private static func copyBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &out) == .success else { return nil }
        return (out as? NSNumber)?.boolValue
    }
}
#endif

// MARK: - Daily Delete Time Window

nonisolated enum DeleteSchedule {
    static let defaultMinutes = DailySchedule.defaultMinutes
    static let windowMinutes = DailySchedule.windowMinutes

    static func isWithinWindow(now: Date,
                               targetMinutes: Int,
                               windowMinutes: Int = Self.windowMinutes,
                               calendar: Calendar = .current) -> Bool {
        DailySchedule.isWithinWindow(
            now: now,
            targetMinutes: targetMinutes,
            windowMinutes: windowMinutes,
            calendar: calendar
        )
    }
}

// MARK: - Observable Controller

@MainActor
final class DeleteAutoConfirmController: ObservableObject {
    private static let defaultsKey = "autoConfirmDeletePrompt"
    private static let scheduleEnabledKey = "autoConfirmScheduleEnabled"
    private static let scheduleMinutesKey = "autoConfirmScheduleMinutes"
    private let defaults = UserDefaults.standard
    private var activeObserver: NSObjectProtocol?

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            refreshAccessibilityTrust()
            EventLog.shared.info("Auto-confirm delete prompt \(isEnabled ? "enabled" : "disabled")")
        }
    }

    @Published var scheduleEnabled: Bool {
        didSet {
            guard scheduleEnabled != oldValue else { return }
            defaults.set(scheduleEnabled, forKey: Self.scheduleEnabledKey)
            EventLog.shared.info(scheduleEnabled
                ? "Scheduled auto-delete enabled for \(formattedScheduleTime)"
                : "Scheduled auto-delete time disabled")
        }
    }

    /// Minutes after midnight in local time (0...1439); defaults to 180 (3:00 AM).
    @Published var scheduleMinutes: Int {
        didSet {
            let clamped = ((scheduleMinutes % 1440) + 1440) % 1440
            if clamped != scheduleMinutes { scheduleMinutes = clamped; return }
            guard scheduleMinutes != oldValue else { return }
            defaults.set(scheduleMinutes, forKey: Self.scheduleMinutesKey)
        }
    }

    @Published private(set) var isAccessibilityTrusted: Bool

    var isSupported: Bool {
        #if APP_SANDBOX_YES
        return false
        #else
        return !SandboxCompat.isSandboxed
        #endif
    }

    var willAutoConfirm: Bool {
        isSupported && isEnabled && isAccessibilityTrusted
    }

    var hasActiveSchedule: Bool {
        isSupported && isEnabled && scheduleEnabled
    }

    var scheduleDate: Date {
        get {
            Calendar.current.date(
                bySettingHour: scheduleMinutes / 60,
                minute: scheduleMinutes % 60,
                second: 0,
                of: Date()
            ) ?? Date()
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            let mins = DailySchedule.clampMinutes((comps.hour ?? 3) * 60 + (comps.minute ?? 0))
            if mins != scheduleMinutes { scheduleMinutes = mins }
        }
    }

    var formattedScheduleTime: String {
        scheduleDate.formatted(date: .omitted, time: .shortened)
    }

    var formattedWindowEnd: String {
        let endMinutes = (scheduleMinutes + DeleteSchedule.windowMinutes) % 1440
        let endDate = Calendar.current.date(
            bySettingHour: endMinutes / 60,
            minute: endMinutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
        return endDate.formatted(date: .omitted, time: .shortened)
    }

    /// True unless a daily delete schedule is active and `now` is outside the scheduled window.
    func allowsScheduledDeletion(now: Date = Date()) -> Bool {
        guard hasActiveSchedule else { return true }
        return DeleteSchedule.isWithinWindow(now: now, targetMinutes: scheduleMinutes)
    }

    var deferredScheduleDescription: String? {
        guard hasActiveSchedule, !allowsScheduledDeletion() else { return nil }
        return "scheduled auto-delete at \(formattedScheduleTime)"
    }

    init() {
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
        scheduleEnabled = defaults.bool(forKey: Self.scheduleEnabledKey)
        if defaults.object(forKey: Self.scheduleMinutesKey) != nil {
            let saved = defaults.integer(forKey: Self.scheduleMinutesKey)
            scheduleMinutes = ((saved % 1440) + 1440) % 1440
        } else {
            scheduleMinutes = DeleteSchedule.defaultMinutes
        }
        #if APP_SANDBOX_YES
        isAccessibilityTrusted = false
        #else
        isAccessibilityTrusted = !SandboxCompat.isSandboxed && AXIsProcessTrusted()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityTrust() }
        }
        #endif
    }

    deinit {
        if let obs = activeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func refreshAccessibilityTrust() {
        #if APP_SANDBOX_YES
        isAccessibilityTrusted = false
        #else
        let trusted = !SandboxCompat.isSandboxed && AXIsProcessTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }
        #endif
    }

    func requestAccessibilityPermission() {
        #if !APP_SANDBOX_YES
        guard !SandboxCompat.isSandboxed else { return }
        let opts = [AXConst.promptOption: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refreshAccessibilityTrust()
        if !isAccessibilityTrusted {
            openAccessibilitySettings()
        }
        #endif
    }

    func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Runs `deletionBlock` (`PHPhotoLibrary.shared().performChanges`) while arming a strictly
    /// scoped watcher for PhotoSyncer's own delete dialog if auto-confirm is enabled and trusted.
    func performDeletion(expectedCount: Int, _ deletionBlock: () async throws -> Void) async rethrows {
        #if APP_SANDBOX_YES
        try await deletionBlock()
        #else
        refreshAccessibilityTrust()
        guard willAutoConfirm, expectedCount > 0 else {
            try await deletionBlock()
            return
        }
        // If the Mac woke via an RTC schedule into Dark Wake, wake WindowServer / display briefly
        // so macOS renders the PhotoKit confirmation dialog for Accessibility inspection.
        let displayAssertion = PowerAssertion.declareUserActivity(reason: "PhotoSyncer scheduled iCloud delete")
        defer { PowerAssertion.releaseAssertion(displayAssertion) }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "PhotoSyncer"
        let session = PromptWatchSession(expectedAppName: appName, expectedCount: expectedCount)
        session.start()
        defer { session.stop() }
        try await deletionBlock()
        #endif
    }
}

// MARK: - Modular Settings UI Section (Embedded in DeleteOptionsView)

struct AutoConfirmDeleteSettingsSection: View {
    @ObservedObject var controller: DeleteAutoConfirmController
    var manualHoldActive: Bool = false
    var onAllowScheduledRuns: () -> Void = {}
    var onScheduleChanged: () -> Void = {}
    @State private var showEnableWarning = false

    var body: some View {
        if controller.isSupported {
            Section("Automatic prompt confirmation") {
                Toggle("Auto-confirm PhotoSyncer delete prompts", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { newValue in
                        guard newValue != controller.isEnabled else { return }
                        if newValue {
                            showEnableWarning = true
                        } else {
                            controller.isEnabled = false
                        }
                    }
                ))

                if controller.isEnabled {
                    if controller.isAccessibilityTrusted {
                        Label {
                            Text("Accessibility access is active. Only macOS dialogs matching “Allow “PhotoSyncer” to delete …” with the exact batch count are ever clicked (the prompt will still flash briefly).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label {
                                Text("Allow PhotoSyncer in System Settings › Privacy & Security › Accessibility so it can click its own delete confirmation dialog. Until granted, macOS will wait for manual confirmation.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            HStack(spacing: 8) {
                                Button("Grant Accessibility Access…") {
                                    controller.requestAccessibilityPermission()
                                }
                                .controlSize(.small)
                                Button("Check Again") {
                                    controller.refreshAccessibilityTrust()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    Toggle("Only auto-delete at a scheduled time", isOn: Binding(
                        get: { controller.scheduleEnabled },
                        set: { newValue in
                            controller.scheduleEnabled = newValue
                            onScheduleChanged()
                        }
                    ))

                    if controller.scheduleEnabled {
                        DatePicker(
                            "Scheduled time",
                            selection: Binding(
                                get: { controller.scheduleDate },
                                set: { newDate in
                                    controller.scheduleDate = newDate
                                    onScheduleChanged()
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )

                        Text("Verified deletions stay queued during the day and run between \(controller.formattedScheduleTime) and \(controller.formattedWindowEnd) while your Mac is awake, avoiding focus interruptions while you work. Manual “Delete … Queued from iCloud…” in the menu bar still works anytime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if manualHoldActive {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                                Text("“Hold deletions in queue until I click Delete in the menu” is on above, which prevents automatic runs at \(controller.formattedScheduleTime).")
                                    .font(.caption)
                                Spacer()
                                Button("Allow Scheduled Runs") {
                                    onAllowScheduledRuns()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    Text("Uses macOS Accessibility to automatically click Delete exclusively on PhotoSyncer's own iCloud Photos deletion dialogs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { controller.refreshAccessibilityTrust() }
            .alert("Automatically confirm PhotoSyncer delete prompts?", isPresented: $showEnableWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Enable Auto-Confirm", role: .destructive) {
                    controller.isEnabled = true
                    if !controller.isAccessibilityTrusted {
                        controller.requestAccessibilityPermission()
                    }
                }
            } message: {
                Text("When PhotoSyncer deletes verified copies from iCloud Photos, it will automatically click Delete on its own macOS confirmation prompt (which will briefly flash on screen).\n\nStrict checks ensure no other app or system dialog is ever clicked, and deleted items still stay in Recently Deleted for 30 days.")
            }
        }
    }
}
