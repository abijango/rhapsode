import Foundation
import SmartSpeechKit
import Testing
@testable import Rhapsode

@Suite("SmartSpeech edit cache")
struct SmartSpeechEditCacheTests {
    @Test("round trips finalized source-time edits")
    func roundTripsFinalizedEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let cache = SmartSpeechEditCache(directory: fixture.directory)
        let policy = Self.policy()
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1.25, end: 2.5, kind: .compressPause),
            AudioEdit(start: 7, end: 9.5, kind: .removeMusic)
        ])

        try cache.store(map, for: source, policy: policy)

        #expect(cache.load(for: source, policy: policy) == map)
    }

    @Test("classifier or policy evolution invalidates an entry")
    func invalidatesChangedPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let cache = SmartSpeechEditCache(directory: fixture.directory)
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1, end: 2, kind: .compressPause)
        ])

        try cache.store(map, for: source, policy: Self.policy())

        #expect(cache.load(for: source, policy: .init(
            classifierVersion: 2,
            policyVersion: 1,
            settingsFingerprint: "live-v1"
        )) == nil)
        #expect(cache.load(for: source, policy: .init(
            classifierVersion: 1,
            policyVersion: 2,
            settingsFingerprint: "live-v1"
        )) == nil)
        #expect(cache.load(for: source, policy: .init(
            classifierVersion: 1,
            policyVersion: 1,
            settingsFingerprint: "live-v2"
        )) == nil)
    }

    @Test("source-file mutation invalidates an entry")
    func invalidatesMutatedSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var source = try fixture.source()
        let cache = SmartSpeechEditCache(directory: fixture.directory)
        let policy = Self.policy()
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1, end: 2, kind: .compressPause)
        ])
        try cache.store(map, for: source, policy: policy)

        try Data("different source bytes".utf8).write(to: fixture.sourceURL)
        source = try fixture.source()

        #expect(cache.load(for: source, policy: policy) == nil)
    }

    @Test("corrupt entries fail closed and are discarded")
    func rejectsCorruptEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let cache = SmartSpeechEditCache(directory: fixture.directory)
        let policy = Self.policy()
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1, end: 2, kind: .compressPause)
        ])
        try cache.store(map, for: source, policy: policy)

        let entryURL = try cache.entryURL(for: source, policy: policy)
        try Data("not a cache record".utf8).write(to: entryURL)

        #expect(cache.load(for: source, policy: policy) == nil)
        #expect(!FileManager.default.fileExists(atPath: entryURL.path))
    }

    @Test("rejects oversized maps before writing")
    func rejectsOversizedMaps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let cache = SmartSpeechEditCache(
            directory: fixture.directory,
            limits: .init(maximumEntryBytes: 1_024, maximumEditCount: 1)
        )
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1, end: 2, kind: .compressPause),
            AudioEdit(start: 3, end: 4, kind: .compressPause)
        ])

        #expect(throws: SmartSpeechEditCache.Error.entryTooLarge) {
            try cache.store(map, for: source, policy: Self.policy())
        }
    }

    private static func policy() -> SmartSpeechEditCache.PolicyKey {
        .init(classifierVersion: 1, policyVersion: 1, settingsFingerprint: "live-v1")
    }

    private struct Fixture {
        let directory: URL
        let sourceURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sourceURL = directory.appending(path: "chapter.m4b")
            try Data("initial source bytes".utf8).write(to: sourceURL)
        }

        func source() throws -> SmartSpeechEditCache.Source {
            try .init(url: sourceURL, duration: 12, cutPoints: [0, 6])
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
