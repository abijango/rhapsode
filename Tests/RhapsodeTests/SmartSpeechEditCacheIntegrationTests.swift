import Foundation
import SmartSpeechKit
import Testing
@testable import Rhapsode

@Suite("SmartSpeech edit cache integration")
struct SmartSpeechEditCacheIntegrationTests {
    @Test("warm-start map is matched to the exact live tier policy")
    func warmStartMapMatchesExactLiveTierPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let cache = SmartSpeechEditCache(directory: fixture.directory)
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 2, end: 3.5, kind: .compressPause)
        ])

        let defaultPolicy = SmartSpeechEditCache.livePolicy(for: .default)
        try cache.store(map, for: source, policy: defaultPolicy)

        #expect(cache.load(for: source, policy: defaultPolicy) == map)
        #expect(cache.load(for: source, policy: SmartSpeechEditCache.livePolicy(for: .more)) == nil)
        #expect(cache.load(for: source, policy: SmartSpeechEditCache.livePolicy(for: .aggressive)) == nil)
    }

    @Test("live policy fingerprint captures the complete effective tier settings")
    func livePolicyFingerprintChangesWithEffectiveSettings() {
        let defaultPolicy = SmartSpeechEditCache.livePolicy(for: .default)
        let morePolicy = SmartSpeechEditCache.livePolicy(for: .more)
        let aggressivePolicy = SmartSpeechEditCache.livePolicy(for: .aggressive)

        #expect(defaultPolicy.classifierVersion == SmartSpeechEditCache.liveClassifierRevision)
        #expect(defaultPolicy.policyVersion == SmartSpeechEditCache.livePolicyRevision)
        #expect(defaultPolicy.settingsFingerprint != morePolicy.settingsFingerprint)
        #expect(morePolicy.settingsFingerprint != aggressivePolicy.settingsFingerprint)
    }

    private struct Fixture {
        let directory: URL
        let sourceURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sourceURL = directory.appending(path: "chapter.m4b")
            try Data("source bytes".utf8).write(to: sourceURL)
        }

        func source() throws -> SmartSpeechEditCache.Source {
            try .init(url: sourceURL, duration: 12, cutPoints: [0, 6])
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
