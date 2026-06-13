import Accelerate
import Foundation

public func estimateDelayGCCPHAT(
    reference: [Float],
    microphone: [Float],
    fftSize requestedFFTSize: Int,
    maxDelaySamples: Int
) -> Int {
    let fftSize = max(2, nextPowerOfTwo(requestedFFTSize))
    guard reference.contains(where: { $0 != 0 }) || microphone.contains(where: { $0 != 0 }) else {
        return 0
    }
    guard let forward = try? vDSP.DiscreteFourierTransform(
        count: fftSize,
        direction: .forward,
        transformType: .complexComplex,
        ofType: Float.self
    ), let inverse = try? vDSP.DiscreteFourierTransform(
        count: fftSize,
        direction: .inverse,
        transformType: .complexComplex,
        ofType: Float.self
    ) else {
        return 0
    }

    var referenceReal = zeroPadded(reference, count: fftSize)
    var microphoneReal = zeroPadded(microphone, count: fftSize)
    let zeroImaginary = [Float](repeating: 0, count: fftSize)

    removeMean(&referenceReal)
    removeMean(&microphoneReal)

    var referenceSpectrumReal = [Float](repeating: 0, count: fftSize)
    var referenceSpectrumImag = [Float](repeating: 0, count: fftSize)
    var microphoneSpectrumReal = [Float](repeating: 0, count: fftSize)
    var microphoneSpectrumImag = [Float](repeating: 0, count: fftSize)

    forward.transform(
        inputReal: referenceReal,
        inputImaginary: zeroImaginary,
        outputReal: &referenceSpectrumReal,
        outputImaginary: &referenceSpectrumImag
    )
    forward.transform(
        inputReal: microphoneReal,
        inputImaginary: zeroImaginary,
        outputReal: &microphoneSpectrumReal,
        outputImaginary: &microphoneSpectrumImag
    )

    var crossReal = [Float](repeating: 0, count: fftSize)
    var crossImag = [Float](repeating: 0, count: fftSize)

    for index in 0..<fftSize {
        let real = referenceSpectrumReal[index] * microphoneSpectrumReal[index]
            + referenceSpectrumImag[index] * microphoneSpectrumImag[index]
        let imag = referenceSpectrumReal[index] * microphoneSpectrumImag[index]
            - referenceSpectrumImag[index] * microphoneSpectrumReal[index]
        let magnitude = hypotf(real, imag)

        if magnitude > 1e-12 {
            crossReal[index] = real / magnitude
            crossImag[index] = imag / magnitude
        }
    }

    var correlationReal = [Float](repeating: 0, count: fftSize)
    var correlationImag = [Float](repeating: 0, count: fftSize)
    inverse.transform(
        inputReal: crossReal,
        inputImaginary: crossImag,
        outputReal: &correlationReal,
        outputImaginary: &correlationImag
    )

    let scale = Float(fftSize)
    var bestLag = 0
    var bestMagnitude = Float.zero
    let boundedDelay = min(maxDelaySamples, fftSize / 2)

    for lag in -boundedDelay...boundedDelay {
        let index = lag >= 0 ? lag : fftSize + lag
        let magnitude = abs(correlationReal[index] / scale)
        if magnitude > bestMagnitude {
            bestMagnitude = magnitude
            bestLag = lag
        }
    }

    return bestLag
}

private func zeroPadded(_ source: [Float], count: Int) -> [Float] {
    var output = [Float](repeating: 0, count: count)
    let copied = min(source.count, count)
    output.withUnsafeMutableBufferPointer { outputBuffer in
        source.withUnsafeBufferPointer { sourceBuffer in
            guard let out = outputBuffer.baseAddress, let input = sourceBuffer.baseAddress else { return }
            out.update(from: input, count: copied)
        }
    }
    return output
}

private func removeMean(_ values: inout [Float]) {
    guard !values.isEmpty else { return }
    var mean = Float.zero
    vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
    var negativeMean = -mean
    vDSP_vsadd(values, 1, &negativeMean, &values, 1, vDSP_Length(values.count))
}

private func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 2 }
    var power = 1
    while power < value {
        power <<= 1
    }
    return power
}
