import Testing
@testable import CaptureKit

@Suite("Tier-2 system-audio fallback plan")
struct Tier2SystemAudioFallbackPlanTests {
    @Test("Starts SCKit when ScreenRecorder was the only system-audio owner")
    func startsSCKitWhenNoSystemAudioSourceSurvivesDemotion() {
        #expect(Tier2SystemAudioFallbackPlan.shouldStartSCKit(
            systemAudioEnabled: true,
            hasSystemTask: false,
            hasDeviceAudioCapture: false,
            hasProcessTap: false,
            hasSCKitCapture: false
        ))
    }

    @Test("Does not start SCKit when another system-audio source is active")
    func skipsSCKitWhenSystemAudioAlreadyHasAProducer() {
        #expect(!Tier2SystemAudioFallbackPlan.shouldStartSCKit(
            systemAudioEnabled: true,
            hasSystemTask: true,
            hasDeviceAudioCapture: false,
            hasProcessTap: false,
            hasSCKitCapture: false
        ))
    }

    @Test("Does not start SCKit when system audio is disabled")
    func skipsSCKitWhenSystemAudioIsDisabled() {
        #expect(!Tier2SystemAudioFallbackPlan.shouldStartSCKit(
            systemAudioEnabled: false,
            hasSystemTask: false,
            hasDeviceAudioCapture: false,
            hasProcessTap: false,
            hasSCKitCapture: false
        ))
    }
}
