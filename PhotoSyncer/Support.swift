import Foundation
import Photos
import AVFoundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Network
import CryptoKit
import IOKit
import IOKit.pwr_mgt

enum SyncScheduleMode: String, CaseIterable, Identifiable {
    case interval
    case daily

    var id: String { rawValue }
    var label: String {
        switch self {
        case .interval: return "Every fixed interval"
        case .daily: return "Daily at a set time"
        }
    }
}

enum SyncInterval: Int, CaseIterable, Identifiable {
    case h1 = 1, h4 = 4, h12 = 12, h24 = 24
    var id: Int { rawValue }
    var label: String { "\(rawValue) hour\(rawValue == 1 ? "" : "s")" }
    var seconds: TimeInterval { TimeInterval(rawValue) * 3600 }
}

nonisolated enum DailySchedule {
    static let defaultMinutes = 3 * 60      // 3:00 AM
    static let windowMinutes = 60           // 1-hour window when strict in-window execution is used

    static func clampMinutes(_ minutes: Int) -> Int {
        ((minutes % 1440) + 1440) % 1440
    }

    /// Most recent occurrence of `targetMinutes` (minutes after midnight) at or before `now`.
    static func mostRecentOccurrence(atOrBefore now: Date,
                                     targetMinutes: Int,
                                     calendar: Calendar = .current) -> Date? {
        let clamped = clampMinutes(targetMinutes)
        let hour = clamped / 60, minute = clamped % 60
        let startOfToday = calendar.startOfDay(for: now)
        if let todayTarget = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfToday),
           todayTarget <= now {
            return todayTarget
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: yesterday)
    }

    /// Next upcoming occurrence of `targetMinutes` strictly after `now`.
    static func nextOccurrence(after now: Date,
                               targetMinutes: Int,
                               calendar: Calendar = .current) -> Date? {
        let clamped = clampMinutes(targetMinutes)
        let hour = clamped / 60, minute = clamped % 60
        let startOfToday = calendar.startOfDay(for: now)
        if let todayTarget = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfToday),
           todayTarget > now {
            return todayTarget
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
    }

    /// True when `now` falls within `[targetTime, targetTime + windowMinutes)` in `calendar`
    /// (handles windows crossing midnight, such as 11:30 PM → 12:30 AM).
    static func isWithinWindow(now: Date,
                               targetMinutes: Int,
                               windowMinutes: Int = Self.windowMinutes,
                               calendar: Calendar = .current) -> Bool {
        guard let recent = mostRecentOccurrence(atOrBefore: now, targetMinutes: targetMinutes, calendar: calendar) else {
            return false
        }
        let elapsed = now.timeIntervalSince(recent)
        return elapsed >= 0 && elapsed < TimeInterval(max(windowMinutes, 1) * 60)
    }

    /// Determines whether a daily scheduled sync is due at `now`.
    /// Uses `max(lastSync, scheduleChangedAt)` so changing the time in Settings never falsely treats
    /// an earlier hour today as a missed run, while a manual evening sync still lets a 3:00 AM sync run.
    static func isDailySyncDue(now: Date,
                               lastSync: Date?,
                               scheduleChangedAt: Date?,
                               targetMinutes: Int,
                               catchUpIfMissed: Bool,
                               windowMinutes: Int = Self.windowMinutes,
                               calendar: Calendar = .current) -> Bool {
        if !catchUpIfMissed {
            guard isWithinWindow(now: now, targetMinutes: targetMinutes, windowMinutes: windowMinutes, calendar: calendar) else {
                return false
            }
        }
        guard let recent = mostRecentOccurrence(atOrBefore: now, targetMinutes: targetMinutes, calendar: calendar) else {
            return lastSync == nil
        }
        if let lastSync {
            let baseline = scheduleChangedAt.map { max(lastSync, $0) } ?? lastSync
            return recent > baseline
        } else if let scheduleChangedAt {
            return recent > scheduleChangedAt
        } else {
            return true
        }
    }
}

enum DeleteStyle: String, CaseIterable, Identifiable {
    case justSynced, oldest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .justSynced: return "Files that were just synced"
        case .oldest: return "Oldest synced files"
        }
    }
}

/// One library asset with its approximate size, used to apply the data budget.
nonisolated struct LibraryItem: Sendable {
    var id: String
    var date: Date
    var bytes: Int64
}

/// Live progress and outcome state for on-demand destination file integrity verification.
nonisolated struct DestinationVerificationState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting(destinationName: String, index: Int, totalDestinations: Int)
        case running(
            destinationName: String,
            currentFile: String,
            processedFiles: Int,
            totalFiles: Int,
            intactFiles: Int,
            damagedFiles: Int,
            startedAt: Date,
            canceling: Bool
        )
        case completed(
            intactFiles: Int,
            damagedFiles: Int,
            unreachableDestinations: [String],
            finishedAt: Date
        )
        case canceled(
            processedFiles: Int,
            totalFiles: Int,
            intactFiles: Int,
            damagedFiles: Int,
            finishedAt: Date
        )
        case failed(message: String, finishedAt: Date)
    }

    var phase: Phase = .idle

    var isActive: Bool {
        switch phase {
        case .connecting, .running:
            return true
        case .idle, .completed, .canceled, .failed:
            return false
        }
    }

    var isCanceling: Bool {
        switch phase {
        case .running(_, _, _, _, _, _, _, let canceling):
            return canceling
        default:
            return false
        }
    }

    var fractionCompleted: Double? {
        guard case .running(_, _, let processed, let total, _, _, _, _) = phase, total > 0 else {
            return nil
        }
        return min(max(Double(processed) / Double(total), 0.0), 1.0)
    }

    var percentInt: Int? {
        guard let frac = fractionCompleted else { return nil }
        return Int((frac * 100.0).rounded(.down))
    }

    var menuStatusText: String? {
        switch phase {
        case .idle, .completed, .canceled, .failed:
            return nil
        case .connecting(let name, let index, let total):
            if isCanceling { return "Canceling verification…" }
            return total > 1
                ? "Connecting to \(name) (\(index)/\(total)) for verification…"
                : "Connecting to \(name) for verification…"
        case .running(let destName, _, let processed, let total, _, _, _, let canceling):
            if canceling { return "Canceling verification…" }
            if total > 0 {
                let pct = Int((min(max(Double(processed) / Double(total), 0.0), 1.0) * 100.0).rounded(.down))
                return "Verifying \(destName) · \(processed)/\(total) (\(pct)%)"
            }
            return "Verifying \(destName)…"
        }
    }

    mutating func markCanceling() {
        if case .running(let dest, let file, let processed, let total, let intact, let damaged, let started, _) = phase {
            phase = .running(
                destinationName: dest,
                currentFile: file,
                processedFiles: processed,
                totalFiles: total,
                intactFiles: intact,
                damagedFiles: damaged,
                startedAt: started,
                canceling: true
            )
        }
    }
}

