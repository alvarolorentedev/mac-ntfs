import AppKit
import Foundation

/// Collects diagnostics for troubleshooting: extension state, FSKit daemons,
/// module registration, mount table and the detected NTFS volumes.
enum Diagnostics {
    static func collect(volumes: [NTFSVolumeInfo], extensionState: String) -> String {
        var lines: [String] = []
        func section(_ title: String) {
            lines.append("")
            lines.append("===== \(title) =====")
        }

        lines.append("Mountee diagnostics")
        lines.append("date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("extension: \(extensionState)")

        section("FSKit daemons")
        lines.append(run("/usr/bin/pgrep", ["-lf", "fskitd"]) ?? "(fskitd not running)")
        lines.append(run("/usr/bin/pgrep", ["-lf", "fskit_agent"]) ?? "(fskit_agent not running)")

        section("registered FSKit modules")
        lines.append(run("/usr/bin/pluginkit", ["-m", "-p", "com.apple.fskit.fsmodule", "-vv"]) ?? "(unavailable)")

        section("mount table (ntfs)")
        let mounts = run("/sbin/mount", []) ?? ""
        let ntfsLines = mounts.split(separator: "\n").filter { $0.lowercased().contains("ntfs") || $0.contains("fskit") }
        lines.append(ntfsLines.isEmpty ? "(none)" : ntfsLines.joined(separator: "\n"))

        section("detected NTFS volumes")
        if volumes.isEmpty {
            lines.append("(none)")
        } else {
            for volume in volumes {
                let size = ByteCountFormatter.string(fromByteCount: volume.sizeBytes, countStyle: .file)
                let mount = volume.mountPoint ?? "not mounted"
                let mode = volume.isMounted ? (volume.isWritable ? "read-write" : "read-only") : "-"
                lines.append("\(volume.bsdName)  \(volume.name)  \(size)  \(mount)  [\(mode)]")
            }
        }

        section("safety policy")
        lines.append("Read/write is refused for dirty and hibernated volumes; they mount read-only.")
        lines.append("Extended attributes, symbolic links and hard links are reported as unsupported.")

        return lines.joined(separator: "\n") + "\n"
    }

    static func write(volumes: [NTFSVolumeInfo], extensionState: String) -> URL? {
        let directory = supportDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("diagnostics-\(stamp).txt")
        do {
            try collect(volumes: volumes, extensionState: extensionState).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Copies prior diagnostic reports on first launch. Originals remain, and
    /// existing destination files are never overwritten.
    static func migrateLegacyReports() {
        let oldDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacNTFS", isDirectory: true)
        copyLegacyReports(from: oldDirectory, to: supportDirectory)
    }

    static func copyLegacyReports(from oldDirectory: URL, to newDirectory: URL) {
        let manager = FileManager.default
        guard let reports = try? manager.contentsOfDirectory(at: oldDirectory,
                                                             includingPropertiesForKeys: nil),
              !reports.isEmpty else { return }

        do {
            try manager.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Mountee: could not create diagnostics migration folder: %@", error.localizedDescription)
            return
        }

        for report in reports where report.lastPathComponent.hasPrefix("diagnostics-") && report.pathExtension == "txt" {
            let destination = newDirectory.appendingPathComponent(report.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.copyItem(at: report, to: destination)
            } catch {
                NSLog("Mountee: could not copy legacy diagnostic report %@: %@",
                      report.lastPathComponent, error.localizedDescription)
            }
        }
    }

    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mountee", isDirectory: true)
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
