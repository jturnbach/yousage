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
                .modifier(OpensUsageAtLaunch())
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

/// `open YouSage.app --args -openUsageAtLaunch YES` presents the Usage window
/// immediately — the only way to reach it without clicking through the menu bar
/// extra, which scripted UI runs can't always do. It rides on the menu bar
/// label because that is the one view alive at launch.
private struct OpensUsageAtLaunch: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            if UserDefaults.standard.bool(forKey: "openUsageAtLaunch") {
                openWindow(id: "usage")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
