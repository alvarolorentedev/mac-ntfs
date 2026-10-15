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

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            logger.debug("probe: not a block device resource; not recognized")
            replyHandler(FSProbeResult.notRecognized, nil)
            return
        }
        do {
            var sector = [UInt8](repeating: 0, count: 512)
            let readCount = try sector.withUnsafeMutableBytes { buffer in
                try blockResource.read(into: buffer, startingAt: 0, length: 512)
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
        guard let blockResource = resource as? FSBlockDeviceResource else {
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        if options.taskOptions.contains("-f") {
            replyHandler(nil, POSIXError(.ENOTSUP))
            return
        }

        // Platform convention: mount(8) delivers no options for a regular
        // mount; an explicit read-only request arrives as "rdonly"/"ro"
        // (used by the app through FSClient). Read/write is therefore the
        // default, and the bridge refuses it whenever the volume is dirty or
        // hibernated, downgrading to read-only with a logged reason. The
        // MacNTFS app itself always requests read-only unless the user
        // explicitly chooses read/write.
        var readOnly = false
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

        let volume = NTFSVolume(bridge: bridge,
                                shim: shim,
                                readOnly: ntfs_bridge_is_read_only(bridge),
                                volumeName: "NTFS Volume")
        containerStatus = .ready
        replyHandler(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func didFinishLoading() {
        logger.debug("extension finished loading")
    }
}