/// Errors that abort a whole run (as opposed to a single item failing).
nonisolated enum SyncError: LocalizedError {
    case message(String)
    case diskFull
    case localDiskFull
    case permission(String)
    /// The original exists only in iCloud and Photos would not download it.
    case cloudOnly(String)
    /// macOS Automation permission to control Photos was refused.
    case automationDenied
    /// The user paused sync; the run stops cleanly at an item boundary.
    case paused
    /// The destination (USB drive / NAS) isn't connected right now. Not a failure: we wait for it.
    case destinationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let m): return m
        case .paused: return "Paused"
        case .message(let m), .permission(let m): return m
        case .diskFull: return "The destination disk is full. Free up space; sync will resume automatically."
        case .localDiskFull:
            return "This Mac is low on startup disk space. Free up local disk space; sync will resume automatically."
        case .cloudOnly(let d):
            return "Original is only in iCloud and could not be downloaded. Open it in Photos or set Photos › Settings › iCloud › Download Originals. (\(d))"
        case .automationDenied:
            return "Allow PhotoSyncer to control Photos in System Settings › Privacy & Security › Automation."
        }
    }
}

/// Thread-safe state shared between a PhotoKit completion handler and its stall timer,
/// guaranteeing the continuation is resumed exactly once.
nonisolated final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var last = Date()

    func touch() { lock.lock(); last = Date(); lock.unlock() }
    /// Returns true for the first caller only.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func stalled(after t: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && Date().timeIntervalSince(last) > t
    }
}

nonisolated enum ErrorInfo {
    /// Full detail for diagnosing opaque framework errors (domain, code, underlying chain).
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var e: NSError? = error as NSError
        var depth = 0
        while let cur = e, depth < 3 {
            parts.append("\(cur.domain) \(cur.code): \(cur.localizedDescription)")
            e = cur.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
    }
}

