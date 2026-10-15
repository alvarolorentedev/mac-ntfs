import Darwin
import FSKit
import Foundation

/// Enables this app's FSKit module for the current user.
///
/// macOS keeps the per-user FSKit enablement list at
/// `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`.
/// `fskit_agent` reads that list once at startup, and `fskitd` refuses mounts
/// with "Module ... is disabled!" until the module id is in it. On recent macOS
/// releases the System Settings toggle fails for third-party FSKit modules
/// (LoginItems talks to fskitd as an unentitled client), so the host app
/// maintains the list itself and restarts the agent. This is undocumented
/// surface: every step reports its outcome and nothing is assumed to succeed.
///
/// The host app must be non-sandboxed: the settings group is unreachable from
/// the sandbox, and signalling the user's own `fskit_agent` is out of reach
/// there as well.
///
/// Mechanism described in Apple's documentation only as "enable in System
/// Settings"; the same approach is used by other open-source FSKit drivers.
enum ModuleEnabler {
    static let moduleID = "com.github.alvarolorentedev.macntfs.ntfsmodule"

    enum Outcome: Equatable {
        case enabled
        case notRegistered
        case failed(String)
    }

    static var listURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist")
    }

    /// Enables the module: first through fskitd's management service (the
    /// channel System Settings uses), then — if that is refused — by
    /// maintaining the per-user list directly. Waits until FSKit reports the
    /// module as enabled.
    static func enable(timeout: TimeInterval = 15) -> Outcome {
        if isEnabled() == .enabled {
            return .enabled
        }
        let daemonError = FSKitDaemonEnablement.requestEnable(identifier: moduleID)
        if let daemonError {
            do {
                try addToEnabledList()
            } catch {
                return .failed("fskitd enablement failed (\(daemonError)); direct list update failed: \(error.localizedDescription)")
            }
            restartAgent()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch isEnabled() {
            case .enabled:
                return .enabled
            case nil:
                return .failed("FSKit did not answer while checking module state.")
            case .disabled, .notRegistered:
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if let daemonError {
            return .failed("Enablement request was refused (\(daemonError)) and FSKit still reports the extension as disabled.")
        }
        return .failed("The module is listed but FSKit still reports the extension as disabled.")
    }

    enum EnabledState: Equatable {
        case enabled
        case disabled
        case notRegistered
    }

    /// Reads the live enablement state from FSKit. Blocking; call off the main
    /// thread.
    static func isEnabled() -> EnabledState? {
        let semaphore = DispatchSemaphore(value: 0)
        var state: EnabledState?
        Task {
            do {
                let modules = try await FSClient.shared.installedExtensions
                if let module = modules.first(where: { $0.bundleIdentifier == moduleID }) {
                    state = module.isEnabled ? .enabled : .disabled
                } else {
                    state = .notRegistered
                }
            } catch {
                state = nil
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return state
    }

    // MARK: - Steps

    private static func addToEnabledList() throws {
        let url = listURL
        var format = PropertyListSerialization.PropertyListFormat.binary
        var modules: [String] = []

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            modules = plist as? [String] ?? []
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }

        guard !modules.contains(moduleID) else { return }
        modules.append(moduleID)
        let data = try PropertyListSerialization.data(fromPropertyList: modules, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// SIGKILLs the user's `fskit_agent`; launchd respawns it on the next FSKit
    /// request with the updated list. SIGTERM is ignored by the agent.
    @discardableResult
    private static func restartAgent() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "fskit_agent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
