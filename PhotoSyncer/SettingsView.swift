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

        func attach(to window: NSWindow?, selectedTab: Int?) {
            guard let window else { return }
            let isNewWindow = observedWindow !== window
            let tabChanged = selectedTab != nil && selectedTab != lastTab
            if let selectedTab { lastTab = selectedTab }

            if isNewWindow {
                observedWindow = window
                observations = [
                    window.observe(\.styleMask, options: [.new]) { [weak self] _, _ in
                        if Thread.isMainThread {
                            MainActor.assumeIsolated { self?.enforce() }
                        }
                    },
                    window.observe(\.maxSize, options: [.new]) { [weak self] _, _ in
                        if Thread.isMainThread {
                            MainActor.assumeIsolated { self?.enforce() }
                        }
                    },
                    window.observe(\.contentMaxSize, options: [.new]) { [weak self] _, _ in
                        if Thread.isMainThread {
                            MainActor.assumeIsolated { self?.enforce() }
                        }
                    },
                ]
            }

            if isNewWindow || tabChanged {
                enforce()
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
                Picker("Check for new photos every", selection: $syncer.interval) {
                    ForEach(SyncInterval.allCases) { Text($0.label).tag($0) }
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
                Text("Reads back every synced file from each enabled destination without using the OS file cache and checks its SHA-256 checksum against the ledger. Any missing or damaged copies are automatically queued to be restored on the next sync.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Verify Destination Files Now") { syncer.verifyDestinationsNow() }
                    .disabled(syncer.isSyncing)
            }

            Section("Reset") {
                Text("Deletes all logs and the sync history, then re-scans your whole Photos library and rebuilds from scratch. Files already in your destination folder are not deleted. You will be asked to confirm.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Purge Logs & Rebuild…", role: .destructive) { syncer.confirmAndReset() }
                    .disabled(syncer.isSyncing)
            }
        }
        .formStyle(.grouped)
    }
}
