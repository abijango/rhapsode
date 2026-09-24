import Testing
@testable import Rhapsode

@Suite("SmartSpeech diagnostic contract")
struct SmartSpeechDiagnosticContractTests {
    @Test("cancelled prescan exposes deterministic numeric coverage and fixed fallback")
    func formatsCancelledPrescanWithoutContent() {
        let event = SmartSpeechDiagnosticEvent.prescan(
            status: .cancelled,
            analyzedSeconds: 12.5,
            sourceSeconds: 60,
            fallback: .rolling
        )

        #expect(event.coverage == 12.5 / 60)
        #expect(event.formatted == "prescan status=cancelled analyzed_s=12.5 source_s=60 coverage=0.208 fallback=rolling")
    }

    @Test("producer event distinguishes candidates, realized edits, mode, and low-ahead")
    func formatsProducerMetrics() {
        let event = SmartSpeechDiagnosticEvent.producer(
            mode: .rollingFallback,
            candidatePauseSeconds: 9,
            candidateMusicSeconds: 3,
            realizedPauseSeconds: 7.5,
            realizedMusicSeconds: 2.25,
            lowAhead: true
        )

        #expect(event.formatted == "producer mode=rolling_fallback candidate_pause_s=9 candidate_music_s=3 realized_pause_s=7.5 realized_music_s=2.25 low_ahead=1")
    }

    @Test("session summary is bounded while playback-only removals aggregate")
    func boundsSummaryAndCountsPlaybackRemovalsOnly() {
        var summary = SmartSpeechDiagnosticSummary(capacity: 2)
        summary.record(.prescan(
            status: .cancelled,
            analyzedSeconds: 12.5,
            sourceSeconds: 60,
            fallback: .rolling
        ))
        summary.record(.prescan(
            status: .completed,
            analyzedSeconds: 60,
            sourceSeconds: 60,
            fallback: .none
        ))
        summary.record(.producer(
            mode: .mapped,
            candidatePauseSeconds: 8,
            candidateMusicSeconds: 0,
            realizedPauseSeconds: 7,
            realizedMusicSeconds: 0,
            lowAhead: false
        ))

        #expect(summary.realizedRemovedSeconds(for: .pause) == 0)
        #expect(summary.cancelledPrescanCount == 1)
        #expect(summary.cancelledPrescanAnalyzedSeconds == 12.5)
        summary.record(.playbackRemoval(kind: .pause, seconds: 0.75))
        summary.record(.playbackRemoval(kind: .pause, seconds: 0.25))

        #expect(summary.events.count == 2)
        #expect(summary.droppedEventCount == 3)
        #expect(summary.realizedRemovedSeconds(for: .pause) == 1)
        #expect(summary.realizedRemovedSeconds(for: .music) == 0)
    }
}
