import Darwin
import Foundation
import MetricKit
import OSLog

/// On-device diagnostics: a rotating log file under Application Support plus the
/// same lines on the unified log. Release writes too — DEBUG `print` is not enough
/// after a phone crash.
///
/// The file is excluded from backup. Do not put tokens or passwords in messages.
enum DiagnosticLog {
    enum Category: String, Sendable {
        case app, sync, reader, playback, smartspeech
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.naufalmir.rhapsode"
    private static let dirName = "Diagnostics"
    private static let currentName = "rhapsode.log"
    private static let rotatedName = "rhapsode.log.1"
    private static let crashMarkerName = "crash-pending"
    private static let pendingCrashDefaultsKey = "diagnosticPendingCrash"
    /// Soft cap per file. Current + rotated ≈ 2.5 MB of recent history.
    private static let maxFileBytes = 1_250_000

    private static let queue = DispatchQueue(label: "com.naufalmir.rhapsode.diagnostic-log")
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let metricsSubscriber = DiagnosticMetricsSubscriber()

    // Touched only on `queue`.
    nonisolated(unsafe) private static var bootstrapped = false
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var currentURL: URL?

    static var hasPendingCrash: Bool {
        UserDefaults.standard.bool(forKey: pendingCrashDefaultsKey)
    }

    static func clearPendingCrashFlag() {
        UserDefaults.standard.set(false, forKey: pendingCrashDefaultsKey)
    }

    /// Create the log directory, absorb a previous-launch crash marker, and install
    /// handlers. Safe to call more than once. Call before anything else in `init`.
    static func bootstrap() {
        queue.sync {
            guard !bootstrapped else { return }
            bootstrapped = true

            guard let dir = try? logsDirectory() else { return }
            currentURL = dir.appendingPathComponent(currentName, isDirectory: false)
            let markerURL = dir.appendingPathComponent(crashMarkerName, isDirectory: false)

            var leftover = ""
            if let data = try? Data(contentsOf: markerURL),
               !data.isEmpty,
               let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                leftover = text
                UserDefaults.standard.set(true, forKey: pendingCrashDefaultsKey)
            }
            try? FileManager.default.removeItem(at: markerURL)
            openCrashMarkerFD(markerURL)

            openCurrentFileUnlocked()
            if !leftover.isEmpty {
                writeUnlocked("\(iso.string(from: Date())) FAULT app  previous launch: \(leftover)\n")
            }
        }

        MXMetricManager.shared.add(metricsSubscriber)
        installExceptionHandler()
        installSignalHandlers()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("launch v\(version) (\(build)) \(os)", category: .app)
    }

    nonisolated static func info(_ message: String, category: Category = .app) {
        emit("INFO", category: category, message: message)
    }

    nonisolated static func error(_ message: String, category: Category = .app) {
        emit("ERROR", category: category, message: message)
    }

    nonisolated static func fault(_ message: String, category: Category = .app) {
        emit("FAULT", category: category, message: message)
        UserDefaults.standard.set(true, forKey: pendingCrashDefaultsKey)
    }

    /// Combined current + rotated log, newest at the bottom.
    static func readAll() -> String {
        queue.sync {
            try? fileHandle?.synchronize()
            let dir = (try? logsDirectory()) ?? currentURL?.deletingLastPathComponent()
            guard let dir else { return "" }
            let rotated = dir.appendingPathComponent(rotatedName, isDirectory: false)
            let current = dir.appendingPathComponent(currentName, isDirectory: false)
            let older = (try? String(contentsOf: rotated, encoding: .utf8)) ?? ""
            let newer = (try? String(contentsOf: current, encoding: .utf8)) ?? ""
            return older + newer
        }
    }

    /// Tail used by the in-app viewer (full file still goes out via Share).
    static func readRecent(maxBytes: Int = 200_000) -> String {
        let all = readAll()
        guard let data = all.data(using: .utf8), data.count > maxBytes else { return all }
        let slice = data.suffix(maxBytes)
        let text = String(decoding: slice, as: UTF8.self)
        if let cut = text.firstIndex(of: "\n") {
            return String(text[text.index(after: cut)...])
        }
        return text
    }

    static func byteCount() -> Int {
        queue.sync {
            let dir = (try? logsDirectory()) ?? currentURL?.deletingLastPathComponent()
            guard let dir else { return 0 }
            let names = [currentName, rotatedName]
            return names.reduce(0) { sum, name in
                let url = dir.appendingPathComponent(name, isDirectory: false)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                    .intValue ?? 0
                return sum + size
            }
        }
    }

    /// Snapshot both files into one shareable text file in the same folder.
    static func exportFile() -> URL? {
        let body = readAll()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return queue.sync {
            let header = """
            Rhapsode diagnostics
            Exported \(iso.string(from: Date()))
            App \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)

            """
            guard let dir = try? logsDirectory() else { return nil }
            let url = dir.appendingPathComponent("rhapsode-diagnostics.txt", isDirectory: false)
            do {
                try (header + body).write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                return nil
            }
        }
    }

