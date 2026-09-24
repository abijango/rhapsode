import AVFoundation
import Foundation
import SmartSpeechKit

/// Persistent cache for finalized, source-time SmartSpeech edits.
///
/// The caller supplies revisions for every classifier and policy decision that affects the map.
/// A cache entry is valid only while those revisions and the source file fingerprint still match.
struct SmartSpeechEditCache: Sendable {
    static let formatVersion = 1
    /// Bump when the audio classifier's region semantics change.
    static let liveClassifierRevision = 1
    /// Bump when source-region-to-edit planning or live rendering policy changes.
    static let livePolicyRevision = 1

    struct Source: Sendable {
        let url: URL
        let duration: TimeInterval
        let cutPoints: [TimeInterval]

        init(url: URL, duration: TimeInterval, cutPoints: [TimeInterval]) throws {
            guard url.isFileURL,
                  duration.isFinite,
                  duration >= 0,
                  cutPoints.allSatisfy(\.isFinite),
                  zip(cutPoints, cutPoints.dropFirst()).allSatisfy { $0 <= $1 },
                  cutPoints.allSatisfy({ $0 >= 0 && $0 <= duration })
            else {
                throw Error.invalidSource
            }

            self.url = url.standardizedFileURL
            self.duration = duration
            self.cutPoints = cutPoints
        }
    }

    /// Bump `classifierVersion` whenever classification can produce different semantic regions.
    /// Bump `policyVersion` for changes to semantic-region-to-edit decisions, and use
    /// `settingsFingerprint` for the exact active settings and other policy inputs.
    struct PolicyKey: Codable, Equatable, Sendable {
        let classifierVersion: Int
        let policyVersion: Int
        let settingsFingerprint: String

        init(classifierVersion: Int, policyVersion: Int, settingsFingerprint: String) {
            self.classifierVersion = classifierVersion
            self.policyVersion = policyVersion
            self.settingsFingerprint = settingsFingerprint
        }
    }

    /// The complete policy identity for live playback. The fingerprint deliberately includes both
    /// the selected tier and every effective analyzer, edit-planning, and renderer setting.
    static func livePolicy(for preset: SmartSpeechSettings.Preset) -> PolicyKey {
        let settings = LiveSmartSpeechTuning.settings(preset: preset)
        let fingerprint = LivePolicyFingerprint(
            tier: preset.rawValue,
            settings: settings,
            editPolicy: LiveTrimProducer.semanticEditPolicy(for: settings)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(fingerprint)) ?? Data()
        return PolicyKey(
            classifierVersion: liveClassifierRevision,
            policyVersion: livePolicyRevision,
            settingsFingerprint: data.base64EncodedString()
        )
    }

    struct Limits: Sendable {
        static let `default` = Self(
            maximumEntryBytes: 1 * 1_024 * 1_024,
            maximumEditCount: 20_000,
            maximumCacheBytes: 32 * 1_024 * 1_024
        )

        let maximumEntryBytes: Int
        let maximumEditCount: Int
        let maximumCacheBytes: Int

        init(maximumEntryBytes: Int, maximumEditCount: Int, maximumCacheBytes: Int = 32 * 1_024 * 1_024) {
            self.maximumEntryBytes = maximumEntryBytes
            self.maximumEditCount = maximumEditCount
            self.maximumCacheBytes = maximumCacheBytes
        }
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case invalidSource
        case invalidEditMap
        case entryTooLarge
    }

    private static let filePrefix = "smart-speech-edit-cache-"

