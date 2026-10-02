// Maclator.app: a launcher for running arm64 macOS apps on an Intel Mac through maclator.

import SwiftUI

@main
struct MaclatorApp: App {
    @StateObject private var launcher = Launcher()
    @StateObject private var monitor = GuestMonitor()

    var body: some Scene {
        Window("Maclator", id: "main") {
            RootView()
                .environmentObject(launcher)
                .environmentObject(monitor)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Rescan Apps") { launcher.refresh() }.keyboardShortcut("r")
            }
        }
    }
}