nonisolated enum ResourceWriter {
    /// Give up if iCloud makes no download progress for this long.
    static let stallTimeout: TimeInterval = 300

    /// Writes a Photos resource to `url`, downloading from iCloud if needed. Tries, in order:
    /// 1) PHAssetResourceManager.writeData  2) PHAssetResourceManager.requestData (streamed)
    /// 3) PHImageManager (a different Photos code path: original image data / original video).
    /// Returns a note when a fallback was needed. Never hangs: stalls time out.
    static func write(_ res: PHAssetResource, asset: PHAsset, to url: URL) async throws -> String? {
        var failures: [String] = []
        do { try await writeData(res, to: url); return nil }
        catch { failures.append("writeData: \(ErrorInfo.describe(error))") }

        try? FileManager.default.removeItem(at: url)
        do { try await stream(res, to: url); return "writeData failed; streamed instead (\(failures[0]))" }
        catch { failures.append("requestData: \(ErrorInfo.describe(error))") }

        try? FileManager.default.removeItem(at: url)
        do {
            if asset.mediaType == .video { try await videoFile(asset, to: url) }
            else { try await imageData(asset, to: url) }
            return "resource APIs failed; used PHImageManager instead (\(failures.joined(separator: " | ")))"
        } catch {
            try? FileManager.default.removeItem(at: url)
            failures.append("PHImageManager: \(ErrorInfo.describe(error))")
        }
        let (inCloud, diag) = await diagnose(res, asset: asset)
        let detail = failures.joined(separator: " | ") + " | " + diag
        if inCloud == true { throw SyncError.cloudOnly(detail) }
        throw SyncError.message(detail)
    }

    /// Facts that explain why Photos won't serve the original (e.g. still only in iCloud).
    static func diagnose(_ res: PHAssetResource, asset: PHAsset) async -> (inCloud: Bool?, text: String) {
        var parts = ["type=\(res.type.rawValue)", "uti=\(res.uniformTypeIdentifier)",
                     "mediaType=\(asset.mediaType.rawValue)", "subtypes=\(asset.mediaSubtypes.rawValue)",
                     "source=\(asset.sourceType.rawValue)", "size=\(asset.pixelWidth)x\(asset.pixelHeight)"]
        // Probe only (network disallowed): is the original available locally, or only in iCloud?
        let probe: (Bool, Bool?) = await withCheckedContinuation { cont in
            if asset.mediaType == .video {
                let o = PHVideoRequestOptions()
                o.version = .original
                o.isNetworkAccessAllowed = false
                PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, info in
                    let cloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue
                    cont.resume(returning: (av != nil, cloud))
                }
            } else {
                let o = PHImageRequestOptions()
                o.version = .original
                o.isNetworkAccessAllowed = false
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, info in
                    let cloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue
                    cont.resume(returning: (data != nil, cloud))
                }
            }
        }
        parts.append("localData=\(probe.0) inCloud=\(probe.1.map(String.init) ?? "?")")
        return (probe.1, "diag[" + parts.joined(separator: " ") + "]")
    }

    private static func imageData(_ asset: PHAsset, to url: URL) async throws {
        let dog = Watchdog()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let o = PHImageRequestOptions()
            o.version = .original
            o.deliveryMode = .highQualityFormat
            o.isNetworkAccessAllowed = true
            o.progressHandler = { @Sendable _, _, _, _ in dog.touch() }
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { @Sendable data, _, _, info in
                guard dog.finish() else { return }
                guard let data else {
                    let cloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue
                    cont.resume(throwing: (info?[PHImageErrorKey] as? Error)
                        ?? SyncError.message("No image data returned (inCloud=\(cloud.map(String.init) ?? "?"))"))
                    return
                }
                do { try data.write(to: url, options: .atomic); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
            watch(dog, cont)
        }
    }

    private static func videoFile(_ asset: PHAsset, to url: URL) async throws {
        let dog = Watchdog()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let o = PHVideoRequestOptions()
            o.version = .original
            o.deliveryMode = .highQualityFormat
            o.isNetworkAccessAllowed = true
            o.progressHandler = { @Sendable _, _, _, _ in dog.touch() }
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { @Sendable av, _, info in
                guard dog.finish() else { return }
                guard let src = (av as? AVURLAsset)?.url else {
                    cont.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? SyncError.message("No video file returned"))
                    return
                }
                do { try FileManager.default.copyItem(at: src, to: url); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
            watch(dog, cont)
        }
    }

    private static func writeData(_ res: PHAssetResource, to url: URL) async throws {
        let dog = Watchdog()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { @Sendable _ in dog.touch() }

            PHAssetResourceManager.default().writeData(for: res, toFile: url, options: options) { @Sendable error in
                guard dog.finish() else { return }
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            watch(dog, cont)
        }
    }

    private static func stream(_ res: PHAssetResource, to url: URL) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SyncError.message("Cannot create staging file")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let dog = Watchdog()
        let writeError = ErrorBox()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { @Sendable _ in dog.touch() }

            PHAssetResourceManager.default().requestData(for: res, options: options, dataReceivedHandler: { @Sendable data in
                dog.touch()
                do { try handle.write(contentsOf: data) } catch { writeError.set(error) }
            }, completionHandler: { @Sendable error in
                guard dog.finish() else { return }
                if let e = writeError.value ?? error { cont.resume(throwing: e) } else { cont.resume() }
            })
            watch(dog, cont)
        }
    }

    /// Fails the continuation if no progress is made for `stallTimeout`.
    private static func watch(_ dog: Watchdog, _ cont: CheckedContinuation<Void, Error>) {
        @Sendable func poll() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                if dog.isFinished { return }
                if dog.stalled(after: stallTimeout) {
                    if dog.finish() { cont.resume(throwing: SyncError.message("Timed out waiting for the iCloud download")) }
                } else { poll() }
            }
        }
        poll()
    }
}

