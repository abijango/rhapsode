import Foundation
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

/// Bug 7 fix: `AudiobookPlayer.handleInterruption` delegates the resume decision to this pure
/// gate so it is testable without AVAudioSession/AVAudioEngine.
@Suite("Interruption resume gate")
struct InterruptionResumeGateTests {
    @Test("resumes only when playing at began and the system offers shouldResume")
    func resumesWhenPlayingAndOffered() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: true)
        #expect(gate.ended(shouldResume: true) == true)
    }

    @Test("does not resume when not playing when the interruption began")
    func doesNotResumeWhenNotPlaying() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: false)
        #expect(gate.ended(shouldResume: true) == false)
    }

    @Test("does not resume without the shouldResume option")
    func doesNotResumeWithoutOption() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: true)
        #expect(gate.ended(shouldResume: false) == false)
    }

    @Test("an explicit pause during the interruption cancels the resume")
    func explicitPauseCancelsResume() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: true)
        gate.disarm()   // pause() called for any other reason while interrupted
        #expect(gate.ended(shouldResume: true) == false)
    }

    @Test("the route disappearing mid-interruption cancels the resume, even if replaced")
    func routeLossCancelsResume() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: true)
        gate.routeLost()
        #expect(gate.ended(shouldResume: true) == false)
    }

    @Test("a route loss outside any interruption does not affect a later one")
    func routeLossOutsideInterruptionIsIgnored() {
        var gate = InterruptionResumeGate()
        gate.routeLost()   // e.g. plain unplug, no interruption in progress
        gate.began(wasPlaying: true)
        #expect(gate.ended(shouldResume: true) == true)
    }

    @Test("ended consumes the gate so a stray repeat is inert")
    func endedConsumesGate() {
        var gate = InterruptionResumeGate()
        gate.began(wasPlaying: true)
        #expect(gate.ended(shouldResume: true) == true)
        #expect(gate.ended(shouldResume: true) == false)
    }
}

/// Bug 8 fix: `AudiobookPlayer.handleRouteChange` / the remote `playCommand` target delegate to
/// this pure, one-shot window so the suppression rule is testable without AVAudioSession.
@Suite("Accessory play suppression window")
struct AccessoryPlaySuppressionWindowTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("suppresses the first attempt inside the window")
    func suppressesFirstAttemptInsideWindow() {
        var window = AccessoryPlaySuppressionWindow()
        window.arm(now: t0, window: 2)
        #expect(window.consumeShouldSuppress(now: t0.addingTimeInterval(1)) == true)
    }

    @Test("is one-shot: a second attempt right after is never blocked")
    func isOneShot() {
        var window = AccessoryPlaySuppressionWindow()
        window.arm(now: t0, window: 2)
        _ = window.consumeShouldSuppress(now: t0.addingTimeInterval(1))
        #expect(window.consumeShouldSuppress(now: t0.addingTimeInterval(1.1)) == false)
    }

    @Test("a deliberate attempt after the window passes through, consuming the arm")
    func passesThroughAfterWindow() {
        var window = AccessoryPlaySuppressionWindow()
        window.arm(now: t0, window: 2)
        #expect(window.consumeShouldSuppress(now: t0.addingTimeInterval(3)) == false)
        #expect(window.consumeShouldSuppress(now: t0.addingTimeInterval(3.1)) == false)
    }

    @Test("clear cancels a pending arm")
    func clearCancelsArm() {
        var window = AccessoryPlaySuppressionWindow()
        window.arm(now: t0, window: 2)
        window.clear()
        #expect(window.consumeShouldSuppress(now: t0.addingTimeInterval(1)) == false)
    }
}
