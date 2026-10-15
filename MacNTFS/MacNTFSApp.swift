import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Clicking the Dock icon reopens the main window when it is closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct MacNTFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        CLI.handle(arguments: CommandLine.arguments)
    }

    var body: some Scene {
        MenuBarExtra("MacNTFS", systemImage: "externaldrive") {
            MenuView(model: model)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("MacNTFS", id: "main") {
            MenuView(model: model)
                .onAppear { model.start() }
        }
        .windowResizability(.contentSize)
    }
}
