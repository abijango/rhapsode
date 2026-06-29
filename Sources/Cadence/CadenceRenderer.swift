import AVFoundation
import Foundation
import CadenceKit

/// Inputs to render one **original source file** into a trimmed `.m4a` (spec §6, WP3).
/// Deliberately primitives — no `@Model` — so the engine is unit-testable and CadenceKit-pure
/// dependencies only. The coordinator (WP4) adapts an `Audiobook`/its tracks into this.
struct CadenceRenderRequest: Sendable {
    let sourceURL: URL
    /// Chunk cut points in **source seconds**, ascending, starting at 0. For an `.m4b` these are
    /// the chapter prefix-sums (chapter-aligned chunking); for a single MP3 file pass `[0]`.
    /// Windows longer than `maxChunkSeconds` are subdivided internally (fixed-size fallback).
    let cutPoints: [TimeInterval]
    /// Chapter titles parallel to `cutPoints`, for the remapped chapter marks. If the counts
    /// don't match, no chapter marks are emitted.
    let titles: [String]
    let preset: CadenceSettings.Preset
    let outputURL: URL
}

/// Output of a render: the trimmed file is at `request.outputURL`; this carries the metadata the
/// coordinator persists into a `TrimmedRendition` (durations, savings, map, remapped chapters).
struct CadenceRenderResult: Sendable {
    let originalDuration: TimeInterval
    let trimmedDuration: TimeInterval
    let savedSeconds: TimeInterval
    let regionCount: Int
    let timelineMap: CadenceTimelineMap
    let chapters: [CadenceChapterMark]
}

enum CadenceRenderError: Error, CustomStringConvertible {
    case emptyFile
    case sampleRateMismatch(chunk: Double, file: Double)
    case noOutput

    var description: String {
        switch self {
        case .emptyFile: return "Source file decoded to zero frames."
        case let .sampleRateMismatch(chunk, file): return "Chunk sample rate \(chunk) ≠ file rate \(file)."
        case .noOutput: return "Render produced no trimmed audio."
        }
    }
}

/// Chapter-aligned, chunked, streaming renderer. Decodes one chunk at a time → analyses the mono
/// downmix → renders the original channels → appends to a streaming AAC writer, so peak memory is
/// bounded to a single chunk regardless of book length. Builds the global source↔trimmed map and
/// remapped chapters as it goes.
///
/// Known limitation (accepted, spec §13 chunking): a silence straddling a chunk boundary is
/// analysed independently on each side, so it may be slightly under-trimmed at the seam. Chapter
/// joins are natural pauses, so this is inaudible; it is also why the oracle (§14) is compared
/// per-chunk-span, not against a whole-file CLI run.
struct CadenceRenderer {
    /// Cap on a single decoded chunk. A chapter longer than this is split into fixed sub-chunks.
    /// 5 min keeps peak decode memory modest (≈100 MB stereo float32 @ 44.1 kHz per buffer).
    var maxChunkSeconds: TimeInterval = 300

