import SwiftUI

@main
struct PhotoSyncerApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(syncer: appDelegate.syncer)
        }
        .defaultSize(width: 820, height: 580)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}
