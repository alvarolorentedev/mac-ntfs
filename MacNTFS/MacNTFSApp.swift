import Foundation
import SwiftUI

@main
struct MacNTFSApp: App {
    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--enable-extension") {
            switch ModuleEnabler.enable() {
            case .enabled:
                Self.appendLog("enable-extension: OK")
                print("MacNTFS: extension enabled")
                exit(0)
            case .notRegistered:
                Self.appendLog("enable-extension: module not registered")
                print("MacNTFS: extension is not registered; run the app once first")
                exit(1)
            case .failed(let message):
                Self.appendLog("enable-extension: FAILED: \(message)")
                fputs("MacNTFS: \(message)\n", stderr)
                exit(1)
            }
        }
        if arguments.contains("--extension-status") {
            switch ModuleEnabler.isEnabled() {
            case .enabled:
                Self.appendLog("extension-status: enabled")
                print("enabled")
                exit(0)
            case .disabled:
                Self.appendLog("extension-status: disabled")
                print("disabled")
                exit(1)
            case .notRegistered:
                Self.appendLog("extension-status: not-registered")
                print("not-registered")
                exit(2)
            case nil:
                Self.appendLog("extension-status: unknown")
                print("unknown")
                exit(3)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }

    /// The CLI paths may run without any attached terminal (for example when
    /// launched through LaunchServices), so outcomes also go to a log file.
    private static func appendLog(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacNTFS/extension-enable.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] uid=\(getuid()) pid=\(getpid()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
