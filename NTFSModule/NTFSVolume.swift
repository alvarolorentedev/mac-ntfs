import Foundation
import FSKit
import os

/// Serializes access to a libntfs-3g bridge and reports errors as POSIX errors.
func ntfsStatusError(_ status: ntfs_bridge_status, readOnly: Bool = false) -> NSError {
    func posix(_ code: POSIXError.Code) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
    }
    if readOnly {
        return posix(.EROFS)
    }
    switch status {
    case NTFS_BRIDGE_ERR_NOT_FOUND: return posix(.ENOENT)
    case NTFS_BRIDGE_ERR_EXISTS: return posix(.EEXIST)
    case NTFS_BRIDGE_ERR_PERM: return posix(.EROFS)
    case NTFS_BRIDGE_ERR_INVAL: return posix(.EINVAL)
    case NTFS_BRIDGE_ERR_NOT_SUPPORTED: return posix(.ENOTSUP)
    case NTFS_BRIDGE_ERR_NOT_DIRECTORY: return posix(.ENOTDIR)
    case NTFS_BRIDGE_ERR_IS_DIRECTORY: return posix(.EISDIR)
    case NTFS_BRIDGE_ERR_NOT_EMPTY: return posix(.ENOTEMPTY)
    case NTFS_BRIDGE_ERR_NO_SPACE: return posix(.ENOSPC)
    default: return posix(.EIO)
    }
}

private final class DirectoryEmitBox {
    var entries: [(name: String, type: ntfs_bridge_entry_type, inode: UInt64)] = []
}

private let directoryEmitCallback: ntfs_bridge_dir_emit = { context, entry in
    guard let context, let entry else {
        return false
    }
    let box = Unmanaged<DirectoryEmitBox>.fromOpaque(context).takeUnretainedValue()
    var copy = entry.pointee
    let name = withUnsafePointer(to: &copy.name) { pointer in
        String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }
    box.entries.append((name, copy.type, copy.file_id))
    return true
}

/// The NTFS volume as seen by FSKit. Owns the bridge and the device shim; all
/// bridge calls run serialized on `queue` because libntfs-3g is not
/// thread-safe per volume and the extension may receive concurrent FSKit
/// callbacks.
final class NTFSVolume: FSVolume {
    private var bridge: OpaquePointer?
    private let shim: NTFSDeviceShim
    private let queue = DispatchQueue(label: "com.github.alvarolorentedev.macntfs.bridge")
    private var items: [UInt64: NTFSItem] = [:]
    private var cachedRoot: NTFSItem?
    private let logger = Logger(subsystem: "com.github.alvarolorentedev.macntfs.ntfsmodule", category: "volume")

