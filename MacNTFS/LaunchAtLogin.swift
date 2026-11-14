import Foundation
import ServiceManagement

/// Login-item control for the menu bar app itself, backed by `SMAppService`
/// (macOS 13+). The main app registers directly, so there is no helper bundle
/// to install and no extra entitlement to request.
///
/// Everything here reflects the system's actual state: `status` is read from
/// `SMAppService`, never cached, and `setEnabled` reports the failure instead
/// of assuming success.
enum LaunchAtLogin {
    /// Live registration state from the system.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns a
    /// human-readable message on failure, or `nil` on success. Blocking;
    /// call off the main thread.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Stable, script-friendly spelling of `status` for the CLI hooks.
    static var statusDescription: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not-registered"
        case .requiresApproval: return "requires-approval"
        case .notFound: return "not-found"
        @unknown default: return "unknown"
        }
    }
}
