import Testing
@testable import AudioDSP

@Suite("GCC-PHAT delay estimator")
struct GCCPHATTests {
    @Test("Recovers known positive delays within one sample", arguments: [37, 512, 1_500])
    func recoversKnownDelay(delay: Int) {
        let reference = deterministicNoise(count: 4_096)
        let microphone = delayedCopy(reference, delay: delay)

        let estimated = estimateDelayGCCPHAT(
            reference: reference,
            microphone: microphone,
            fftSize: 4_096,
            maxDelaySamples: 2_000
        )

        #expect(abs(estimated - delay) <= 1)
    }

    @Test("Returns zero for silent input")
    func silentInputReturnsZero() {
        let silence = Array(repeating: Float.zero, count: 4_096)

        let estimated = estimateDelayGCCPHAT(
            reference: silence,
            microphone: silence,
            fftSize: 4_096,
            maxDelaySamples: 2_000
        )

        #expect(estimated == 0)
    }
}
