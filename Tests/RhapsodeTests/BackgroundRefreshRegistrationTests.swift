import Dispatch
import Testing
@testable import Rhapsode

@Suite("Background refresh registration")
struct BackgroundRefreshRegistrationTests {
    @Test("main-actor launch handler is delivered on the main queue")
    func mainActorLaunchQueue() {
        #expect(BackgroundRefresh.launchQueue === DispatchQueue.main)
    }
}
