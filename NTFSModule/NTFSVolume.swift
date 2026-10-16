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
    var entries: [(name: String, type: ntfs_bridge_entry_type, inode: UInt64, cookie: UInt64)] = []
    let limit: Int
    init(limit: Int) {
        self.limit = limit
    }
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
    box.entries.append((name, copy.type, copy.file_id, copy.cookie))
    return box.entries.count < box.limit
}

/// The NTFS volume as seen by FSKit. Owns the bridge and the device shim; all
/// bridge calls run serialized on `queue` because libntfs-3g is not
/// thread-safe per volume and the extension may receive concurrent FSKit
/// callbacks.
///
/// FSKit revised its volume protocols in macOS 27: `FSVolume.Operations` and
/// `FSVolume.ReadWriteOperations` (introduced in 15.4) were replaced by the
/// async `FSVolume.Handler` and `FSVolume.ReadWriteHandler`. This base holds
/// everything version-independent; `NTFSVolumeV1` and `NTFSVolumeV3` are the
/// thin adapters, and the file system picks one per OS version.
class NTFSVolumeBase: FSVolume {
    /// Maximum entries collected from the bridge per enumeration call; larger
    /// batches trade memory for fewer round trips with FSKit.
    static let enumerationBatchSize = 256
    /// Resume token that means "the enumeration is finished".
    static let endCookie = UInt64.max

    private var bridge: OpaquePointer?
    private let shim: NTFSDeviceShim
    private let queue = DispatchQueue(label: "com.github.alvarolorentedev.macntfs.bridge")
    private var items: [UInt64: NTFSItem] = [:]
    var cachedRoot: NTFSItem?
    let logger = Logger(subsystem: "com.github.alvarolorentedev.macntfs.ntfsmodule", category: "volume")

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

    deinit {
        // Last-resort flush and release: FSKit normally deactivates first, but
        // an unload without deactivation must not leak the open volume.
        closeBridge()
    }

    var bridgeReadOnly: Bool {
        queue.sync { bridge.map { ntfs_bridge_is_read_only($0) } ?? true }
    }

    var hasOpenBridge: Bool {
        queue.sync { bridge != nil }
    }

    func withBridge<T>(_ body: (OpaquePointer) -> T) throws -> T {
        try queue.sync {
            guard let bridge else {
                throw POSIXError(.EIO)
            }
            return body(bridge)
        }
    }

