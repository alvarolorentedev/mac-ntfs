import Foundation
import FSKit

/// Opaque per-vnode object. FSKit hands one of these back to the volume for
/// every item it tracks. M1 only ever creates the root item; M3 attaches the
/// libntfs-3g node (MFT record number and in-memory state) to it.
final class NTFSItem: FSItem {
    let name: FSFileName
    var attributes = FSItem.Attributes()

    init(name: FSFileName) {
        self.name = name
    }
}
