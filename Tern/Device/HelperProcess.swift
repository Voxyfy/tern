import Foundation

/// Everything ternd can tell us, decoded from one JSON line of its stdout.
enum HelperEvent: Sendable {
    case hello(version: String)
    case devices([Device])
    case status(state: String, detail: String)
    case set(lat: Double, lon: Double)
    case reset
    case error(scope: String, message: String)
    case log(String)       // a stderr line from go-ios
    case exited(Int32)
}

struct Device: Identifiable, Hashable, Codable, Sendable {
    var udid: String
    var name: String
    var productType: String
    var version: String
    var connection: String
    var id: String { udid }

    /// "iPhone17,1" means nothing to a person; fall back to it only when the name is empty.
    var displayName: String { name.isEmpty ? productType : name }
}

/// Owns the ternd child process. Requests go in as JSON lines on stdin, events come back
/// on stdout. The class is thread-confined to its own queue; callers get events on the main actor.
final class HelperProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let queue = DispatchQueue(label: "com.voxyfy.tern.helper")
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let onEvent: @Sendable (HelperEvent) -> Void
    private(set) var isRunning = false

    init(onEvent: @escaping @Sendable (HelperEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// The helper ships inside the bundle (Contents/MacOS/ternd). A developer running from
    /// Xcode without the build script sees a clear error instead of a crash.
    static var executableURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "ternd")
    }

    func launch() throws {
        guard let url = Self.executableURL else {
            throw HelperError.missingBinary
        }
        process.executableURL = url
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.isRunning = false
            self.onEvent(.exited(p.terminationStatus))
        }
        // Read inside the handler: availableData blocks when nothing is pending, and doing that
        // on the serial queue would starve the writes queued behind it.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data, isError: false) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data, isError: true) }
        }
        try process.run()
        isRunning = true
    }

    func send(_ request: [String: Any]) {
        guard isRunning, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        queue.async { [stdin] in
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data([0x0A]))
        }
    }

    func terminate() {
        send(["cmd": "quit"])
        queue.asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func consume(_ chunk: Data, isError: Bool) {
        if chunk.isEmpty { return }
        if isError { stderrBuffer.append(chunk) } else { stdoutBuffer.append(chunk) }
        while let newline = (isError ? stderrBuffer : stdoutBuffer).firstIndex(of: 0x0A) {
            let line: Data
            if isError {
                line = stderrBuffer.subdata(in: 0..<newline)
                stderrBuffer.removeSubrange(0...newline)
            } else {
                line = stdoutBuffer.subdata(in: 0..<newline)
                stdoutBuffer.removeSubrange(0...newline)
            }
            if isError {
                if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                    onEvent(.log(Self.prettyLog(text)))
                }
            } else if let event = Self.decode(line) {
                onEvent(event)
            }
        }
    }

    /// go-ios writes structured JSON logs; show the message and the error field only.
    private static func prettyLog(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["msg"] as? String else { return text }
        let level = (obj["level"] as? String) ?? "INFO"
        if let err = obj["error"] ?? obj["err"] { return "\(level) \(msg): \(err)" }
        return "\(level) \(msg)"
    }

    private static func decode(_ line: Data) -> HelperEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = obj["event"] as? String else { return nil }
        switch event {
        case "hello":
            return .hello(version: obj["version"] as? String ?? "?")
        case "devices":
            guard let raw = obj["devices"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let devices = try? JSONDecoder().decode([Device].self, from: data) else { return .devices([]) }
            return .devices(devices)
        case "status":
            return .status(state: obj["state"] as? String ?? "", detail: obj["detail"] as? String ?? "")
        case "set":
            return .set(lat: obj["lat"] as? Double ?? 0, lon: obj["lon"] as? Double ?? 0)
        case "reset":
            return .reset
        case "error":
            return .error(scope: obj["scope"] as? String ?? "", message: obj["message"] as? String ?? "")
        default:
            return nil
        }
    }
}

enum HelperError: LocalizedError {
    case missingBinary

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            return String(localized: "The device helper (ternd) is missing from the app bundle. Run scripts/build-ternd.sh and rebuild.")
        }
    }
}