    func cachedItem(inode: UInt64, parentInode: UInt64, name: FSFileName, path: String) -> NTFSItem {
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

    func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    func removeCachedItem(inode: UInt64) {
        queue.sync { _ = items.removeValue(forKey: inode) }
    }

    func makeTimespec(_ ns: Int64) -> timespec {
        timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    }

    func nanoseconds(_ value: timespec) -> Int64 {
        Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }

    func result<T>(_ value: T?) throws -> T {
        guard let value else {
            throw POSIXError(.EINVAL)
        }
        return value
    }

    func fill(_ target: FSItem.Attributes, from raw: ntfs_bridge_attrs) {
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
    func refreshAttributes(of item: NTFSItem) -> FSItem.Attributes {
        var raw = ntfs_bridge_attrs()
        if let status = try? withBridge({ ntfs_bridge_getattr_inode($0, item.inode, &raw) }),
           status == NTFS_BRIDGE_OK {
            fill(item.attributes, from: raw)
        }
        return item.attributes
    }

    func closeBridge() {
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

extension NTFSVolumeBase: FSVolume.CommonOperations {
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

    func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        logger.notice("mounted \(self.bridgeReadOnly ? "read-only" : "read-write", privacy: .public)")
        replyHandler(nil)
    }

    func unmount(replyHandler: @escaping () -> Void) {
        if let status = try? withBridge({ ntfs_bridge_sync($0) }), status != NTFS_BRIDGE_OK {
            logger.error("sync during unmount failed: \(String(cString: ntfs_bridge_strerror(status)), privacy: .public)")
        }
        replyHandler()
    }

    func synchronize(flags: FSSyncFlags, replyHandler: @escaping ((any Error)?) -> Void) {
        do {
            let status = try withBridge { ntfs_bridge_sync($0) }
            if status != NTFS_BRIDGE_OK {
                replyHandler(ntfsStatusError(status))
                return
            }
            replyHandler(nil)
        } catch {
            replyHandler(error)
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
        guard let item = item as? NTFSItem, item.inode != UInt64(NTFS_BRIDGE_ROOT_INODE) else {
            replyHandler(nil)
            return
        }
        removeCachedItem(inode: item.inode)
        replyHandler(nil)
    }
}

extension NTFSVolumeBase: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

// MARK: - macOS 27 adapter

@available(macOS 27.0, *)
final class NTFSVolumeV3: NTFSVolumeBase {}

@available(macOS 27.0, *)
extension NTFSVolumeV3: FSVolume.Handler {
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
            removeCachedItem(inode: overItem.inode)
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
        guard let item = item as? NTFSItem,
              let directory = directory as? NTFSItem,
              let nameString = name.string else {
            throw POSIXError(.EINVAL)
        }
        if bridgeReadOnly {
            throw POSIXError(.EROFS)
        }
        let removedAttributes = item.attributes
        // Build the path from the live parent: `item.path` goes stale when an
        // ancestor directory was renamed since the item was last looked up.
        let status = try withBridge { ntfs_bridge_unlink($0, childPath(directory.path, nameString)) }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }
        removeCachedItem(inode: item.inode)
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
        let setsSize = newAttributes.isValid(.size) && item.attributes.type != .directory
        let setsAccessTime = newAttributes.isValid(.accessTime)
        let setsModifyTime = newAttributes.isValid(.modifyTime)
        if (setsSize || setsAccessTime || setsModifyTime) && bridgeReadOnly {
            throw POSIXError(.EROFS)
        }
        if setsSize {
            let status = try withBridge { ntfs_bridge_truncate_inode($0, item.inode, newAttributes.size) }
            guard status == NTFS_BRIDGE_OK else {
                throw ntfsStatusError(status)
            }
            newAttributes.consumedAttributes.insert(.size)
        }
        if setsAccessTime || setsModifyTime {
            // Ignoring these would make touch(1) and cp -p report success while
            // nothing changed.
            let accessNs = setsAccessTime ? nanoseconds(newAttributes.accessTime) : 0
            let modifyNs = setsModifyTime ? nanoseconds(newAttributes.modifyTime) : 0
            let status = try withBridge {
                ntfs_bridge_set_times_inode($0, item.inode,
                                            setsAccessTime, accessNs,
                                            setsModifyTime, modifyNs)
            }
            guard status == NTFS_BRIDGE_OK else {
                throw ntfsStatusError(status)
            }
            if setsAccessTime { newAttributes.consumedAttributes.insert(.accessTime) }
            if setsModifyTime { newAttributes.consumedAttributes.insert(.modifyTime) }
        }
        return try result(FSSetAttributesResult(attributes: refreshAttributes(of: item), freeSpace: nil))
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            context: FSContext) async throws -> FSEnumerateDirectoryResult {
        return try result(FSEnumerateDirectoryResult(verifier: enumerate(directory, startingAt: cookie, attributes: attributes, packer: packer).rawValue))
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext) async throws -> FSReadSymlinkResult {
        throw POSIXError(.ENOTSUP)
    }
}

@available(macOS 27.0, *)
extension NTFSVolumeV3: FSVolume.ReadWriteHandler {
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

// MARK: - macOS 15.4–26 adapter

final class NTFSVolumeV1: NTFSVolumeBase {}

// The V1 volume protocols are deprecated in macOS 27 in favor of FSVolume.Handler;
// they remain the only API on 15.4–26, which is why this adapter exists.
@available(macOS, deprecated: 27.0)
extension NTFSVolumeV1: FSVolume.Operations {
    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, (any Error)?) -> Void) {
        let root = cachedItem(inode: UInt64(NTFS_BRIDGE_ROOT_INODE),
                              parentInode: UInt64(NTFS_BRIDGE_ROOT_INODE),
                              name: FSFileName(string: "/"),
                              path: "/")
        refreshAttributes(of: root)
        cachedRoot = root
        replyHandler(root, nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        closeBridge()
        replyHandler(nil)
    }

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? NTFSItem, let nameString = name.string else {
            replyHandler(nil, nil, POSIXError(.EINVAL))
            return
        }
        do {
            var inode: UInt64 = 0
            var raw = ntfs_bridge_attrs()
            let status = try withBridge { ntfs_bridge_lookup($0, directory.inode, nameString, &inode, &raw) }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(nil, nil, ntfsStatusError(status))
                return
            }
            let path = childPath(directory.path, nameString)
            let item = cachedItem(inode: inode, parentInode: directory.inode, name: name, path: path)
            fill(item.attributes, from: raw)
            replyHandler(item, name, nil)
        } catch {
            replyHandler(nil, nil, error)
        }
    }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest,
                    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? NTFSItem, let nameString = name.string else {
            replyHandler(nil, nil, POSIXError(.EINVAL))
            return
        }
        guard type == .file || type == .directory else {
            replyHandler(nil, nil, POSIXError(.ENOTSUP))
            return
        }
        if bridgeReadOnly {
            replyHandler(nil, nil, POSIXError(.EROFS))
            return
        }
        do {
            let path = childPath(directory.path, nameString)
            let status = try withBridge { ntfs_bridge_create($0, path, type == .directory) }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(nil, nil, ntfsStatusError(status))
                return
            }
            var inode: UInt64 = 0
            var raw = ntfs_bridge_attrs()
            let lookupStatus = try withBridge { ntfs_bridge_lookup($0, directory.inode, nameString, &inode, &raw) }
            guard lookupStatus == NTFS_BRIDGE_OK else {
                replyHandler(nil, nil, ntfsStatusError(lookupStatus))
                return
            }
            let item = cachedItem(inode: inode, parentInode: directory.inode, name: name, path: path)
            fill(item.attributes, from: raw)
            replyHandler(item, name, nil)
        } catch {
            replyHandler(nil, nil, error)
        }
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, POSIXError(.ENOTSUP))
    }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, POSIXError(.ENOTSUP))
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?,
                    replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem,
              let sourceDirectory = sourceDirectory as? NTFSItem,
              let destinationDirectory = destinationDirectory as? NTFSItem,
              let sourceString = sourceName.string,
              let destinationString = destinationName.string else {
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        if bridgeReadOnly {
            replyHandler(nil, POSIXError(.EROFS))
            return
        }
        do {
            let from = childPath(sourceDirectory.path, sourceString)
            let to = childPath(destinationDirectory.path, destinationString)
            let status = try withBridge { ntfs_bridge_rename($0, from, to) }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(nil, ntfsStatusError(status))
                return
            }
            if let overItem = overItem as? NTFSItem {
                removeCachedItem(inode: overItem.inode)
            }
            item.name = destinationName
            item.path = to
            item.parentInode = destinationDirectory.inode
            refreshAttributes(of: item)
            replyHandler(destinationName, nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem,
                    replyHandler: @escaping ((any Error)?) -> Void) {
        guard let item = item as? NTFSItem,
              let directory = directory as? NTFSItem,
              let nameString = name.string else {
            replyHandler(POSIXError(.EINVAL))
            return
        }
        if bridgeReadOnly {
            replyHandler(POSIXError(.EROFS))
            return
        }
        do {
            // Build the path from the live parent: `item.path` goes stale when an
            // ancestor directory was renamed since the item was last looked up.
            let status = try withBridge { ntfs_bridge_unlink($0, childPath(directory.path, nameString)) }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(ntfsStatusError(status))
                return
            }
            removeCachedItem(inode: item.inode)
            replyHandler(nil)
        } catch {
            replyHandler(error)
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                       of item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        replyHandler(refreshAttributes(of: item), nil)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            replyHandler(nil, POSIXError(.EINVAL))
            return
        }
        let setsSize = newAttributes.isValid(.size) && item.attributes.type != .directory
        let setsAccessTime = newAttributes.isValid(.accessTime)
        let setsModifyTime = newAttributes.isValid(.modifyTime)
        if (setsSize || setsAccessTime || setsModifyTime) && bridgeReadOnly {
            replyHandler(nil, POSIXError(.EROFS))
            return
        }
        do {
            if setsSize {
                let status = try withBridge { ntfs_bridge_truncate_inode($0, item.inode, newAttributes.size) }
                guard status == NTFS_BRIDGE_OK else {
                    replyHandler(nil, ntfsStatusError(status))
                    return
                }
                newAttributes.consumedAttributes.insert(.size)
            }
            if setsAccessTime || setsModifyTime {
                // Ignoring these would make touch(1) and cp -p report success while
                // nothing changed.
                let accessNs = setsAccessTime ? nanoseconds(newAttributes.accessTime) : 0
                let modifyNs = setsModifyTime ? nanoseconds(newAttributes.modifyTime) : 0
                let status = try withBridge {
                    ntfs_bridge_set_times_inode($0, item.inode,
                                                setsAccessTime, accessNs,
                                                setsModifyTime, modifyNs)
                }
                guard status == NTFS_BRIDGE_OK else {
                    replyHandler(nil, ntfsStatusError(status))
                    return
                }
                if setsAccessTime { newAttributes.consumedAttributes.insert(.accessTime) }
                if setsModifyTime { newAttributes.consumedAttributes.insert(.modifyTime) }
            }
            replyHandler(refreshAttributes(of: item), nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        do {
            let verifier = try enumerate(directory, startingAt: cookie, attributes: attributes, packer: packer)
            replyHandler(verifier, nil)
        } catch {
            replyHandler(FSDirectoryVerifier(rawValue: 1), error)
        }
    }

    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, POSIXError(.ENOTSUP))
    }
}

