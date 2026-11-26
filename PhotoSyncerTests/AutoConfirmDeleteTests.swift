import Foundation
import Testing
@testable import PhotoSyncer

@MainActor
struct AutoConfirmDeleteTests {
    nonisolated private static let trustedHost = "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter"
    nonisolated private static let trustedBundle = "com.apple.UserNotificationCenter"

    private func makeCandidate(
        ownerPID: pid_t = 999,
        myPID: pid_t = 100,
        bundleIdentifier: String? = Self.trustedBundle,
        executablePath: String? = Self.trustedHost,
        staticTexts: [String],
        buttonTitles: [String]
    ) -> DeletePromptCandidate {
        DeletePromptCandidate(
            ownerPID: ownerPID,
            myPID: myPID,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            staticTexts: staticTexts,
            buttonTitles: buttonTitles
        )
    }

    @Test func acceptsGenuinePhotoSyncerSingleAndBatchDeletePrompts() {
        let singlePhoto = makeCandidate(
            staticTexts: [
                "Allow “PhotoSyncer” to delete this photo?",
                "This photo will be deleted from iCloud\u{00A0}Photos on all your devices. It will be in Recently Deleted for 30 days.",
            ],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(singlePhoto, expectedAppName: "PhotoSyncer", expectedCount: 1) == 1)

        let singleVideo = makeCandidate(
            staticTexts: [
                "Allow “PhotoSyncer” to delete this video?",
                "This video will be deleted from the library. It will be in Recently Deleted for 30 days.",
            ],
            buttonTitles: ["Delete Video", "Don’t Allow"]
        )
        #expect(DeletePromptVerifier.verify(singleVideo, expectedAppName: "PhotoSyncer", expectedCount: 1) == 0)

        let singleItem = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete one item?"],
            buttonTitles: ["Don't Allow", "Delete this Item"]
        )
        #expect(DeletePromptVerifier.verify(singleItem, expectedAppName: "PhotoSyncer", expectedCount: 1) == 1)

        let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: 1234), number: .decimal)
        let batchItems = makeCandidate(
            staticTexts: [
                "Allow “PhotoSyncer” to delete \(formattedCount) items?",
                "These items will be deleted from iCloud\u{00A0}Photos on all your devices.",
            ],
            buttonTitles: ["Don’t Allow", "Delete \(formattedCount) Items"]
        )
        #expect(DeletePromptVerifier.verify(batchItems, expectedAppName: "PhotoSyncer", expectedCount: 1234) == 1)
    }

    @Test func rejectsOtherAppsAndNamePrefixCollisions() {
        let otherApp = makeCandidate(
            staticTexts: ["Allow “OtherCleaner” to delete 5 photos?"],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(otherApp, expectedAppName: "PhotoSyncer", expectedCount: 5) == nil)

        let prefixCollision = makeCandidate(
            staticTexts: ["Allow “PhotoSyncerHelper” to delete 5 photos?"],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(prefixCollision, expectedAppName: "PhotoSyncer", expectedCount: 5) == nil)
    }

    @Test func rejectsBatchCountMismatches() {
        let fiftyInsteadOfFive = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete 50 photos?"],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(fiftyInsteadOfFive, expectedAppName: "PhotoSyncer", expectedCount: 5) == nil)

        let wrongBatch = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete 4 photos?"],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(wrongBatch, expectedAppName: "PhotoSyncer", expectedCount: 5) == nil)

        let singularWhenBatchExpected = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete this photo?"],
            buttonTitles: ["Don’t Allow", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(singularWhenBatchExpected, expectedAppName: "PhotoSyncer", expectedCount: 2) == nil)
    }

    @Test func rejectsNonSystemProcessesFinderPhotosAndSelf() {
        let validTexts = ["Allow “PhotoSyncer” to delete 3 photos?"]
        let validButtons = ["Don’t Allow", "Delete"]

        // Own PID (PhotoSyncer's own confirmation alerts)
        let ownAlert = makeCandidate(ownerPID: 100, myPID: 100, staticTexts: validTexts, buttonTitles: validButtons)
        #expect(DeletePromptVerifier.verify(ownAlert, expectedAppName: "PhotoSyncer", expectedCount: 3) == nil)

        // Interactive Photos.app
        let photosApp = makeCandidate(
            bundleIdentifier: "com.apple.Photos",
            executablePath: "/System/Applications/Photos.app/Contents/MacOS/Photos",
            staticTexts: validTexts,
            buttonTitles: validButtons
        )
        #expect(DeletePromptVerifier.verify(photosApp, expectedAppName: "PhotoSyncer", expectedCount: 3) == nil)

        // Finder
        let finder = makeCandidate(
            bundleIdentifier: "com.apple.finder",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            staticTexts: validTexts,
            buttonTitles: validButtons
        )
        #expect(DeletePromptVerifier.verify(finder, expectedAppName: "PhotoSyncer", expectedCount: 3) == nil)

        // Third-party spoofed executable path outside /System/Library/
        let thirdParty = makeCandidate(
            bundleIdentifier: "com.example.Spoof",
            executablePath: "/Applications/Spoof.app/Contents/MacOS/Spoof",
            staticTexts: validTexts,
            buttonTitles: validButtons
        )
        #expect(DeletePromptVerifier.verify(thirdParty, expectedAppName: "PhotoSyncer", expectedCount: 3) == nil)
    }

    @Test func rejectsTCCPrivacyAlbumAndMalformedButtonDialogs() {
        let tccPhotos = makeCandidate(
            staticTexts: ["“PhotoSyncer” would like to access your Photos."],
            buttonTitles: ["Don’t Allow", "Full Access"]
        )
        #expect(DeletePromptVerifier.verify(tccPhotos, expectedAppName: "PhotoSyncer", expectedCount: 1) == nil)

        let albumPrompt = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete the album “Vacation”?"],
            buttonTitles: ["Don’t Allow", "Delete Album"]
        )
        #expect(DeletePromptVerifier.verify(albumPrompt, expectedAppName: "PhotoSyncer", expectedCount: 1) == nil)

        let missingDontAllow = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete 2 photos?"],
            buttonTitles: ["Cancel", "Delete"]
        )
        #expect(DeletePromptVerifier.verify(missingDontAllow, expectedAppName: "PhotoSyncer", expectedCount: 2) == nil)

        let ambiguousDeleteButtons = makeCandidate(
            staticTexts: ["Allow “PhotoSyncer” to delete 2 photos?"],
            buttonTitles: ["Don’t Allow", "Delete", "Delete 2 Photos"]
        )
        #expect(DeletePromptVerifier.verify(ambiguousDeleteButtons, expectedAppName: "PhotoSyncer", expectedCount: 2) == nil)
    }

    @Test func unsandboxedFolderBookmarksRoundTripAndConnect() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSyncerBookmarkTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bookmark = try SandboxCompat.createBookmark(for: dir)
        let resolved = try SandboxCompat.resolveBookmark(bookmark)
        #expect(resolved.url.standardizedFileURL == dir.standardizedFileURL)

        let backend = FolderBackend(url: resolved.url)
        try await backend.connect()
        let files = try await backend.list()
        #expect(files.isEmpty)
        await backend.close()
    }
}
