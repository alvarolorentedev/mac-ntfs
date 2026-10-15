import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MacNTFS").font(.headline)
                Spacer()
                Text(model.extensionState)
                    .foregroundStyle(model.extensionState == "Enabled" ? .green : .orange)
            }

            if model.extensionState != "Enabled" {
                Button("Enable File System Extension") { model.enableExtension() }
                Text("Read-only mounting still requires the extension to be enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if model.volumes.isEmpty {
                Text("No NTFS volumes detected")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.volumes) { volume in
                VolumeRow(volume: volume, busy: model.busyDevice == volume.bsdName, model: model)
                if volume.id != model.volumes.last?.id {
                    Divider()
                }
            }

            Divider()

            HStack {
                Button("Refresh") { model.refresh() }
                Button("Copy Diagnostics") {
                    let text = Diagnostics.collect(volumes: model.volumes, extensionState: model.extensionState)
                    Diagnostics.copyToPasteboard(text)
                    if let url = Diagnostics.write(volumes: model.volumes, extensionState: model.extensionState) {
                        model.note("Diagnostics copied to the clipboard; saved at \(url.path)")
                    }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 440)
    }
}

private struct VolumeRow: View {
    let volume: NTFSVolumeInfo
    let busy: Bool
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: volume.isMounted ? "externaldrive.fill" : "externaldrive")
                Text(volume.name).bold()
                Spacer()
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if volume.isMounted {
                    Button("Unmount") { model.unmount(volume) }
                    Button("Eject") { model.eject(volume) }
                    Button("Reveal") {
                        if let mountPoint = volume.mountPoint {
                            NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
                        }
                    }
                    Button("Details") { model.showDetails(volume) }
                } else {
                    Button("Mount Read-Only") { model.mount(volume, readWrite: false) }
                    Button("Mount Read/Write") { model.mount(volume, readWrite: true) }
                    Button("Eject") { model.eject(volume) }
                }
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(busy)
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        guard volume.isMounted else {
            return "not mounted"
        }
        return volume.isWritable ? "read-write" : "read-only"
    }
}