@available(macOS, deprecated: 27.0)
extension NTFSVolumeV1: FSVolume.ReadWriteOperations {
    func read(from item: FSItem,
              at offset: off_t,
              length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            replyHandler(0, POSIXError(.EINVAL))
            return
        }
        do {
            var actuallyRead = 0
            let status = try withBridge { bridge -> ntfs_bridge_status in
                buffer.withUnsafeMutableBytes { raw in
                    ntfs_bridge_read_inode(bridge, item.inode, UInt64(offset), raw.baseAddress, length, &actuallyRead)
                }
            }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(0, ntfsStatusError(status))
                return
            }
            replyHandler(actuallyRead, nil)
        } catch {
            replyHandler(0, error)
        }
    }

    func write(contents: Data,
               to item: FSItem,
               at offset: off_t,
               replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            replyHandler(0, POSIXError(.EINVAL))
            return
        }
        if bridgeReadOnly {
            logger.notice("write refused: volume is read-only")
            replyHandler(0, POSIXError(.EROFS))
            return
        }
        do {
            var actuallyWritten = 0
            let status = try withBridge { bridge -> ntfs_bridge_status in
                contents.withUnsafeBytes { raw in
                    ntfs_bridge_write_inode(bridge, item.inode, UInt64(offset), raw.baseAddress, contents.count, &actuallyWritten)
                }
            }
            guard status == NTFS_BRIDGE_OK else {
                replyHandler(0, ntfsStatusError(status))
                return
            }
            replyHandler(actuallyWritten, nil)
        } catch {
            replyHandler(0, error)
        }
    }
}

