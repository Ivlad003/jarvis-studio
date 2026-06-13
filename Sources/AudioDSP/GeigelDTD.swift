import Foundation

public struct GeigelDTD {
    private let threshold: Float
    private let holdSamples: Int
    private let energyFloor: Float
    private var referenceMagnitudes: [Float]
    private var writeIndex = 0
    private var holdRemaining = 0

    public init(
        referenceWindowLength: Int,
        threshold: Float = 2,
        holdSamples: Int,
        energyFloor: Float = 1e-6
    ) {
        precondition(referenceWindowLength > 0, "referenceWindowLength must be positive")
        precondition(threshold > 0, "threshold must be positive")
        self.threshold = threshold
        self.holdSamples = max(0, holdSamples)
        self.energyFloor = energyFloor
        self.referenceMagnitudes = [Float](repeating: 0, count: referenceWindowLength)
    }

    public mutating func reset() {
        referenceMagnitudes = [Float](repeating: 0, count: referenceMagnitudes.count)
        writeIndex = 0
        holdRemaining = 0
    }

    public mutating func shouldAdapt(reference: Float, microphone: Float) -> Bool {
        referenceMagnitudes[writeIndex] = abs(reference)
        writeIndex = (writeIndex + 1) % referenceMagnitudes.count

        let maxReference = referenceMagnitudes.max() ?? 0
        let hasReference = maxReference > energyFloor
        let doubleTalk = hasReference && abs(microphone) >= threshold * maxReference

        if doubleTalk {
            holdRemaining = max(0, holdSamples - 1)
            return false
        }

        if holdRemaining > 0 {
            holdRemaining -= 1
            return false
        }

        return true
    }
}
