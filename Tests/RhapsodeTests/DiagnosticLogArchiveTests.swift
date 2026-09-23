import Foundation
import Testing
@testable import Rhapsode

/// The zip step is the part of log archiving most likely to silently do nothing: it relies on
/// `NSFileCoordinator`'s `.forUploading` behaviour, which hands back a TEMPORARY archive that
/// is deleted the moment the closure returns. Getting that wrong yields a missing or empty
/// file and the day's log is gone, so it's worth pinning.
@Suite("Diagnostics — day archives")
struct DiagnosticLogArchiveTests {

    @Test("Zipping a log file produces a non-empty archive that outlives the coordinator")
    func zipProducesDurableArchive() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("rhapsode-2026-09-17.log")
        // Repetitive text, like a real log — also proves compression actually happens.
        let body = String(repeating: "2026-09-17T10:00:00Z INFO app  launch v0.1.0\n", count: 500)
        try body.write(to: source, atomically: true, encoding: .utf8)

        let archive = try #require(DiagnosticLog.zipForTesting(source))

        #expect(FileManager.default.fileExists(atPath: archive.path))
        let archivedSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue)
        #expect(archivedSize > 0)
        #expect(archivedSize < body.utf8.count)   // it compressed rather than just copied
        #expect(archive.lastPathComponent == "rhapsode-2026-09-17.log.zip")
    }
}
