import Testing
import TranscriptionKit
@testable import KosmoNotes

@Suite("Recorder live transcript")
struct RecorderLiveTranscriptTests {
    @Test("live finals build a batch-equivalent result")
    func liveFinalsBuildBatchEquivalentResult() {
        let result = RecorderState.liveTranscriptResult(
            from: [
                .init(start: 0, end: 1, text: " hello ", confidence: 0.9, isFinal: true),
                .init(start: 1, end: 2, text: "world", confidence: 0.9, isFinal: true),
            ],
            duration: 2.5,
            language: "en"
        )

        #expect(result?.language == "en")
        #expect(result?.duration == 2.5)
        #expect(result?.text == "hello world")
        #expect(result?.segments.map(\.text) == [" hello ", "world"])
    }

    @Test("blank live finals do not replace batch transcription")
    func blankLiveFinalsDoNotReplaceBatchTranscription() {
        let result = RecorderState.liveTranscriptResult(
            from: [
                .init(start: 0, end: 1, text: "   ", confidence: 0.9, isFinal: true),
            ],
            duration: 1,
            language: nil
        )

        #expect(result == nil)
    }
}
