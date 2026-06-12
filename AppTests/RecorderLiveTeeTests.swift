import AVFoundation
import Foundation
import Testing
import TranscriptionKit
@testable import KosmoNotes

@available(macOS 14.0, *)
private actor RecorderLiveTeeEngineBox {
    private(set) var attachedFile: URL?
    private(set) var ingests: [TimeInterval] = []

    func attach(_ file: URL) {
        attachedFile = file
    }

    func ingest(sampleTime: TimeInterval, pcmData: Data) {
        ingests.append(sampleTime)
    }
}

@available(macOS 14.0, *)
@Test func recorderLiveTeeIngestsAccumulatedSampleTime() async throws {
    let box = RecorderLiveTeeEngineBox()
    let bridge = RecorderLiveTeeEngine(
        attach: { file in await box.attach(file) },
        ingest: { sampleTime, pcmData in await box.ingest(sampleTime: sampleTime, pcmData: pcmData) },
        tick: { _, _ in },
        finish: { _, _ in },
        snapshot: { LiveTranscriptState.empty }
    )
    let tee = RecorderLiveTee(engine: bridge, cadence: 60)

    await tee.start()
    let buffer = try #require(makeBuffer(frameCount: 1_600, sampleRate: 16_000))
    await tee.receive(buffer, at: 0, source: .mic)
    await tee.receive(buffer, at: 0, source: .mic)

    let ingests = await box.ingests
    #expect(ingests.count == 2)
    #expect(ingests[0] == 0.1)
    #expect(ingests[1] == 0.2)

    await tee.stop()
}

@available(macOS 14.0, *)
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