    static func clear() {
        queue.sync {
            try? fileHandle?.close()
            fileHandle = nil
            guard let dir = try? logsDirectory() else { return }
            for name in [currentName, rotatedName, "rhapsode-diagnostics.txt"] {
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent(name, isDirectory: false)
                )
            }
            openCurrentFileUnlocked()
            UserDefaults.standard.set(false, forKey: pendingCrashDefaultsKey)
        }
        info("log cleared", category: .app)
    }

    /// NSException path — Foundation is allowed here (unlike a signal handler).
    fileprivate static func recordUncaughtException(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        let line = "NSException \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)"
        queue.sync {
            writeUnlocked("\(iso.string(from: Date())) FAULT app  \(line)\n")
            try? fileHandle?.synchronize()
        }
        UserDefaults.standard.set(true, forKey: pendingCrashDefaultsKey)
        previousExceptionHandler?(exception)
    }

    fileprivate static func ingestMetricKit(_ payload: MXDiagnosticPayload) {
        func dump(_ items: [some MXDiagnostic]?, label: String) {
            guard let items, !items.isEmpty else { return }
            for item in items {
                let json = String(data: item.jsonRepresentation(), encoding: .utf8) ?? "<binary>"
                fault("MetricKit \(label):\n\(json)", category: .app)
            }
        }
        dump(payload.crashDiagnostics, label: "crash")
        dump(payload.hangDiagnostics, label: "hang")
        dump(payload.cpuExceptionDiagnostics, label: "cpuException")
        dump(payload.diskWriteExceptionDiagnostics, label: "diskWrite")
    }

    // MARK: - Internals

    private nonisolated static func emit(_ level: String, category: Category, message: String) {
        let now = Date()
        queue.async {
            let line = "\(iso.string(from: now)) \(level) \(category.rawValue)  \(message)\n"
            writeUnlocked(line)
        }

        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case "ERROR", "FAULT":
            logger.error("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }
    }

    private static func logsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var dir = appSupport.appendingPathComponent(dirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        }
        return dir
    }

    private static func openCurrentFileUnlocked() {
        guard let url = currentURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
        } catch {
            fileHandle = nil
        }
    }

    private static func writeUnlocked(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeededUnlocked(incoming: data.count)
        if fileHandle == nil { openCurrentFileUnlocked() }
        do {
            try fileHandle?.write(contentsOf: data)
            try fileHandle?.synchronize()
        } catch {
            fileHandle = nil
        }
    }

    private static func rotateIfNeededUnlocked(incoming: Int) {
        guard let url = currentURL else { return }
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
        guard currentSize + incoming > maxFileBytes else { return }

        try? fileHandle?.close()
        fileHandle = nil
        let rotated = url.deletingLastPathComponent().appendingPathComponent(rotatedName, isDirectory: false)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        openCurrentFileUnlocked()
    }
}

// MARK: - Crash leftovers (signal + NSException)

/// Pre-opened fd so a dying process can write without allocating.
private nonisolated(unsafe) var diagnosticCrashFD: Int32 = -1
private nonisolated(unsafe) var previousExceptionHandler: NSUncaughtExceptionHandler?

private let diagnosticSignalHandler: @convention(c) (Int32) -> Void = { sig in
    let fd = diagnosticCrashFD
    if fd >= 0 {
        let prefix: StaticString = "CRASH signal="
        prefix.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
        let n = sig < 0 ? 0 : Int(sig)
        var chars: (UInt8, UInt8, UInt8) = (48, 10, 0)
        if n >= 10 {
            chars.0 = UInt8(n / 10) + 48
            chars.1 = UInt8(n % 10) + 48
            chars.2 = 10
            withUnsafeBytes(of: &chars) { raw in
                _ = write(fd, raw.baseAddress, 3)
            }
        } else {
            chars.0 = UInt8(n) + 48
            chars.1 = 10
            withUnsafeBytes(of: &chars) { raw in
                _ = write(fd, raw.baseAddress, 2)
            }
        }
        fsync(fd)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

private func openCrashMarkerFD(_ url: URL) {
    url.path.withCString { path in
        diagnosticCrashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }
}

private func installExceptionHandler() {
    previousExceptionHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
        DiagnosticLog.recordUncaughtException(exception)
    }
}

private func installSignalHandlers() {
    for sig in [SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGTRAP, SIGFPE] {
        signal(sig, diagnosticSignalHandler)
    }
}

// MARK: - MetricKit (next-launch crash / hang reports)

private final class DiagnosticMetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            DiagnosticLog.ingestMetricKit(payload)
        }
    }
}