    private let directory: URL
    private let limits: Limits

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartSpeechEditCache", isDirectory: true),
        limits: Limits = .default
    ) {
        self.directory = directory
        self.limits = limits
    }

    /// Builds the source-domain identity from the actual audio file so cache lookup never depends
    /// on a rounded or chapter-relative duration supplied by the playback UI.
    static func source(url: URL, cutPoints: [TimeInterval]) throws -> Source {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { throw Error.invalidSource }
        return try Source(
            url: url,
            duration: Double(file.length) / sampleRate,
            cutPoints: cutPoints
        )
    }

    /// Returns a map only when the exact source file, source-domain inputs, cache format, and policy
    /// key match. Corrupt or stale records are removed and treated as a cache miss.
    func load(for source: Source, policy: PolicyKey) -> PlaybackEditMap? {
        let url = cacheFileURL(for: source, policy: policy)
        do {
            let signature = try SourceSignature(source: source)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= limits.maximumEntryBytes else {
                discard(url)
                return nil
            }

            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.formatVersion == Self.formatVersion,
                  record.source == signature,
                  record.policy == policy,
                  isValid(record.edits, for: source),
                  PlaybackEditMap(edits: record.edits).edits == record.edits
            else {
                discard(url)
                return nil
            }

            return PlaybackEditMap(edits: record.edits)
        } catch {
            discard(url)
            return nil
        }
    }

    /// Atomically replaces the cache entry after validating that every finalized edit is expressed
    /// in the original source timeline and fits the configured entry/cache limits.
    func store(_ map: PlaybackEditMap, for source: Source, policy: PolicyKey) throws {
        guard map.edits.count <= limits.maximumEditCount else { throw Error.entryTooLarge }
        guard isValid(map.edits, for: source),
              PlaybackEditMap(edits: map.edits).edits == map.edits
        else {
            throw Error.invalidEditMap
        }

        let record = Record(
            formatVersion: Self.formatVersion,
            source: try SourceSignature(source: source),
            policy: policy,
            edits: map.edits
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= limits.maximumEntryBytes else { throw Error.entryTooLarge }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try entryURL(for: source, policy: policy)
        try makeRoom(for: data.count, replacing: url)
        try data.write(to: url, options: [.atomic])
    }

    /// Exposed to focused tests and diagnostic tooling; callers should otherwise use `load`/`store`.
    func entryURL(for source: Source, policy: PolicyKey) throws -> URL {
        _ = try SourceSignature(source: source)
        return cacheFileURL(for: source, policy: policy)
    }

    private func isValid(_ edits: [AudioEdit], for source: Source) -> Bool {
        edits.count <= limits.maximumEditCount &&
            edits.allSatisfy {
                $0.start.isFinite &&
                    $0.end.isFinite &&
                    $0.start >= 0 &&
                    $0.end > $0.start &&
                    $0.end <= source.duration
            }
    }

    private func cacheFileURL(for source: Source, policy: PolicyKey) -> URL {
        let identity = [
            String(Self.formatVersion),
            source.url.path,
            String(policy.classifierVersion),
            String(policy.policyVersion),
            policy.settingsFingerprint
        ].joined(separator: "\u{1F}")
        return directory.appendingPathComponent(
            "\(Self.filePrefix)\(stableHash(identity)).json",
            isDirectory: false
        )
    }

    private func makeRoom(for incomingBytes: Int, replacing destination: URL) throws {
        guard incomingBytes <= limits.maximumCacheBytes else { throw Error.entryTooLarge }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = contents.compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard url.lastPathComponent.hasPrefix(Self.filePrefix),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize
            else {
                return nil
            }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }

        let existingBytes = entries.reduce(0) { partial, entry in
            partial + (entry.url == destination ? 0 : entry.size)
        }
        var requiredBytes = existingBytes + incomingBytes - limits.maximumCacheBytes
        guard requiredBytes > 0 else { return }

        for entry in entries
            .filter({ $0.url != destination })
            .sorted(by: { $0.modified < $1.modified }) {
            try? FileManager.default.removeItem(at: entry.url)
            requiredBytes -= entry.size
            if requiredBytes <= 0 { return }
        }

        throw Error.entryTooLarge
    }

    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private struct SourceSignature: Codable, Equatable {
        let path: String
        let fileSize: Int
        let modificationTimeNanoseconds: Int64
        let duration: TimeInterval
        let cutPoints: [TimeInterval]

        init(source: Source) throws {
            let values = try source.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let fileSize = values.fileSize,
                  let modificationDate = values.contentModificationDate
            else {
                throw Error.invalidSource
            }

            self.path = source.url.path
            self.fileSize = fileSize
            self.modificationTimeNanoseconds = Int64(
                (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
            )
            self.duration = source.duration
            self.cutPoints = source.cutPoints
        }
    }

    private struct LivePolicyFingerprint: Codable {
        let tier: String
        let settings: SmartSpeechSettings
        let editPolicy: SemanticEditPolicy
    }

    private struct Record: Codable {
        let formatVersion: Int
        let source: SourceSignature
        let policy: PolicyKey
        let edits: [AudioEdit]
    }
}
