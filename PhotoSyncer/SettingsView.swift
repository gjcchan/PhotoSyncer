import SwiftUI
import AppKit

/// The single window for everything configurable: General, Delete, Activity, Logs, Maintenance.
struct SettingsView: View {
    @ObservedObject var syncer: SyncEngine

    var body: some View {
        TabView {
            GeneralTab(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("General", systemImage: "gearshape") }
            DestinationsView(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Destinations", systemImage: "externaldrive.connected.to.line.below") }
            DeleteOptionsView(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Delete", systemImage: "icloud.slash") }
            ActivityTab(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Activity", systemImage: "exclamationmark.bubble") }
            FailedTab(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Failed", systemImage: "xmark.icloud") }
                .badge(syncer.parkedCount)
            LogView(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Logs", systemImage: "doc.text") }
            MaintenanceTab(syncer: syncer)
                .navigationTitle("PhotoSyncer")
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
        }
        .navigationTitle("PhotoSyncer")
        .frame(minWidth: 760, minHeight: 520)
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
    @ObservedObject var syncer: SyncEngine
    @ObservedObject private var log = EventLog.shared
    @State private var filter = ""

    private var attention: [AttentionItem] {
        guard !filter.isEmpty else { return syncer.attentionItems }
        return syncer.attentionItems.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.message.localizedCaseInsensitiveContains(filter)
        }
    }

    private var errors: [LogEvent] {
        let all = log.allErrors                      // newest first
        guard !filter.isEmpty else { return all }
        return all.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Sync", value: syncer.statusText)
                LabeledContent("Duplicates found", value: "\(syncer.duplicatesFound)")
                LabeledContent("Awaiting iCloud delete", value: "\(syncer.pendingDeleteCount)")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            if let d = syncer.cloudDiagnosis {
                VStack(alignment: .leading, spacing: 6) {
                    Label(d, systemImage: "exclamationmark.icloud").fontWeight(.semibold)
                    Text("macOS Photos itself failed to fetch these originals from iCloud, so no app can. Things to check:")
                    Text("• Photos › Settings › iCloud: iCloud Photos is on and signed in with the same Apple Account as your iPhone.\n• On the iPhone: Settings › [your name] › iCloud › Photos – is it uploading, paused, or out of storage?\n• Open one of the waiting photos in Photos. If it shows an error or never loads, the original is no longer in iCloud.\n• If so, import them from the iPhone directly (connect it, or AirDrop / Image Capture), then run Photos › Repair Library (hold ⌥⌘ while opening Photos).")
                        .font(.callout)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter both lists", text: $filter)
                    .textFieldStyle(.roundedBorder)
                if !filter.isEmpty {
                    Button("Clear") { filter = "" }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Drag the divider to give either list more room; each list scrolls on its own.
            VSplitView {
                pane(title: "Needs attention (\(attention.count)\(filter.isEmpty ? "" : " of \(syncer.attentionItems.count)"))") {
                    if syncer.attentionItems.isEmpty {
                        Text("Nothing is failing or waiting.").foregroundStyle(.secondary)
                    } else {
                        Button("Retry Now") { syncer.retryFailed() }
                            .disabled(syncer.isSyncing || syncer.isPaused)
                    }
                } content: {
                    List(attention) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.cloud ? "☁︎ " : "")\(item.name)").fontWeight(.medium)
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                            Text("Attempt \(item.attempts) · next retry \(item.retryAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .textSelection(.enabled)
                    }
                }

                pane(title: "Recent errors (\(errors.count)\(filter.isEmpty ? "" : " of \(log.allErrors.count)"))") {
                    EmptyView()
                } content: {
                    List(errors) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.date.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(e.message).textSelection(.enabled)
                        }
                    }
                    .overlay { if errors.isEmpty { Text("No recent errors").foregroundStyle(.secondary) } }
                }
            }
        }
    }

    private func pane<Header: View, Content: View>(title: String, @ViewBuilder header: () -> Header,
                                                   @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                header()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            content().listStyle(.inset)
        }
        .frame(minHeight: 140)
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
