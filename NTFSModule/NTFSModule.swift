import ExtensionFoundation
import FSKit

@main
struct NTFSModuleExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        NTFSFileSystem()
    }
}
