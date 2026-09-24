import AVFoundation
import Foundation

final class RubberBandStream {
    struct PushProgress: Equatable, Sendable {
        let playbackRate: Double
        let inputFrames: Int
        let outputFrames: Int
        let targetOutputFrames: Int
        let cumulativeInputFrames: Int
        let cumulativeOutputFrames: Int
        let cumulativeTargetOutputFrames: Int

        /// Rubber Band can emit output later than the input push that caused it.
        /// These frame totals are independent counters, not an exact timeline pair.
        var mappingIsEstimated: Bool { true }
    }

    enum StreamError: Error {
        case unavailable
        case invalidConfiguration
        case unsupportedBufferFormat
        case channelCountMismatch
        case alreadyFinished
        case failed(String)
    }

    let sampleRate: Double
    let channelCount: Int
    let playbackRate: Double
    private(set) var pushProgress: [PushProgress] = []
    private(set) var discardedTailPaddingFrames = 0
    private var cumulativeInputFrames = 0
    private var cumulativeOutputFrames = 0
    private var cumulativeTargetOutputFrames = 0
    private var cumulativeTargetOutputFrameBudget = 0.0
    private var currentPlaybackRate: Double
    private var pendingOutput = [[Float]]()

    private var maximumPendingFrames: Int { max(65_536, Int(sampleRate * 2)) }

#if PERSONAL_RUBBERBAND
    private let adapter: RubberBandR3Adapter
#endif

    init(sampleRate: Double, channelCount: Int, playbackRate: Double) throws {
        guard sampleRate.isFinite, (8_000 ... 192_000).contains(sampleRate),
              channelCount > 0, channelCount <= Int(UInt32.max),
              playbackRate.isFinite, playbackRate > 0 else {
            throw StreamError.invalidConfiguration
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.playbackRate = playbackRate
        currentPlaybackRate = playbackRate

#if PERSONAL_RUBBERBAND
        adapter = try RubberBandR3Adapter(
            sampleRate: sampleRate,
            channelCount: channelCount,
            playbackRate: playbackRate
        )
#else
        throw StreamError.unavailable
#endif
    }

    func process(_ samples: [Float]) throws -> [Float] {
        guard channelCount == 1 else { throw StreamError.channelCountMismatch }
        guard samples.count <= Int(UInt32.max) else { throw StreamError.invalidConfiguration }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let input = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(1, samples.count))
        ) else {
            throw StreamError.failed("Could not allocate mono input buffer")
        }

