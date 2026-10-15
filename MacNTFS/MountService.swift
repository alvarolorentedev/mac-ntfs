import DiskArbitration
import Foundation

enum MountServiceError: LocalizedError {
    case invalidDevice(String)
    case deviceNotFound(String)
    case operationFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidDevice(let name): return "Refusing to operate on unexpected device name '\(name)'"
        case .deviceNotFound(let name): return "Disk Arbitration does not know device '\(name)'"
        case .operationFailed(let message): return message
        case .timedOut: return "The operation timed out"
        }
    }
}

/// Mounts, unmounts and ejects volumes through Disk Arbitration. Falls back to
/// the mount(8) path with a user-owned mount point only if Disk Arbitration
/// refuses, and never interpolates device names into shell strings.
final class MountService {
    private let session: DASession

    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        self.session = session
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    static func isValidDevice(_ value: String) -> Bool {
        value.range(of: "^disk[0-9]+(s[0-9]+)?$", options: .regularExpression) != nil
    }

    func mount(bsdName: String, readWrite: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        guard Self.isValidDevice(bsdName) else {
            completion(.failure(MountServiceError.invalidDevice(bsdName)))
            return
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            completion(.failure(MountServiceError.deviceNotFound(bsdName)))
            return
        }
        // Read-only is requested explicitly; read/write is the platform default
        // and is still subject to the module's dirty/hibernation safety gate.
        let box = OperationBox { [weak self] dissenter in
            if let dissenter {
                if let fallback = self?.fallbackMount(bsdName: bsdName, readWrite: readWrite) {
                    completion(.success(fallback))
                } else {
                    completion(.failure(MountServiceError.operationFailed(OperationBox.message(for: dissenter))))
                }
            } else {
                completion(.success(self?.currentMountPoint(bsdName: bsdName) ?? ""))
            }
        }
        let callback: DADiskMountCallback = { _, dissenter, context in
            guard let context else { return }
            Unmanaged<OperationBox>.fromOpaque(context).takeRetainedValue().fire(dissenter: dissenter)
        }
        let context = Unmanaged.passRetained(box).toOpaque()

        if readWrite {
            DADiskMountWithArguments(disk, nil, 0, callback, context, nil)
        } else {
            let optionStrings: [CFString] = ["rdonly" as CFString]
            var argumentRefs: [Unmanaged<CFString>?] = optionStrings.map { Unmanaged.passUnretained($0) as Unmanaged<CFString>? }
            argumentRefs.append(nil)
            withExtendedLifetime(optionStrings) {
                DADiskMountWithArguments(disk, nil, 0, callback, context, &argumentRefs)
            }
        }
    }

    func unmount(bsdName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Self.isValidDevice(bsdName) else {
            completion(.failure(MountServiceError.invalidDevice(bsdName)))
            return
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            completion(.failure(MountServiceError.deviceNotFound(bsdName)))
            return
        }
        let box = OperationBox { dissenter in
            if let dissenter {
                if DADissenterGetStatus(dissenter) == kDAReturnNotMounted {
                    completion(.success(()))
                } else {
                    completion(.failure(MountServiceError.operationFailed(OperationBox.message(for: dissenter))))
                }
            } else {
                completion(.success(()))
            }
        }
        DADiskUnmount(disk, 0, { _, dissenter, context in
            guard let context else { return }
            Unmanaged<OperationBox>.fromOpaque(context).takeRetainedValue().fire(dissenter: dissenter)
        }, Unmanaged.passRetained(box).toOpaque())
    }

    func eject(bsdName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Self.isValidDevice(bsdName) else {
            completion(.failure(MountServiceError.invalidDevice(bsdName)))
            return
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            completion(.failure(MountServiceError.deviceNotFound(bsdName)))
            return
        }
        let box = OperationBox { dissenter in
            if let dissenter {
                completion(.failure(MountServiceError.operationFailed(OperationBox.message(for: dissenter))))
            } else {
                completion(.success(()))
            }
        }
        DADiskEject(disk, 0, { _, dissenter, context in
            guard let context else { return }
            Unmanaged<OperationBox>.fromOpaque(context).takeRetainedValue().fire(dissenter: dissenter)
        }, Unmanaged.passRetained(box).toOpaque())
    }

    func currentMountPoint(bsdName: String) -> String? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let rawDescription = DADiskCopyDescription(disk) else {
            return nil
        }
        let description = rawDescription as NSDictionary as? [String: Any] ?? [:]
        if let url = description[kDADiskDescriptionVolumePathKey as String] as? URL {
            return url.path
        }
        return nil
    }

    private func currentVolumeName(bsdName: String) -> String {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let rawDescription = DADiskCopyDescription(disk) else {
            return bsdName
        }
        let description = rawDescription as NSDictionary as? [String: Any] ?? [:]
        return (description[kDADiskDescriptionVolumeNameKey as String] as? String) ?? bsdName
    }

    /// fallback mount(8) into a user-owned mount point, used only when Disk
    /// Arbitration itself refuses (for example on hosts where the FSKit mount
    /// helper is unavailable).
    private func fallbackMount(bsdName: String, readWrite: Bool) -> String? {
        guard let home = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        var safeName = currentVolumeName(bsdName: bsdName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if safeName.isEmpty {
            safeName = bsdName
        }
        let base = home.appendingPathComponent("MacNTFS/Volumes", isDirectory: true)
        var mountPoint = base.appendingPathComponent(safeName, isDirectory: true)
        if FileManager.default.fileExists(atPath: mountPoint.path) {
            // Same label on another disk (or a leftover directory): keep the
            // two mounts apart.
            mountPoint = base.appendingPathComponent("\(safeName)-\(bsdName)", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        var arguments = ["-F", "-t", "macntfs"]
        if !readWrite {
            arguments += ["-o", "rdonly"]
        }
        arguments += ["/dev/\(bsdName)", mountPoint.path]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? mountPoint.path : nil
        } catch {
            return nil
        }
    }
}

/// Keeps the completion alive until Disk Arbitration calls back, and converts
/// a dissenter into a readable message.
private final class OperationBox {
    private let completion: (DADissenter?) -> Void
    init(completion: @escaping (DADissenter?) -> Void) {
        self.completion = completion
    }

    func fire(dissenter: DADissenter?) {
        completion(dissenter)
    }

    static func message(for dissenter: DADissenter) -> String {
        if let raw = DADissenterGetStatusString(dissenter) {
            return raw as String
        }
        return "Disk Arbitration returned status \(DADissenterGetStatus(dissenter))"
    }
}