/// Extracts the highest-fidelity local space-saving copy Photos already has on disk (never touches the network).
/// - Videos: prefers a local video resource or compressed local AVAsset (.mp4/.mov), falling back to a
///   lossless metadata-enriched poster frame (.png) only if Photos has no playable video stream cached locally.
/// - Photos: prefers untouched raw local derivative/proxy bytes (native HEIC/JPEG/PNG + full camera EXIF/GPS/HDR)
///   when at least as large as Photos' decoded local derivative; otherwise encodes the largest local derivative
///   as lossless PNG with capture date, timezone, and GPS metadata embedded.
nonisolated enum LocalPreview {
    struct Result: Sendable {
        var ext: String
        var isVideo: Bool
    }

    private struct AssetBox: @unchecked Sendable { let av: AVAsset }

    static func write(for asset: PHAsset, to url: URL) async -> Result? {
        try? FileManager.default.removeItem(at: url)
        if asset.mediaType == .video {
            if let ext = await writeVideo(for: asset, to: url) {
                return Result(ext: ext, isVideo: true)
            }
        }
        if let ext = await writeImage(for: asset, to: url) {
            return Result(ext: ext, isVideo: false)
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    // MARK: Video (local resource → local compressed AVAsset)
    private static func writeVideo(for asset: PHAsset, to url: URL) async -> String? {
        let excluded: Set<PHAssetResourceType> = [.pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo]
        let priority: [PHAssetResourceType] = [.fullSizeVideo, .video, .adjustmentBaseVideo]
        let candidates = PHAssetResource.assetResources(for: asset)
            .filter { !excluded.contains($0.type) && $0.contentType.conforms(to: .audiovisualContent) }
            .sorted { a, b in
                let pa = a.pixelWidth * a.pixelHeight, pb = b.pixelWidth * b.pixelHeight
                if pa != pb { return pa > pb }
                return (priority.firstIndex(of: a.type) ?? 99) < (priority.firstIndex(of: b.type) ?? 99)
            }

        for res in candidates {
            try? FileManager.default.removeItem(at: url)
            if await writeResourceLocal(res, to: url),
               await isPlayableVideo(at: url, declaredUTI: res.uniformTypeIdentifier, fallbackName: res.originalFilename) {
                return preferredExt(for: res.contentType, fallbackName: res.originalFilename, defaultExt: "mov")
            }
        }

        let modes: [(PHVideoRequestOptionsVersion, PHVideoRequestOptionsDeliveryMode)] = [
            (.current, .highQualityFormat),
            (.current, .mediumQualityFormat),
            (.current, .fastFormat),
            (.original, .highQualityFormat),
        ]
        for (ver, mode) in modes {
            try? FileManager.default.removeItem(at: url)
            if let ext = await writeLocalAVAsset(for: asset, version: ver, mode: mode, to: url) {
                return ext
            }
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    private static func writeLocalAVAsset(for asset: PHAsset, version: PHVideoRequestOptionsVersion,
                                          mode: PHVideoRequestOptionsDeliveryMode, to url: URL) async -> String? {
        enum Outcome: Sendable { case copied(String), composition(AssetBox), none }
        let outcome: Outcome = await withCheckedContinuation { cont in
            let dog = Watchdog()
            let o = PHVideoRequestOptions()
            o.isNetworkAccessAllowed = false
            o.version = version
            o.deliveryMode = mode
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { @Sendable av, _, _ in
                guard dog.finish() else { return }
                guard let av else { cont.resume(returning: .none); return }
                if let src = (av as? AVURLAsset)?.url, src.isFileURL {
                    try? FileManager.default.removeItem(at: url)
                    if (try? FileManager.default.copyItem(at: src, to: url)) != nil {
                        let e = src.pathExtension.lowercased()
                        cont.resume(returning: .copied(e.isEmpty ? "mp4" : e))
                        return
                    }
                }
                cont.resume(returning: .composition(AssetBox(av: av)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if dog.finish() { cont.resume(returning: .none) }
            }
        }

        switch outcome {
        case .none:
            return nil
        case .copied(let ext):
            return await isPlayableVideo(at: url, fallbackName: "preview.\(ext)") ? ext : nil
        case .composition(let box):
            guard let session = AVAssetExportSession(asset: box.av, presetName: AVAssetExportPresetHighestQuality) else {
                return nil
            }
            let types = await session.compatibleFileTypes
            let ft: AVFileType = types.contains(.mp4) ? .mp4 : (types.contains(.mov) ? .mov : (types.first ?? .mp4))
            let ext = preferredExt(for: UTType(ft.rawValue), fallbackName: nil, defaultExt: ft == .mov ? "mov" : "mp4")
            let tmp = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-exp.\(ext)")
            try? FileManager.default.removeItem(at: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try await session.export(to: tmp, as: ft)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                return await isPlayableVideo(at: url, declaredUTI: ft.rawValue, fallbackName: "preview.\(ext)") ? ext : nil
            } catch {
                return nil
            }
        }
    }

    private static func isPlayableVideo(at url: URL, declaredUTI: String? = nil, fallbackName: String? = nil) async -> Bool {
        guard let size = FileHash.size(of: url), size > 0 else { return false }
        guard let av = await VideoInspector.loadPlayableAsset(at: url, declaredUTI: declaredUTI, fallbackFilename: fallbackName) else {
            return false
        }
        let tracks = (try? await av.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    // MARK: Image (raw local bytes → metadata-enriched local derivative)
    private static func writeImage(for asset: PHAsset, to url: URL) async -> String? {
        let rawTmp = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-raw")
        defer { try? FileManager.default.removeItem(at: rawTmp) }

        var rawInfo = await writeRawImageData(for: asset, to: rawTmp)
        if rawInfo == nil {
            rawInfo = await writeRawImageResource(for: asset, to: rawTmp)
        }

        // If the raw file is already near full asset resolution, take it untouched without decoding anything.
        let fullPixels = max(asset.pixelWidth * asset.pixelHeight, 0)
        if let raw = rawInfo, fullPixels > 0, raw.pixels >= fullPixels / 2 {
            try? FileManager.default.removeItem(at: url)
            if (try? FileManager.default.moveItem(at: rawTmp, to: url)) != nil { return raw.ext }
        }

        let cg = await requestBestCGImage(for: asset)
        let cgPixels = cg.map { $0.width * $0.height } ?? 0

        // Prefer raw untouched bytes whenever they match or beat the decoded derivative's resolution.
        if let raw = rawInfo, raw.pixels >= cgPixels {
            try? FileManager.default.removeItem(at: url)
            if (try? FileManager.default.moveItem(at: rawTmp, to: url)) != nil { return raw.ext }
        }

        guard let cg else { return nil }
        guard encodePNG(cg, for: asset, to: url) else { return nil }
        return "png"
    }

    private static func writeRawImageData(for asset: PHAsset, to url: URL) async -> (pixels: Int, ext: String)? {
        guard asset.mediaType == .image else { return nil }
        let utiString: String? = await withCheckedContinuation { cont in
            let dog = Watchdog()
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = false
            o.version = .current
            o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { @Sendable data, uti, _, _ in
                guard dog.finish() else { return }
                guard let data, !data.isEmpty, (try? data.write(to: url, options: .atomic)) != nil else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: uti)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if dog.finish() { cont.resume(returning: nil) }
            }
        }
        guard let utiString else { return nil }
        return imageInfo(at: url, fallbackType: UTType(utiString), fallbackName: nil)
    }

    private static func writeRawImageResource(for asset: PHAsset, to url: URL) async -> (pixels: Int, ext: String)? {
        let priority: [PHAssetResourceType] = [.fullSizePhoto, .photo, .alternatePhoto, .adjustmentBasePhoto, .photoProxy]
        let candidates = PHAssetResource.assetResources(for: asset)
            .filter { $0.contentType.conforms(to: .image) }
            .sorted { a, b in
                let pa = a.pixelWidth * a.pixelHeight, pb = b.pixelWidth * b.pixelHeight
                if pa != pb { return pa > pb }
                return (priority.firstIndex(of: a.type) ?? 99) < (priority.firstIndex(of: b.type) ?? 99)
            }
        for res in candidates {
            try? FileManager.default.removeItem(at: url)
            if await writeResourceLocal(res, to: url),
               let info = imageInfo(at: url, fallbackType: res.contentType, fallbackName: res.originalFilename) {
                return info
            }
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    private static func writeResourceLocal(_ res: PHAssetResource, to url: URL) async -> Bool {
        let dog = Watchdog()
        return await withCheckedContinuation { cont in
            let o = PHAssetResourceRequestOptions()
            o.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().writeData(for: res, toFile: url, options: o) { @Sendable err in
                guard dog.finish() else { return }
                cont.resume(returning: err == nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if dog.finish() { cont.resume(returning: false) }
            }
        }
    }

    private static func requestBestCGImage(for asset: PHAsset) async -> CGImage? {
        for version in [PHImageRequestOptionsVersion.current, .unadjusted] {
            let cg: CGImage? = await withCheckedContinuation { cont in
                let dog = Watchdog()
                let o = PHImageRequestOptions()
                o.isNetworkAccessAllowed = false
                o.version = version
                o.deliveryMode = .highQualityFormat
                o.resizeMode = .none
                PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                                      contentMode: .default, options: o) { @Sendable image, _ in
                    guard dog.finish() else { return }
                    guard let image else { cont.resume(returning: nil); return }
                    let reps: [CGImage] = image.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
                    let largest = reps.max(by: { $0.width * $0.height < $1.width * $1.height })
                    let best = largest ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    cont.resume(returning: best)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if dog.finish() { cont.resume(returning: nil) }
                }
            }
            if let cg { return cg }
        }
        return nil
    }

    /// Encodes a decoded derivative as a lossless PNG while embedding capture date, timezone, and GPS metadata.
    static func encodePNG(_ cg: CGImage, creationDate: Date?, location: CLLocation?, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        let props = metadataProperties(creationDate: creationDate, location: location)
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func encodePNG(_ cg: CGImage, for asset: PHAsset, to url: URL) -> Bool {
        encodePNG(cg, creationDate: asset.creationDate, location: asset.location, to: url)
    }

    static func metadataProperties(creationDate: Date?, location: CLLocation?) -> [CFString: Any] {
        var props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]

        if let date = creationDate {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.timeZone = .current
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let stamp = fmt.string(from: date)

            let sec = TimeZone.current.secondsFromGMT(for: date)
            let sign = sec >= 0 ? "+" : "-"
            let absSec = abs(sec)
            let offset = String(format: "%@%02d:%02d", sign, absSec / 3600, (absSec % 3600) / 60)

            var exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: stamp,
                kCGImagePropertyExifDateTimeDigitized: stamp,
                kCGImagePropertyExifOffsetTimeOriginal: offset,
                kCGImagePropertyExifOffsetTimeDigitized: offset,
            ]
            let frac = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
            let ms = Int((abs(frac) * 1000).rounded()) % 1000
            if ms > 0 {
                let subsec = String(format: "%03d", ms)
                exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec
                exif[kCGImagePropertyExifSubsecTimeDigitized] = subsec
            }
            props[kCGImagePropertyExifDictionary] = exif
            tiff[kCGImagePropertyTIFFDateTime] = stamp
        }
        props[kCGImagePropertyTIFFDictionary] = tiff

        if let loc = location, CLLocationCoordinate2DIsValid(loc.coordinate) {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(loc.coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: loc.coordinate.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(loc.coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: loc.coordinate.longitude >= 0 ? "E" : "W",
            ]
            if loc.verticalAccuracy >= 0 {
                gps[kCGImagePropertyGPSAltitude] = abs(loc.altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = loc.altitude < 0 ? 1 : 0
            }
            if loc.horizontalAccuracy >= 0 {
                gps[kCGImagePropertyGPSHPositioningError] = loc.horizontalAccuracy
            }
            let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
            let dFmt = DateFormatter()
            dFmt.locale = Locale(identifier: "en_US_POSIX")
            dFmt.calendar = Calendar(identifier: .gregorian)
            dFmt.timeZone = utc
            dFmt.dateFormat = "yyyy:MM:dd"
            let tFmt = DateFormatter()
            tFmt.locale = Locale(identifier: "en_US_POSIX")
            tFmt.calendar = Calendar(identifier: .gregorian)
            tFmt.timeZone = utc
            tFmt.dateFormat = "HH:mm:ss"
            gps[kCGImagePropertyGPSDateStamp] = dFmt.string(from: loc.timestamp)
            gps[kCGImagePropertyGPSTimeStamp] = tFmt.string(from: loc.timestamp)
            props[kCGImagePropertyGPSDictionary] = gps
        }
        return props
    }

    private static func imageInfo(at url: URL, fallbackType: UTType?, fallbackName: String?) -> (pixels: Int, ext: String)? {
        guard let size = FileHash.size(of: url), size > 0,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let detected = CGImageSourceGetType(src).flatMap { UTType($0 as String) } ?? fallbackType
        let ext = preferredExt(for: detected, fallbackName: fallbackName, defaultExt: "jpg")
        return (max(w * h, 1), ext)
    }

    private static func preferredExt(for type: UTType?, fallbackName: String?, defaultExt: String) -> String {
        if let e = type?.preferredFilenameExtension?.lowercased(), !e.isEmpty {
            return e == "jpeg" ? "jpg" : e
        }
        if fallbackName != nil {
            let e = ((fallbackName ?? "") as NSString).pathExtension.lowercased()
            if !e.isEmpty { return e == "jpeg" ? "jpg" : e }
        }
        return defaultExt
    }
}

/// Validates staged and preview video files (including Live Photo `.MOV` paired videos).
///
/// On macOS, `AVURLAsset(url:)` inspects the `file://` URL's path extension unless
/// `AVURLAssetOutOfBandMIMETypeKey` is provided; an extensionless staging file causes
/// `AVURLAsset.load(.isPlayable)` to return `false` even for valid QuickTime/MP4 containers.
/// `VideoInspector` both derives the right staging file extension and falls back to container
/// magic-byte / UTI MIME hints when opening extensionless files.
nonisolated enum VideoInspector {
    static func stagingExtension(originalFilename: String, uniformTypeIdentifier: String) -> String {
        let rawExt = (originalFilename as NSString).pathExtension.lowercased()
        let cleanScalars = rawExt.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        if !cleanScalars.isEmpty {
            return String(String.UnicodeScalarView(cleanScalars))
        }
        if let utExt = UTType(uniformTypeIdentifier)?.preferredFilenameExtension?.lowercased(), !utExt.isEmpty {
            return utExt
        }
        return ""
    }

    static func sniffMIMEType(at url: URL, declaredUTI: String? = nil, fallbackFilename: String? = nil) -> String? {
        if let h = try? FileHandle(forReadingFrom: url) {
            let header = (try? h.read(upToCount: 16)) ?? Data()
            try? h.close()
            if header.count >= 12 {
                let boxType = String(decoding: header[4..<8], as: UTF8.self)
                if boxType == "ftyp" {
                    let brand = String(decoding: header[8..<12], as: UTF8.self)
                    if brand == "qt  " { return "video/quicktime" }
                    if brand == "M4V " || brand == "M4VH" || brand == "M4VP" { return "video/x-m4v" }
                    return "video/mp4"
                }
                if boxType == "wide" || boxType == "mdat" || boxType == "moov" || boxType == "free" || boxType == "skip" {
                    return "video/quicktime"
                }
                if header.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
                    return "video/x-matroska"
                }
                if String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
                   String(decoding: header[8..<12], as: UTF8.self) == "AVI " {
                    return "video/avi"
                }
            }
        }
        if let declaredUTI, let mime = UTType(declaredUTI)?.preferredMIMEType {
            return mime
        }
        if let fallbackFilename {
            let ext = (fallbackFilename as NSString).pathExtension
            if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType {
                return mime
            }
        }
        let urlExt = url.pathExtension
        if !urlExt.isEmpty, let mime = UTType(filenameExtension: urlExt)?.preferredMIMEType {
            return mime
        }
        return nil
    }

    static func loadPlayableAsset(at url: URL,
                                  declaredUTI: String? = nil,
                                  fallbackFilename: String? = nil) async -> AVURLAsset? {
        if !url.pathExtension.isEmpty {
            let direct = AVURLAsset(url: url)
            if (try? await direct.load(.isPlayable)) == true {
                return direct
            }
        }
        if let mime = sniffMIMEType(at: url, declaredUTI: declaredUTI, fallbackFilename: fallbackFilename) {
            let hinted = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": mime])
            if (try? await hinted.load(.isPlayable)) == true {
                return hinted
            }
        }
        if url.pathExtension.isEmpty {
            let plain = AVURLAsset(url: url)
            if (try? await plain.load(.isPlayable)) == true {
                return plain
            }
        }
        return nil
    }

    static func validateVideoFile(at url: URL,
                                  declaredUTI: String? = nil,
                                  fallbackFilename: String? = nil,
                                  expectedDuration: TimeInterval? = nil) async throws {
        guard let sz = FileHash.size(of: url), sz > 0 else {
            throw SyncError.message("Downloaded file is empty")
        }
        guard let av = await loadPlayableAsset(at: url, declaredUTI: declaredUTI, fallbackFilename: fallbackFilename) else {
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
        if let expectedDuration, expectedDuration > 2.0, dur.seconds < expectedDuration * 0.8 {
            throw SyncError.message(
                String(format: "Exported video is %.1f s but expected %.1f s (truncated)", dur.seconds, expectedDuration))
        }
    }
}

/// Last-resort route for iCloud-only originals: ask the Photos app itself (via AppleScript) to
/// export the original, which forces its own iCloud download. Needs Automation permission.
nonisolated enum PhotosApp {
    private static let queue = DispatchQueue(label: "PhotoSyncer.applescript")   // NSAppleScript isn't thread-safe

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Exports the original of `localIdentifier` into `folder` and returns the file's URL.
    static func exportOriginal(localIdentifier: String, into folder: URL) async throws -> URL {
        let source = """
        with timeout of 900 seconds
            tell application "Photos"
                set theItem to media item id "\(escape(localIdentifier))"
                export {theItem} to (POSIX file "\(escape(folder.path))" as alias) with using originals
            end tell
        end timeout
        """
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: SyncError.message("Could not build the Photos export script")); return
                }
                var info: NSDictionary?
                _ = script.executeAndReturnError(&info)
                if let info {
                    let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                    let msg = (info[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                    if code == -1743 { cont.resume(throwing: SyncError.automationDenied) }
                    else { cont.resume(throwing: SyncError.message("Photos export failed (\(code)): \(msg)")) }
                } else {
                    cont.resume()
                }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let best = files.max {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let file = best else { throw SyncError.message("Photos did not export a file") }
        return file
    }
}

nonisolated final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    var value: Error? { lock.lock(); defer { lock.unlock() }; return error }
}

nonisolated enum FileHash {
    /// SHA-256 and byte count of a file in a single open/read pass. `noCache` bypasses the OS file
    /// cache so the bytes are actually re-read from the (possibly network) volume instead of memory.
    static func sha256AndSize(of url: URL, noCache: Bool = false) async throws -> (hash: String, size: UInt64) {
        try await Task.detached {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            if noCache { _ = fcntl(h.fileDescriptor, F_NOCACHE, 1) }
            var hasher = SHA256()
            var total: UInt64 = 0
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += UInt64(chunk.count)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (hex, total)
        }.value
    }

    static func sha256(of url: URL, noCache: Bool = false) async throws -> String {
        (try await sha256AndSize(of: url, noCache: noCache)).hash
    }

    static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}

/// Copies a locally staged file to the destination (e.g. a NAS) and proves the copy is
/// byte-identical: flush to disk, then re-read from the destination without the OS cache
/// and compare size + SHA-256 with the original.
nonisolated enum VerifiedCopy {
    static func copy(from src: URL, to dst: URL, expectedHash: String, expectedSize: UInt64) async throws {
        try await Task.detached {
            let outFD = Darwin.open(dst.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard outFD >= 0 else {
                throw SyncError.message("Cannot create a file in the destination folder")
            }
            let outH = FileHandle(fileDescriptor: outFD, closeOnDealloc: false)
            let inH: FileHandle
            do {
                inH = try FileHandle(forReadingFrom: src)
            } catch {
                try? outH.close()
                throw error
            }
            var written: UInt64 = 0
            do {
                while let chunk = try inH.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try outH.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                }
                // Push to stable storage; network filesystems may not support the strong form.
                if fcntl(outH.fileDescriptor, F_FULLFSYNC) == -1 { try? outH.synchronize() }
                try outH.close()
                try inH.close()
            } catch {
                try? outH.close(); try? inH.close()
                throw error
            }

            guard written == expectedSize else {
                throw SyncError.message("Copy verification failed: size mismatch")
            }
            let (readBack, readSize) = try await FileHash.sha256AndSize(of: dst, noCache: true)
            guard readSize == expectedSize else {
                throw SyncError.message("Copy verification failed: size mismatch")
            }
            guard readBack == expectedHash else {
                throw SyncError.message("Copy verification failed: checksum mismatch")
            }
        }.value
    }
}

nonisolated enum FileNames {
    static let canaryName = ".photosyncer-id"

    /// Replace characters SMB/NAS and other filesystems reject; trim trailing dots/spaces; cap length.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var n = name.components(separatedBy: illegal).joined(separator: "_")
        let ext = (n as NSString).pathExtension
        var base = (n as NSString).deletingPathExtension
        while let last = base.last, last == "." || last == " " { base.removeLast() }
        if base.count > 180 { base = String(base.prefix(180)) }
        n = ext.isEmpty ? base : "\(base).\(String(ext.prefix(16)))"
        return base.isEmpty ? "asset" + (ext.isEmpty ? "" : ".\(ext)") : n
    }

    /// Unicode-normalized form so NFC/NFD differences between filesystems don't look like missing files.
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
}

/// Lets scheduled (not manual) syncs wait for a good network.
nonisolated final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.path = p; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "PhotoSyncer.network"))
    }

    /// nil when it's fine to sync in the background.
    var blockReason: String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = path else { return nil }
        if p.status != .satisfied { return "Waiting for network" }
        if p.isConstrained { return "Waiting (Low Data Mode)" }
        if p.isExpensive { return "Waiting for a non-metered network" }
        return nil
    }
}

/// Runs potentially blocking VFS / filesystem calls (such as probing an offline NAS share) off the
/// `@MainActor` and off Swift's cooperative thread pool, failing cleanly if the kernel call stalls.
nonisolated enum BlockingIO {
    private static let queue = DispatchQueue(label: "PhotoSyncer.blockingIO", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(timeout: TimeInterval,
                                 timeoutMessage: String = "The destination volume stopped responding",
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let dog = Watchdog()
            queue.async {
                do {
                    let value = try work()
                    if dog.finish() { cont.resume(returning: value) }
                } catch {
                    if dog.finish() { cont.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if dog.finish() {
                    cont.resume(throwing: SyncError.destinationUnavailable(timeoutMessage))
                }
            }
        }
    }
}

/// Kernel-enforced advisory lock (`flock`) preventing two PhotoSyncer processes from racing on the ledger.
/// Automatically released by the kernel even on `SIGKILL` or crash.
nonisolated final class InstanceLock: @unchecked Sendable {
    private let lockPath: String
    private var fd: Int32 = -1

    init(directory: URL? = nil) {
        let dir = directory ?? SandboxCompat.appSupportDirectory
        lockPath = dir.appendingPathComponent("photosyncer.lock").path
    }

    func acquire(retryTimeout: TimeInterval = 1.5) -> Bool {
        if fd >= 0 { return true }
        let opened = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return true }
        let deadline = Date().addingTimeInterval(max(retryTimeout, 0))
        while true {
            if flock(opened, LOCK_EX | LOCK_NB) == 0 {
                fd = opened
                let pidText = "\(getpid())\n"
                _ = ftruncate(opened, 0)
                _ = pidText.withCString { Darwin.write(opened, $0, strlen($0)) }
                return true
            }
            if Date() >= deadline { break }
            usleep(100_000)
        }
        Darwin.close(opened)
        return false
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Holds both `NetworkClientActive` (required to keep macOS awake across RTC timer / Dark Wake sessions)
/// and `PreventUserIdleSystemSleep` (prevents idle sleep during interactive sessions), bounded by a
/// kernel-enforced `TimeoutActionRelease` safety timeout so a stalled task can never hold power forever.
nonisolated final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [IOPMAssertionID] = []
    let lastReturnCode: IOReturn

    init(name: String, details: String? = nil, timeout: TimeInterval = 7200) {
        let clampedTimeout = max(timeout, 1)
        var lastKR: IOReturn = kIOReturnError
        for type in ["NetworkClientActive", "PreventUserIdleSystemSleep"] {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let kr = IOPMAssertionCreateWithDescription(
                type as CFString,
                name as CFString,
                details as CFString?,
                nil,
                nil,
                clampedTimeout,
                "TimeoutActionRelease" as CFString,
                &id
            )
            lastKR = kr
            if kr == kIOReturnSuccess, id != IOPMAssertionID(kIOPMNullAssertionID) {
                ids.append(id)
            }
        }
        lastReturnCode = ids.isEmpty ? lastKR : kIOReturnSuccess
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !ids.isEmpty
    }

    func release() {
        lock.lock()
        let toRelease = ids
        ids.removeAll()
        lock.unlock()
        for id in toRelease {
            _ = IOPMAssertionRelease(id)
        }
    }

    deinit { release() }

    /// Wakes the display / WindowServer out of Dark Wake so system confirmation alerts can render on screen.
    static func declareUserActivity(reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let kr = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
        return (kr == kIOReturnSuccess && id != IOPMAssertionID(kIOPMNullAssertionID)) ? id : nil
    }

    static func releaseAssertion(_ id: IOPMAssertionID?) {
        guard let id, id != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        _ = IOPMAssertionRelease(id)
    }
}

// MARK: - Concurrent Sync Coordination

/// Tracks committed and in-flight reserved filenames for a single destination so concurrent workers
/// never pick the same target filename (case-insensitively, NFC/NFD-normalized).
nonisolated struct DestinationNameBook: Sendable {
    private(set) var names: Set<String>
    private(set) var actualNames: [String: String]
    private(set) var sizes: [String: UInt64]
    private(set) var reservedNames: Set<String> = []

    init(listing: [RemoteFile]) {
        names = Set(listing.map { FileNames.key($0.name) })
        actualNames = Dictionary(listing.map { (FileNames.key($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
        sizes = Dictionary(listing.map { (FileNames.key($0.name), $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    func isOccupied(_ name: String) -> Bool {
        let k = FileNames.key(name)
        return names.contains(k) || reservedNames.contains(k)
    }

    /// Returns `(actualName, size)` if `name` is already committed on disk and not currently being
    /// inspected/written by another worker.
    func unreservedExisting(_ name: String) -> (actualName: String, size: UInt64)? {
        let k = FileNames.key(name)
        guard names.contains(k), !reservedNames.contains(k) else { return nil }
        return (actualNames[k] ?? name, sizes[k] ?? 0)
    }

    @discardableResult
    mutating func reserve(_ name: String) -> Bool {
        let k = FileNames.key(name)
        guard !names.contains(k), !reservedNames.contains(k) else { return false }
        reservedNames.insert(k)
        return true
    }

    /// Temporarily locks an existing committed filename while a worker hashes it for adoption,
    /// preventing a second worker from simultaneously hashing or colliding with it.
    mutating func lockExistingForInspection(_ name: String) -> Bool {
        let k = FileNames.key(name)
        guard names.contains(k), !reservedNames.contains(k) else { return false }
        reservedNames.insert(k)
        return true
    }

    mutating func releaseReservation(_ name: String) {
        reservedNames.remove(FileNames.key(name))
    }

    mutating func commitFile(name: String, size: UInt64) {
        let k = FileNames.key(name)
        reservedNames.remove(k)
        names.insert(k)
        actualNames[k] = name
        sizes[k] = size
    }

    mutating func removeFile(name: String) {
        let k = FileNames.key(name)
        reservedNames.remove(k)
        names.remove(k)
        actualNames[k] = nil
        sizes[k] = nil
    }
}

/// FIFO worker + byte-budget limiter for concurrent photo/video staging and SMB uploads.
/// Allows up to `maxWorkers` items concurrently while `inFlightBytes <= maxInFlightBytes`,
/// always admitting a single oversized video solo (`inFlightCount == 0`) so large files never deadlock
/// and never thrash NAS spinning disks alongside other large transfers.
actor SyncPipelineGate {
    nonisolated static let defaultMaxWorkers = 4
    nonisolated static let defaultMaxInFlightBytes: Int64 = 512_000_000   // 512 MB cap on concurrent staged bytes

    private let maxWorkers: Int
    private let maxInFlightBytes: Int64
    private(set) var inFlightCount = 0
    private(set) var inFlightBytes: Int64 = 0
    private var waiters: [(bytes: Int64, cont: CheckedContinuation<Void, Never>)] = []

    init(maxWorkers: Int = SyncPipelineGate.defaultMaxWorkers,
         maxInFlightBytes: Int64 = SyncPipelineGate.defaultMaxInFlightBytes) {
        self.maxWorkers = max(1, maxWorkers)
        self.maxInFlightBytes = max(1, maxInFlightBytes)
    }

    private func canAdmit(bytes: Int64) -> Bool {
        guard inFlightCount < maxWorkers else { return false }
        if inFlightCount == 0 { return true }
        return inFlightBytes + bytes <= maxInFlightBytes
    }

    func acquire(bytes: Int64) async {
        let cost = max(bytes, 1)
        if waiters.isEmpty && canAdmit(bytes: cost) {
            inFlightCount += 1
            inFlightBytes += cost
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append((cost, cont))
        }
    }

    func release(bytes: Int64) {
        let cost = max(bytes, 1)
        inFlightCount = max(0, inFlightCount - 1)
        inFlightBytes = max(0, inFlightBytes - cost)
        while let first = waiters.first, canAdmit(bytes: first.bytes) {
            waiters.removeFirst()
            inFlightCount += 1
            inFlightBytes += first.bytes
            first.cont.resume()
        }
    }
}

/// Coordinates simultaneous workers that happen to stage byte-identical content (same SHA-256)
/// for the same destination, so the second worker awaits the first instead of uploading a duplicate.
@MainActor
final class InFlightHashGate {
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func waitIfInFlight(key: String) async -> Bool {
        guard waiters[key] != nil else { return false }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(cont)
        }
        return true
    }

    func begin(key: String) {
        if waiters[key] == nil {
            waiters[key] = []
        }
    }

    func end(key: String) {
        let list = waiters.removeValue(forKey: key) ?? []
        for cont in list { cont.resume() }
    }
}
