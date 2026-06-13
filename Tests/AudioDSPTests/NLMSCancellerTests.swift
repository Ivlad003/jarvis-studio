import Testing
@testable import AudioDSP

@Suite("NLMS adaptive canceller")
struct NLMSCancellerTests {
    @Test("Synthetic echo reaches at least 20 dB ERLE", arguments: [Float(0.1), Float(0.3), Float(0.5)])
    func syntheticEchoReachesTargetERLE(stepSize: Float) {
        let reference = deterministicNoise(count: 18_000, seed: UInt64(stepSize * 1_000) + 17)
        var impulse = Array(repeating: Float.zero, count: 128)
        impulse[7] = 0.62
        impulse[23] = -0.31
        impulse[49] = 0.17
        impulse[83] = -0.08
        let microphone = convolve(reference, impulse: impulse)

        var canceller = NLMSCanceller(filterLength: 128, stepSize: stepSize)
        var cleaned = Array(repeating: Float.zero, count: microphone.count)

        for index in microphone.indices {
            cleaned[index] = canceller.process(reference: reference[index], microphone: microphone[index]).error
        }

        let tailStart = microphone.count - 5_000
        let erle = ERLE.decibels(
            microphone: Array(microphone[tailStart...]),
            cleaned: Array(cleaned[tailStart...])
        )

        #expect(erle >= 20)
        #expect(canceller.coefficients.allSatisfy { $0.isFinite })
    }

    @Test("Silence does not diverge")
    func silenceDoesNotDiverge() {
        var canceller = NLMSCanceller(filterLength: 64, stepSize: 0.3)

        for _ in 0..<2_000 {
            let result = canceller.process(reference: 0, microphone: 0)
            #expect(result.error.isFinite)
            #expect(result.predictedEcho.isFinite)
        }

        #expect(canceller.coefficients.allSatisfy { $0.isFinite })
        #expect((canceller.coefficients.map { Swift.abs($0) }.max() ?? 0) <= 0.000_001)
    }
}
