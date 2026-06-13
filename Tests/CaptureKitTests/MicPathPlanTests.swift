import Testing
@testable import CaptureKit

@Suite("Mic path plan")
struct MicPathPlanTests {
    // The single-HAL SCStream mic is used on macOS 15 screen+mic (avoids the
    // AVAudioEngine HAL-contention dead-mic). The system-audio doubling it would
    // otherwise cause is removed in ScreenAudioMixer (mic-only mix), not here.

    @Test("Uses SCStream mic on macOS 15 screen+mic")
    func usesSCStreamMicForMacOS15ScreenMic() {
        #expect(MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: true,
            micEnabled: true,
            echoCancellationEnabled: false,
            isMacOS15OrNewer: true
        ))
    }

    @Test("Uses SCStream mic regardless of echo cancellation setting")
    func usesSCStreamMicRegardlessOfEchoCancellation() {
        #expect(MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: true,
            micEnabled: true,
            echoCancellationEnabled: true,
            isMacOS15OrNewer: true
        ))
    }

    @Test("Uses AVAudioEngine mic on macOS 14")
    func usesAudioEngineMicOnMacOS14() {
        #expect(!MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: true,
            micEnabled: true,
            echoCancellationEnabled: false,
            isMacOS15OrNewer: false
        ))
    }

    @Test("Audio-only sessions never use SCStream mic")
    func audioOnlyNeverUsesSCStreamMic() {
        #expect(!MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: false,
            micEnabled: true,
            echoCancellationEnabled: false,
            isMacOS15OrNewer: true
        ))
    }

    @Test("Sessions without mic never use SCStream mic")
    func micDisabledNeverUsesSCStreamMic() {
        #expect(!MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: true,
            micEnabled: false,
            echoCancellationEnabled: false,
            isMacOS15OrNewer: true
        ))
    }
}
