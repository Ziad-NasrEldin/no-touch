import Foundation
#if canImport(Darwin)
import Darwin
#endif
import RecorderContracts

/// Durable capture-side diagnostics sink. Events are appended to a JSONL file
/// so capture/transfer/lifecycle evidence survives process death.
/// Payloads must stay non-content-bearing by contract — no audio, no transcript.
///
/// A lock-guarded class rather than an actor so callers never need `await` —
/// emission must be callable from init, deinit, and sync bookkeeping paths.
/// Write failures are intentionally silent: diagnostics must never break capture.
public final class CaptureDiagnostics: @unchecked Sendable {
    private let fileURL: URL
    private let maxFileBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private let encoder: JSONEncoder
    private let deviceModel: String
    private let osVersion: String

    /// - Parameter maxFileBytes: rolls `events.jsonl` to `events.1.jsonl` past
    ///   this size so a full day of verbose events never grows unbounded.
    public init(
        directory: URL? = nil,
        defaultFolderName: String = "WatchCapture",
        maxFileBytes: Int = 2_000_000
    ) {
        var paths = directory.flatMap { try? CapturePaths.makeCustom(root: $0) }
            ?? (try? CapturePaths.makeDefault(folderName: defaultFolderName))
        if paths == nil {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("\(defaultFolderName)-\(UUID().uuidString)", isDirectory: true)
            paths = (try? CapturePaths.makeCustom(root: tmp)) ?? CapturePaths(root: tmp)
        }
        self.fileURL = paths!.diagnosticsFile
        self.maxFileBytes = maxFileBytes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.deviceModel = CaptureDiagnostics.machineIdentifier()
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    deinit {
        try? handle?.close()
    }

    public var logFileURL: URL { fileURL }

    public func emit(_ event: DiagnosticsEvent) {
        guard let data = try? encoder.encode(event) else { return }
        lock.lock()
        defer { lock.unlock() }
        rollIfNeeded(appending: data.count + 1)
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            try? handle.close()
            self.handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? self.handle?.seekToEnd()
        }
    }

    public func emit(
        _ subsystem: DiagnosticsSubsystem,
        name: String,
        severity: DiagnosticsSeverity = .info,
        payload: [String: String] = [:]
    ) {
        emit(DiagnosticsEvent(subsystem: subsystem, severity: severity, name: name, payload: payload))
    }

    /// Re-open the log at EOF after a rollover. Caller holds `lock`.
    private func rollIfNeeded(appending nextBytes: Int) {
        guard let handle,
              let end = try? handle.seekToEnd(),
              end + UInt64(nextBytes) > UInt64(maxFileBytes) else { return }
        try? handle.close()
        let rolled = fileURL.deletingLastPathComponent().appendingPathComponent("events.1.jsonl")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: fileURL, to: rolled)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? self.handle?.seekToEnd()
    }

    /// All persisted events (current file plus the previous rolled file),
    /// oldest first. Best effort — corrupt lines are skipped, not fatal.
    public func allEvents() -> [DiagnosticsEvent] {
        let rolled = fileURL.deletingLastPathComponent().appendingPathComponent("events.1.jsonl")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [DiagnosticsEvent] = []
        lock.lock()
        try? handle?.synchronize()
        lock.unlock()
        for url in [rolled, fileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                if let event = try? decoder.decode(DiagnosticsEvent.self, from: line) {
                    events.append(event)
                }
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    public func report() -> DiagnosticsReport {
        DiagnosticsReport(deviceModel: deviceModel, osVersion: osVersion, events: allEvents())
    }

    /// Hardware identifier (e.g. `Watch6,6`, `iPhone15,3`) via utsname — works
    /// on every Apple platform without importing UIKit/WatchKit into the library.
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
