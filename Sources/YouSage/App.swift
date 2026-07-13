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

        Window("Usage", id: "usage") {
            UsageWindow()
        }
        // The design's comfortable content width, plus the room the toolbar's
        // range control and Export button need beside the title.
        .defaultSize(width: 860, height: 720)

        Window("YouSage Settings", id: "settings") {
            SettingsView()
                .frame(width: 520, height: 520)
        }
        .windowResizability(.contentSize)
    }
}
