import SwiftUI
import AppKit

struct LogView: View {
    @ObservedObject var syncer: SyncEngine
    @ObservedObject var log = EventLog.shared
    @State private var errorsOnly = false

    private var shown: [LogEvent] {
        log.events.filter { !errorsOnly || $0.level != .info }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Filter", selection: $errorsOnly) {
                    Text("All").tag(false)
                    Text("Errors & Warnings").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Label {
                    Text("Duplicates found: \(Text("\(syncer.duplicatesFound)").foregroundStyle(.secondary))")
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
                .padding(.leading, 12)

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text(errorsOnly: errorsOnly), forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
                }
                Button("Clear", role: .destructive) { log.clear() }
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                List(shown) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date.formatted(date: .abbreviated, time: .standard))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(e.level.rawValue.uppercased())
                            .font(.caption.bold())
                            .foregroundStyle(color(e.level))
                            .frame(width: 56, alignment: .leading)
                        Text(e.message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(e.id)
                }
                .overlay { if shown.isEmpty { Text("No log entries").foregroundStyle(.secondary) } }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: log.events.count) { scrollToEnd(proxy) }
            }
        }
        .frame(minWidth: 700, minHeight: 360)
    }

    private func color(_ level: LogEvent.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}
