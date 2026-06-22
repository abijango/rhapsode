import AVFoundation
import Foundation

/// A trim plan in the sample-index domain: the source ranges copied verbatim, in
/// order, and the joints where consecutive ranges are spliced together. Pure output
/// of `OfflineTrimRenderer.plan` so the keep/savings math is testable without audio.
public struct TrimPlan: Sendable {
    /// Source-sample ranges to copy, in output order. Adjacent ranges meet at a splice.
    public let keptIntervals: [Range<Int>]
    /// Per joint: `(outCut, inResume)` — last source sample of the outgoing range and the
    /// first source sample of the incoming range. One per gap between kept intervals.
    public let joints: [(outCut: Int, inResume: Int)]

    /// Total frames copied (pre-splice; ignores crossfade overlap). The rendered file is
    /// slightly shorter — each crossfade overlaps the join by the crossfade length.
    public var keptFrameCount: Int { keptIntervals.reduce(0) { $0 + $1.count } }
}

/// One slope-1 mapping segment between source and rendered (trimmed) samples. Within a
/// segment source and trimmed advance 1:1; the gap between consecutive segments is the dropped
/// silence (plus each join's crossfade overlap, attributed to the seam). `trimmedStart` of a
/// segment equals the previous segment's `trimmedEnd`, so the trimmed axis is continuous while
/// the source axis jumps — exactly the source→trimmed collapse of a removed gap.
public struct RenderSegment: Sendable, Equatable {
    public let sourceStart: Int
    public let sourceEnd: Int
    public let trimmedStart: Int
    public let trimmedEnd: Int
    public init(sourceStart: Int, sourceEnd: Int, trimmedStart: Int, trimmedEnd: Int) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.trimmedStart = trimmedStart
        self.trimmedEnd = trimmedEnd
    }
}

/// Rendered audio plus the realized source↔trimmed segment map. The map is built **inside** the
/// render loop so it captures the *actual* clamped crossfade per join — anchoring trimmed offsets
/// to real cumulative output, so it never drifts across thousands of joins (WP3 / spec Flag 3).
public struct RenderOutput {
    public let buffer: AVAudioPCMBuffer
    public let segments: [RenderSegment]
    public init(buffer: AVAudioPCMBuffer, segments: [RenderSegment]) {
        self.buffer = buffer
        self.segments = segments
    }
}

/// Builds the trimmed output by copying speech + the first `target` seconds of each
/// silence, then splicing the joins with a **zero-crossing snap + equal-power crossfade**
/// (rule 4). A hard cut is a bug — it produces the artifact this harness tests against.
public struct OfflineTrimRenderer {
    public let settings: CadenceSettings

    /// Zero-crossing search window on each side of a cut (±2 ms).
    static let snapWindowMs = 2.0

    public init(settings: CadenceSettings) {
        self.settings = settings
    }

    /// Pure plan: keep `[regionStart, regionStart+target]` of each silence, drop the rest,
    /// resume at the region end. Speech and its trailing kept-silence are contiguous in the
    /// source, so they merge into one kept interval; the joint is the dropped silence tail.
    public func plan(regions: [SilenceRegion], totalFrames: Int, sampleRate: Double) -> TrimPlan {
        func frames(_ t: TimeInterval) -> Int { min(max(0, Int((t * sampleRate).rounded())), totalFrames) }

        var intervals: [Range<Int>] = []
        var joints: [(outCut: Int, inResume: Int)] = []
        var cursor = 0   // start of the current kept interval

        for region in regions {
            let regionStart = frames(region.start)
            let regionEnd = frames(region.end)
            guard regionEnd > regionStart, regionStart >= cursor else { continue }
            let target = SilencePolicy.target(forSilenceDuration: region.duration, settings: settings)
            let keepEnd = min(regionStart + frames(target), regionEnd)
            guard keepEnd > cursor else { continue }
            intervals.append(cursor..<keepEnd)
            joints.append((outCut: keepEnd, inResume: regionEnd))
            cursor = regionEnd
        }
        intervals.append(cursor..<totalFrames)
        return TrimPlan(keptIntervals: intervals, joints: joints)
    }

    /// Equal-power crossfade envelope. `progress` runs 0→1 across the join; the outgoing
    /// tail fades by `cos`, the incoming head rises by `sin`, so `out² + incoming² ≈ 1`
    /// (constant power — correct for blending the uncorrelated silence-tail and speech-onset).
    public static func equalPowerGains(progress: Double) -> (out: Double, incoming: Double) {
        let theta = max(0, min(1, progress)) * (.pi / 2)
        return (out: cos(theta), incoming: sin(theta))
    }