        input.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty, let channel = input.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }

        let output = try process(input)
        guard let channel = output.floatChannelData?[0] else {
            throw StreamError.failed("Output buffer did not expose Float32 samples")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Process calls and `finishBuffer` must be serialized on the producer queue.
    /// The one-argument overload retains the stream's initial fixed playback rate.
    func process(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try process(buffer, playbackRate: playbackRate)
    }

    func process(_ buffer: AVAudioPCMBuffer, playbackRate: Double) throws -> AVAudioPCMBuffer {
#if PERSONAL_RUBBERBAND
        guard !adapter.isFinished else { throw StreamError.alreadyFinished }
        guard playbackRate.isFinite, playbackRate > 0 else {
            throw StreamError.invalidConfiguration
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              abs(buffer.format.sampleRate - sampleRate) < 0.5,
              Int(buffer.format.channelCount) == channelCount,
              buffer.floatChannelData != nil else {
            throw StreamError.unsupportedBufferFormat
        }

        let inputFrames = Int(buffer.frameLength)
        let nextTargetBudget = cumulativeTargetOutputFrameBudget
            + Double(inputFrames) / playbackRate
        guard nextTargetBudget.isFinite, nextTargetBudget < Double(Int.max) else {
            throw StreamError.invalidConfiguration
        }
        let nextTargetOutputFrames = Int(nextTargetBudget.rounded(.down))
        let targetOutputFrames = nextTargetOutputFrames - cumulativeTargetOutputFrames
        var outputChannels = Array(repeating: [Float](), count: channelCount)
        try adapter.setPlaybackRate(playbackRate)
        if inputFrames > 0 {
            try adapter.process(
                input: buffer.floatChannelData!,
                frameCount: inputFrames,
                output: &outputChannels
            )
        }
        cumulativeInputFrames += inputFrames
        currentPlaybackRate = playbackRate
        cumulativeTargetOutputFrameBudget = nextTargetBudget
        cumulativeTargetOutputFrames = nextTargetOutputFrames
        appendPending(outputChannels)
        let availableOutputFrames = max(0, cumulativeTargetOutputFrames - cumulativeOutputFrames)
        let output = try makeBuffer(
            channels: releasePending(maximumFrames: availableOutputFrames),
            format: buffer.format
        )
        cumulativeOutputFrames += Int(output.frameLength)
        guard (pendingOutput.first?.count ?? 0) <= maximumPendingFrames else {
            throw StreamError.failed("Rubber Band output exceeded the bounded pending-frame budget")
        }
        pushProgress.append(
            PushProgress(
                playbackRate: currentPlaybackRate,
                inputFrames: inputFrames,
                outputFrames: Int(output.frameLength),
                targetOutputFrames: targetOutputFrames,
                cumulativeInputFrames: cumulativeInputFrames,
                cumulativeOutputFrames: cumulativeOutputFrames,
                cumulativeTargetOutputFrames: cumulativeTargetOutputFrames
            )
        )
        return output
#else
        throw StreamError.unavailable
#endif
    }

    func finish() throws -> [Float] {
        guard channelCount == 1 else { throw StreamError.channelCountMismatch }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let tail = try finishBuffer(format: format)
        guard let channel = tail.floatChannelData?[0] else {
            throw StreamError.failed("Tail buffer did not expose Float32 samples")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(tail.frameLength)))
    }

    func finishBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
#if PERSONAL_RUBBERBAND
        guard !adapter.isFinished else { throw StreamError.alreadyFinished }
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              abs(format.sampleRate - sampleRate) < 0.5,
              Int(format.channelCount) == channelCount else {
            throw StreamError.unsupportedBufferFormat
        }

        appendPending(try adapter.finish())
        let expectedOutputFrames = Int(cumulativeTargetOutputFrameBudget.rounded())
        let remainingExpectedFrames = max(0, expectedOutputFrames - cumulativeOutputFrames)
        let pendingFrames = pendingOutput.first?.count ?? 0
        guard pendingFrames >= remainingExpectedFrames else {
            throw StreamError.failed(
                "Rubber Band duration mismatch: drained \(pendingFrames) tail frames; "
                    + "\(remainingExpectedFrames) were required"
            )
        }
        let tail = try makeBuffer(
            channels: releasePending(maximumFrames: remainingExpectedFrames),
            format: format
        )
        discardedTailPaddingFrames = pendingOutput.first?.count ?? 0
        pendingOutput = Array(repeating: [], count: channelCount)
        cumulativeOutputFrames += Int(tail.frameLength)
        let tailTargetFrames = expectedOutputFrames - cumulativeTargetOutputFrames
        cumulativeTargetOutputFrames = expectedOutputFrames
        pushProgress.append(
            PushProgress(
                playbackRate: currentPlaybackRate,
                inputFrames: 0,
                outputFrames: Int(tail.frameLength),
                targetOutputFrames: tailTargetFrames,
                cumulativeInputFrames: cumulativeInputFrames,
                cumulativeOutputFrames: cumulativeOutputFrames,
                cumulativeTargetOutputFrames: cumulativeTargetOutputFrames
            )
        )
        return tail
#else
        throw StreamError.unavailable
#endif
    }

    private func makeBuffer(channels: [[Float]], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = channels.first?.count ?? 0
        guard channels.count == channelCount,
              channels.allSatisfy({ $0.count == frameCount }),
              frameCount <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(1, frameCount))
              ),
              let channelData = buffer.floatChannelData else {
            throw StreamError.failed("Could not allocate output buffer")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channelIndex in 0 ..< channelCount where frameCount > 0 {
            channels[channelIndex].withUnsafeBufferPointer { source in
                channelData[channelIndex].update(from: source.baseAddress!, count: frameCount)
            }
        }
        return buffer
    }

    private func appendPending(_ channels: [[Float]]) {
        if pendingOutput.isEmpty {
            pendingOutput = Array(repeating: [], count: channelCount)
        }
        for channelIndex in 0 ..< channelCount {
            pendingOutput[channelIndex].append(contentsOf: channels[channelIndex])
        }
    }

    private func releasePending(maximumFrames: Int) -> [[Float]] {
        let availableFrames = pendingOutput.first?.count ?? 0
        let frameCount = min(maximumFrames, availableFrames)
        let released = pendingOutput.map { Array($0.prefix(frameCount)) }
        pendingOutput = pendingOutput.map { Array($0.dropFirst(frameCount)) }
        return released
    }
}

#if PERSONAL_RUBBERBAND
private final class RubberBandR3Adapter {
    private typealias State = OpaquePointer

    private let state: State
    private let sampleRate: Double
    private let channelCount: Int
    private var startDelayRemaining: Int
    private(set) var isFinished = false
    private var discardedOutput: [[Float]]

