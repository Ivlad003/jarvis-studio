import Foundation
import Testing
@testable import CaptureKit

@Suite("ScreenAudioMixer near-end isolation")
struct ScreenAudioMixerTests {
    private func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            out[i] = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32))) / Float(Int32.max)
        }
        return out
    }

    private func tone(_ count: Int, hz: Double, amp: Double) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(amp * sin(2.0 * Double.pi * hz * Double(i) / 48_000.0))
        }
        return out
    }

    private func energy(_ v: [Float]) -> Double {
        v.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    private func erleDB(reference: [Float], residual: [Float]) -> Double {
        10 * log10(energy(reference) / max(energy(residual), 1e-12))
    }

    @Test("Subtracts the system copy out of the mic, recovering the near-end")
    func isolatesNearEnd() {
        let n = 48_000
        let system = noise(n, seed: 0xBEEF)
        let nearEnd = tone(n, hz: 220, amp: 0.3)
        let mic = zip(nearEnd, system).map(+)   // entangled SCStream mic

        let recovered = ScreenAudioMixer.isolateNearEnd(mic: mic, system: system)
        let residual = zip(recovered, nearEnd).map(-)

        #expect(erleDB(reference: mic, residual: residual) >= 20)
    }

    @Test("Clean mic (no system bleed) passes through ~unchanged")
    func cleanMicPassesThrough() {
        let n = 48_000
        let system = noise(n, seed: 0xABCD)   // unrelated system audio
        let nearEnd = tone(n, hz: 200, amp: 0.3)
        let mic = nearEnd                      // mic did NOT bleed the system

        let recovered = ScreenAudioMixer.isolateNearEnd(mic: mic, system: system)

        // g ≈ 0 ⇒ subtract nothing ⇒ recovered ≈ near-end (preserved).
        let residual = zip(recovered, nearEnd).map(-)
        #expect(erleDB(reference: nearEnd, residual: residual) >= 30)
    }

    @Test("Recovers near-end even when the system copy is delayed")
    func isolatesNearEndWithOffset() {
        let n = 48_000
        let base = noise(n + 500, seed: 0xCAFE)
        let nearEnd = tone(n, hz: 330, amp: 0.25)
        let delay = 120
        let mic = (0..<n).map { i in nearEnd[i] + base[i + delay] }
        let system = Array(base[0..<n])

        let recovered = ScreenAudioMixer.isolateNearEnd(mic: mic, system: system)
        let lo = 600, hi = n - 600
        let residual = Array(zip(recovered[lo..<hi], nearEnd[lo..<hi]).map(-))

        #expect(erleDB(reference: Array(mic[lo..<hi]), residual: residual) >= 18)
    }

    @Test("Remix applies gains and clamps to [-1, 1]")
    func remixClampsAndScales() {
        let near: [Float] = [0.5, -0.5, 0.9, 0.0]
        let system: [Float] = [0.4, 0.4, 0.9, -0.2]
        let out = ScreenAudioMixer.remix(nearEnd: near, system: system, micVolume: 1.8, systemVolume: 0.6)

        #expect(out.count == 4)
        #expect(out[0] == 1)                          // 0.5*1.8 + 0.4*0.6 = 1.14 → clamp 1.0
        #expect(abs(out[1] - (-0.66)) < 1e-5)         // -0.5*1.8 + 0.4*0.6
        #expect(out.allSatisfy { $0 >= -1 && $0 <= 1 })
    }
}
