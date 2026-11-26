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

    @Test func dailyScheduleWindowHandles3AMBoundariesAndMidnightWraparound() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        func makeDate(day: Int, hour: Int, minute: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: 0))!
        }

        // 3:00 AM target (180 minutes): active [03:00, 04:00), inactive outside.
        let target3AM = 3 * 60
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 2, minute: 59), targetMinutes: target3AM, calendar: cal) == false)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 3, minute: 0), targetMinutes: target3AM, calendar: cal) == true)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 3, minute: 45), targetMinutes: target3AM, calendar: cal) == true)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 4, minute: 0), targetMinutes: target3AM, calendar: cal) == false)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 15, minute: 30), targetMinutes: target3AM, calendar: cal) == false)

        // 11:30 PM target (1410 minutes): crosses midnight cleanly into [00:00, 00:30) of next day.
        let target1130PM = 23 * 60 + 30
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 23, minute: 29), targetMinutes: target1130PM, calendar: cal) == false)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 25, hour: 23, minute: 45), targetMinutes: target1130PM, calendar: cal) == true)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 26, hour: 0, minute: 15), targetMinutes: target1130PM, calendar: cal) == true)
        #expect(DeleteSchedule.isWithinWindow(now: makeDate(day: 26, hour: 0, minute: 30), targetMinutes: target1130PM, calendar: cal) == false)

        // Daily sync due logic: editing schedule at 11:14 PM does not falsely trigger today's past 3:00 AM slot,
        // triggers at 3:00 AM next morning even after a 9:00 PM manual sync, and respects catchUpIfMissed.
        let manualSync9PM = makeDate(day: 25, hour: 21, minute: 0)
        let edited1114PM = makeDate(day: 25, hour: 23, minute: 14)
        #expect(DailySchedule.isDailySyncDue(
            now: makeDate(day: 25, hour: 23, minute: 15),
            lastSync: manualSync9PM,
            scheduleChangedAt: edited1114PM,
            targetMinutes: target3AM,
            catchUpIfMissed: true,
            calendar: cal
        ) == false)

        // Fires at 3:00 AM next morning even though manualSync9PM was only 6 hours earlier.
        #expect(DailySchedule.isDailySyncDue(
            now: makeDate(day: 26, hour: 3, minute: 0),
            lastSync: manualSync9PM,
            scheduleChangedAt: edited1114PM,
            targetMinutes: target3AM,
            catchUpIfMissed: true,
            calendar: cal
        ) == true)

        // Once 3:04 AM finishes, does not fire again at 3:30 AM.
        let synced304AM = makeDate(day: 26, hour: 3, minute: 4)
        #expect(DailySchedule.isDailySyncDue(
            now: makeDate(day: 26, hour: 3, minute: 30),
            lastSync: synced304AM,
            scheduleChangedAt: edited1114PM,
            targetMinutes: target3AM,
            catchUpIfMissed: true,
            calendar: cal
        ) == false)

        // Missed 3:00 AM run checked at 8:30 AM: runs when catchUpIfMissed is true, skips when false.
        #expect(DailySchedule.isDailySyncDue(
            now: makeDate(day: 27, hour: 8, minute: 30),
            lastSync: synced304AM,
            scheduleChangedAt: edited1114PM,
            targetMinutes: target3AM,
            catchUpIfMissed: true,
            calendar: cal
        ) == true)
        #expect(DailySchedule.isDailySyncDue(
            now: makeDate(day: 27, hour: 8, minute: 30),
            lastSync: synced304AM,
            scheduleChangedAt: edited1114PM,
            targetMinutes: target3AM,
            catchUpIfMissed: false,
            calendar: cal
        ) == false)
    }

    @Test func autoWakeConfigBuildsPMSetCommandsAndPreservesPowerOffSchedules() {
        // 1-minute early wake lead time (including midnight wraparound).
        #expect(AutoWakeConfig.wakeMinutes(forSyncMinutes: 180) == 179)
        #expect(AutoWakeConfig.formatPMSetTime(AutoWakeConfig.wakeMinutes(forSyncMinutes: 180)) == "02:59:00")
        #expect(AutoWakeConfig.wakeMinutes(forSyncMinutes: 0) == 1439)
        #expect(AutoWakeConfig.formatPMSetTime(AutoWakeConfig.wakeMinutes(forSyncMinutes: 0)) == "23:59:00")

        // Parse AutoWake.plist with both RepeatingPowerOn and RepeatingPowerOff (Mon–Fri 10:30 PM sleep).
        let plist: [String: Any] = [
            "RepeatingPowerOn": [
                "eventtype": "wake",
                "time": 179,
                "weekdays": 127,
            ],
            "RepeatingPowerOff": [
                "eventtype": "sleep",
                "time": 22 * 60 + 30,
                "weekdays": 31,   // M(1)+T(2)+W(4)+R(8)+F(16) = MTWRF
            ],
        ]
        let state = AutoWakeConfig.parsePlist(plist)
        #expect(AutoWakeConfig.isDailyWakeInstalled(state, forSyncMinutes: 180) == true)
        #expect(AutoWakeConfig.isDailyWakeInstalled(state, forSyncMinutes: 240) == false)
        #expect(state.powerOff == AutoWakeConfig.Entry(eventType: "sleep", weekdays: 31, timeMinutes: 1350))

        // Enabling without an existing power-off schedule.
        #expect(AutoWakeConfig.pmsetArguments(enableWakeForSyncMinutes: 180, preservingPowerOff: nil)
            == ["repeat", "wake", "MTWRFSU", "02:59:00"])

        // Enabling while preserving an existing RepeatingPowerOff entry.
        #expect(AutoWakeConfig.pmsetArguments(enableWakeForSyncMinutes: 180, preservingPowerOff: state.powerOff)
            == ["repeat", "wake", "MTWRFSU", "02:59:00", "sleep", "MTWRF", "22:30:00"])

        // Disabling while preserving an existing RepeatingPowerOff entry vs. cancelling outright.
        #expect(AutoWakeConfig.pmsetArguments(enableWakeForSyncMinutes: nil, preservingPowerOff: state.powerOff)
            == ["repeat", "sleep", "MTWRF", "22:30:00"])
        #expect(AutoWakeConfig.pmsetArguments(enableWakeForSyncMinutes: nil, preservingPowerOff: nil)
            == ["repeat", "cancel"])

        // Live IOKit Dark-Wake + Idle-Sleep power assertion creation & idempotent release.
        let assertion = PowerAssertion(name: "PhotoSyncer unit test", timeout: 10)
        if assertion.lastReturnCode == 0 {
            #expect(assertion.isActive == true)
        }
        assertion.release()
        #expect(assertion.isActive == false)
        assertion.release()
        #expect(assertion.isActive == false)
    }
}
