import Testing
@testable import Rhapsode

@Suite("Adaptive speed lifecycle")
@MainActor
struct AdaptiveSpeedLifecycleTests {
    @Test("enabling a persisted preference before loading audio does not query a detached node")
    func enablesBeforeLoad() {
        let backend = LiveAudioBackend()
        backend.adaptiveSpeedEnabled = true
        #expect(backend.adaptiveSpeedEnabled)
        backend.adaptiveSpeedEnabled = false
        #expect(!backend.adaptiveSpeedEnabled)
    }
}
