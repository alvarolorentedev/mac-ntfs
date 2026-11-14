import ExtensionFoundation
import FSKit

@main
struct MounteeFSKitExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        NTFSFileSystem()
    }
}
