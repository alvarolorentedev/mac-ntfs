import Foundation
import FSKit
import os

/// M1 volume: a single empty read-only root directory.
///
/// Every mutating operation reports `ENOTSUP` explicitly instead of pretending
/// to succeed. The libntfs-3g bridge (M3) replaces all of this with real
/// operations and safety gating.
final class NTFSVolume: FSVolume {
    private let resource: FSBlockDeviceResource
    let isReadOnly: Bool
    private let logger = Logger(subsystem: "com.github.alvarolorentedev.macntfs.ntfsmodule", category: "volume")

    private lazy var root: NTFSItem = {
        let item = NTFSItem(name: FSFileName(string: "/"))
        item.attributes.fileID = .rootDirectory
        item.attributes.parentID = .parentOfRoot
        item.attributes.uid = 0
        item.attributes.gid = 0
        item.attributes.linkCount = 1
        item.attributes.type = .directory
        item.attributes.mode = UInt32(S_IFDIR | 0o755)
        item.attributes.allocSize = 1
        item.attributes.size = 1

        var now = timespec()
        timespec_get(&now, TIME_UTC)
        item.attributes.accessTime = now
        item.attributes.changeTime = now
        item.attributes.modifyTime = now
        item.attributes.birthTime = now
        item.attributes.addedTime = now
        return item
    }()

    init(resource: FSBlockDeviceResource, readOnly: Bool) {
        self.resource = resource
        self.isReadOnly = readOnly
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: "NTFS Volume"))
    }
}

extension NTFSVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

extension NTFSVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        FSStatFSResult(fileSystemTypeName: "NTFS")
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        root
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
    }

    func mount(options: FSTaskOptions) async throws {
        logger.info("mounted (read-only, M1 proof of concept)")
    }

    func unmount() async {
        logger.info("unmounted; no state to flush in M1")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // No writable state in M1. Flush semantics arrive with the bridge (M3).
    }

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        guard let item = item as? NTFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return item.attributes
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
    }

    func reclaimItem(_ item: FSItem) async throws {
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        guard let directory = directory as? NTFSItem, directory === root else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        if attributes == nil {
            _ = packer.packEntry(name: FSFileName(string: "."),
                                 itemType: .directory,
                                 itemID: .rootDirectory,
                                 nextCookie: FSDirectoryCookie(1),
                                 attributes: nil)
            _ = packer.packEntry(name: FSFileName(string: ".."),
                                 itemType: .directory,
                                 itemID: .rootDirectory,
                                 nextCookie: FSDirectoryCookie(2),
                                 attributes: nil)
        }
        return FSDirectoryVerifier(1)
    }
}
