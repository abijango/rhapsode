import Foundation
import CadenceKit

/// A piecewise-linear bijection between **source time** (the original file's timeline, the
/// canonical coordinate system for all persisted positions/bookmarks/chapters) and **trimmed
/// time** (the rendered `.m4a`'s shorter timeline). Built from the renderer's realized
/// `RenderSegment`s, so it is anchored to actual output offsets and does not drift (spec Flag 3).
///
/// Each point is monotonic non-decreasing in both axes. Within a kept segment the slope is 1;
/// a dropped silence shows up as a run where source advances while trimmed stays flat — so a
/// source time inside a removed gap maps to the seam (the start of the next kept audio), which
/// is exactly what smart-resume (§11) wants.
struct CadenceTimelineMap: Codable, Sendable, Equatable {
    struct Point: Codable, Sendable, Equatable {
        var source: Double
        var trimmed: Double
    }

    private(set) var points: [Point]
    let sourceDuration: TimeInterval
    let trimmedDuration: TimeInterval

    /// Source → trimmed. Clamped to the mapped range.
    func toTrimmed(_ source: TimeInterval) -> TimeInterval {
        interpolate(source, key: \.source, value: \.trimmed)
    }

    /// Trimmed → source. Clamped to the mapped range. Inverse of `toTrimmed` at the breakpoints;
    /// flat-trimmed runs (dropped silence) invert to the seam onset.
    func toSource(_ trimmed: TimeInterval) -> TimeInterval {
        interpolate(trimmed, key: \.trimmed, value: \.source)
    }

    /// Generic monotonic piecewise-linear lookup along one axis. Binary-searches the last point
    /// whose `key` ≤ `x`, then linearly interpolates `value` into the next strictly-increasing step.
    private func interpolate(_ x: Double, key: KeyPath<Point, Double>,
                             value: KeyPath<Point, Double>) -> Double {
        guard let first = points.first else { return x }
        guard let last = points.last else { return x }
        if x <= first[keyPath: key] { return first[keyPath: value] }
        if x >= last[keyPath: key] { return last[keyPath: value] }

        var lo = 0, hi = points.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if points[mid][keyPath: key] <= x { lo = mid } else { hi = mid }
        }
        // Advance past any flat run on the key axis so the denominator is non-zero.
        var i = lo
        while i + 1 < points.count && points[i + 1][keyPath: key] <= x { i += 1 }
        let a = points[i], b = points[min(i + 1, points.count - 1)]
        let span = b[keyPath: key] - a[keyPath: key]
        guard span > 0 else { return a[keyPath: value] }
        let t = (x - a[keyPath: key]) / span
        return a[keyPath: value] + t * (b[keyPath: value] - a[keyPath: value])
    }
}

/// Accumulates a global `CadenceTimelineMap` across chapter chunks. Each chunk's segments are in
/// chunk-local sample coordinates; we offset source by the chunk's source start and trimmed by
/// the cumulative trimmed duration of prior chunks, gluing the per-chunk staircases into one map.
struct CadenceTimelineMapBuilder {
    private var points: [CadenceTimelineMap.Point] = []

    /// Fold one chunk's realized segments into the global map.
    /// - Parameters:
    ///   - sourceBase: chunk's start time in source seconds.
    ///   - trimmedBase: cumulative trimmed seconds emitted before this chunk.
    mutating func append(segments: [RenderSegment], sampleRate: Double,
                         sourceBase: TimeInterval, trimmedBase: TimeInterval) {
        for seg in segments {
            add(.init(source: sourceBase + Double(seg.sourceStart) / sampleRate,
                      trimmed: trimmedBase + Double(seg.trimmedStart) / sampleRate))
            add(.init(source: sourceBase + Double(seg.sourceEnd) / sampleRate,
                      trimmed: trimmedBase + Double(seg.trimmedEnd) / sampleRate))
        }
    }

    /// Append a point, dropping exact duplicates and enforcing monotonicity against float noise.
    private mutating func add(_ p: CadenceTimelineMap.Point) {
        if let last = points.last {
            if last == p { return }
            // Clamp tiny non-monotonic jitter from float rounding at chunk seams.
            let s = max(p.source, last.source)
            let t = max(p.trimmed, last.trimmed)
            points.append(.init(source: s, trimmed: t))
        } else {
            points.append(p)
        }
    }

    func finish(sourceDuration: TimeInterval, trimmedDuration: TimeInterval) -> CadenceTimelineMap {
        CadenceTimelineMap(points: points, sourceDuration: sourceDuration, trimmedDuration: trimmedDuration)
    }
}

/// A chapter mark remapped into trimmed time (spec §7.1 `chapterMapBlob`), fed to the
/// now-playing / chapter UI during trimmed playback.
struct CadenceChapterMark: Codable, Sendable, Equatable {
    var title: String
    /// Chapter start in **trimmed** time.
    var trimmedStart: TimeInterval
    /// Chapter start in **source** time (kept so positions remain source-domain).
    var sourceStart: TimeInterval
}
