import AVFoundation
import Testing
import CaptureKit
import TranscriptionKit
@testable import KosmoNotes

private actor StreamingSessionBox {
    private(set) var sent: [Data] = []
    private(set) var finished = false
    private(set) var cancelled = false

    func send(_ data: Data) {
        sent.append(data)
    }

    func finish() {
        finished = true
    }

    func cancel() {
        cancelled = true
    }
}

@Suite("StreamingLiveSource")
struct StreamingLiveSourceTests {
    @Test("updates draft and stable transcript from streaming session events")
    func updatesSnapshotFromEvents() async throws {
        let box = StreamingSessionBox()
        let (events, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        let source = StreamingLiveSource(
            openSession: {
                StreamingLiveSession(
                    events: events,
                    send: { data in await box.send(data) },
                    finish: { await box.finish() },
                    cancel: { await box.cancel() }
                )
            },
            encodePCM: { _ in Data([0x01]) }
        )

        try await source.start()
        continuation.yield(.init(start: 0, end: 1, text: "draft words", confidence: 0.5, isFinal: false))
        try await Task.sleep(for: .milliseconds(10))

        var snapshot = await source.snapshot()
        #expect(snapshot.mutableText == "draft words")
        #expect(snapshot.stableText == "")

        continuation.yield(.init(start: 0, end: 1, text: "final words", confidence: 0.9, isFinal: true))
        try await Task.sleep(for: .milliseconds(10))

        snapshot = await source.snapshot()
        #expect(snapshot.stableText == "final words")
        #expect(snapshot.mutableText == "")

        await source.stop()
        #expect(await box.finished == true)
    }

    @Test("sends only mic buffers as encoded streaming PCM")
    func sendsOnlyMicBuffers() async throws {
        let box = StreamingSessionBox()
        let (events, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        defer { continuation.finish() }
        let source = StreamingLiveSource(
            openSession: {
                StreamingLiveSession(
                    events: events,
                    send: { data in await box.send(data) },
                    finish: { await box.finish() },
                    cancel: { await box.cancel() }
                )
            },
            encodePCM: { buffer in Data([UInt8(buffer.frameLength & 0xff)]) }
        )
        let micBuffer = try #require(makeBuffer(frameCount: 1_600, sampleRate: 48_000))
        let systemBuffer = try #require(makeBuffer(frameCount: 800, sampleRate: 48_000))

        try await source.start()
        await source.receive(systemBuffer, at: 1, source: .system)
        await source.receive(micBuffer, at: 2, source: .mic)

        #expect(await box.sent == [Data([0x40])])
    }

    @Test("default encoder downsamples 48 kHz float mono to 16 kHz little-endian linear16")
    func defaultEncoderDownsamplesToLinear16() throws {
        let buffer = try #require(makeBuffer(frameCount: 6, sampleRate: 48_000))
        let samples: [Float] = [-1.0, 0.0, 1.0, 0.5, -0.5, 0.25]
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData?[0][index] = sample
        }

        let data = try StreamingLiveSource.encodeLinear16PCM16k(buffer)

        #expect(data.count == 4)
        #expect(readInt16(data, offset: 0) == Int16.min)
        #expect(readInt16(data, offset: 2) == 16_384)
    }
}

private func makeBuffer(frameCount: AVAudioFrameCount, sampleRate: Double) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }
    buffer.frameLength = frameCount
    return buffer
}

private func readInt16(_ data: Data, offset: Int) -> Int16 {
    data.withUnsafeBytes { rawBuffer in
        rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)
    }
}
