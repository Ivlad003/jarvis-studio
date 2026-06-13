import Foundation

func deterministicNoise(count: Int, seed: UInt64 = 0xC0FFEE) -> [Float] {
    var state = seed
    var values: [Float] = []
    values.reserveCapacity(count)

    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let raw = UInt32((state >> 32) & 0xFFFF_FFFF)
        let normalized = Float(raw) / Float(UInt32.max)
        values.append((normalized * 2) - 1)
    }

    return values
}

func delayedCopy(_ source: [Float], delay: Int) -> [Float] {
    precondition(delay >= 0)
    var out = Array(repeating: Float.zero, count: source.count)
    guard delay < source.count else { return out }

    for index in delay..<source.count {
        out[index] = source[index - delay]
    }

    return out
}

func convolve(_ source: [Float], impulse: [Float]) -> [Float] {
    var out = Array(repeating: Float.zero, count: source.count)

    for index in source.indices {
        var sample = Float.zero
        for tap in impulse.indices where index >= tap {
            sample += source[index - tap] * impulse[tap]
        }
        out[index] = sample
    }

    return out
}

func maxAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
}
