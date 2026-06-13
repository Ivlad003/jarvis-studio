import Accelerate
import Foundation

public struct NLMSCanceller {
    public struct Result: Sendable, Equatable {
        public let predictedEcho: Float
        public let error: Float
    }

    public var coefficients: [Float] { taps }

    private let filterLength: Int
    private let stepSize: Float
    private let regularization: Float
    private var taps: [Float]
    private var referenceRing: [Float]
    private var writeIndex: Int

    public init(filterLength: Int, stepSize: Float = 0.3, regularization: Float = 1e-6) {
        precondition(filterLength > 0, "filterLength must be positive")
        precondition(stepSize > 0 && stepSize < 2, "NLMS is stable for 0 < stepSize < 2")
        self.filterLength = filterLength
        self.stepSize = stepSize
        self.regularization = regularization
        self.taps = [Float](repeating: 0, count: filterLength)
        self.referenceRing = [Float](repeating: 0, count: filterLength * 2)
        self.writeIndex = 0
    }

    public mutating func reset() {
        taps.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vclr(base, 1, vDSP_Length(buffer.count))
        }
        referenceRing.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vclr(base, 1, vDSP_Length(buffer.count))
        }
        writeIndex = 0
    }

    public mutating func process(reference: Float, microphone: Float, adapt: Bool = true) -> Result {
        writeIndex = (writeIndex - 1 + filterLength) % filterLength
        referenceRing[writeIndex] = reference
        referenceRing[writeIndex + filterLength] = reference

        var predictedEcho = Float.zero
        var referenceEnergy = Float.zero

        referenceRing.withUnsafeBufferPointer { ringBuffer in
            taps.withUnsafeBufferPointer { tapBuffer in
                guard
                    let referenceBase = ringBuffer.baseAddress?.advanced(by: writeIndex),
                    let tapBase = tapBuffer.baseAddress
                else { return }

                vDSP_dotpr(
                    referenceBase,
                    1,
                    tapBase,
                    1,
                    &predictedEcho,
                    vDSP_Length(filterLength)
                )
                vDSP_svesq(
                    referenceBase,
                    1,
                    &referenceEnergy,
                    vDSP_Length(filterLength)
                )
            }
        }

        let error = microphone - predictedEcho
        if adapt, referenceEnergy > regularization, error.isFinite {
            var adaptationScale = stepSize * error / (referenceEnergy + regularization)
            taps.withUnsafeMutableBufferPointer { tapBuffer in
                referenceRing.withUnsafeBufferPointer { ringBuffer in
                    guard
                        let referenceBase = ringBuffer.baseAddress?.advanced(by: writeIndex),
                        let tapBase = tapBuffer.baseAddress
                    else { return }

                    vDSP_vsma(
                        referenceBase,
                        1,
                        &adaptationScale,
                        tapBase,
                        1,
                        tapBase,
                        1,
                        vDSP_Length(filterLength)
                    )
                }
            }
        }

        return Result(predictedEcho: predictedEcho, error: error)
    }
}
