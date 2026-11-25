import SwiftUI

struct DeleteOptionsView: View {
    @ObservedObject var syncer: SyncEngine

    @State private var draftBudgetGB: Int = 50
    @State private var pendingLowerBudget: Int?
    @State private var showOldestWarning = false
    @State private var stepperTask: Task<Void, Never>?
    @FocusState private var budgetFocused: Bool

    private var budgetText: String { "\(syncer.budgetGB) GB" }

    private var summary: String {
        switch (syncer.deleteStyle, syncer.budgetEnabled) {
        case (.justSynced, false):
            return "Each file is deleted from iCloud right after it has been copied and verified."
        case (.justSynced, true):
            return "Files are deleted right after they are synced, but only while your iCloud library is over \(budgetText). Once it is under budget, nothing is deleted."
        case (.oldest, _):
            return "When your iCloud library is over \(budgetText), the oldest files that are already copied and verified are deleted until it is back under budget."
        }
    }

    private var measured: String {
        guard syncer.libraryBytes > 0, let at = syncer.libraryMeasuredAt else {
            return "Not measured yet (measured after each sync while a budget is on)."
        }
        let size = ByteCountFormatter.string(fromByteCount: syncer.libraryBytes, countStyle: .file)
        return "Last measured: \(size) on \(at.formatted(date: .abbreviated, time: .shortened))"
    }

    private var holdSummary: String {
        if !syncer.holdDeletions {
            return "PhotoSyncer asks macOS to delete queued items automatically at the end of each sync."
        }
        if syncer.holdThresholdEnabled {
            return "Eligible items accumulate silently in the deletion queue across background syncs until the queue reaches \(syncer.holdThresholdGB) GB, or until you click “Delete Queued from iCloud…” in the menu bar."
        }
        return "Eligible items accumulate silently in the deletion queue across background syncs without interrupting you, until you click “Delete Queued from iCloud…” in the menu bar."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Delete from iCloud after sync", isOn: $syncer.deleteAfterSync)
            }

