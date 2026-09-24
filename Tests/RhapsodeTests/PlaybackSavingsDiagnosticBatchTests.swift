import Testing
@testable import Rhapsode

@Suite("Playback savings diagnostic batching")
struct PlaybackSavingsDiagnosticBatchTests {
    @Test("short sessions flush their bounded actually-listened batch")
    func shortSessionFlushesAndResets() {
        var batch = PlaybackSavingsDiagnosticBatch(interval: 30)

        #expect(batch.record(listenedSeconds: 8, savedSeconds: 1.25) == nil)

        let snapshot = batch.flush()
        #expect(snapshot?.listenedSeconds == 8)
        #expect(snapshot?.savedSeconds == 1.25)
        #expect(snapshot?.formatted == "playback_saved listened_s=8 saved_s=1.25")
        #expect(batch.flush() == nil)
    }

    @Test("full batches do not attribute unclassified savings to pauses or music")
    func fullBatchIsUnclassified() {
        var batch = PlaybackSavingsDiagnosticBatch(interval: 30)

        #expect(batch.record(listenedSeconds: 12, savedSeconds: 0.5) == nil)
        let snapshot = batch.record(listenedSeconds: 18, savedSeconds: 1.5)

        #expect(snapshot?.listenedSeconds == 30)
        #expect(snapshot?.savedSeconds == 2)
        #expect(snapshot?.formatted == "playback_saved listened_s=30 saved_s=2")
        #expect(batch.flush() == nil)
    }
}
