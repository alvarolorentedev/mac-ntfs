import AppKit
import SwiftUI

struct ContentView: View {
    @State private var copied = false
    @State private var extensionState = "Checking\u{2026}"
    @State private var enableMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacNTFS")
                .font(.title2.bold())
            Text("NTFS read/write for macOS via FSKit. No kernel extension, no macFUSE.")
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                Text("File system extension:")
                Text(extensionState)
                    .foregroundStyle(extensionState == "Enabled" ? .green : .orange)
                if extensionState != "Enabled" {
                    Button("Enable Extension") { enableExtension() }
                }
                Button("Refresh") { refresh() }
            }
            if let enableMessage {
                Text(enableMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("To test with a disposable image:")
            Text("./scripts/m1-mount-test.sh")
                .font(.system(.callout, design: .monospaced))
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Open Extensions Settings") {
                    _ = FSClientBridge.openSettings()
                }
                Button(copied ? "Copied" : "Copy Test Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("./scripts/m1-mount-test.sh", forType: .string)
                    copied = true
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 560, alignment: .leading)
        .task { refresh() }
    }

    private func refresh() {
        Task.detached {
            let state = ModuleEnabler.isEnabled()
            await MainActor.run {
                switch state {
                case .enabled: extensionState = "Enabled"
                case .disabled: extensionState = "Disabled"
                case .notRegistered: extensionState = "Not registered (launch the app once)"
                case nil: extensionState = "Unknown"
                }
            }
        }
    }

    private func enableExtension() {
        enableMessage = nil
        Task.detached {
            let outcome = ModuleEnabler.enable()
            await MainActor.run {
                switch outcome {
                case .enabled:
                    extensionState = "Enabled"
                case .failed(let message):
                    enableMessage = message
                case .notRegistered:
                    extensionState = "Not registered"
                }
            }
        }
    }
}

import FSKit

private enum FSClientBridge {
    static func openSettings() -> Bool {
        FSClient.shared.openFileSystemExtensionsSettings()
    }
}
