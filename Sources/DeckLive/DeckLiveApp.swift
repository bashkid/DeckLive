import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a raw Swift Package executable (no Info.plist) means
        // macOS sometimes doesn't treat this as a normal foreground app,
        // so the window gets created but never actually shown/focused.
        // Forcing this explicitly fixes that.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Drop the DeckLive logo onto the dock + cmd-tab. When the binary
        // is wrapped into a .app bundle by scripts/build-app.sh, the
        // bundle's CFBundleIconFile takes precedence; this runtime set is
        // what gives the icon to plain `swift run` dev runs.
        if let iconURL = Bundle.module.url(forResource: "decklive_logo", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main
struct DeckLiveApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var deckStore = DeckStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deckStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF or PowerPoint…") {
                    deckStore.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
