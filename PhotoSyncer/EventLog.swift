import SwiftUI
import Combine
import os

struct LogEvent: Identifiable, Codable {
    enum Level: String, Codable { case info, warning, error }
    var id = UUID()
    var date: Date
    var level: Level
    var message: String
}

/// App-wide event log: shown in the menu / log window, persisted to disk across launches
/// (rotated at 1 MB, one backup kept) and mirrored to the unified system log.
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()
    static let maxInMemory = 5000
    private static let maxFileBytes: UInt64 = 5_000_000

    @Published private(set) var events: [LogEvent] = []

    let fileURL: URL
    private let osLog = Logger(subsystem: "com.gc.PhotoSyncer", category: "app")
    private nonisolated let writeQueue = DispatchQueue(label: "PhotoSyncer.eventlog", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("PhotoSyncer.log.jsonl")
        loadRecent()
    }

    // MARK: Logging API
    func debug(_ message: String) { osLog.debug("\(message, privacy: .public)") }   // system log only
    func info(_ message: String) { append(.info, message) }
    func warning(_ message: String) { append(.warning, message) }
    func error(_ message: String) { append(.error, message) }

    var errorCount: Int { events.reduce(0) { $0 + ($1.level == .error ? 1 : 0) } }

    /// Every error still in the log, newest first (up to `maxInMemory` entries are kept).
    var allErrors: [LogEvent] { events.filter { $0.level == .error }.reversed() }

    /// Newest first.
    func recentErrors(_ limit: Int = 5) -> [LogEvent] {
        Array(events.filter { $0.level == .error }.suffix(limit).reversed())
    }

    func clear() {
        events.removeAll()
        let url = fileURL
        writeQueue.async {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        }
    }

    func text(errorsOnly: Bool = false) -> String {
        events.filter { !errorsOnly || $0.level != .info }
            .map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue.uppercased())] \($0.message)" }
            .joined(separator: "\n")
    }

    // MARK: Internals
    private func append(_ level: LogEvent.Level, _ message: String) {
        let event = LogEvent(date: Date(), level: level, message: message)
        events.append(event)
        if events.count > Self.maxInMemory { events.removeFirst(events.count - Self.maxInMemory) }
        switch level {
        case .info: osLog.info("\(message, privacy: .public)")
        case .warning: osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
        persist(event)
    }

    private func persist(_ event: LogEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let url = fileURL
        let maxBytes = Self.maxFileBytes
        writeQueue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
               size > maxBytes {
                let backup = url.appendingPathExtension("1")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            }
        }
    }

    /// Restore the tail of the persisted log so errors from before a restart stay visible.
    private func loadRecent() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A).suffix(Self.maxInMemory)
        events = lines.compactMap { try? decoder.decode(LogEvent.self, from: Data($0)) }
    }
}
