import SwiftUI
import AppKit

@main
struct YouSageApp: App {
    @ObservedObject private var state = AppState.shared

    init() {
        // Make sure we're a menu-bar-only accessory even if LSUIElement is somehow
        // overridden by a host environment.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .frame(width: 380)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("YouSage Settings", id: "settings") {
            SettingsView()
                .frame(width: 520, height: 520)
        }
        .windowResizability(.contentSize)
    }
}
