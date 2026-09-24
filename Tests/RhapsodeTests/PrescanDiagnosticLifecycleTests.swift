import Testing
@testable import Rhapsode

@Suite("Prescan diagnostic lifecycle")
struct PrescanDiagnosticLifecycleTests {
    @Test("worker completion is withheld until the result is accepted")
    func completionRequiresAcceptance() {
        var lifecycle = PrescanDiagnosticLifecycle()

        let started = lifecycle.recordWorkerStatus(.started, analyzedSeconds: 0, sourceSeconds: 60)
        let workerCompletion = lifecycle.recordWorkerStatus(.completed, analyzedSeconds: 60, sourceSeconds: 60)
        let accepted = lifecycle.acceptCompletion(sourceSeconds: 60)

        #expect(started?.formatted == "prescan status=started analyzed_s=0 source_s=60 coverage=0.000 fallback=rolling")
        #expect(workerCompletion == nil)
        #expect(accepted?.formatted == "prescan status=completed analyzed_s=60 source_s=60 coverage=1.000 fallback=none")
    }

    @Test("discarded results end as cancelled with their last observed coverage")
    func rejectedResultIsCancelled() {
        var lifecycle = PrescanDiagnosticLifecycle()

        _ = lifecycle.recordWorkerStatus(.progress, analyzedSeconds: 12.5, sourceSeconds: 60)
        let cancelled = lifecycle.cancelIfNeeded()

        #expect(cancelled?.formatted == "prescan status=cancelled analyzed_s=12.5 source_s=60 coverage=0.208 fallback=rolling")
        #expect(lifecycle.acceptCompletion(sourceSeconds: 60) == nil)
    }
}