// MARK: - Shared enumeration

extension NTFSVolumeBase {
    /// Collects one batch of directory entries and packs them for FSKit,
    /// returning the resume verifier. Shared by both API generations because
    /// the packer type and the cookie/verifier semantics are identical.
    func enumerate(_ directory: FSItem,
                   startingAt cookie: FSDirectoryCookie,
                   attributes: FSItem.GetAttributesRequest?,
                   packer: FSDirectoryEntryPacker) throws -> FSDirectoryVerifier {
        guard let directory = directory as? NTFSItem else {
            throw POSIXError(.EINVAL)
        }
        if cookie.rawValue == Self.endCookie {
            return FSDirectoryVerifier(rawValue: 1)
        }

        // FSKit asks the volume for "." and ".." when it doesn't need
        // attributes; the resume tokens 0 and 1 belong to them. The bridge
        // itself filters the library's own "." and ".." entries, so a resume
        // token is passed to it unchanged.
        var synthetic: [(name: String, inode: UInt64, resumeToken: UInt64)] = []
        if attributes == nil {
            if cookie.rawValue == 0 {
                synthetic = [(".", directory.inode, 0), ("..", directory.parentInode, 1)]
            } else if cookie.rawValue == 1 {
                synthetic = [("..", directory.parentInode, 1)]
            }
        }

        let box = DirectoryEmitBox(limit: Self.enumerationBatchSize + 1)
        let status = try withBridge { bridge -> ntfs_bridge_status in
            withExtendedLifetime(box) {
                ntfs_bridge_readdir_inode(bridge, directory.inode, cookie.rawValue,
                                          directoryEmitCallback,
                                          Unmanaged.passUnretained(box).toOpaque())
            }
        }
        guard status == NTFS_BRIDGE_OK else {
            throw ntfsStatusError(status)
        }

        // The last entry of a full batch stays unpacked: its token is the
        // resume point for the next call. The bridge re-emits the entry at
        // the token it is given, so every packed entry carries the token of
        // its successor and nothing is skipped or repeated.
        let entries = box.entries
        let batchIsFull = entries.count > Self.enumerationBatchSize
        let packable = entries.prefix(batchIsFull ? entries.count - 1 : entries.count)
        let pendingToken = batchIsFull ? entries[entries.count - 1].cookie : Self.endCookie

        var sequence: [(name: String, type: ntfs_bridge_entry_type, inode: UInt64, resumeToken: UInt64)] = []
        for item in synthetic {
            sequence.append((item.name, NTFS_BRIDGE_TYPE_DIRECTORY, item.inode, item.resumeToken))
        }
        for entry in packable {
            sequence.append((entry.name, entry.type, entry.inode, entry.cookie))
        }
        guard !sequence.isEmpty else {
            return FSDirectoryVerifier(rawValue: 1)
        }

        var itemAttributes = [FSItem.Attributes?](repeating: nil, count: sequence.count)
        if attributes != nil, !packable.isEmpty {
            // One serialized pass fetches the attributes for the batch.
            itemAttributes = try withBridge { bridge in
                packable.map { entry in
                    var raw = ntfs_bridge_attrs()
                    guard ntfs_bridge_getattr_inode(bridge, entry.inode, &raw) == NTFS_BRIDGE_OK else {
                        return nil
                    }
                    let filled = FSItem.Attributes()
                    fill(filled, from: raw)
                    return filled
                }
            }
        }

        var index = 0
        while index < sequence.count {
            let item = sequence[index]
            let nextCookie = index + 1 < sequence.count ? sequence[index + 1].resumeToken : pendingToken
            let packed = packer.packEntry(name: FSFileName(string: item.name),
                                          itemType: item.type == NTFS_BRIDGE_TYPE_DIRECTORY ? .directory : .file,
                                          itemID: FSItem.Identifier(rawValue: item.inode) ?? .invalid,
                                          nextCookie: FSDirectoryCookie(nextCookie),
                                          attributes: itemAttributes[index])
            if !packed {
                break
            }
            index += 1
        }
        return FSDirectoryVerifier(rawValue: 1)
    }
}
