import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Clicking the Dock icon reopens the main window when it is closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct MounteeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        Diagnostics.migrateLegacyReports()
        CLI.handle(arguments: CommandLine.arguments)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Offering to start at login is a launch-time decision, so present it
        // once the run loop is up rather than from inside `init`.
        DispatchQueue.main.async { offerLaunchAtLoginIfNeeded(model: model) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, updaterController: updaterController)
                .onAppear { model.start() }
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Mountee", id: "main") {
            MenuView(model: model, updaterController: updaterController)
                .onAppear { model.start() }
        }
        .windowResizability(.contentSize)
    }

    private var menuBarIcon: NSImage {
        let image = NSImage(named: "MounteeMenuBar")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

/// On first launch, offer to add Mountee to Login Items, defaulting to yes.
/// Asked at most once; a later change is made with the menu toggle. Skipped
/// when the login item is already registered.
private func offerLaunchAtLoginIfNeeded(model: AppModel) {
    let key = "MounteeDidOfferLaunchAtLogin"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: key) else { return }
    defaults.set(true, forKey: key)
    guard LaunchAtLogin.status == .notRegistered else { return }

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Open Mountee at login?"
    alert.informativeText = "Mountee can open automatically when you log in, so your NTFS drives are ready without launching the app. You can change this any time from the Mountee menu."
    alert.addButton(withTitle: "Add to Login Items")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
        model.setLaunchAtLogin(true)
    }
}
