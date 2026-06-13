import Foundation
import Testing
import TranscriptionKit
@testable import KosmoNotes

@Suite("Recorder live transcript")
struct RecorderLiveTranscriptTests {

    private func repoFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = relativePath
            .split(separator: "/")
            .reduce(repoRoot) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

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

    @Test("live FTS indexing uses a coarse cadence gate")
    func liveFTSIndexingUsesCoarseCadenceGate() throws {
        let source = try repoFile("App/State/RecorderState.swift")

        #expect(source.contains("LiveTranscriptIndexCadence"))
        #expect(source.contains("minimumInterval: 30"))
        #expect(source.contains("liveIndexCadence.shouldIndex"))
        #expect(!source.contains("try? await sessionStore.indexTranscript(sid: streamingSessionID, text: text)"))
    }
}
