import AppKit
import SwiftUI
import Combine

/// Read-only status row inside `NSMenu` using manual frame layout (no Auto Layout intrinsic-size
/// invalidation and no `NSMenu.itemChanged` calls), so live counter updates while the menu is open
/// redraw only this label's pixels without disturbing AppKit's hover highlight or item text colors.
final class StatusRowView: NSView {
    static let menuWidth: CGFloat = 300
    private static let hPad: CGFloat = 14
    private static let vPad: CGFloat = 3

    private let label = NSTextField(labelWithString: "")
    private let wraps: Bool
    private let rowFont: NSFont

    init(wraps: Bool = false, isTitle: Bool = false) {
        self.wraps = wraps
        let size = NSFont.menuFont(ofSize: 0).pointSize
        self.rowFont = isTitle
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: isTitle ? 24 : 22))
        autoresizingMask = [.width]

        label.font = rowFont
        label.textColor = isTitle ? .labelColor : .secondaryLabelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        if wraps {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 4
            label.cell?.wraps = true
            label.cell?.isScrollable = false
        } else {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: Self.hPad,
            y: Self.vPad,
            width: max(bounds.width - Self.hPad * 2, 10),
            height: max(bounds.height - Self.vPad * 2, 14)
        )
    }

    func setText(_ text: String, resizeHeight: Bool) {
        if label.stringValue != text {
            label.stringValue = text
        }
        if resizeHeight {
            updateHeight(for: NSAttributedString(string: text, attributes: [.font: rowFont]))
        }
    }

    private func updateHeight(for attr: NSAttributedString) {
        let h: CGFloat
        if wraps, attr.length > 0 {
            let textW = Self.menuWidth - Self.hPad * 2
            let rect = attr.boundingRect(
                with: NSSize(width: textW, height: 120),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            h = max(ceil(rect.height) + Self.vPad * 2, 22)
        } else {
            h = 22
        }
        if abs(frame.height - h) > 0.5 {
            frame.size.height = h
            needsLayout = true
        }
    }
}

