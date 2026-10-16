import Foundation
import Observation

/// Where the link to the phone stands. The sidebar renders this directly.
enum ConnectionState: Equatable {
    case helperMissing(String)
    case noDevice
    case idle                 // device listed, not connected
    case connecting(String)   // "tunnel", "service", "mounting"…
    case ready
    case failed(String)
}

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    var selectedUDID: String?
    private(set) var state: ConnectionState = .noDevice
    private(set) var log: [String] = []
    private(set) var helperVersion = ""
    /// The last coordinate the device acknowledged; the map dot follows this, not the intent.
    private(set) var deviceLocation: (lat: Double, lon: Double)?

    private var helper: HelperProcess?
    private var pollTask: Task<Void, Never>?

    var selectedDevice: Device? { devices.first { $0.udid == selectedUDID } }
    var isReady: Bool { state == .ready }
    var isBusy: Bool { if case .connecting = state { return true } else { return false } }

    func start() {
        guard helper == nil else { return }
        let helper = HelperProcess { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try helper.launch()
            self.helper = helper
        } catch {
            state = .helperMissing(error.localizedDescription)
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isReady && !self.isBusy {
                    self.append("→ devices")
                    self.helper?.send(["cmd": "devices"])
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func connect() {
        guard let udid = selectedUDID, let helper else { return }
        state = .connecting("")
        append("→ connect \(udid)")
        helper.send(["cmd": "connect", "udid": udid])
    }

    func disconnect() {
        helper?.send(["cmd": "disconnect"])
        deviceLocation = nil
        state = devices.isEmpty ? .noDevice : .idle
    }

    func setLocation(lat: Double, lon: Double) {
        guard isReady else { return }
        helper?.send(["cmd": "set", "lat": lat, "lon": lon])
    }

    func resetLocation() {
        guard isReady else { return }
        helper?.send(["cmd": "reset"])
    }

    func shutdown() {
        pollTask?.cancel()
        helper?.terminate()
    }

    private func handle(_ event: HelperEvent) {
        switch event {
        case .hello(let version):
            helperVersion = version
            append("ternd \(version)")
        case .devices(let list):
            devices = list
            if let selected = selectedUDID, !list.contains(where: { $0.udid == selected }) {
                selectedUDID = nil
            }
            if selectedUDID == nil { selectedUDID = list.first?.udid }
            if case .connecting = state { return }
            if state == .ready { return }
            state = list.isEmpty ? .noDevice : .idle
        case .status(let s, let detail):
            switch s {
            case "ready":
                state = .ready
                append(String(localized: "Connected"))
            case "disconnected":
                state = devices.isEmpty ? .noDevice : .idle
                deviceLocation = nil
            default:
                state = .connecting(Self.humanState(s, detail))
                append(Self.humanState(s, detail))
            }
        case .set(let lat, let lon):
            deviceLocation = (lat, lon)
        case .reset:
            deviceLocation = nil
            append(String(localized: "Location reset"))
        case .error(let scope, let message):
            append("\(scope): \(message)")
            if scope == "connect" { state = .failed(message) }
        case .log(let line):
            append(line)
        case .exited(let code):
            append("ternd exited (\(code))")
            helper = nil
            state = .helperMissing(String(localized: "The device helper stopped. Relaunch Tern."))
        }
    }

    /// Also mirrored to ~/Library/Logs/Tern/helper.log so a bug report can carry it.
    private func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
        Self.logFile.write("\(stamp)  \(line)\n")
    }

    static let logFile: LogFile = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tern", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LogFile(url: dir.appendingPathComponent("helper.log"))
    }()

    private static func humanState(_ state: String, _ detail: String) -> String {
        switch state {
        case "connecting": return String(localized: "Connecting") + (detail.isEmpty ? "" : " · \(detail)")
        case "tunnel": return String(localized: "Opening tunnel")
        case "service": return String(localized: "Starting location service")
        case "mounting": return String(localized: "Mounting developer disk image")
        default: return detail.isEmpty ? state : "\(state) · \(detail)"
        }
    }
}

/// Append-only text file, truncated when it grows past a megabyte.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.voxyfy.tern.log")

    init(url: URL) { self.url = url }

    func write(_ text: String) {
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: self.url.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: self.url)
            }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: self.url)
            }
        }
    }
}
