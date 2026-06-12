import Testing
@testable import CaptureKit

@Suite("Mic path plan")
struct MicPathPlanTests {
    @Test("Uses SCStream mic on macOS 15 screen+mic when echo cancellation is off")
    func usesSCStreamMicForMacOS15ScreenMicWithoutEchoCancellation() {
        #expect(MicPathPlan.shouldUseSCStreamMic(
            screenRecordingEnabled: true,
            micEnabled: true,
            echoCancellationEnabled: false,
            isMacOS15OrNewer: true
        ))
    }

    @Test("Uses AVAudioEngine mic when echo cancellation is on")
    func usesAudioEngineMicWhenEchoCancellationIsOn() {
        #expect(!MicPathPlan.shouldUseSCStreamMic(
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
