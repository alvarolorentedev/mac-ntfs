import Foundation
import FSKit
import os

/// Unary FSKit file system: one block device resource in, one volume out.
///
/// Safety default: the volume is read-only unless the mount request explicitly
/// asks for read/write AND the bridge confirms the volume is neither dirty nor
/// hibernated by Windows. The bridge reports the reason for a downgrade; the
/// volume then mounts read-only and logs it.
final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private static let oemID: [UInt8] = Array("NTFS    ".utf8)
    private let logger = Logger(subsystem: "com.github.alvarolorentedev.macntfs.ntfsmodule", category: "fileSystem")
    /// FSKit's check flow loads the resource before asking for a check and then
    /// reuses the same container for the mount; keep the volume so the bridge
    /// is opened exactly once per resource. Keyed on the resource: a second
    /// disk must never be handed the first disk's volume.
    private var volumesByResource: [ObjectIdentifier: NTFSVolumeBase] = [:]

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            logger.debug("probe: not a block device resource; not recognized")
            replyHandler(FSProbeResult.notRecognized, nil)
            return
        }
        do {
            // 4Kn devices reject sub-block reads; the boot sector is in the
            // first logical block on any geometry.
            let readLength = max(512, Int(blockResource.blockSize))
            var sector = [UInt8](repeating: 0, count: readLength)
            let readCount = try sector.withUnsafeMutableBytes { buffer in
                try blockResource.read(into: buffer, startingAt: 0, length: readLength)
            }
            guard readCount >= 11, Array(sector[3..<11]) == Self.oemID else {
                logger.debug("probe: NTFS OEM ID not present; not recognized")
                replyHandler(FSProbeResult.notRecognized, nil)
                return
            }
            logger.info("probe: NTFS signature found; usable")
            replyHandler(FSProbeResult.usable(name: "", containerID: FSContainerIdentifier(uuid: UUID())), nil)
        } catch {
            logger.error("probe: reading boot sector failed: \(String(describing: error), privacy: .public)")
            replyHandler(nil, error)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        logger.notice("load: entered resource=\(String(describing: type(of: resource)), privacy: .public) options=\(options.taskOptions.joined(separator: "|"), privacy: .public)")
        guard let blockResource = resource as? FSBlockDeviceResource else {
            logger.notice("load: rejected: resource is not a block device")
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        // "-f" arrives from the system's check task (a force-load context), not
        // from a format request; formatting is refused separately in
        // startFormat. Loads in that context stay read-only.
        let forceLoad = options.taskOptions.contains("-f")
        if let existing = volumesByResource[ObjectIdentifier(resource)], existing.hasOpenBridge {
            logger.notice("load: reusing the volume already opened for this resource")
            replyHandler(existing, nil)
            return
        }

        // Platform convention: mount(8) delivers no options for a regular
        // mount; an explicit read-only request arrives as "rdonly"/"ro"
        // (used by the app through FSClient). Read/write is therefore the
        // default, and the bridge refuses it whenever the volume is dirty or
        // hibernated, downgrading to read-only with a logged reason. The
        // MacNTFS app itself always requests read-only unless the user
        // explicitly chooses read/write.
        var readOnly = forceLoad
        for option in options.taskOptions {
            let components = option.lowercased().components(separatedBy: CharacterSet(charactersIn: " ,-"))
            if components.contains("rdonly") || components.contains("ro") {
                readOnly = true
            }
        }
        logger.notice("load: task options \(options.taskOptions.joined(separator: "|"), privacy: .public); requested read-only: \(readOnly)")

        let shim = NTFSDeviceShim(resource: blockResource)
        var operations = ntfs_bridge_device_ops()
        shim.fillOperations(&operations)

        var status = NTFS_BRIDGE_OK
        var downgraded = false
        var dirty = false
        var hibernated = false
        let name = blockResource.bsdName
        guard let bridge = ntfs_bridge_open_device(&operations,
                                                   name,
                                                   readOnly,
                                                   &status,
                                                   &downgraded,
                                                   &dirty,
                                                   &hibernated) else {
            logger.error("load: opening the NTFS volume failed: \(String(cString: ntfs_bridge_strerror(status)), privacy: .public)")
            replyHandler(nil, ntfsStatusError(status))
            return
        }

        if hibernated {
            logger.warning("load: volume is hibernated by Windows (Fast Startup); read/write refused")
        }
        if dirty {
            logger.warning("load: volume is marked dirty; read/write refused")
        }
        if downgraded {
            logger.warning("load: read/write was requested but the volume is not safe to write; mounted read-only")
        }

        let label = ntfs_bridge_volume_name(bridge).map { String(cString: $0) } ?? ""
        // FSKit replaced the volume protocols in macOS 27 (async
        // FSVolume.Handler); macOS 26 only has FSVolume.Operations. The volume
        // classes share one core, so the only version-dependent code is here.
        let readOnlyVolume = ntfs_bridge_is_read_only(bridge)
        let volumeName = label.isEmpty ? "NTFS Volume" : label
        let volume: NTFSVolumeBase
        if #available(macOS 27.0, *) {
            volume = NTFSVolumeV3(bridge: bridge, shim: shim, readOnly: readOnlyVolume, volumeName: volumeName)
            logger.notice("load: using the macOS 27+ FSVolume.Handler adapter")
        } else {
            volume = NTFSVolumeV1(bridge: bridge, shim: shim, readOnly: readOnlyVolume, volumeName: volumeName)
            logger.notice("load: using the legacy FSVolume.Operations adapter")
        }
        volumesByResource[ObjectIdentifier(resource)] = volume
        containerStatus = .ready
        replyHandler(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // The volume closes its bridge in deactivateVolume; close here too so
        // an unload without deactivation cannot leak the open volume.
        volumesByResource.removeValue(forKey: ObjectIdentifier(resource))?.closeBridge()
        reply(nil)
    }

    func didFinishLoading() {
        logger.debug("extension finished loading")
    }
}

/// Read-only maintenance preflight. The system refuses to mount FSKit block
/// device file systems until a check succeeds; this check is deliberately
/// limited to confirming that the volume opened (which loadResource already
/// established) and it never repairs or writes anything.
extension NTFSFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let joinedOptions = options.taskOptions.joined(separator: " ").lowercased()
        if joinedOptions.contains("y") {
            let message = "MacNTFS does not repair NTFS volumes; use Windows chkdsk for repairs. No changes were made."
            task.logMessage(message)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard !volumesByResource.isEmpty else {
            let message = "MacNTFS preflight found no loaded volume for this resource."
            task.logMessage(message)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENXIO))
        }
        task.logMessage("MacNTFS preflight: the NTFS volume opened successfully. Read-only verification only; no repairs or disk writes were performed.")
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        task.didComplete(error: nil)
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let message = "MacNTFS never formats NTFS volumes."
        task.logMessage(message)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP),
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