    init(sampleRate: Double, channelCount: Int, playbackRate: Double) throws {
        let processRealTime: Int32 = 0x00000001
        let engineFinerR3: Int32 = 0x20000000
        let channelsTogether: Int32 = 0x10000000
        let options = processRealTime | engineFinerR3 | channelsTogether
        guard let state = rubberband_new(
            UInt32(sampleRate.rounded()),
            UInt32(channelCount),
            options,
            1 / playbackRate,
            1
        ) else {
            throw RubberBandStream.StreamError.failed("Rubber Band could not create an R3 stretcher")
        }

        guard rubberband_get_engine_version(state) == 3 else {
            rubberband_delete(state)
            throw RubberBandStream.StreamError.failed("Rubber Band R3 engine is unavailable")
        }

        self.state = state
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        discardedOutput = Array(repeating: [], count: channelCount)
        startDelayRemaining = Int(rubberband_get_start_delay(state))
        let startPadding = Int(rubberband_get_preferred_start_pad(state))
        if startPadding > 0 {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            )!
            guard let silence = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(startPadding)
            ), let channels = silence.floatChannelData else {
                rubberband_delete(state)
                throw RubberBandStream.StreamError.failed("Could not allocate start-padding buffer")
            }
            silence.frameLength = AVAudioFrameCount(startPadding)
            for channelIndex in 0 ..< channelCount {
                for frame in 0 ..< startPadding {
                    channels[channelIndex][frame] = 0
                }
            }
            try process(input: channels, frameCount: startPadding, output: &discardedOutput)
        }
    }

    deinit {
        rubberband_delete(state)
    }

    func process(
        input: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        output: inout [[Float]]
    ) throws {
        guard !isFinished else { throw RubberBandStream.StreamError.alreadyFinished }
        let chunkFrames = 16_384
        var offset = 0
        while offset < frameCount {
            let count = min(chunkFrames, frameCount - offset)
            let pointers: [UnsafePointer<Float>?] = (0 ..< channelCount).map {
                UnsafePointer(input[$0].advanced(by: offset))
            }
            pointers.withUnsafeBufferPointer { inputPointers in
                rubberband_process(state, inputPointers.baseAddress, UInt32(count), 0)
            }
            try drain(output: &output)
            offset += count
        }
    }

    func setPlaybackRate(_ playbackRate: Double) throws {
        guard !isFinished else { throw RubberBandStream.StreamError.alreadyFinished }
        rubberband_set_time_ratio(state, 1 / playbackRate)
    }

    func finish() throws -> [[Float]] {
        guard !isFinished else { throw RubberBandStream.StreamError.alreadyFinished }
        isFinished = true
        rubberband_process(state, nil, 0, 1)
        var output = Array(repeating: [Float](), count: channelCount)
        try drain(output: &output)
        return output
    }

    private func drain(output: inout [[Float]]) throws {
        while true {
            let available = Int(rubberband_available(state))
            guard available > 0 else { return }
            let count = min(available, 16_384)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            )!
            guard let block = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channels = block.floatChannelData else {
                throw RubberBandStream.StreamError.failed("Could not allocate Rubber Band output block")
            }
            let pointers: [UnsafeMutablePointer<Float>?] = (0 ..< channelCount).map {
                channels[$0]
            }
            let retrieved = pointers.withUnsafeBufferPointer {
                rubberband_retrieve(state, $0.baseAddress, UInt32(count))
            }
            guard retrieved > 0 else {
                throw RubberBandStream.StreamError.failed("Rubber Band reported output but returned no frames")
            }
            let dropped = min(startDelayRemaining, Int(retrieved))
            startDelayRemaining -= dropped
            let kept = Int(retrieved) - dropped
            for channelIndex in 0 ..< channelCount where kept > 0 {
                output[channelIndex].append(
                    contentsOf: UnsafeBufferPointer(
                        start: channels[channelIndex].advanced(by: dropped),
                        count: kept
                    )
                )
            }
        }
    }
}

@_silgen_name("rubberband_new")
private func rubberband_new(
    _ sampleRate: UInt32,
    _ channelCount: UInt32,
    _ options: Int32,
    _ initialTimeRatio: Double,
    _ initialPitchScale: Double
) -> OpaquePointer?

@_silgen_name("rubberband_delete")
private func rubberband_delete(_ state: OpaquePointer)

@_silgen_name("rubberband_get_engine_version")
private func rubberband_get_engine_version(_ state: OpaquePointer) -> Int32

@_silgen_name("rubberband_get_preferred_start_pad")
private func rubberband_get_preferred_start_pad(_ state: OpaquePointer) -> UInt32

@_silgen_name("rubberband_get_start_delay")
private func rubberband_get_start_delay(_ state: OpaquePointer) -> UInt32

@_silgen_name("rubberband_set_time_ratio")
private func rubberband_set_time_ratio(_ state: OpaquePointer, _ ratio: Double)

@_silgen_name("rubberband_process")
private func rubberband_process(
    _ state: OpaquePointer,
    _ input: UnsafePointer<UnsafePointer<Float>?>?,
    _ frameCount: UInt32,
    _ final: Int32
)

@_silgen_name("rubberband_available")
private func rubberband_available(_ state: OpaquePointer) -> Int32

@_silgen_name("rubberband_retrieve")
private func rubberband_retrieve(
    _ state: OpaquePointer,
    _ output: UnsafePointer<UnsafeMutablePointer<Float>?>?,
    _ frameCount: UInt32
) -> UInt32
#endif
