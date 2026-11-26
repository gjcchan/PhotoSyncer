import SwiftUI
import Combine
import AppKit

// MARK: - Pure AutoWake Plist & pmset Builder

/// Pure, stateless parser and command builder for macOS's `/usr/bin/pmset` repeating wake schedule
/// (`/Library/Preferences/SystemConfiguration/com.apple.AutoWake.plist`).
nonisolated enum AutoWakeConfig {
    static let plistPath = "/Library/Preferences/SystemConfiguration/com.apple.AutoWake.plist"
    /// `pmset` weekday bitmask: M=1, T=2, W=4, R=8, F=16, S=32, U=64 → `MTWRFSU` = 127.
    static let everyDayMask = 127

    struct Entry: Equatable, Sendable {
        var eventType: String
        var weekdays: Int
        var timeMinutes: Int
    }

    struct ScheduleState: Equatable, Sendable {
        var powerOn: Entry?
        var powerOff: Entry?
    }

    /// Wakes the Mac 1 minute before the scheduled daily sync time (e.g. 2:59 AM for a 3:00 AM sync)
    /// so macOS's 30-second post-wake drive & Wi-Fi settle completes before the sync minute arrives.
    static func wakeMinutes(forSyncMinutes syncMinutes: Int) -> Int {
        DailySchedule.clampMinutes(syncMinutes - 1)
    }

    static func formatPMSetTime(_ minutes: Int) -> String {
        let clamped = DailySchedule.clampMinutes(minutes)
        return String(format: "%02d:%02d:00", clamped / 60, clamped % 60)
    }

    static func weekdaysString(_ mask: Int) -> String? {
        let mapping: [(Int, String)] = [
            (1, "M"), (2, "T"), (4, "W"), (8, "R"), (16, "F"), (32, "S"), (64, "U"),
        ]
        let out = mapping.compactMap { (bit, letter) in (mask & bit) != 0 ? letter : nil }.joined()
        return out.isEmpty ? nil : out
    }

    static func parsePlist(_ dict: [String: Any]) -> ScheduleState {
        func parseEntry(_ raw: Any?) -> Entry? {
            guard let d = raw as? [String: Any],
                  let type = d["eventtype"] as? String, !type.isEmpty,
                  let weekdays = (d["weekdays"] as? NSNumber)?.intValue,
                  let time = (d["time"] as? NSNumber)?.intValue else {
                return nil
            }
            return Entry(
                eventType: type,
                weekdays: weekdays,
                timeMinutes: DailySchedule.clampMinutes(time)
            )
        }
        return ScheduleState(
            powerOn: parseEntry(dict["RepeatingPowerOn"]),
            powerOff: parseEntry(dict["RepeatingPowerOff"])
        )
    }

    static func isDailyWakeInstalled(_ state: ScheduleState, forSyncMinutes syncMinutes: Int) -> Bool {
        guard let on = state.powerOn else { return false }
        guard on.eventType == "wake" || on.eventType == "wakepoweron" else { return false }
        guard (on.weekdays & everyDayMask) == everyDayMask else { return false }
        return on.timeMinutes == wakeMinutes(forSyncMinutes: syncMinutes)
    }

    /// Builds `/usr/bin/pmset` arguments to install or remove the daily wake timer while preserving
    /// any existing `RepeatingPowerOff` (`sleep` / `shutdown` / `restart`) schedule on the system.
    static func pmsetArguments(enableWakeForSyncMinutes syncMinutes: Int?,
                               preservingPowerOff off: Entry?) -> [String] {
        let validOffTypes: Set<String> = ["sleep", "shutdown", "restart"]
        let offArgs: [String]? = {
            guard let off,
                  validOffTypes.contains(off.eventType),
                  let days = weekdaysString(off.weekdays) else {
                return nil
            }
            return [off.eventType, days, formatPMSetTime(off.timeMinutes)]
        }()

        if let syncMinutes {
            let wakeTime = formatPMSetTime(wakeMinutes(forSyncMinutes: syncMinutes))
            var args = ["repeat", "wake", "MTWRFSU", wakeTime]
            if let offArgs { args.append(contentsOf: offArgs) }
            return args
        } else if let offArgs {
            return ["repeat"] + offArgs
        } else {
            return ["repeat", "cancel"]
        }
    }

    static func appleScriptCommand(arguments: [String]) -> String {
        let shellCmd = (["/usr/bin/pmset"] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let escaped = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

// MARK: - Observable Wake Scheduler Controller

@MainActor
final class SystemWakeScheduler: ObservableObject {
    private static let enabledKey = "wakeMacForDailySync"
    private nonisolated static let adminQueue = DispatchQueue(label: "PhotoSyncer.pmsetAdmin")
    private let defaults = UserDefaults.standard
    private var activeObserver: NSObjectProtocol?

    @Published private(set) var wakeEnabled: Bool {
        didSet {
            guard wakeEnabled != oldValue else { return }
            defaults.set(wakeEnabled, forKey: Self.enabledKey)
        }
    }

    @Published private(set) var installedState: AutoWakeConfig.ScheduleState
    @Published private(set) var isApplying = false
    @Published var lastError: String?

    var isSupported: Bool {
        #if APP_SANDBOX_YES
        return false
        #else
        return !SandboxCompat.isSandboxed
        #endif
    }

    init() {
        wakeEnabled = defaults.bool(forKey: Self.enabledKey)
        #if APP_SANDBOX_YES
        installedState = AutoWakeConfig.ScheduleState(powerOn: nil, powerOff: nil)
        #else
        if SandboxCompat.isSandboxed {
            installedState = AutoWakeConfig.ScheduleState(powerOn: nil, powerOff: nil)
        } else {
            installedState = Self.readSystemState()
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSystemSchedule() }
            }
        }
        #endif
    }

    deinit {
        if let obs = activeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    nonisolated private static func readSystemState() -> AutoWakeConfig.ScheduleState {
        guard let dict = NSDictionary(contentsOfFile: AutoWakeConfig.plistPath) as? [String: Any] else {
            return AutoWakeConfig.ScheduleState(powerOn: nil, powerOff: nil)
        }
        return AutoWakeConfig.parsePlist(dict)
    }

    func refreshSystemSchedule() {
        guard isSupported else { return }
        let latest = Self.readSystemState()
        if installedState != latest {
            installedState = latest
        }
    }

    func isConfigured(forSyncMinutes syncMinutes: Int) -> Bool {
        guard isSupported else { return false }
        return AutoWakeConfig.isDailyWakeInstalled(installedState, forSyncMinutes: syncMinutes)
    }

    func formattedWakeTime(forSyncMinutes syncMinutes: Int) -> String {
        Self.formatMinutes(AutoWakeConfig.wakeMinutes(forSyncMinutes: syncMinutes))
    }

    func formattedInstalledWakeTime() -> String? {
        guard let on = installedState.powerOn else { return nil }
        return Self.formatMinutes(on.timeMinutes)
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        let clamped = DailySchedule.clampMinutes(minutes)
        let date = Calendar.current.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: Date()
        ) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    func setWakeEnabled(_ enabled: Bool, syncMinutes: Int) {
        guard isSupported, !isApplying else { return }
        lastError = nil
        refreshSystemSchedule()

        if enabled {
            wakeEnabled = true
            if isConfigured(forSyncMinutes: syncMinutes) {
                EventLog.shared.info("macOS daily wake already configured for \(formattedWakeTime(forSyncMinutes: syncMinutes))")
                return
            }
            applyWakeSchedule(syncMinutes: syncMinutes, revertToggleOnCancel: true)
        } else {
            if installedState.powerOn == nil {
                wakeEnabled = false
                EventLog.shared.info("Wake Mac from sleep disabled")
                return
            }
            disableWakeSchedule()
        }
    }

    func applyWakeSchedule(syncMinutes: Int, revertToggleOnCancel: Bool = false) {
        #if !APP_SANDBOX_YES
        guard isSupported, !isApplying else { return }
        refreshSystemSchedule()
        let args = AutoWakeConfig.pmsetArguments(
            enableWakeForSyncMinutes: syncMinutes,
            preservingPowerOff: installedState.powerOff
        )
        let targetWakeStr = formattedWakeTime(forSyncMinutes: syncMinutes)
        let targetSyncStr = Self.formatMinutes(syncMinutes)
        isApplying = true
        lastError = nil

        Task {
            let outcome = await Self.runPrivilegedPMSet(arguments: args)
            isApplying = false
            refreshSystemSchedule()
            switch outcome {
            case .success:
                wakeEnabled = true
                lastError = nil
                EventLog.shared.info("Scheduled macOS daily wake at \(targetWakeStr) for \(targetSyncStr) sync")
            case .cancelled:
                if revertToggleOnCancel, !isConfigured(forSyncMinutes: syncMinutes) {
                    wakeEnabled = false
                }
            case .failure(let message):
                if revertToggleOnCancel, !isConfigured(forSyncMinutes: syncMinutes) {
                    wakeEnabled = false
                }
                lastError = "Could not update macOS wake schedule: \(message)"
                EventLog.shared.error("pmset wake schedule failed: \(message)")
            }
        }
        #endif
    }

    func disableWakeSchedule() {
        #if !APP_SANDBOX_YES
        guard isSupported, !isApplying else { return }
        refreshSystemSchedule()
        guard installedState.powerOn != nil else {
            wakeEnabled = false
            lastError = nil
            return
        }
        let args = AutoWakeConfig.pmsetArguments(
            enableWakeForSyncMinutes: nil,
            preservingPowerOff: installedState.powerOff
        )
        isApplying = true
        lastError = nil

        Task {
            let outcome = await Self.runPrivilegedPMSet(arguments: args)
            isApplying = false
            refreshSystemSchedule()
            switch outcome {
            case .success:
                wakeEnabled = false
                lastError = nil
                EventLog.shared.info("Removed macOS daily wake schedule")
            case .cancelled:
                break
            case .failure(let message):
                lastError = "Could not remove macOS wake schedule: \(message)"
                EventLog.shared.error("pmset wake cancel failed: \(message)")
            }
        }
        #endif
    }

    #if !APP_SANDBOX_YES
    private enum PMSetOutcome: Sendable {
        case success
        case cancelled
        case failure(String)
    }

    nonisolated private static func runPrivilegedPMSet(arguments: [String]) async -> PMSetOutcome {
        let scriptSource = AutoWakeConfig.appleScriptCommand(arguments: arguments)
        return await withCheckedContinuation { cont in
            adminQueue.async {
                guard let script = NSAppleScript(source: scriptSource) else {
                    cont.resume(returning: .failure("Could not create administrator authorization script"))
                    return
                }
                var errorInfo: NSDictionary?
                _ = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -128 {
                        cont.resume(returning: .cancelled)
                    } else {
                        let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
                        cont.resume(returning: .failure(msg))
                    }
                } else {
                    cont.resume(returning: .success)
                }
            }
        }
    }
    #endif
}

// MARK: - Modular Settings Rows (Embedded in Settings › General › Schedule)

struct SystemWakeSettingsRows: View {
    @ObservedObject var scheduler: SystemWakeScheduler
    let syncMinutes: Int

    var body: some View {
        if scheduler.isSupported {
            Toggle("Wake Mac from sleep for scheduled sync", isOn: Binding(
                get: { scheduler.wakeEnabled },
                set: { scheduler.setWakeEnabled($0, syncMinutes: syncMinutes) }
            ))
            .disabled(scheduler.isApplying)

            if scheduler.wakeEnabled {
                if scheduler.isConfigured(forSyncMinutes: syncMinutes) {
                    Label {
                        Text("macOS will wake daily at \(scheduler.formattedWakeTime(forSyncMinutes: syncMinutes)) (1 minute early so drives and Wi-Fi reconnect in time) and stay awake until the sync finishes. MacBooks with the lid closed require AC power to wake.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "alarm.waves.left.and.right.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if let current = scheduler.formattedInstalledWakeTime() {
                                Text("macOS wake timer is currently set to \(current). Apply to update it to \(scheduler.formattedWakeTime(forSyncMinutes: syncMinutes)).")
                                    .font(.caption)
                            } else {
                                Text("Administrator approval is needed once to set macOS's daily wake timer for \(scheduler.formattedWakeTime(forSyncMinutes: syncMinutes)).")
                                    .font(.caption)
                            }
                            Spacer()
                            Button(scheduler.isApplying ? "Applying…" : "Apply Wake Schedule…") {
                                scheduler.applyWakeSchedule(syncMinutes: syncMinutes)
                            }
                            .controlSize(.small)
                            .disabled(scheduler.isApplying)
                        }
                        Text("MacBooks with the lid closed require AC power to wake on schedule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let err = scheduler.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct OrphanedWakeTimerRow: View {
    @ObservedObject var scheduler: SystemWakeScheduler

    var body: some View {
        if scheduler.isSupported, scheduler.wakeEnabled, let current = scheduler.formattedInstalledWakeTime() {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                Text("A daily macOS wake timer (\(current)) is still active from daily scheduling.")
                    .font(.caption)
                Spacer()
                Button(scheduler.isApplying ? "Removing…" : "Turn Off Wake Timer…") {
                    scheduler.disableWakeSchedule()
                }
                .controlSize(.small)
                .disabled(scheduler.isApplying)
            }
        }
    }
}
