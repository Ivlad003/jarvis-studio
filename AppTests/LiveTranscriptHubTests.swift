import Testing
import TranscriptionKit
@testable import KosmoNotes

@Suite("LiveTranscriptHub")
struct LiveTranscriptHubTests {
    @Test("interim segments remain draft until a final segment commits them")
    func interimSegmentsRemainDraftUntilFinal() async {
        let hub = LiveTranscriptHub()

        await hub.apply(.init(start: 1, end: 2, text: "draft words", confidence: 0.5, isFinal: false))
        var snapshot = await hub.snapshot()
        #expect(snapshot.stableText == "")
        #expect(snapshot.mutableText == "draft words")

        await hub.apply(.init(start: 1, end: 2, text: "final words", confidence: 0.9, isFinal: true))
        snapshot = await hub.snapshot()
        #expect(snapshot.stableText == "final words")
        #expect(snapshot.mutableText == "")
    }

    @Test("empty transcript events are ignored")
    func emptyTranscriptEventsAreIgnored() async {
        let hub = LiveTranscriptHub()

        await hub.apply(.init(start: 1, end: 2, text: "   ", confidence: 0.5, isFinal: false))

        #expect(await hub.snapshot() == .empty)
    }

    @Test("failure status preserves existing transcript text")
    func failureStatusPreservesTranscriptText() async {
        let hub = LiveTranscriptHub()
        await hub.apply(.init(start: 1, end: 2, text: "locked", confidence: 0.9, isFinal: true))

        await hub.markFailed("network timeout")
        let snapshot = await hub.snapshot()

        #expect(snapshot.stableText == "locked")
        #expect(snapshot.status == .failed(lastError: "network timeout"))
    }

    @Test("final segments are retained and forwarded to the persistence sink")
    func finalSegmentsAreRetainedAndForwarded() async {
        let box = FinalSegmentBox()
        let hub = LiveTranscriptHub(onFinalSegment: { segment in
            await box.append(segment)
        })

        await hub.apply(.init(start: 0, end: 1, text: "draft", confidence: 0.5, isFinal: false))
        await hub.apply(.init(start: 0, end: 1, text: "final", confidence: 0.9, isFinal: true))

        #expect(await hub.finalSegments().map(\.text) == ["final"])
        #expect(await box.segments.map(\.text) == ["final"])
    }
}

private actor FinalSegmentBox {
    private(set) var segments: [TranscriptSegment] = []

    func append(_ segment: TranscriptSegment) {
        segments.append(segment)
    }
}
