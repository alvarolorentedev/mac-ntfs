import Foundation
import FSKit
import os

/// Unary FSKit file system: one block device resource in, one volume out.
///
/// M1 scope: prove the module loads and mounts a disposable NTFS image.
/// The volume is always read-only and empty; the libntfs-3g bridge replaces
/// read-only-stub behavior in M3, including dirty/hibernation safety gating.
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
            // M1 does not parse the volume label or serial yet; the docs allow
            // an empty name and a random container identifier for unary file
            // systems without a durable identifier. M3 replaces both with
            // values from libntfs-3g.
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
            // Formatting is not supported; a force-load cannot be satisfied.
            replyHandler(nil, POSIXError(.ENOTSUP))
            return
        }
        // Safety default: read-only until the user explicitly opts in, which
        // the bridge only permits once the volume passes dirty/hibernation
        // checks (M3).
        let volume = NTFSVolume(resource: blockResource, readOnly: true)
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
