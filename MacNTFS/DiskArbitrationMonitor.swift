import Darwin
import DiskArbitration
import Foundation

/// An NTFS volume (or raw image) reported by Disk Arbitration.
struct NTFSVolumeInfo: Identifiable, Hashable {
    let bsdName: String
    let name: String
    let sizeBytes: Int64
    let mountPoint: String?
    let isWritable: Bool

    var id: String { bsdName }
    var isMounted: Bool { mountPoint != nil }
}

/// Monitors disks through Disk Arbitration. Device names always come from the
/// system and are validated before any use; nothing here builds shell strings.
final class DiskArbitrationMonitor {
    private let session: DASession
    private var volumeIDs: Set<String> = []
    private(set) var volumes: [NTFSVolumeInfo] = []
    var onChange: (([NTFSVolumeInfo]) -> Void)?

    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        self.session = session
    }

    func start() {
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            guard let context else { return }
            Unmanaged<DiskArbitrationMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)
        refresh()
    }

    /// Reads /dev entries, resolves each through Disk Arbitration, and filters
    /// for NTFS content.
    func refresh() {
        let detected = enumerateVolumes()
        volumes = detected
        onChange?(detected)
    }

    private func enumerateVolumes() -> [NTFSVolumeInfo] {
        let deviceNames = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let mounts = mountTable()
        var result: [NTFSVolumeInfo] = []
        for entry in deviceNames where entry.hasPrefix("disk") && !entry.hasPrefix("rdisk") {
            guard entry.range(of: "^disk[0-9]+(s[0-9]+)?$", options: .regularExpression) != nil else {
                continue
            }
            if let info = describe(bsdName: entry, mounts: mounts) {
                result.append(info)
            }
        }
        return result.sorted { $0.bsdName < $1.bsdName }
    }

    /// Mount state comes from the kernel mount table, not Disk Arbitration:
    /// volumes mounted through the module do not always update the DA
    /// description, and the mount table also carries the read-only flag.
    private func mountTable() -> [String: (path: String, readOnly: Bool)] {
        var result: [String: (path: String, readOnly: Bool)] = [:]
        var info: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&info, MNT_NOWAIT)
        guard let info, count > 0 else {
            return result
        }
        for index in 0..<Int(count) {
            let entry = info[index]
            var fs = entry.f_mntfromname
            var mp = entry.f_mntonname
            let source = withUnsafePointer(to: &fs) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let path = withUnsafePointer(to: &mp) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let readOnly = (entry.f_flags & UInt32(MNT_RDONLY)) != 0
            result[source] = (path, readOnly)
        }
        return result
    }

    private func describe(bsdName: String, mounts: [String: (path: String, readOnly: Bool)]) -> NTFSVolumeInfo? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let rawDescription = DADiskCopyDescription(disk) else {
            return nil
        }
        let description = rawDescription as NSDictionary as? [String: Any] ?? [:]
        guard isNTFS(description) else {
            return nil
        }

        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
        var mountPoint: String?
        var writable = false
        if let tableEntry = mounts["/dev/\(bsdName)"] {
            mountPoint = tableEntry.path
            writable = !tableEntry.readOnly
        } else if let url = description[kDADiskDescriptionVolumePathKey as String] as? URL {
            mountPoint = url.path
            writable = FileManager.default.isWritableFile(atPath: url.path)
        }
        var sizeBytes: Int64 = 0
        if let size = description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber {
            sizeBytes = size.int64Value
        }
        let displayName = volumeName?.isEmpty == false ? volumeName! : bsdName

        return NTFSVolumeInfo(bsdName: bsdName,
                              name: displayName,
                              sizeBytes: sizeBytes,
                              mountPoint: mountPoint,
                              isWritable: writable)
    }

    private func isNTFS(_ description: [String: Any]) -> Bool {
        if let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String {
            let normalized = kind.lowercased()
            if normalized == "ntfs" || normalized == "macntfs" {
                return true
            }
        }
        if let content = description[kDADiskDescriptionMediaContentKey as String] as? String {
            if content == "Windows_NTFS" {
                return true
            }
            if content == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" {
                return true
            }
        }
        return false
    }
}
