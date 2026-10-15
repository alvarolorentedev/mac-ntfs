import Foundation
import FSKit

/// Opaque per-vnode object. Holds the NTFS MFT record number plus the cached
/// path used by the path-based bridge operations (create/unlink/rename).
final class NTFSItem: FSItem {
    let inode: UInt64
    var parentInode: UInt64
    var name: FSFileName
    var path: String
    var attributes = FSItem.Attributes()

    init(inode: UInt64, parentInode: UInt64, name: FSFileName, path: String) {
        self.inode = inode
        self.parentInode = parentInode
        self.name = name
        self.path = path
    }
}
