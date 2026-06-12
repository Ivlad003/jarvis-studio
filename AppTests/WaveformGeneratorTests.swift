import Foundation
import Testing
@testable import KosmoNotes

@Suite("WaveformGenerator")
struct WaveformGeneratorTests {

    @Test("averages interleaved stereo frames and ignores partial trailing sample")
    func averagesInterleavedStereoFrames() {
        let amplitudes = WaveformGenerator.averageInterleavedFrameAmplitudes(
            [0.5, -1.0, 0.25, 0.75, 0.9],
            channelCount: 2
        )

        #expect(amplitudes == [0.75, 0.5])
    }
}
