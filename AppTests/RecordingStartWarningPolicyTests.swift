import Testing
@testable import KosmoNotes

@Suite("Recording start warning policy")
struct RecordingStartWarningPolicyTests {
    @Test("Warns when system audio is captured through built-in speakers without echo cancellation")
    func warnsForSpeakerSystemAudioWithoutEchoCancellation() {
        let warning = RecordingStartWarningPolicy.speakerEchoWarning(
            systemAudioEnabled: true,
            echoCancellationEnabled: false,
            defaultOutputBuiltIn: true
        )

        #expect(warning == "Playing through speakers — enable Echo cancellation in Settings → Transcription or use headphones to avoid echo in the recording.")
    }

    @Test("Does not warn when echo cancellation is enabled")
    func skipsWarningWhenEchoCancellationIsEnabled() {
        #expect(RecordingStartWarningPolicy.speakerEchoWarning(
            systemAudioEnabled: true,
            echoCancellationEnabled: true,
            defaultOutputBuiltIn: true
        ) == nil)
    }

    @Test("Does not warn when default output is not built-in")
    func skipsWarningForNonBuiltInOutput() {
        #expect(RecordingStartWarningPolicy.speakerEchoWarning(
            systemAudioEnabled: true,
            echoCancellationEnabled: false,
            defaultOutputBuiltIn: false
        ) == nil)
    }

    @Test("Does not warn when system audio is disabled")
    func skipsWarningWhenSystemAudioIsDisabled() {
        #expect(RecordingStartWarningPolicy.speakerEchoWarning(
            systemAudioEnabled: false,
            echoCancellationEnabled: false,
            defaultOutputBuiltIn: true
        ) == nil)
    }
}
