import SwiftUI

struct DeleteOptionsView: View {
    @ObservedObject var syncer: SyncEngine

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
        guard syncer.libraryBytes > 0, let at = syncer.libraryMeasuredAt else { return "Not measured yet (measured after each sync while a budget is on)." }
        let size = ByteCountFormatter.string(fromByteCount: syncer.libraryBytes, countStyle: .file)
        return "Last measured: \(size) on \(at.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Delete from iCloud after sync", isOn: $syncer.deleteAfterSync)
            }

            Group {
                Section("What to delete") {
                    Picker("Delete", selection: $syncer.deleteStyle) {
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
                        TextField("GB", value: $syncer.budgetGB, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $syncer.budgetGB, in: 1...100_000, step: 5).labelsHidden()
                        Text("GB")
                    }
                    .disabled(!syncer.budgetEnabled)
                    Text(measured).font(.caption).foregroundStyle(.secondary)
                }

                Section("Summary") {
                    Text(summary)
                    Text("Only files that were copied, checksum-verified and re-checked just before deletion are ever removed. macOS still asks you to confirm each deletion.")
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
    }
}