    func render(_ req: CadenceRenderRequest) throws -> CadenceRenderResult {
        let settings = CadenceSettings(preset: req.preset)

        // Probe format + duration. Wraps any AVAudioFile failure as AudioIOError.undecodable so the
        // coordinator's WP10 catch can classify DRM/corrupt files and mark the book unavailable.
        //
        // Safety assumption: callers guarantee the file is COMPLETE before calling render.
        // BackgroundDownloader uses an atomic fm.moveItem before enqueuing, so a partial/in-flight
        // download cannot reach here. If that trigger topology ever changes, this wrapping would
        // over-capture a transient failure as a permanent disable — review at that point.
        let probe: AVAudioFile
        do { probe = try AVAudioFile(forReading: req.sourceURL) }
        catch { throw AudioIOError.undecodable(underlying: error) }
        let sampleRate = probe.processingFormat.sampleRate
        let channels = probe.processingFormat.channelCount
        let originalDuration = Double(probe.length) / sampleRate
        guard probe.length > 0 else { throw CadenceRenderError.emptyFile }

        let windows = Self.chunkWindows(cutPoints: req.cutPoints, totalDuration: originalDuration,
                                        maxChunkSeconds: maxChunkSeconds)

        let writer = try AudioIO.AACFileWriter(
            url: req.outputURL, sampleRate: sampleRate, channelCount: channels,
            bitRate: Self.targetBitRate(for: req.sourceURL, channels: channels))

        var mapBuilder = CadenceTimelineMapBuilder()
        var cumulativeTrimmed: TimeInterval = 0
        var regionCount = 0

        for w in windows {
            try Task.checkCancellation()   // cooperative cancel between chunks (WP4 coordinator)
            try autoreleasepool {
                let buffer = try AudioIO.decode(req.sourceURL, startSeconds: w.start,
                                                durationSeconds: w.end - w.start,
                                                maxSeconds: maxChunkSeconds + 5)
                guard buffer.format.sampleRate == sampleRate else {
                    throw CadenceRenderError.sampleRateMismatch(chunk: buffer.format.sampleRate, file: sampleRate)
                }
                let mono = AudioIO.downmixToMono(buffer)
                let analysis = SilenceAnalyzer(settings: settings).analyze(monoSamples: mono, sampleRate: sampleRate)
                let rendered = try OfflineTrimRenderer(settings: settings)
                    .renderMapped(buffer: buffer, regions: analysis.regions)
                try writer.append(rendered.buffer)
                mapBuilder.append(segments: rendered.segments, sampleRate: sampleRate,
                                  sourceBase: w.start, trimmedBase: cumulativeTrimmed)
                cumulativeTrimmed += Double(rendered.buffer.frameLength) / sampleRate
                regionCount += analysis.regions.count
            }
        }
        writer.finish()

        guard cumulativeTrimmed > 0 else { throw CadenceRenderError.noOutput }
        let map = mapBuilder.finish(sourceDuration: originalDuration, trimmedDuration: cumulativeTrimmed)

        var chapters: [CadenceChapterMark] = []
        if req.titles.count == req.cutPoints.count {
            for (i, src) in req.cutPoints.enumerated() {
                chapters.append(.init(title: req.titles[i], trimmedStart: map.toTrimmed(src), sourceStart: src))
            }
        }

        return CadenceRenderResult(
            originalDuration: originalDuration, trimmedDuration: cumulativeTrimmed,
            savedSeconds: max(0, originalDuration - cumulativeTrimmed),
            regionCount: regionCount, timelineMap: map, chapters: chapters)
    }

    struct Window: Equatable { let start: TimeInterval; let end: TimeInterval }

    /// Expand cut points into render windows, subdividing any window longer than the cap into
    /// equal fixed-size sub-chunks. Cut points at/after `totalDuration` are dropped; a leading 0
    /// and a trailing `totalDuration` are always present.
    static func chunkWindows(cutPoints: [TimeInterval], totalDuration: TimeInterval,
                             maxChunkSeconds: TimeInterval) -> [Window] {
        var bounds = cutPoints.filter { $0 > 0 && $0 < totalDuration }.sorted()
        bounds.insert(0, at: 0)
        bounds.append(totalDuration)

        var windows: [Window] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            let len = b - a
            guard len > 0 else { continue }
            if len <= maxChunkSeconds {
                windows.append(Window(start: a, end: b))
            } else {
                let parts = Int(ceil(len / maxChunkSeconds))
                let step = len / Double(parts)
                for p in 0..<parts {
                    let s = a + Double(p) * step
                    let e = (p == parts - 1) ? b : a + Double(p + 1) * step
                    windows.append(Window(start: s, end: e))
                }
            }
        }
        return windows
    }

    /// Target AAC bitrate ≥ source (spec §6). Falls back to a spoken-word-appropriate default
    /// when the source rate can't be read.
    static func targetBitRate(for url: URL, channels: AVAudioChannelCount) -> Int {
        let fallback = channels >= 2 ? 128_000 : 96_000
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .audio).first {
            let est = Int(track.estimatedDataRate)
            if est > 0 { return max(est, fallback) }
        }
        return fallback
    }
}
