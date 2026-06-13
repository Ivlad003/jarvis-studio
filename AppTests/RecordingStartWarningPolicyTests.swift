import Testing
import AIKit
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

    @Test("Deepgram streaming asks for cost confirmation before recording when first-hour projection exceeds the cap")
    func deepgramStreamingRequiresCostConfirmationBeforeRecordingWhenProjectionExceedsCap() {
        let estimate = RecordingStartWarningPolicy.streamingTranscriptionStartCostOverage(
            provider: .deepgram,
            costCapUSD: 0.01,
            projectedDurationSec: 60 * 60
        )

        #expect(estimate == CostEstimator.estimateTranscription(
            durationSec: 60 * 60,
            pricing: CostEstimator.deepgram_nova_2_streaming
        ))
    }

    @Test("Deepgram streaming skips cost confirmation when the first-hour projection is within the cap")
    func deepgramStreamingSkipsCostConfirmationWhenProjectionIsWithinCap() {
        let estimate = RecordingStartWarningPolicy.streamingTranscriptionStartCostOverage(
            provider: .deepgram,
            costCapUSD: 1.00,
            projectedDurationSec: 60 * 60
        )

        #expect(estimate == nil)
    }

    @Test("Non-streaming transcription providers skip the streaming start cost gate")
    func nonStreamingProvidersSkipStreamingStartCostGate() {
        #expect(RecordingStartWarningPolicy.streamingTranscriptionStartCostOverage(
            provider: .openaiWhisper,
            costCapUSD: 0,
            projectedDurationSec: 60 * 60
        ) == nil)
        #expect(RecordingStartWarningPolicy.streamingTranscriptionStartCostOverage(
            provider: .whisperKit,
            costCapUSD: 0,
            projectedDurationSec: 60 * 60
        ) == nil)
    }
}
