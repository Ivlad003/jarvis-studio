import Testing
@testable import AudioDSP

@Suite("Geigel double-talk detector")
struct GeigelDTDTests {
    @Test("Freezes adaptation during near-end speech and resumes after hold")
    func freezesAndResumes() {
        var detector = GeigelDTD(
            referenceWindowLength: 64,
            threshold: 2,
            holdSamples: 8
        )

        for _ in 0..<80 {
            let adapt = detector.shouldAdapt(reference: 0.5, microphone: 0.2)
            #expect(adapt)
        }

        let doubleTalk = detector.shouldAdapt(reference: 0.5, microphone: 1.4)
        #expect(!doubleTalk)

        for _ in 0..<7 {
            let held = detector.shouldAdapt(reference: 0.5, microphone: 0.2)
            #expect(!held)
        }

        let resumed = detector.shouldAdapt(reference: 0.5, microphone: 0.2)
        #expect(resumed)
    }

    @Test("Frozen detector keeps NLMS coefficients unchanged")
    func frozenDetectorKeepsCoefficientsStable() {
        let reference = deterministicNoise(count: 4_000)
        var impulse = Array(repeating: Float.zero, count: 64)
        impulse[9] = 0.7
        impulse[21] = -0.2
        let echo = convolve(reference, impulse: impulse)
        var detector = GeigelDTD(referenceWindowLength: 64, threshold: 2, holdSamples: 64)
        var canceller = NLMSCanceller(filterLength: 64, stepSize: 0.3)

        for index in 0..<2_000 {
            let adapt = detector.shouldAdapt(reference: reference[index], microphone: echo[index])
            _ = canceller.process(reference: reference[index], microphone: echo[index], adapt: adapt)
        }

        let before = canceller.coefficients

        for index in 2_000..<2_064 {
            let nearEnd = Float(3)
            let adapt = detector.shouldAdapt(reference: reference[index], microphone: echo[index] + nearEnd)
            _ = canceller.process(reference: reference[index], microphone: echo[index] + nearEnd, adapt: adapt)
            #expect(!adapt)
        }

        #expect(maxAbsDifference(before, canceller.coefficients) <= 0.000_001)
    }
}
