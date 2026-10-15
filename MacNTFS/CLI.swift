import Foundation

/// Command-line entry points. They exist so the app's exact mounting code can
/// be exercised by scripts and CI without a GUI, and they are what
/// scripts/m4-mount-test.sh drives.
enum CLI {
    /// Handles CLI invocations; returns normally when the process should start
    /// the regular menu bar app.
    static func handle(arguments: [String]) {
        if arguments.contains("--enable-extension") {
            switch ModuleEnabler.enable() {
            case .enabled:
                print("MacNTFS: extension enabled")
                exit(0)
            case .notRegistered:
                print("MacNTFS: extension is not registered; run the app once first")
                exit(1)
            case .failed(let message):
                fputs("MacNTFS: \(message)\n", stderr)
                exit(1)
            }
        }

        if arguments.contains("--extension-status") {
            switch ModuleEnabler.isEnabled() {
            case .enabled:
                print("enabled")
                exit(0)
            case .disabled:
                print("disabled")
                exit(1)
            case .notRegistered:
                print("not-registered")
                exit(2)
            case nil:
                print("unknown")
                exit(3)
            }
        }

        if arguments.contains("--list-volumes") {
            guard let monitor = DiskArbitrationMonitor() else {
                fputs("error: Disk Arbitration unavailable\n", stderr)
                exit(1)
            }
            monitor.start()
            for volume in monitor.volumes {
                let mount = volume.mountPoint ?? "-"
                let mode = volume.isMounted ? (volume.isWritable ? "rw" : "ro") : "-"
                print("\(volume.bsdName)\t\(volume.name)\t\(volume.sizeBytes)\t\(mount)\t\(mode)")
            }
            exit(0)
        }

        if let index = arguments.firstIndex(of: "--mount") {
            let device = value(after: index, in: arguments) ?? ""
            let readWrite = arguments.contains("--rw")
            runMountOperation(device: device, readWrite: readWrite)
        }

        if let index = arguments.firstIndex(of: "--unmount") {
            let device = value(after: index, in: arguments) ?? ""
            runSimpleOperation(device: device) { service, bsd, completion in
                service.unmount(bsdName: bsd, completion: completion)
            }
        }

        if let index = arguments.firstIndex(of: "--eject") {
            let device = value(after: index, in: arguments) ?? ""
            runSimpleOperation(device: device) { service, bsd, completion in
                service.eject(bsdName: bsd, completion: completion)
            }
        }

        if arguments.contains("--diagnostics") {
            guard let monitor = DiskArbitrationMonitor() else {
                fputs("error: Disk Arbitration unavailable\n", stderr)
                exit(1)
            }
            monitor.start()
            let state: String
            switch ModuleEnabler.isEnabled() {
            case .enabled: state = "Enabled"
            case .disabled: state = "Disabled"
            case .notRegistered: state = "Not registered"
            case nil: state = "Unknown"
            }
            let text = Diagnostics.collect(volumes: monitor.volumes, extensionState: state)
            if let index = arguments.firstIndex(of: "--diagnostics"),
               let path = value(after: index, in: arguments) {
                do {
                    try text.write(toFile: path, atomically: true, encoding: .utf8)
                    print(path)
                    exit(0)
                } catch {
                    fputs("error: cannot write \(path): \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if let url = Diagnostics.write(volumes: monitor.volumes, extensionState: state) {
                print(url.path)
                exit(0)
            }
            fputs("error: could not write diagnostics\n", stderr)
            exit(1)
        }
    }

    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("--") else {
            return nil
        }
        return arguments[next]
    }

    private static func pumpRunLoop(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    private static func runMountOperation(device: String, readWrite: Bool) -> Never {
        guard MountService.isValidDevice(device) else {
            fputs("error: invalid device '\(device)'\n", stderr)
            exit(2)
        }
        guard let service = MountService() else {
            fputs("error: Disk Arbitration unavailable\n", stderr)
            exit(1)
        }
        var done = false
        var outcome: Result<String, Error>?
        service.mount(bsdName: device, readWrite: readWrite) { result in
            outcome = result
            done = true
        }
        _ = pumpRunLoop(until: { done }, timeout: 30)
        guard let outcome else {
            fputs("error: mount timed out\n", stderr)
            exit(1)
        }
        switch outcome {
        case .success(let mountPoint):
            let final = mountPoint.isEmpty ? (service.currentMountPoint(bsdName: device) ?? "") : mountPoint
            print(final)
            exit(0)
        case .failure(let error):
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSimpleOperation(device: String,
                                           _ operation: @escaping (MountService, String, @escaping (Result<Void, Error>) -> Void) -> Void) -> Never {
        guard MountService.isValidDevice(device) else {
            fputs("error: invalid device '\(device)'\n", stderr)
            exit(2)
        }
        guard let service = MountService() else {
            fputs("error: Disk Arbitration unavailable\n", stderr)
            exit(1)
        }
        var done = false
        var outcome: Result<Void, Error>?
        operation(service, device) { result in
            outcome = result
            done = true
        }
        _ = pumpRunLoop(until: { done }, timeout: 30)
        guard let outcome else {
            fputs("error: operation timed out\n", stderr)
            exit(1)
        }
        switch outcome {
        case .success:
            exit(0)
        case .failure(let error):
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
