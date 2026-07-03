import AVFoundation
import Foundation
import CadenceKit

/// EXPLORATION MODULE — resolves an `Audiobook` into the single downloaded source file the live
/// engine plays, plus its chapter cut points (for chunk alignment) and tier. Deliberately narrow:
/// the spike plays ONE source file (§ deferred: multi-file gapless). For a single-file `.m4b` that
/// is the whole book; for a multi-file (MP3 folder) book it is the first track only, which is an
/// accepted spike limitation surfaced in the UI.
struct LiveCadenceSource {
    let url: URL
    let sourceDuration: TimeInterval
    /// Chapter starts in source seconds (ascending, leading 0). Used to align chunk seams to
    /// natural pauses, matching the pre-render renderer.
    let cutPoints: [TimeInterval]
    let titles: [String]
    let preset: CadenceSettings.Preset
    let isMultiFile: Bool

    /// Build from a book, using the tier it *would* use if enabled (per-book override or global
    /// default). Returns nil if the book has no tracks or the file can't be resolved.
    init?(book: Audiobook) {
        let tracks = book.orderedTracks
        guard let first = tracks.first else { return nil }
        guard let url = try? ContainerPaths.url(forRelativePath: first.fileRelPath) else { return nil }
        self.url = url
        self.preset = book.effectiveCadenceTier

        // Single-file when every track shares one file (M4B with chapter metadata).
        let singleFile = tracks.count > 1 && tracks.allSatisfy { $0.fileRelPath == first.fileRelPath }
        self.isMultiFile = !singleFile && tracks.count > 1

        if singleFile {
            // Chapter prefix-sums as cut points; whole file duration.
            var acc: TimeInterval = 0
            var cps: [TimeInterval] = []
            var tts: [String] = []
            for t in tracks {
                cps.append(acc)
                tts.append(t.title)
                acc += t.duration
            }
            self.cutPoints = cps
            self.titles = tts
            self.sourceDuration = acc > 0 ? acc : first.duration
        } else {
            // Multi-file (or genuinely single-track): play just the first file, no chapter seams.
            self.cutPoints = [0]
            self.titles = [first.title]
            self.sourceDuration = first.duration
        }
    }

    #if DEBUG
    /// Debug: build from a raw file URL (bundled fixture / smoke test), bypassing SwiftData.
    /// Single chunk-run (no chapter seams); duration probed from the file.
    init?(debugFileURL url: URL, preset: CadenceSettings.Preset) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.url = url
        self.preset = preset
        self.sourceDuration = Double(file.length) / file.processingFormat.sampleRate
        self.cutPoints = [0]
        self.titles = [url.deletingPathExtension().lastPathComponent]
        self.isMultiFile = false
    }
    #endif
}
