@preconcurrency import AVFoundation
import Testing
@testable import CaptureKit

@Suite("Audio PCM buffer stream")
struct AudioPCMBufferStreamTests {
    @Test("Bounded stream keeps newest PCM buffers")
    func boundedStreamKeepsNewestBuffers() async throws {
        let (stream, continuation) = AudioPCMBufferStream.makeStream(bufferingNewest: 2)

        for index in 0..<5 {
            guard let buffer = AVAudioPCMBuffer.taggedIndex(index, frameCount: 16) else {
                Issue.record("Failed to create tagged buffer")
                continue
            }
            continuation.yield(buffer)
        }
        continuation.finish()

        var observed: [Int] = []
        for await buffer in stream {
            guard let firstSample = buffer.floatChannelData?[0][0] else {
                Issue.record("Missing first sample")
                continue
            }
            observed.append(Int(firstSample.rounded()))
        }

        #expect(observed == [3, 4])
    }
}