    /// Render the trimmed buffer: snap each joint to nearby zero-crossings and equal-power
    /// crossfade across it. Channels stay aligned (one snapped index applied to all).
    public func render(buffer: AVAudioPCMBuffer, regions: [SilenceRegion]) throws -> AVAudioPCMBuffer {
        try renderMapped(buffer: buffer, regions: regions).buffer
    }

    /// As `render`, but also returns the realized source↔trimmed segment map (WP3). The audio
    /// path is byte-for-byte identical to `render`; the segments are pure bookkeeping captured
    /// alongside, anchored to the actual cumulative output so the map cannot drift.
    public func renderMapped(buffer: AVAudioPCMBuffer, regions: [SilenceRegion]) throws -> RenderOutput {
        let sampleRate = buffer.format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        // Whole buffer is one 1:1 segment when there's nothing to splice.
        func identity() -> RenderOutput {
            RenderOutput(buffer: buffer,
                         segments: [RenderSegment(sourceStart: 0, sourceEnd: totalFrames,
                                                  trimmedStart: 0, trimmedEnd: totalFrames)])
        }
        guard totalFrames > 0, let source = buffer.floatChannelData else { return identity() }

        let plan = plan(regions: regions, totalFrames: totalFrames, sampleRate: sampleRate)
        // No joints → nothing to splice; hand back the input untouched.
        guard plan.keptIntervals.count > 1 else { return identity() }

        let reference = AudioIO.downmixToMono(buffer)   // zero-crossing reference; all channels share the index
        let crossfadeFrames = max(1, Int((settings.crossfadeMs / 1000.0 * sampleRate).rounded()))
        let snapWindow = max(1, Int((Self.snapWindowMs / 1000.0 * sampleRate).rounded()))

        // Snap interior boundaries to zero crossings (within their own interval interiors).
        var starts = plan.keptIntervals.map(\.lowerBound)
        var ends = plan.keptIntervals.map(\.upperBound)
        for j in 0..<(plan.keptIntervals.count - 1) {
            ends[j] = Self.snapZeroCrossing(reference, around: ends[j],
                                            lo: starts[j] + 1, hi: ends[j] + snapWindow,
                                            window: snapWindow, total: totalFrames)
            starts[j + 1] = Self.snapZeroCrossing(reference, around: starts[j + 1],
                                                  lo: starts[j + 1] - snapWindow, hi: ends[j + 1] - 1,
                                                  window: snapWindow, total: totalFrames)
        }

        // Concatenate intervals with equal-power crossfades, per channel.
        var out = [[Float]](repeating: [], count: channelCount)
        let capacity = zip(starts, ends).reduce(0) { $0 + max(0, $1.1 - $1.0) }
        for ch in 0..<channelCount { out[ch].reserveCapacity(capacity) }

        func append(_ range: Range<Int>) {
            for ch in 0..<channelCount {
                out[ch].append(contentsOf: UnsafeBufferPointer(start: source[ch] + range.lowerBound,
                                                               count: range.count))
            }
        }

        var segments: [RenderSegment] = []
        append(starts[0]..<ends[0])
        segments.append(RenderSegment(sourceStart: starts[0], sourceEnd: ends[0],
                                      trimmedStart: 0, trimmedEnd: ends[0] - starts[0]))
        var prevIntervalLen = ends[0] - starts[0]

        for i in 1..<starts.count {
            let inLen = ends[i] - starts[i]
            let written = out[0].count   // cumulative trimmed output BEFORE interval i's new frames
            let cf = min(crossfadeFrames, inLen, prevIntervalLen, written)
            if cf > 0 {
                for k in 0..<cf {
                    let progress = cf == 1 ? 1.0 : Double(k) / Double(cf - 1)
                    let (gOut, gIn) = Self.equalPowerGains(progress: progress)
                    let outIdx = written - cf + k
                    for ch in 0..<channelCount {
                        let blended = out[ch][outIdx] * Float(gOut) + source[ch][starts[i] + k] * Float(gIn)
                        out[ch][outIdx] = blended
                    }
                }
            }
            if starts[i] + cf < ends[i] { append((starts[i] + cf)..<ends[i]) }
            // Interval i's NEW frames occupy trimmed [written, written + newFrames); their source
            // is [starts[i]+cf, ends[i]). The cf head is the blend, attributed to the seam.
            let newFrames = max(0, inLen - cf)
            if newFrames > 0 {
                segments.append(RenderSegment(sourceStart: starts[i] + cf, sourceEnd: ends[i],
                                              trimmedStart: written, trimmedEnd: written + newFrames))
            }
            prevIntervalLen = inLen
        }

        let outFrames = out[0].count
        guard outFrames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(outFrames)),
              let dest = result.floatChannelData else {
            throw AudioIOError.allocationFailed
        }
        result.frameLength = AVAudioFrameCount(outFrames)
        for ch in 0..<channelCount {
            out[ch].withUnsafeBufferPointer { src in
                dest[ch].update(from: src.baseAddress!, count: outFrames)
            }
        }
        return RenderOutput(buffer: result, segments: segments)
    }

    /// QA aid (production WP13): a short file isolating just the splices. For each join it
    /// emits `contextSeconds` of the outgoing kept-silence tail, the same equal-power
    /// crossfade, then `contextSeconds` of the incoming speech onset, with a brief silent
    /// separator between joins — so any click is audible without speech masking it.
    /// Returns `nil` when there are no joins to audition.
    public func renderSpliceAudition(buffer: AVAudioPCMBuffer, regions: [SilenceRegion],
                                     contextSeconds: Double = 0.75) throws -> AVAudioPCMBuffer? {
        let sampleRate = buffer.format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard totalFrames > 0, let source = buffer.floatChannelData else { return nil }

        let plan = plan(regions: regions, totalFrames: totalFrames, sampleRate: sampleRate)
        guard !plan.joints.isEmpty else { return nil }

        let crossfadeFrames = max(1, Int((settings.crossfadeMs / 1000.0 * sampleRate).rounded()))
        let context = max(1, Int(contextSeconds * sampleRate))
        let separator = Int(0.25 * sampleRate)

        var out = [[Float]](repeating: [], count: channelCount)
        func append(_ range: Range<Int>) {
            guard range.lowerBound < range.upperBound else { return }
            for ch in 0..<channelCount {
                out[ch].append(contentsOf: UnsafeBufferPointer(start: source[ch] + range.lowerBound,
                                                               count: range.count))
            }
        }

        for (index, joint) in plan.joints.enumerated() {
            let outRange = max(0, joint.outCut - context)..<joint.outCut
            let inRange = joint.inResume..<min(totalFrames, joint.inResume + context)
            append(outRange)

            let written = out[0].count
            let cf = min(crossfadeFrames, outRange.count, inRange.count, written)
            for k in 0..<cf {
                let progress = cf == 1 ? 1.0 : Double(k) / Double(cf - 1)
                let (gOut, gIn) = Self.equalPowerGains(progress: progress)
                let outIdx = written - cf + k
                for ch in 0..<channelCount {
                    out[ch][outIdx] = out[ch][outIdx] * Float(gOut) + source[ch][inRange.lowerBound + k] * Float(gIn)
                }
            }
            append((inRange.lowerBound + cf)..<inRange.upperBound)

            if index < plan.joints.count - 1, separator > 0 {
                for ch in 0..<channelCount { out[ch].append(contentsOf: repeatElement(0, count: separator)) }
            }
        }

        let outFrames = out[0].count
        guard outFrames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(outFrames)),
              let dest = result.floatChannelData else {
            throw AudioIOError.allocationFailed
        }
        result.frameLength = AVAudioFrameCount(outFrames)
        for ch in 0..<channelCount {
            out[ch].withUnsafeBufferPointer { dest[ch].update(from: $0.baseAddress!, count: outFrames) }
        }
        return result
    }

    /// Nearest sample to `around` (within `±window`, clamped to `[lo, hi]` and the buffer)
    /// at a sign change. Returns `around` unchanged if no crossing is found.
    static func snapZeroCrossing(_ ref: [Float], around: Int, lo: Int, hi: Int,
                                 window: Int, total: Int) -> Int {
        let low = max(1, max(lo, around - window))
        let high = min(total - 1, min(hi, around + window))
        guard low <= high else { return around }
        var best = around
        var bestDistance = Int.max
        for j in low...high where ref[j - 1].sign != ref[j].sign || ref[j] == 0 {
            let distance = abs(j - around)
            if distance < bestDistance { bestDistance = distance; best = j }
        }
        return best
    }
}
