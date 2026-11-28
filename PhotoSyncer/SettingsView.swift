import SwiftUI
import AppKit

/// The single window for everything configurable: General, Delete, Activity, Logs, Maintenance.
struct SettingsView: View {
    @ObservedObject var syncer: SyncEngine
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(syncer: syncer)
                .tag(0)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("General", systemImage: "gearshape") }
            DestinationsView(syncer: syncer)
                .tag(1)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Destinations", systemImage: "externaldrive.connected.to.line.below") }
            DeleteOptionsView(syncer: syncer)
                .tag(2)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Delete", systemImage: "icloud.slash") }
            ActivityTab(syncer: syncer)
                .tag(3)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Activity", systemImage: "exclamationmark.bubble") }
            FailedTab(syncer: syncer)
                .tag(4)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Failed", systemImage: "xmark.icloud") }
                .badge(syncer.parkedCount)
            LogView(syncer: syncer)
                .tag(5)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Logs", systemImage: "doc.text") }
            MaintenanceTab(syncer: syncer)
                .tag(6)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
        }
        .navigationTitle("PhotoSyncer")
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(SettingsWindowConfigurator(selectedTab: selectedTab))
    }
}

/// Keeps macOS's `Settings` window freely resizable across tab switches without mutating window
/// properties on unrelated SwiftUI updates (which would flicker the titlebar zoom button).
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let selectedTab: Int

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.attach(to: nsView.window, selectedTab: selectedTab)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window, selectedTab: nil)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var observedWindow: NSWindow?
        private var observations: [NSKeyValueObservation] = []
        private var lastTab: Int?
        private var isEnforcing = false
        private var enforceScheduled = false

        func attach(to window: NSWindow?, selectedTab: Int?) {
            guard let window else { return }
            let isNewWindow = observedWindow !== window
            let tabChanged = selectedTab != nil && selectedTab != lastTab
            if let selectedTab { lastTab = selectedTab }

            if isNewWindow {
                observedWindow = window
                observations = [
                    window.observe(\.styleMask, options: [.new]) { [weak self] win, _ in
                        guard Thread.isMainThread else { return }
                        MainActor.assumeIsolated {
                            if !win.styleMask.contains(.resizable) || !win.styleMask.contains(.miniaturizable) {
                                self?.scheduleEnforce()
                            }
                        }
                    },
                    window.observe(\.maxSize, options: [.new]) { [weak self] win, _ in
                        guard Thread.isMainThread else { return }
                        MainActor.assumeIsolated {
                            if win.maxSize.width < 10_000 || win.maxSize.height < 10_000 {
                                self?.scheduleEnforce()
                            }
                        }
                    },
                    window.observe(\.contentMaxSize, options: [.new]) { [weak self] win, _ in
                        guard Thread.isMainThread else { return }
                        MainActor.assumeIsolated {
                            if win.contentMaxSize.width < 10_000 || win.contentMaxSize.height < 10_000 {
                                self?.scheduleEnforce()
                            }
                        }
                    },
                ]
            }

            if isNewWindow || tabChanged {
                scheduleEnforce()
            }
        }

        /// Defers `NSWindow` styleMask/min/max mutations out of `NSHostingView.layout()` so AppKit
        /// never calls `-layoutSubtreeIfNeeded` on a hosting view that is already being laid out.
        private func scheduleEnforce() {
            guard !enforceScheduled else { return }
            enforceScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.enforceScheduled = false
                self.enforce()
            }
        }

        private func enforce() {
            guard !isEnforcing, let win = observedWindow else { return }
            isEnforcing = true
            defer { isEnforcing = false }

            if !win.styleMask.contains(.resizable) || !win.styleMask.contains(.miniaturizable) {
                win.styleMask.insert([.resizable, .miniaturizable])
            }
            let minSize = NSSize(width: 760, height: 520)
            if win.contentMinSize != minSize {
                win.contentMinSize = minSize
            }
            if win.maxSize.width < 10_000 || win.maxSize.height < 10_000 {
                win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            if win.contentMaxSize.width < 10_000 || win.contentMaxSize.height < 10_000 {
                win.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }
}

// MARK: General
private struct GeneralTab: View {
    @ObservedObject var syncer: SyncEngine

    var body: some View {
        Form {
            Section("Schedule") {
                Picker("Sync schedule", selection: $syncer.scheduleMode) {
                    ForEach(SyncScheduleMode.allCases) { Text($0.label).tag($0) }
                }
                switch syncer.scheduleMode {
                case .interval:
                    Picker("Check for new photos every", selection: $syncer.interval) {
                        ForEach(SyncInterval.allCases) { Text($0.label).tag($0) }
                    }
                    OrphanedWakeTimerRow(scheduler: syncer.wakeScheduler)
                case .daily:
                    DatePicker("Sync daily at", selection: $syncer.dailySyncDate, displayedComponents: .hourAndMinute)
                    SystemWakeSettingsRows(scheduler: syncer.wakeScheduler, syncMinutes: syncer.dailySyncMinutes)
                    Toggle("Catch up on wake if Mac was asleep at scheduled time", isOn: $syncer.dailyCatchUpIfMissed)
                    Text(syncer.dailyScheduleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("iCloud originals") {
                Toggle("Save a preview while the original is unavailable", isOn: $syncer.savePreviews)
                HStack {
                    Text("Stop auto-retrying an item after")
                    TextField("", value: $syncer.parkAfterAttempts, format: .number)
                        .frame(width: 60).multilineTextAlignment(.trailing)
                    Stepper("", value: $syncer.parkAfterAttempts, in: 1...1000, step: 5).labelsHidden()
                    Text("attempts")
                }
                Text("Photos still waiting for their iCloud original after this many tries move to Settings › Failed and are only retried when you ask.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If Photos can't download an item's full original from iCloud, save the best space-saving copy it has on this Mac (preserving raw derivative files, capture date/GPS metadata, and compressed local videos) as “name-preview.<ext>”. It is replaced automatically when the original arrives, and an item with only a preview is never deleted from iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { syncer.launchAtLogin },
                    set: { syncer.setLaunchAtLogin($0) }))
                if syncer.loginItemNeedsApproval {
                    Button("Approve Login Item in System Settings…") { syncer.openLoginItemsSettings() }
                }
                if let w = syncer.installWarning {
                    Text(w).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Activity (needs attention + recent errors)
private struct ActivityTab: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case attention, errors
        var id: Self { self }
    }

    @ObservedObject var syncer: SyncEngine
    @ObservedObject private var log = EventLog.shared
    @State private var scope: Scope = .attention
    @State private var filter = ""
    @State private var showCloudSteps = false
    @State private var attentionSelection = Set<String>()
    @State private var attentionSortOrder = [KeyPathComparator(\AttentionItem.retryAt)]
    @State private var errorSelection = Set<UUID>()
    @State private var errorSortOrder = [KeyPathComparator(\LogEvent.date, order: .reverse)]

    private var busy: Bool { syncer.isSyncing || syncer.isPaused }

    private var attention: [AttentionItem] {
        let base = filter.isEmpty ? syncer.attentionItems : syncer.attentionItems.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.message.localizedCaseInsensitiveContains(filter)
        }
        return base.sorted(using: attentionSortOrder)
    }

    private var errors: [LogEvent] {
        let base = filter.isEmpty ? log.allErrors : log.allErrors.filter {
            $0.message.localizedCaseInsensitiveContains(filter)
        }
        return base.sorted(using: errorSortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Sync") {
                        Text(syncer.statusText).lineLimit(2)
                    }
                    LabeledContent("Duplicates found", value: "\(syncer.duplicatesFound)")
                    LabeledContent("Awaiting iCloud delete", value: syncer.pendingDeleteSummary)
                }

                if let d = syncer.cloudDiagnosis {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.icloud.fill")
                                .foregroundStyle(.orange)
                            Text(d)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(showCloudSteps ? "Hide Steps" : "How to Fix…") {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showCloudSteps.toggle()
                                }
                            }
                            .controlSize(.small)
                        }
                        if showCloudSteps {
                            Text("macOS Photos itself failed to fetch these originals from iCloud, so no app can. Things to check:")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("• Photos › Settings › iCloud: iCloud Photos is on and signed in with the same Apple Account as your iPhone.\n• On the iPhone: Settings › [your name] › iCloud › Photos – is it uploading, paused, or out of storage?\n• Open one of the waiting photos in Photos. If it shows an error or never loads, the original is no longer in iCloud.\n• If so, import them from the iPhone directly (connect it, or AirDrop / Image Capture), then run Photos › Repair Library (hold ⌥⌘ while opening Photos).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Picker("View", selection: $scope) {
                        Text("Needs Attention (\(syncer.attentionItems.count))").tag(Scope.attention)
                        Text("Recent Errors (\(log.allErrors.count))").tag(Scope.errors)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                    if !filter.isEmpty {
                        Button("Clear") { filter = "" }
                    }
                    Button("Retry Now") { syncer.retryFailed() }
                        .disabled(syncer.attentionItems.isEmpty || busy)
                }

                if syncer.isPaused {
                    Text("Sync is paused – resume it to retry.").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)

            Divider()

            if scope == .attention {
                Table(attention, selection: $attentionSelection, sortOrder: $attentionSortOrder) {
                    TableColumn("File", value: \.name) { item in
                        HStack(spacing: 5) {
                            if item.cloud {
                                Image(systemName: "icloud").foregroundStyle(.secondary)
                            }
                            Text(item.name).textSelection(.enabled)
                        }
                    }
                    .width(min: 140, ideal: 200)

                    TableColumn("Reason", value: \.message) { item in
                        Text(item.message)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(item.message)
                    }

                    TableColumn("Attempts", value: \.attempts) { item in
                        Text("\(item.attempts)").monospacedDigit()
                    }
                    .width(70)

                    TableColumn("Next Retry", value: \.retryAt) { item in
                        Text(item.retryAt.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 95)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Open Preview") { syncer.openPreview(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { syncer.openPreview(id) }
                }
                .overlay {
                    if syncer.attentionItems.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.icloud").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Nothing is failing or waiting.").foregroundStyle(.secondary)
                        }
                    } else if attention.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }

                if !syncer.attentionItems.isEmpty {
                    Text("Double-click a row to open its preview (the best photo or compressed video Photos has cached locally).")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8)
                }
            } else {
                Table(errors, selection: $errorSelection, sortOrder: $errorSortOrder) {
                    TableColumn("Time", value: \.date) { e in
                        Text(e.date.formatted(date: .abbreviated, time: .standard))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 155, ideal: 185)

                    TableColumn("Error", value: \.message) { e in
                        Text(e.message)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .help(e.message)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if !ids.isEmpty {
                        Button("Copy \(ids.count == 1 ? "Error" : "\(ids.count) Errors")") {
                            let text = errors.filter { ids.contains($0.id) }
                                .map { "\($0.date.formatted(date: .abbreviated, time: .standard))  \($0.message)" }
                                .joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
                .overlay {
                    if log.allErrors.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No recent errors.").foregroundStyle(.secondary)
                        }
                    } else if errors.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Failed (parked) items
private struct FailedTab: View {
    @ObservedObject var syncer: SyncEngine
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\AttentionItem.name)]
    @State private var filter = ""

    private var items: [AttentionItem] {
        let base = filter.isEmpty ? syncer.parkedItems : syncer.parkedItems.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.message.localizedCaseInsensitiveContains(filter)
        }
        return base.sorted(using: sortOrder)
    }

    private var busy: Bool { syncer.isSyncing || syncer.isPaused }
    private var selectedCount: Int { selection.intersection(Set(syncer.parkedItems.map(\.id))).count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Photos that are still only in iCloud after \(syncer.parkAfterAttempts) attempts. They are no longer retried automatically.")
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                    Spacer()
                    Button("Retry Selected (\(selectedCount))") { syncer.retryParked(selection) }
                        .disabled(selectedCount == 0 || busy)
                    Button("Retry All (\(syncer.parkedCount))") { syncer.retryParked(nil) }
                        .disabled(syncer.parkedCount == 0 || busy)
                }
                if syncer.isPaused {
                    Text("Sync is paused – resume it to retry.").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)

            Divider()

            Table(items, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("File", value: \.name) { Text($0.name).textSelection(.enabled) }
                    .width(min: 140, ideal: 200)
                TableColumn("Reason", value: \.message) { Text($0.message).foregroundStyle(.secondary).lineLimit(2) }
                TableColumn("Attempts", value: \.attempts) { Text("\($0.attempts)").monospacedDigit() }
                    .width(70)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button("Retry \(ids.count == 1 ? "This One" : "\(ids.count) Selected")") { syncer.retryParked(ids) }
                        .disabled(busy)
                    if ids.count == 1, let id = ids.first { Button("Open Preview") { syncer.openPreview(id) } }
                }
            } primaryAction: { ids in
                if let id = ids.first { syncer.openPreview(id) }          // double-click
            }
            .overlay {
                if syncer.parkedItems.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.icloud").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nothing has stopped retrying.").foregroundStyle(.secondary)
                    }
                } else if items.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }

            Text("Double-click a row to open its preview (the best photo or compressed video Photos has cached locally).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

// MARK: Maintenance
private struct MaintenanceTab: View {
    @ObservedObject var syncer: SyncEngine

    var body: some View {
        Form {
            Section("Integrity") {
                Text("Verifies the SHA-256 checksum of every synced file across each enabled destination (uncached read-back for folders and SMB; server-side SSH SHA-256 or read-back for SFTP). Any missing or damaged copies are automatically queued to be restored on the next sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                verificationProgressAndStatusView

                HStack(spacing: 10) {
                    if syncer.isVerifying {
                        Button("Cancel Verification", role: .cancel) {
                            syncer.cancelVerification()
                        }
                        .disabled(syncer.verificationState.isCanceling)
                    } else {
                        Button("Verify Destination Files Now") {
                            syncer.verifyDestinationsNow()
                        }
                        .disabled(syncer.isSyncing || syncer.enabledDestinations.isEmpty)
                        if syncer.isSyncing {
                            Text("Wait for the current sync to finish before starting verification.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if syncer.enabledDestinations.isEmpty {
                            Text("Enable at least one destination first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Reset") {
                Text("Deletes all logs and the sync history, then re-scans your whole Photos library and rebuilds from scratch. Files already in your destination folder are not deleted. You will be asked to confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Purge Logs & Rebuild…", role: .destructive) { syncer.confirmAndReset() }
                    .disabled(syncer.isSyncing)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var verificationProgressAndStatusView: some View {
        switch syncer.verificationState.phase {
        case .idle:
            EmptyView()

        case .connecting(let destName, let index, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(total > 1
                         ? "Connecting to \(destName) (\(index) of \(total))…"
                         : "Connecting to \(destName)…")
                        .fontWeight(.medium)
                }
                Text("Scheduled syncs, deletions, and destination changes are paused until verification finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .running(let destName, let currentFile, let processed, let total, let intact, let damaged, _, let canceling):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(canceling ? "Canceling verification…" : "Verifying \(destName)…")
                        .fontWeight(.medium)
                    Spacer()
                    if total > 0 {
                        let pct = syncer.verificationState.percentInt ?? 0
                        Text("\(processed.formatted()) / \(total.formatted()) (\(pct)%)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if total > 0 {
                    ProgressView(value: Double(min(processed, total)), total: Double(total))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 12) {
                    if !currentFile.isEmpty && !canceling {
                        Text("Checking \(currentFile)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text("\(intact.formatted()) intact")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if damaged > 0 {
                        Text("\(damaged.formatted()) damaged/missing")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }

                Text("Scheduled syncs, deletions, and destination changes are paused until verification finishes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)

        case .completed(let intact, let damaged, let unreachable, let finishedAt):
            let hasIssues = damaged > 0 || !unreachable.isEmpty
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hasIssues ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .foregroundStyle(hasIssues ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    if damaged == 0 && unreachable.isEmpty {
                        Text("Verification complete: all \(intact.formatted()) file(s) matched their recorded SHA-256 checksums.")
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if damaged > 0 {
                            Text("Verification complete: \(intact.formatted()) intact, \(damaged.formatted()) missing or corrupted (queued for restore on next sync).")
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Verified \(intact.formatted()) file(s) on reachable destinations.")
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !unreachable.isEmpty {
                            Text("Skipped unreachable destination(s): \(unreachable.joined(separator: ", ")).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

        case .canceled(let processed, let total, let intact, let damaged, let finishedAt):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification canceled after \(processed.formatted()) of \(total.formatted()) file(s) (\(intact.formatted()) intact\(damaged > 0 ? ", \(damaged.formatted()) queued for restore" : "")).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Stopped \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

        case .failed(let message, _):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }
}
