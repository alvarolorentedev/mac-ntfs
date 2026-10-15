import Foundation

/// App model shared by the menu bar UI and the CLI test hooks.
final class AppModel: ObservableObject {
    @Published private(set) var volumes: [NTFSVolumeInfo] = []
    @Published private(set) var extensionState = "Checking…"
    @Published private(set) var lastMessage: String?
    @Published private(set) var busyDevice: String?

    private let monitor: DiskArbitrationMonitor
    private let mountService: MountService
    private var started = false

    init() {
        guard let monitor = DiskArbitrationMonitor(), let mountService = MountService() else {
            fatalError("Disk Arbitration unavailable")
        }
        self.monitor = monitor
        self.mountService = mountService
        monitor.onChange = { [weak self] volumes in
            DispatchQueue.main.async {
                self?.volumes = volumes
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.start()
        refreshExtensionState()
    }

    func note(_ message: String) {
        lastMessage = message
    }

    func refresh() {
        monitor.refresh()
        refreshExtensionState()
    }

    func refreshExtensionState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state: String
            switch ModuleEnabler.isEnabled() {
            case .enabled: state = "Enabled"
            case .disabled: state = "Disabled"
            case .notRegistered: state = "Not registered"
            case nil: state = "Unknown"
            }
            DispatchQueue.main.async {
                self?.extensionState = state
                if state == "Enabled" {
                    self?.lastMessage = nil
                }
            }
        }
    }

    func enableExtension() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = ModuleEnabler.enable()
            DispatchQueue.main.async {
                switch outcome {
                case .enabled:
                    self?.extensionState = "Enabled"
                    self?.lastMessage = nil
                case .failed(let message):
                    self?.lastMessage = message
                case .notRegistered:
                    self?.lastMessage = "Extension is not registered; launch the app once from /Applications"
                }
                self?.refresh()
            }
        }
    }

    func mount(_ volume: NTFSVolumeInfo, readWrite: Bool) {
        busyDevice = volume.bsdName
        lastMessage = nil
        mountService.mount(bsdName: volume.bsdName, readWrite: readWrite) { [weak self] result in
            DispatchQueue.main.async {
                self?.busyDevice = nil
                switch result {
                case .success(let mountPoint):
                    self?.lastMessage = mountPoint.isEmpty
                        ? "Mounted \(volume.name)"
                        : "Mounted \(volume.name) at \(mountPoint)"
                case .failure(let error):
                    self?.lastMessage = "Mount failed: \(error.localizedDescription)"
                }
                self?.refresh()
            }
        }
    }

    func showDetails(_ volume: NTFSVolumeInfo) {
        if let mountPoint = volume.mountPoint, volume.isWritable {
            lastMessage = "\(volume.name) is mounted read-write at \(mountPoint)"
        } else if let mountPoint = volume.mountPoint {
            lastMessage = "\(volume.name) is mounted read-only at \(mountPoint)"
        } else {
            lastMessage = "\(volume.name) is not mounted"
        }
    }

    func unmount(_ volume: NTFSVolumeInfo) {
        busyDevice = volume.bsdName
        lastMessage = nil
        mountService.unmount(bsdName: volume.bsdName) { [weak self] result in
            DispatchQueue.main.async {
                self?.busyDevice = nil
                if case .failure(let error) = result {
                    self?.lastMessage = "Unmount failed: \(error.localizedDescription)"
                }
                self?.refresh()
            }
        }
    }

    func eject(_ volume: NTFSVolumeInfo) {
        busyDevice = volume.bsdName
        lastMessage = nil
        mountService.eject(bsdName: volume.bsdName) { [weak self] result in
            DispatchQueue.main.async {
                self?.busyDevice = nil
                if case .failure(let error) = result {
                    self?.lastMessage = "Eject failed: \(error.localizedDescription)"
                }
                self?.refresh()
            }
        }
    }
}
