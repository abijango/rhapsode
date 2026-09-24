#if PERSONAL_RUBBERBAND
import Foundation
import Testing
@testable import Rhapsode

@Suite("Personal Rubber Band preference")
struct RubberBandPreferenceTests {
    @Test("adaptive speed defaults off and preserves an explicit choice")
    func adaptiveSpeedChoice() {
        let key = "cadence.adaptiveSpeed"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(!SmartSpeechPreferences.adaptiveSpeed)
        SmartSpeechPreferences.adaptiveSpeed = true
        #expect(SmartSpeechPreferences.adaptiveSpeed)
        SmartSpeechPreferences.adaptiveSpeed = false
        #expect(!SmartSpeechPreferences.adaptiveSpeed)
    }

    @Test("defaults to R3 and preserves an explicit off choice")
    func defaultAndOff() {
        let key = "cadence.useRubberBand"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(SmartSpeechPreferences.useRubberBand)

        SmartSpeechPreferences.useRubberBand = false
        #expect(!SmartSpeechPreferences.useRubberBand)

        SmartSpeechPreferences.useRubberBand = true
        #expect(SmartSpeechPreferences.useRubberBand)
    }
}
#endif
