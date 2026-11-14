import Foundation

/// Asks fskitd to enable this module over its Mach service. This is the same
/// channel System Settings uses; fskitd checks the caller's entitlements, and
/// the host app's `com.apple.developer.fskit.mount` capability qualifies it.
///
/// Undocumented surface: both known selector spellings are attempted and every
/// outcome is returned as text for logging.
enum FSKitDaemonEnablement {
    private static let serviceName = "com.apple.filesystems.fskitd"

    @objc private protocol EnableForIdentifierProtocol {
        func setEnabledStateForIdentifier(_ identifier: String,
                                          newState: Bool,
                                          replyHandler: @escaping (Error?) -> Void)
    }

    @objc private protocol EnablePlainProtocol {
        func setEnabledState(_ identifier: String,
                             newState: Bool,
                             replyHandler: @escaping (Error?) -> Void)
    }

    /// Returns nil on success, otherwise a description of why every attempt failed.
    static func requestEnable(identifier: String) -> String? {
        if let firstError = attemptForIdentifier(identifier) {
            if let secondError = attemptPlain(identifier) {
                return "setEnabledStateForIdentifier: \(firstError) | setEnabledState: \(secondError)"
            }
        }
        return nil
    }

    private static func attemptForIdentifier(_ identifier: String) -> String? {
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EnableForIdentifierProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = error.localizedDescription
            semaphore.signal()
        } as? EnableForIdentifierProtocol

        guard let proxy else { return "could not create remote proxy" }
        proxy.setEnabledStateForIdentifier(identifier, newState: true) { error in
            if let error { failure = error.localizedDescription }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return failure ?? "timed out waiting for fskitd"
        }
        return failure
    }

    private static func attemptPlain(_ identifier: String) -> String? {
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EnablePlainProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = error.localizedDescription
            semaphore.signal()
        } as? EnablePlainProtocol

        guard let proxy else { return "could not create remote proxy" }
        proxy.setEnabledState(identifier, newState: true) { error in
            if let error { failure = error.localizedDescription }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return failure ?? "timed out waiting for fskitd"
        }
        return failure
    }
}