            Group {
                Section("What to delete") {
                    Picker("Delete", selection: Binding(
                        get: { syncer.deleteStyle },
                        set: { newStyle in
                            guard newStyle != syncer.deleteStyle else { return }
                            if newStyle == .oldest {
                                showOldestWarning = true
                            } else {
                                syncer.deleteStyle = newStyle
                            }
                        }
                    )) {
                        ForEach(DeleteStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Section("Data budget") {
                    Toggle("Only delete when my iCloud library is over a budget", isOn: $syncer.budgetEnabled)
                        .disabled(syncer.deleteStyle == .oldest)     // "oldest" needs a budget to be meaningful
                    HStack {
                        Text("Budget")
                        TextField("GB", value: $draftBudgetGB, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .focused($budgetFocused)
                            .onSubmit { commitDraftBudget() }
                        Stepper("", value: Binding(
                            get: { draftBudgetGB },
                            set: { newVal in
                                let clamped = min(max(newVal, 1), 100_000)
                                draftBudgetGB = clamped
                                scheduleStepperCommit()
                            }
                        ), in: 1...100_000, step: 5).labelsHidden()
                        Text("GB")
                        if draftBudgetGB != syncer.budgetGB {
                            Button("Apply") { commitDraftBudget() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Revert") {
                                stepperTask?.cancel()
                                draftBudgetGB = syncer.budgetGB
                            }
                            .controlSize(.small)
                        }
                    }
                    .disabled(!syncer.budgetEnabled)
                    Text(measured).font(.caption).foregroundStyle(.secondary)
                }

                Section("When to prompt macOS to delete") {
                    Toggle("Hold deletions in queue until I click Delete in the menu", isOn: $syncer.holdDeletions)
                    if syncer.holdDeletions {
                        Toggle("Or auto-prompt once the deletion queue reaches", isOn: $syncer.holdThresholdEnabled)
                        HStack {
                            Text("Queue threshold")
                            TextField("GB", value: $syncer.holdThresholdGB, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $syncer.holdThresholdGB, in: 1...10_000, step: 1).labelsHidden()
                            Text("GB")
                        }
                        .disabled(!syncer.holdThresholdEnabled)
                    }
                    Text(holdSummary).font(.caption).foregroundStyle(.secondary)
                }

                Section("Summary") {
                    Text(summary)
                    Text("Only files that were copied, checksum-verified and re-checked just before deletion are ever removed. macOS still asks you to confirm each deletion batch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!syncer.deleteAfterSync)

            Section {
                Label {
                    Text("With iCloud Photos on, deleting here removes the photo from your iPhone and all other devices too. Items stay in Recently Deleted for 30 days and still count toward your iCloud storage until then.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftBudgetGB = syncer.budgetGB }
        .onChange(of: syncer.budgetGB) { _, newVal in
            if pendingLowerBudget == nil { draftBudgetGB = newVal }
        }
        .onChange(of: budgetFocused) { _, focused in
            if !focused { commitDraftBudget() }
        }
        .alert(
            "Lower iCloud budget from \(syncer.budgetGB) GB to \(pendingLowerBudget ?? draftBudgetGB) GB?",
            isPresented: Binding(
                get: { pendingLowerBudget != nil },
                set: {
                    if !$0 {
                        draftBudgetGB = syncer.budgetGB
                        pendingLowerBudget = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                draftBudgetGB = syncer.budgetGB
                pendingLowerBudget = nil
            }
            Button("Lower to \(pendingLowerBudget ?? draftBudgetGB) GB", role: .destructive) {
                if let target = pendingLowerBudget {
                    syncer.budgetGB = target
                    draftBudgetGB = target
                }
                pendingLowerBudget = nil
            }
        } message: {
            Text(lowerBudgetMessage(targetGB: pendingLowerBudget ?? draftBudgetGB))
        }
        .alert("Retroactively delete oldest synced files over \(syncer.budgetGB) GB?", isPresented: $showOldestWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Use Oldest Synced Files", role: .destructive) {
                syncer.deleteStyle = .oldest
            }
        } message: {
            Text(oldestStyleMessage)
        }
    }

    private func scheduleStepperCommit() {
        stepperTask?.cancel()
        if draftBudgetGB >= syncer.budgetGB {
            syncer.budgetGB = draftBudgetGB
            return
        }
        stepperTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !budgetFocused else { return }
            commitDraftBudget()
        }
    }

    private func commitDraftBudget() {
        stepperTask?.cancel()
        let clamped = min(max(draftBudgetGB, 1), 100_000)
        draftBudgetGB = clamped
        guard clamped != syncer.budgetGB else { return }
        if clamped < syncer.budgetGB {
            pendingLowerBudget = clamped
        } else {
            syncer.budgetGB = clamped
        }
    }

    private func lowerBudgetMessage(targetGB: Int) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let targetBytes = Int64(targetGB) * 1_000_000_000
        var body: String
        if syncer.deleteStyle == .oldest {
            if syncer.libraryBytes > targetBytes {
                let lib = fmt(syncer.libraryBytes)
                let excess = fmt(syncer.libraryBytes - targetBytes)
                body = "Your last measured iCloud library is \(lib). On the next sync, PhotoSyncer will retroactively queue roughly \(excess) of your oldest verified synced photos and videos for deletion from iCloud (and all your devices) to bring the library under \(targetGB) GB."
            } else {
                body = "With “Oldest synced files” selected, lowering the budget to \(targetGB) GB will retroactively queue your oldest verified synced photos and videos for deletion from iCloud (and all your devices) whenever your library exceeds \(targetGB) GB."
            }
        } else {
            body = "With “Files that were just synced” selected, previously synced photos won't be deleted retroactively, but newly synced files will be queued for deletion from iCloud whenever your library exceeds \(targetGB) GB."
        }
        if !syncer.deleteAfterSync {
            body += "\n\n(“Delete from iCloud after sync” is currently off, so nothing will be deleted until it is enabled.)"
        }
        return body
    }

    private var oldestStyleMessage: String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let targetBytes = Int64(syncer.budgetGB) * 1_000_000_000
        if syncer.libraryBytes > targetBytes {
            let lib = fmt(syncer.libraryBytes)
            let excess = fmt(syncer.libraryBytes - targetBytes)
            return "Your last measured iCloud library is \(lib). On the next sync, PhotoSyncer will retroactively queue roughly \(excess) of your oldest verified synced photos and videos for deletion from iCloud (and all your devices) to bring the library under \(syncer.budgetGB) GB."
        }
        return "On the next sync, if your iCloud library exceeds \(syncer.budgetGB) GB, PhotoSyncer will retroactively queue your oldest already-synced verified photos and videos for deletion from iCloud (and all your devices) until the library is under \(syncer.budgetGB) GB."
    }
}