    init(bridge: OpaquePointer, shim: NTFSDeviceShim, readOnly: Bool, volumeName: String) {
        self.bridge = bridge
        self.shim = shim
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: volumeName))
        if readOnly {
            logger.notice("volume opened read-only")
        } else {
            logger.notice("volume opened read-write")
        }
    }

    private var bridgeReadOnly: Bool {
        queue.sync { bridge.map { ntfs_bridge_is_read_only($0) } ?? true }
    }

    private func withBridge<T>(_ body: (OpaquePointer) -> T) throws -> T {
        try queue.sync {
            guard let bridge else {
                throw POSIXError(.EIO)
            }
            return body(bridge)
        }
    }

    private func cachedItem(inode: UInt64, parentInode: UInt64, name: FSFileName, path: String) -> NTFSItem {
        queue.sync {
            if let existing = items[inode] {
                existing.parentInode = parentInode
                existing.name = name
                existing.path = path
                return existing
            }
            let item = NTFSItem(inode: inode, parentInode: parentInode, name: name, path: path)
            items[inode] = item
            return item
        }
    }

    private func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private func makeTimespec(_ ns: Int64) -> timespec {
        timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    }

    private func result<T>(_ value: T?) throws -> T {
        guard let value else {
            throw POSIXError(.EINVAL)
        }
        return value
    }

    private func fill(_ target: FSItem.Attributes, from raw: ntfs_bridge_attrs) {
        target.fileID = FSItem.Identifier(rawValue: raw.file_id) ?? .invalid
        target.type = raw.is_directory ? .directory : .file
        target.size = raw.size
        target.allocSize = raw.allocated_size
        target.linkCount = raw.link_count
        target.mode = raw.mode
        target.uid = 0
        target.gid = 0
        target.flags = 0
        target.accessTime = makeTimespec(raw.access_time_ns)
        target.modifyTime = makeTimespec(raw.modify_time_ns)
        target.changeTime = makeTimespec(raw.change_time_ns)
        target.birthTime = makeTimespec(raw.birth_time_ns)
        target.addedTime = makeTimespec(raw.birth_time_ns)
    }

    @discardableResult
    private func refreshAttributes(of item: NTFSItem) -> FSItem.Attributes {
        var raw = ntfs_bridge_attrs()
        if let status = try? withBridge({ ntfs_bridge_getattr_inode($0, item.inode, &raw) }),
           status == NTFS_BRIDGE_OK {
            fill(item.attributes, from: raw)
        }
        return item.attributes
    }

    fileprivate func closeBridge() {
        queue.sync {
            if let bridge {
                let status = ntfs_bridge_close(bridge)
                if status != NTFS_BRIDGE_OK {
                    logger.error("closing the volume failed: \(String(cString: ntfs_bridge_strerror(status)), privacy: .public)")
                }
                self.bridge = nil
            }
            items.removeAll()
            cachedRoot = nil
        }
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

extension NTFSVolume: FSVolume.Handler {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = false
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "NTFS")
        var stats = ntfs_bridge_volume_stats()
        if let status = try? withBridge({ ntfs_bridge_statfs($0, &stats) }), status == NTFS_BRIDGE_OK {
            result.blockSize = Int(stats.cluster_size)
            result.ioSize = Int(stats.cluster_size)
            result.totalBlocks = stats.total_clusters
            result.availableBlocks = stats.free_clusters
            result.freeBlocks = stats.free_clusters
        }
        result.totalFiles = 0
        result.freeFiles = 0
        return result
    }

    func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        let root = cachedItem(inode: UInt64(NTFS_BRIDGE_ROOT_INODE),
                              parentInode: UInt64(NTFS_BRIDGE_ROOT_INODE),
                              name: FSFileName(string: "/"),
                              path: "/")
        refreshAttributes(of: root)
        cachedRoot = root
        return try result(FSActivateResult(rootItem: root))
    }

    func deactivateVolume(options: FSDeactivateOptions) async throws {
        closeBridge()
    }

    func mount(options: FSTaskOptions) async throws {
        logger.notice("mounted \(self.bridgeReadOnly ? "read-only" : "read-write", privacy: .public)")
    }

    func unmount() async {
        if let status = try? withBridge({ ntfs_bridge_sync($0) }), status != NTFS_BRIDGE_OK {
            logger.error("sync during unmount failed: \(String(cString: ntfs_bridge_strerror(status)), privacy: .public)")
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        let status = try withBridge { ntfs_bridge_sync($0) }
        if status != NTFS_BRIDGE_OK {
            throw ntfsStatusError(status)
        }
    }

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSLookupItemResult {
        guard let directory = directory as? NTFSItem, let nameString = name.string else {
            throw POSIXError(.EINVAL)
        }
        var inode: UInt64 = 0
        var raw = ntfs_bridge_attrs()
        let status = try withBridge { ntfs_bridge_lookup($0, directory.inode, nameString, &inode, &raw) }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        let path = childPath(directory.path, nameString)
        let item = cachedItem(inode: inode, parentInode: directory.inode, name: name, path: path)
        fill(item.attributes, from: raw)
        return try result(FSLookupItemResult(foundItem: item, itemName: name, itemAttributes: item.attributes))
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? NTFSItem, item.inode != UInt64(NTFS_BRIDGE_ROOT_INODE) else {
            return
        }
        queue.sync {
            items.removeValue(forKey: item.inode)
        }
    }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    in directory: FSItem,
                    attributes: FSItem.SetAttributesRequest,
                    context: FSContext) async throws -> FSCreateItemResult {
        guard let directory = directory as? NTFSItem, let nameString = name.string else {
            throw POSIXError(.EINVAL)
        }
        guard type == .file || type == .directory else {
            throw POSIXError(.ENOTSUP)
        }
        if bridgeReadOnly {
            throw POSIXError(.EROFS)
        }
        let path = childPath(directory.path, nameString)
        let status = try withBridge { ntfs_bridge_create($0, path, type == .directory) }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        var inode: UInt64 = 0
        var raw = ntfs_bridge_attrs()
        let lookupStatus = try withBridge { ntfs_bridge_lookup($0, directory.inode, nameString, &inode, &raw) }
        guard lookupStatus == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(lookupStatus)
        }
        let item = cachedItem(inode: inode, parentInode: directory.inode, name: name, path: path)
        fill(item.attributes, from: raw)
        return try result(FSCreateItemResult(newItem: item,
                                             newItemName: name,
                                             newItemAttributes: item.attributes,
                                             directoryAttributes: refreshAttributes(of: directory),
                                             freeSpace: nil))
    }

    func createSymbolicLink(named name: FSFileName,
                            in directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            context: FSContext) async throws -> FSCreateSymlinkResult {
        throw POSIXError(.ENOTSUP)
    }

    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSCreateLinkResult {
        throw POSIXError(.ENOTSUP)
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?,
                    context: FSContext) async throws -> FSRenameItemResult {
        guard let item = item as? NTFSItem,
              let sourceDirectory = sourceDirectory as? NTFSItem,
              let destinationDirectory = destinationDirectory as? NTFSItem,
              let sourceString = sourceName.string,
              let destinationString = destinationName.string else {
            throw POSIXError(.EINVAL)
        }
        if bridgeReadOnly {
            throw POSIXError(.EROFS)
        }
        let from = childPath(sourceDirectory.path, sourceString)
        let to = childPath(destinationDirectory.path, destinationString)
        let status = try withBridge { ntfs_bridge_rename($0, from, to) }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        let overAttributes = (overItem as? NTFSItem)?.attributes
        if let overItem = overItem as? NTFSItem {
            queue.sync {
                items.removeValue(forKey: overItem.inode)
            }
        }
        item.name = destinationName
        item.path = to
        item.parentInode = destinationDirectory.inode
        refreshAttributes(of: item)
        return try result(FSRenameItemResult(newName: destinationName,
                                             renamedItemAttributes: item.attributes,
                                             sourceDirectoryAttributes: refreshAttributes(of: sourceDirectory),
                                             destinationDirectoryAttributes: refreshAttributes(of: destinationDirectory),
                                             overItemAttributes: overAttributes,
                                             freeSpace: nil))
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    from directory: FSItem,
                    context: FSContext) async throws -> FSRemoveItemResult {
        guard let item = item as? NTFSItem, let directory = directory as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        if bridgeReadOnly {
            throw POSIXError(.EROFS)
        }
        let removedAttributes = item.attributes
        let status = try withBridge { ntfs_bridge_unlink($0, item.path) }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        queue.sync {
            items.removeValue(forKey: item.inode)
        }
        return try result(FSRemoveItemResult(itemAttributes: removedAttributes,
                                             directoryAttributes: refreshAttributes(of: directory),
                                             freeSpace: nil))
    }

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                    of item: FSItem,
                    context: FSContext) async throws -> FSGetAttributesResult {
        guard let item = item as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        return try result(FSGetAttributesResult(attributes: refreshAttributes(of: item)))
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem,
                       context: FSContext) async throws -> FSSetAttributesResult {
        guard let item = item as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        if newAttributes.isValid(.size), item.attributes.type != .directory {
            let status = try withBridge { ntfs_bridge_truncate_inode($0, item.inode, newAttributes.size) }
            guard status == NTFS_BRIDGE_OK else {
                throw ntfsStatusError(status)
            }
        }
        return try result(FSSetAttributesResult(attributes: refreshAttributes(of: item), freeSpace: nil))
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            context: FSContext) async throws -> FSEnumerateDirectoryResult {
        guard let directory = directory as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        let box = DirectoryEmitBox()
        let status = try withBridge { bridge -> ntfs_bridge_status in
            withExtendedLifetime(box) {
                ntfs_bridge_readdir_inode(bridge, directory.inode,
                                          directoryEmitCallback,
                                          Unmanaged.passUnretained(box).toOpaque())
            }
        }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        var entries = box.entries
        if attributes == nil {
            entries.insert((".", NTFS_BRIDGE_TYPE_DIRECTORY, directory.inode), at: 0)
            entries.insert(("..", NTFS_BRIDGE_TYPE_DIRECTORY, directory.parentInode), at: 0)
        }
        var index = Int(cookie.rawValue)
        while index < entries.count {
            let entry = entries[index]
            var itemAttributes: FSItem.Attributes?
            if attributes != nil {
                var raw = ntfs_bridge_attrs()
                if let getStatus = try? withBridge({ ntfs_bridge_getattr_inode($0, entry.inode, &raw) }),
                   getStatus == NTFS_BRIDGE_OK {
                    let filled = FSItem.Attributes()
                    fill(filled, from: raw)
                    itemAttributes = filled
                }
            }
            _ = packer.packEntry(name: FSFileName(string: entry.name),
                                 itemType: entry.type == NTFS_BRIDGE_TYPE_DIRECTORY ? .directory : .file,
                                 itemID: FSItem.Identifier(rawValue: entry.inode) ?? .invalid,
                                 nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                                 attributes: itemAttributes)
            index += 1
        }
        return try result(FSEnumerateDirectoryResult(verifier: 1))
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext) async throws -> FSReadSymlinkResult {
        throw POSIXError(.ENOTSUP)
    }
}

extension NTFSVolume: FSVolume.ReadWriteHandler {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> FSReadFileResult {
        guard let item = item as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        var actuallyRead = 0
        let status = try withBridge { bridge -> ntfs_bridge_status in
            buffer.withUnsafeMutableBytes { raw in
                ntfs_bridge_read_inode(bridge, item.inode, UInt64(offset), raw.baseAddress, length, &actuallyRead)
            }
        }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        return try result(FSReadFileResult(bytesRead: actuallyRead, itemAttributes: refreshAttributes(of: item)))
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> FSWriteFileResult {
        guard let item = item as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        if bridgeReadOnly {
            logger.notice("write refused: volume is read-only")
            throw POSIXError(.EROFS)
        }
        var actuallyWritten = 0
        let status = try withBridge { bridge -> ntfs_bridge_status in
            contents.withUnsafeBytes { raw in
                ntfs_bridge_write_inode(bridge, item.inode, UInt64(offset), raw.baseAddress, contents.count, &actuallyWritten)
            }
        }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        return try result(FSWriteFileResult(bytesWritten: actuallyWritten,
                                            itemAttributes: refreshAttributes(of: item),
                                            freeSpace: nil))
    }
}
