import AVFoundation
import Testing
@testable import CaptureKit

actor SourceRecordingSink: LivePCMSink {
    struct Record: Equatable {
        let source: LivePCMSource
        let hostTime: UInt64
        let frameLength: AVAudioFrameCount
    }

    private(set) var records: [Record] = []

    func receive(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64, source: LivePCMSource) async {
        records.append(Record(source: source, hostTime: hostTime, frameLength: buffer.frameLength))
    }
}

@Suite("Live PCM sink routing")
struct LivePCMSinkRoutingTests {
    @Test("FanOutPCMSink forwards a tagged buffer to every child sink")
    func fanOutForwardsToEveryChild() async throws {
        let first = SourceRecordingSink()
        let second = SourceRecordingSink()
        let fanOut = FanOutPCMSink([first, second])
        let buffer = try #require(AVAudioPCMBuffer.sineWave(frameCount: 1_600))

        await fanOut.receive(buffer, at: 123, source: .mic)

        #expect(await first.records == [
            .init(source: .mic, hostTime: 123, frameLength: 1_600),
        ])
        #expect(await second.records == [
            .init(source: .mic, hostTime: 123, frameLength: 1_600),
        ])
    }

    @Test("SourceFilteredPCMSink drops system audio for mic-only transcription")
    func sourceFilterDropsSystemAudio() async throws {
        let child = SourceRecordingSink()
        let filter = SourceFilteredPCMSink(child, allowedSources: [.mic])
        let micBuffer = try #require(AVAudioPCMBuffer.sineWave(frameCount: 800))
        let systemBuffer = try #require(AVAudioPCMBuffer.sineWave(frameCount: 400))

        await filter.receive(systemBuffer, at: 1, source: .system)
        await filter.receive(micBuffer, at: 2, source: .mic)

        #expect(await child.records == [
            .init(source: .mic, hostTime: 2, frameLength: 800),
        ])
    }
}