/// Manages the menu-bar `NSStatusItem`, its `NSMenu`, and the Settings window.
/// Avoids SwiftUI `MenuBarExtra(.menu)`, which tears down and re-inserts `NSMenuItem`s on every
/// `@Published` change during live menu tracking (causing the blue selection highlight to shift
/// and leaving white highlighted text stuck on previously hovered rows).
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let syncer = SyncEngine()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var isMenuOpen = false
    private var refreshScheduled = false
    private var isTerminating = false
    private var currentSymbol = ""

    // Persistent status rows (updated in-place without mutating NSMenu structure)
    private let titleRow = StatusRowView(isTitle: true)
    private let statusRow = StatusRowView()
    private let destProblemRow = StatusRowView(wraps: true)
    private let failureRow = StatusRowView()
    private let cloudWaitingRow = StatusRowView()
    private let cloudDiagnosisRow = StatusRowView(wraps: true)
    private let parkedRow = StatusRowView()
    private let pendingDeleteRow = StatusRowView()
    private let lastErrorRow = StatusRowView(wraps: true)

    private var statusMenuItem: NSMenuItem!
    private var destProblemItem: NSMenuItem!
    private var failureItem: NSMenuItem!
    private var cloudWaitingItem: NSMenuItem!
    private var cloudDiagnosisItem: NSMenuItem!
    private var parkedItem: NSMenuItem!
    private var pendingDeleteItem: NSMenuItem!
    private var lastErrorItem: NSMenuItem!

    // Persistent action items
    private var photosSettingsItem: NSMenuItem!
    private var openPhotosItem: NSMenuItem!
    private var automationItem: NSMenuItem!
    private var reconcileItem: NSMenuItem!
    private var loginApprovalItem: NSMenuItem!

    private var syncNowItem: NSMenuItem!
    private var pauseResumeItem: NSMenuItem!
    private var retryPendingItem: NSMenuItem!
    private var deleteQueuedItem: NSMenuItem!

    private var settingsItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.minimumWidth = StatusRowView.menuWidth
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu

        updateIcon()
        refreshMenu(allowStructuralChanges: true)

        syncer.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        syncer.cloudClock.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        if !syncer.hasActiveWork {
            syncer.flushForTermination()
            return .terminateNow
        }
        isTerminating = true
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString))
        Task { @MainActor in
            await syncer.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func viewItem(_ view: StatusRowView) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = view
        return item
    }

    private func actionItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        return item
    }

    private func buildMenu() {
        titleRow.setText("PhotoSyncer", resizeHeight: false)
        let titleItem = viewItem(titleRow)
        statusMenuItem = viewItem(statusRow)
        destProblemItem = viewItem(destProblemRow)
        failureItem = viewItem(failureRow)
        cloudWaitingItem = viewItem(cloudWaitingRow)
        cloudDiagnosisItem = viewItem(cloudDiagnosisRow)
        parkedItem = viewItem(parkedRow)
        pendingDeleteItem = viewItem(pendingDeleteRow)
        lastErrorItem = viewItem(lastErrorRow)

        photosSettingsItem = actionItem("Open Photos Privacy Settings…", action: #selector(onOpenPhotosPrivacy))
        openPhotosItem = actionItem("Open Photos to Download Originals…", action: #selector(onOpenPhotos))
        automationItem = actionItem("Allow Controlling Photos in Automation Settings…", action: #selector(onOpenAutomation))
        reconcileItem = actionItem("Re-sync Missing Files", action: #selector(onReconcile))
        loginApprovalItem = actionItem("Approve Login Item in System Settings…", action: #selector(onApproveLogin))

        syncNowItem = actionItem("Sync Now", action: #selector(onSyncNow))
        pauseResumeItem = actionItem("Pause Sync", action: #selector(onTogglePause))
        retryPendingItem = actionItem("Retry Pending Now", action: #selector(onRetryFailed))
        deleteQueuedItem = actionItem("Delete Queued from iCloud…", action: #selector(onDeleteQueued))

        settingsItem = actionItem("Settings…", action: #selector(onOpenSettings), key: ",")
        quitItem = actionItem("Quit PhotoSyncer", action: #selector(onQuit), key: "q")

        let all: [NSMenuItem] = [
            titleItem,
            statusMenuItem, destProblemItem, failureItem, cloudWaitingItem,
            cloudDiagnosisItem, parkedItem, pendingDeleteItem, lastErrorItem,
            photosSettingsItem, openPhotosItem, automationItem, reconcileItem, loginApprovalItem,
            .separator(),
            syncNowItem, pauseResumeItem, retryPendingItem, deleteQueuedItem,
            .separator(),
            settingsItem,
            .separator(),
            quitItem,
        ]
        for item in all { menu.addItem(item) }
    }

    // MARK: Live updates
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Schedule in `.common` so updates run even while the menu is tracking in `NSEventTrackingRunLoopMode`.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.updateIcon()
                self.refreshMenu(allowStructuralChanges: !self.isMenuOpen)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu(allowStructuralChanges: true)
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        refreshMenu(allowStructuralChanges: true)
    }

    private func updateIcon() {
        let symbol = syncer.isPaused
            ? "pause.circle"
            : syncer.waitingForDestination
            ? "externaldrive.badge.xmark"
            : syncer.isSyncing
            ? "arrow.triangle.2.circlepath.icloud.fill"
            : (syncer.failedCount > 0 || syncer.destinationProblem != nil
               ? "exclamationmark.icloud" : "icloud")
        guard symbol != currentSymbol else { return }
        currentSymbol = symbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "PhotoSyncer")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    /// When `allowStructuralChanges` is false (while the menu is open under the user's pointer),
    /// only already-visible read-only status labels update their text in-place with locked heights —
    /// no `NSMenuItem` is hidden, shown, enabled/disabled, or retitled during active hover tracking.
    private func refreshMenu(allowStructuralChanges: Bool) {
        statusRow.setText(syncer.statusText, resizeHeight: allowStructuralChanges)

        updateOptionalStatus(destProblemItem, row: destProblemRow,
                             text: syncer.destinationProblem.map { "⚠️ \($0)" },
                             fallbackWhenOpen: "✓ Destinations OK",
                             allowStructural: allowStructuralChanges)
        updateOptionalStatus(failureItem, row: failureRow,
                             text: syncer.failureText.map { "⚠️ \($0)" },
                             fallbackWhenOpen: "✓ 0 failed",
                             allowStructural: allowStructuralChanges)
        updateOptionalStatus(cloudWaitingItem, row: cloudWaitingRow,
                             text: syncer.cloudClock.text.map { "☁︎ \($0)" },
                             fallbackWhenOpen: "☁︎ 0 waiting for iCloud download",
                             allowStructural: allowStructuralChanges)
        updateOptionalStatus(cloudDiagnosisItem, row: cloudDiagnosisRow,
                             text: syncer.cloudDiagnosis.map { "⚠️ \($0)" },
                             fallbackWhenOpen: "",
                             allowStructural: allowStructuralChanges)
        updateOptionalStatus(parkedItem, row: parkedRow,
                             text: syncer.parkedCount > 0 ? "⏸ \(syncer.parkedCount) stopped retrying – Settings › Failed" : nil,
                             fallbackWhenOpen: "⏸ 0 stopped retrying",
                             allowStructural: allowStructuralChanges)
        pendingDeleteRow.setText("Deletion queue: \(syncer.pendingDeleteSummary)", resizeHeight: allowStructuralChanges)
        updateOptionalStatus(lastErrorItem, row: lastErrorRow,
                             text: syncer.lastError.map { "⚠️ \($0)" },
                             fallbackWhenOpen: "",
                             allowStructural: allowStructuralChanges)

        guard allowStructuralChanges else { return }

        setHidden(photosSettingsItem, !syncer.needsPhotosSettings)
        setHidden(openPhotosItem, syncer.cloudWaitingCount == 0)
        setHidden(automationItem, !syncer.needsAutomationSettings)
        setHidden(reconcileItem, !syncer.needsConfirmReconcile)
        setHidden(loginApprovalItem, !syncer.loginItemNeedsApproval)

        let busy = syncer.isSyncing || syncer.isPaused
        if syncNowItem.isEnabled != !busy { syncNowItem.isEnabled = !busy }

        let pauseTitle = syncer.isPaused ? "Resume Sync" : "Pause Sync"
        if pauseResumeItem.title != pauseTitle { pauseResumeItem.title = pauseTitle }

        let pending = syncer.failedCount + syncer.cloudWaitingCount
        setHidden(retryPendingItem, pending == 0)
        if pending > 0 {
            let retryTitle = "Retry \(pending) Pending Now"
            if retryPendingItem.title != retryTitle { retryPendingItem.title = retryTitle }
            if retryPendingItem.isEnabled != !busy { retryPendingItem.isEnabled = !busy }
        }

        let queuedDeletes = syncer.pendingDeleteCount
        setHidden(deleteQueuedItem, queuedDeletes == 0)
        if queuedDeletes > 0 {
            let delTitle = "Delete \(syncer.pendingDeleteSummary) Queued from iCloud…"
            if deleteQueuedItem.title != delTitle { deleteQueuedItem.title = delTitle }
            if deleteQueuedItem.isEnabled != !syncer.isSyncing { deleteQueuedItem.isEnabled = !syncer.isSyncing }
        }
    }

    private func updateOptionalStatus(_ item: NSMenuItem, row: StatusRowView, text: String?,
                                      fallbackWhenOpen: String, allowStructural: Bool) {
        if allowStructural {
            if let text {
                row.setText(text, resizeHeight: true)
                setHidden(item, false)
            } else {
                setHidden(item, true)
            }
        } else if !item.isHidden {
            let shown = text ?? (fallbackWhenOpen.isEmpty ? nil : fallbackWhenOpen)
            if let shown { row.setText(shown, resizeHeight: false) }
        }
    }

    private func setHidden(_ item: NSMenuItem, _ hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }

    // MARK: Settings window
    func showSettings() {
        EnvironmentValues().openSettings()
        // Defer window style/size/activation adjustments to the next run-loop turn after NSMenu
        // closes its tracking session and SwiftUI finishes initial layout of the Settings window.
        DispatchQueue.main.async { [weak self] in
            self?.bringSettingsToFront()
        }
    }

    private func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" || $0.title == "PhotoSyncer"
        }) {
            win.title = "PhotoSyncer"
            if !win.styleMask.contains(.resizable) || !win.styleMask.contains(.miniaturizable) {
                win.styleMask.insert([.resizable, .miniaturizable])
            }
            let minSize = NSSize(width: 760, height: 520)
            if win.contentMinSize != minSize { win.contentMinSize = minSize }
            if win.contentMaxSize.width < 10_000 || win.contentMaxSize.height < 10_000 {
                win.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            if win.maxSize.width < 10_000 || win.maxSize.height < 10_000 {
                win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            win.collectionBehavior.insert(.moveToActiveSpace)
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.orderFrontRegardless()
            win.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Menu actions
    @objc private func onOpenPhotosPrivacy() { syncer.openPhotosPrivacySettings() }
    @objc private func onOpenPhotos() { syncer.openPhotos() }
    @objc private func onOpenAutomation() { syncer.openAutomationSettings() }
    @objc private func onReconcile() { syncer.confirmReconcile() }
    @objc private func onApproveLogin() { syncer.openLoginItemsSettings() }
    @objc private func onSyncNow() { syncer.syncNow() }
    @objc private func onTogglePause() { if syncer.isPaused { syncer.resume() } else { syncer.pause() } }
    @objc private func onRetryFailed() { syncer.retryFailed() }
    @objc private func onDeleteQueued() { syncer.deleteQueuedNow() }
    @objc private func onOpenSettings() { showSettings() }
    @objc private func onQuit() { NSApplication.shared.terminate(nil) }
}
