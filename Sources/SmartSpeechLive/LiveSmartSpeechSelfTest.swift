#if DEBUG
import AVFoundation
import Foundation
import SwiftData
import SmartSpeechKit

/// EXPLORATION MODULE — headless smoke test for the live SmartSpeech engine, triggered by the launch
/// argument `-livesmartspeechselftest`. Drives the engine against the bundled `Sample Chaptered.m4b`
/// fixture and prints whether audio actually flows: position advances, the silence meter increments,
/// seek lands, and pause/resume works. This is a real runtime check (build success alone proves
/// nothing for a cross-thread real-time audio engine), not a substitute for on-device by-ear QA.
@MainActor
enum LiveSmartSpeechSelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("-livesmartspeechselftest") }

    private static func log(_ s: String) { print("LIVESMARTSPEECH-SELFTEST: \(s)") }

    static func run() async {
        guard let url = bundledFixtureURL() else { log("FAIL: no bundled fixture found"); return }
        log("fixture: \(url.lastPathComponent)")

        let engine = LiveSmartSpeechEngine()
        engine.load(debugFileURL: url, preset: .default)
        guard engine.isLoaded else { log("FAIL: engine did not load (\(engine.status))"); return }
        log("loaded, sourceDuration=\(fmt(engine.sourceDuration))s")

        // 1. Audio flows + position advances.
        engine.play()
        try? await sleep(2.5)
        let posAfterPlay = engine.sourcePosition
        log(posAfterPlay > 0.3
            ? "PASS: position advanced to \(fmt(posAfterPlay))s, buffered=\(fmt(engine.bufferedAheadSeconds))s"
            : "FAIL: position did not advance (\(fmt(posAfterPlay))s) — no audio flow")

        // 2. Silence meter increments (trim on by default).
        try? await sleep(2.0)
        log("removedSoFar=\(fmt(engine.removedSoFar))s (\(pct(engine.removedSoFarPercent)))  projectedTotal=\(engine.projectedTotalSaved.map { fmt($0) + "s" } ?? "pending")")

        // 3. Pause/resume (the bug the advisor flagged): position must continue, not reset/jump.
        engine.pause()
        let posAtPause = engine.sourcePosition
        try? await sleep(0.6)
        engine.play()
        try? await sleep(2.0)
        let posAfterResume = engine.sourcePosition
        log(posAfterResume > posAtPause + 0.3 && posAfterResume < posAtPause + 6
            ? "PASS: resume continued from \(fmt(posAtPause))s → \(fmt(posAfterResume))s"
            : "FAIL: resume anomaly (pause=\(fmt(posAtPause))s resume=\(fmt(posAfterResume))s)")

        // 4. Seek lands.
        let target = min(30, engine.sourceDuration * 0.5)
        engine.seek(toSource: target)
        try? await sleep(2.0)
        let posAfterSeek = engine.sourcePosition
        log(abs(posAfterSeek - target) < 4
            ? "PASS: seek landed near \(fmt(target))s (at \(fmt(posAfterSeek))s)"
            : "FAIL: seek missed (target=\(fmt(target))s at=\(fmt(posAfterSeek))s)")

        engine.teardown()

        // Phase 2: synthetic file with KNOWN silence gaps — exercises the non-identity trim/map path
        // (the bundled fixture has no trimmable silence, so removedSoFar stayed 0 above).
        await runSynthetic()

        // Phase 3: DEEP SEEK on a long file — reproduces the user's "stuck after seeking a few
        // minutes ahead" report.
        await runDeepSeek()

        // Phase 4: MUSIC + NARRATION — diagnose the "strange cuts" the user hears when music plays
        // under the narrator. Analysis-only (no playback), prints the detector's internals.
        runMusicNarrationDiagnostic()

        // Phase 5: UNDER-TRIM — is the −50 dBFS ceiling too strict for a normal recording floor?
        runCeilingDiagnostic()

        // Phase 6: MULTI-FILE (WP2) — drive the real AudiobookPlayer through a 2-file MP3 book and
        // verify per-track playback + auto-advance at end-of-track.
        await runMultiFile()

        log("done")
    }

    /// WP2: import the bundled 2-MP3 fixture and drive `AudiobookPlayer` end-to-end: detect
    /// multi-file, play track 0, then confirm auto-advance to track 1 at end-of-track.
    @MainActor
    private static func runMultiFile() async {
        guard let src = bundledMP3FolderURL() else { log("MULTIFILE SKIP: fixture not found"); return }
        guard let root = try? ContainerPaths.mediaRoot() else { log("MULTIFILE FAIL: no media root"); return }
        let dest = root.appendingPathComponent("The Quick Brown Fox", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest) }
        catch { log("MULTIFILE FAIL: copy \(error.localizedDescription)"); return }
        defer { try? FileManager.default.removeItem(at: dest) }

        let book: Audiobook
        do { book = try await AudiobookImporter.makeAudiobook(fromLocal: dest) }
        catch { log("MULTIFILE FAIL: import \(error.localizedDescription)"); return }

        guard let container = try? ModelContainer(
            for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else {
            log("MULTIFILE FAIL: container"); return
        }
        let ctx = container.mainContext
        ctx.insert(book); try? ctx.save()

        let tracks = book.orderedTracks
        log("MULTIFILE: imported \(tracks.count) tracks; durs=\(tracks.map { Int($0.duration.rounded()) })s")
        guard tracks.count >= 2 else { log("MULTIFILE SKIP: need 2+ tracks"); return }

        let player = AudiobookPlayer()
        player.load(book, context: ctx)
        log(player.segmentCount == tracks.count && player.segmentNoun == "Track"
            ? "MULTIFILE PASS: detected multi-file (\(player.segmentCount) tracks)"
            : "MULTIFILE FAIL: not multi-file (segments=\(player.segmentCount) noun=\(player.segmentNoun))")

        player.play()
        try? await sleep(2.0)
        log(player.currentIndex == 0 && player.offsetInTrack > 0.4
            ? "MULTIFILE PASS: track 0 playing (offset \(fmt(player.offsetInTrack))s)"
            : "MULTIFILE FAIL: track 0 not advancing (idx=\(player.currentIndex) offset=\(fmt(player.offsetInTrack))s)")

        let dur0 = tracks[0].duration
        if dur0 > 1.5 {
            player.seekInTrack(to: dur0 - 1.0)   // near end of track 0
            try? await sleep(4.0)
            log(player.currentIndex == 1
                ? "MULTIFILE PASS: auto-advanced to track 1 (offset \(fmt(player.offsetInTrack))s, playing=\(player.isPlaying))"
                : "MULTIFILE FAIL: did not advance to track 1 (idx=\(player.currentIndex))")
        } else {
            log("MULTIFILE SKIP: track 0 too short to test advance (\(fmt(dur0))s)")
        }

        player.teardown()
    }

    private static func bundledMP3FolderURL() -> URL? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let u = base.appendingPathComponent("SampleLibrary/Audiobooks/The Quick Brown Fox", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Why do overlapping music + narration produce strange cuts? Build a file with a CONTINUOUS
    /// music bed (never silent) plus louder narration bursts with gaps (music keeps playing in the
    /// gaps). A human wants NONE of it trimmed — the music is unbroken. Print what the energy
    /// detector actually flags, and its adaptive floor/speech/threshold, under whole-file analysis
    /// vs the live producer's per-12s-chunk analysis.
    private static func runMusicNarrationDiagnostic() {
        let sr = 44_100.0

        // Realistic score: a music bed that swells and dips (like a real soundtrack) but is NEVER
        // truly silent — it bottoms out around −32 dBFS. This is the case the user reported.
        guard let music = makeMusicNarrationFile(seconds: 36, sr: sr, musicAmp: 0.14, dynamic: true) else {
            log("MUSIC FAIL: no file"); return
        }
        defer { try? FileManager.default.removeItem(at: music) }
        let ceiling = SmartSpeechSettings().absoluteSilenceCeilingDb

        // End-to-end through the pre-scan — the SAME detection the live producer uses (global floor
        // A + absolute ceiling B). A continuous music bed should now trim ~nothing.
        if let r = try? LiveSilencePrescan.analyze(url: music, cutPoints: [0], preset: .aggressive) {
            log("MUSIC realistic-bed: globalFloor=\(fmt(r.globalFloorDb))dB ceiling=\(fmt(ceiling))dB → projected(aggressive)=\(fmt(r.projectedSavedSeconds))s regions=\(r.regionCount)")
            log(r.projectedSavedSeconds < 0.6
                ? "MUSIC PASS: continuous music bed under narration is NOT cut (A+B)"
                : "MUSIC FAIL: music bed still trimmed \(fmt(r.projectedSavedSeconds))s")

            // Fix A illustration: per-chunk region counts with the OLD chunk-local floor vs the new
            // global floor. Global should be at least as stable/conservative.
            let settings = SmartSpeechSettings(preset: .aggressive)
            var local = 0, global = 0, start = 0.0
            while start < 36 {
                let end = min(start + 12, 36)
                if let chunk = try? AudioIO.decode(music, startSeconds: start, durationSeconds: end - start, maxSeconds: 20) {
                    let profile = SilenceAnalyzer.profile(monoSamples: AudioIO.downmixToMono(chunk), sampleRate: sr)
                    local += SilenceAnalyzer(settings: settings).regions(from: profile).count
                    global += SilenceAnalyzer(settings: settings).regions(from: profile, floorOverrideDb: r.globalFloorDb, speechOverrideDb: nil).count
                }
                start = end
            }
            log("MUSIC per-chunk regions on realistic bed: localFloor=\(local) globalFloor(FixA)=\(global)")
        }

        // Control: genuine silence (tone bursts with TRUE silent gaps) must STILL be trimmed — the
        // fix must not over-suppress real dead air.
        if let sil = makeSyntheticSilenceFile(seconds: 24) {
            defer { try? FileManager.default.removeItem(at: sil) }
            if let r = try? LiveSilencePrescan.analyze(url: sil, cutPoints: [0], preset: .aggressive) {
                log(r.projectedSavedSeconds > 3
                    ? "MUSIC CONTROL PASS: genuine silence still trimmed (\(fmt(r.projectedSavedSeconds))s)"
                    : "MUSIC CONTROL FAIL: real silence no longer trimmed (\(fmt(r.projectedSavedSeconds))s)")
            }
        }
    }

    /// Is the −50 dBFS silence ceiling the reason trimming nearly stopped? Build a normal recording:
    /// narration bursts over a continuous ROOM-TONE floor at −45 dBFS (above −50), with real pauses
    /// (narrator silent, only room tone). Sweep the ceiling and show trimming vanishes at −50 but
    /// returns once the ceiling is relaxed — and confirm the live pre-scan (which now uses the
    /// relaxed live ceiling) trims it.
    private static func runCeilingDiagnostic() {
        let sr = 44_100.0
        guard let room = makeRoomToneNarration(seconds: 30, sr: sr, floorDbfs: -45) else { log("CEIL FAIL: no file"); return }
        defer { try? FileManager.default.removeItem(at: room) }

        guard let buf = try? AudioIO.decode(room, maxSeconds: 120) else { return }
        let profile = SilenceAnalyzer.profile(monoSamples: AudioIO.downmixToMono(buf), sampleRate: sr)
        let s = SmartSpeechSettings(preset: .aggressive)
        log("CEIL room-tone floor=\(fmt(profile.noiseFloorDb))dB speech=\(fmt(profile.speechLevelDb))dB")
        for ceil in [-50.0, -40.0, -30.0, LiveSmartSpeechTuning.silenceCeilingDb] {
            var cfg = s; cfg.absoluteSilenceCeilingDb = ceil
            let regions = SilenceAnalyzer(settings: cfg).regions(from: profile)
            let trimmed = regions.reduce(0.0) { $0 + ($1.duration - SilencePolicy.target(forSilenceDuration: $1.duration, settings: cfg)) }
            log("CEIL ceiling=\(fmt(ceil))dB → regions=\(regions.count) trimmed=\(fmt(trimmed))s")
        }

        // End-to-end: the live pre-scan (now using the relaxed live ceiling + global floor) should trim.
        if let r = try? LiveSilencePrescan.analyze(url: room, cutPoints: [0], preset: .aggressive) {
            log(r.projectedSavedSeconds > 1
                ? "CEIL PASS: live pre-scan trims normal recording (\(fmt(r.projectedSavedSeconds))s, floor=\(fmt(r.globalFloorDb))dB, liveCeiling=\(fmt(LiveSmartSpeechTuning.silenceCeilingDb))dB)"
                : "CEIL FAIL: live pre-scan still under-trims (\(fmt(r.projectedSavedSeconds))s)")
        }
    }

    /// Narration bursts over a CONTINUOUS room-tone floor at `floorDbfs` (a realistic recording noise
    /// floor). The "pauses" are room tone only — genuine silence a listener wants trimmed, but sitting
    /// above a strict −50 dBFS ceiling.
    private static func makeRoomToneNarration(seconds: Int, sr: Double, floorDbfs: Double) -> URL? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }
        let total = AVAudioFrameCount(Double(seconds) * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = total
        let floorAmp = Float(pow(10.0, floorDbfs / 20.0) * 2.0.squareRoot())   // sine amp for target RMS
        let onFrames = Int(1.4 * sr), offFrames = Int(0.9 * sr)
        let cycle = onFrames + offFrames
        for i in 0..<Int(total) {
            let t = Float(i) / Float(sr)
            let roomTone = floorAmp * sinf(2 * .pi * 196 * t)                  // continuous recording floor
            let narration = (i % cycle) < onFrames ? 0.30 * sinf(2 * .pi * 320 * t) : 0
            ch[0][i] = roomTone + narration
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("livecadence-roomtone.wav")
        try? FileManager.default.removeItem(at: url)
        do { try AudioIO.writeWAV(buffer, to: url); return url } catch { return nil }
    }

    /// Continuous 196 Hz music bed + narration bursts (amp 0.34, 1.4 s on / 0.9 s off). During the
    /// "off" gaps only the music plays — nothing should be trimmed. `dynamic` makes the bed swell/dip
    /// with a 0.25 Hz envelope but keep it above ~30% amplitude, so it's quiet-but-never-silent, like
    /// a real score (as opposed to a synthetic gap that hits true digital silence).
    private static func makeMusicNarrationFile(seconds: Int, sr: Double, musicAmp: Float = 0.06,
                                               fileName: String = "livecadence-music.wav",
                                               dynamic: Bool = false) -> URL? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }
        let total = AVAudioFrameCount(Double(seconds) * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = total
        let onFrames = Int(1.4 * sr), offFrames = Int(0.9 * sr)
        let cycle = onFrames + offFrames
        for i in 0..<Int(total) {
            let t = Float(i) / Float(sr)
            let env: Float = dynamic ? (0.65 + 0.35 * sinf(2 * .pi * 0.25 * t)) : 1  // 0.30…1.0, never 0
            let music = musicAmp * env * sinf(2 * .pi * 196 * t)
            let speaking = (i % cycle) < onFrames
            let narration = speaking ? 0.34 * sinf(2 * .pi * 320 * t) : 0
            ch[0][i] = music + narration
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        do { try AudioIO.writeWAV(buffer, to: url); return url } catch { return nil }
    }

    /// Reproduce the reported hang: a long file, play briefly, seek a few minutes ahead, and verify
    /// playback actually resumes (position advances past the seek target) instead of stalling.
    private static func runDeepSeek() async {
        guard let url = makeSyntheticSilenceFile(seconds: 240) else { log("DEEPSEEK FAIL: no file"); return }
        let engine = LiveSmartSpeechEngine()
        engine.load(debugFileURL: url, preset: .default)
        guard engine.isLoaded else { log("DEEPSEEK FAIL: not loaded"); return }
        log("DEEPSEEK: duration=\(fmt(engine.sourceDuration))s; playing then seeking to 120s")

        engine.play()
        try? await sleep(2.0)
        let before = engine.sourcePosition
        log("DEEPSEEK: pos before seek=\(fmt(before))s")

        engine.seek(toSource: 120)
        try? await sleep(4.0)
        let after = engine.sourcePosition
        log(after > 121 && after < 135
            ? "DEEPSEEK PASS: resumed and advanced to \(fmt(after))s after seeking to 120s"
            : "DEEPSEEK FAIL/STUCK: pos=\(fmt(after))s after seek to 120s (buffered=\(fmt(engine.bufferedAheadSeconds))s, status=\(engine.status))")
        engine.teardown()
        try? FileManager.default.removeItem(at: url)
    }

    /// Build a tone/silence file, run it through the live engine, and confirm the silence meter
    /// reports a real non-zero number (the point of the whole spike, per the quantified-confirmation
    /// requirement) and that the source↔output map is non-identity (source outruns output).
    private static func runSynthetic() async {
        guard let url = makeSyntheticSilenceFile() else { log("SYNTH FAIL: could not write file"); return }
        let engine = LiveSmartSpeechEngine()
        engine.load(debugFileURL: url, preset: .aggressive)
        guard engine.isLoaded else { log("SYNTH FAIL: not loaded"); return }

        // Wait for the async pre-scan to land.
        for _ in 0..<20 {
            if engine.projectedTotalSaved != nil { break }
            try? await sleep(0.15)
        }
        let projected = engine.projectedTotalSaved ?? 0
        log(projected > 0.5
            ? "SYNTH PASS: pre-scan projected \(fmt(projected))s of \(fmt(engine.sourceDuration))s trimmable"
            : "SYNTH FAIL: pre-scan found no trimmable silence (\(fmt(projected))s)")

        engine.play()
        try? await sleep(5.0)
        log(engine.removedSoFar > 0.2
            ? "SYNTH PASS: meter incremented — removedSoFar=\(fmt(engine.removedSoFar))s at pos \(fmt(engine.sourcePosition))s (map non-identity: source outran output)"
            : "SYNTH FAIL: meter did not increment (removedSoFar=\(fmt(engine.removedSoFar))s)")
        engine.teardown()
        try? FileManager.default.removeItem(at: url)
    }

    /// 24 s mono @ 44.1 kHz: 2 s of tone then 2 s of near-silence, repeated. The 2 s gaps are far
    /// above `minSilenceDuration`, so every tier trims them hard.
    private static func makeSyntheticSilenceFile(seconds: Int = 24) -> URL? {
        let sr = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }
        let total = AVAudioFrameCount(Double(seconds) * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = total
        let block = Int(2.0 * sr)   // 2 s tone / 2 s silence blocks
        for i in 0..<Int(total) {
            let inTone = (i / block) % 2 == 0
            ch[0][i] = inTone ? 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sr)) : 0.0
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("livecadence-synth.wav")
        try? FileManager.default.removeItem(at: url)
        do { try AudioIO.writeWAV(buffer, to: url); return url } catch { return nil }
    }

    private static func bundledFixtureURL() -> URL? {
        // SampleLibrary is bundled as a folder reference; find the chaptered m4b.
        if let u = Bundle.main.url(forResource: "Sample Chaptered", withExtension: "m4b",
                                   subdirectory: "SampleLibrary/Audiobooks") { return u }
        if let u = Bundle.main.url(forResource: "Sample Chaptered", withExtension: "m4b") { return u }
        // Fallback: search the bundle.
        if let base = Bundle.main.resourceURL,
           let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension == "m4b" { return f }
        }
        return nil
    }

    private static func sleep(_ s: Double) async throws { try await Task.sleep(for: .seconds(s)) }
    private static func fmt(_ t: Double) -> String { String(format: "%.2f", t) }
    private static func pct(_ p: Double) -> String { String(format: "%.0f%%", p * 100) }
}
#endif
