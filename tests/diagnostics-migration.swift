import Foundation

struct NTFSVolumeInfo {
    let bsdName: String
    let name: String
    let sizeBytes: Int64
    let mountPoint: String?
    let isWritable: Bool
    var isMounted: Bool { mountPoint != nil }
}

@main
struct DiagnosticsMigrationCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mountee-diagnostics-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = root.appendingPathComponent("old", isDirectory: true)
        let new = root.appendingPathComponent("new", isDirectory: true)
        let oldReport = old.appendingPathComponent("diagnostics-old.txt")
        let existingReport = new.appendingPathComponent("diagnostics-kept.txt")
        let activeMount = root.appendingPathComponent("MacNTFS/Volumes/Active", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingReport.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeMount, withIntermediateDirectories: true)
        try Data("copy me".utf8).write(to: oldReport)
        try Data("old version".utf8).write(to: existingReport)
        try Data("keep mount".utf8).write(to: activeMount.appendingPathComponent("sentinel"))
        try Data("not a diagnostic".utf8).write(to: old.appendingPathComponent("notes.txt"))

        Diagnostics.copyLegacyReports(from: old, to: new)

        let copied = try String(contentsOf: new.appendingPathComponent("diagnostics-old.txt"), encoding: .utf8)
        let original = try String(contentsOf: oldReport, encoding: .utf8)
        let existing = try String(contentsOf: existingReport, encoding: .utf8)
        let mountData = try String(contentsOf: activeMount.appendingPathComponent("sentinel"), encoding: .utf8)
        precondition(copied == "copy me")
        precondition(original == "copy me")
        precondition(existing == "old version")
        precondition(!FileManager.default.fileExists(atPath: new.appendingPathComponent("notes.txt").path))
        precondition(mountData == "keep mount")
        print("diagnostics migration checks passed")
    }
}
