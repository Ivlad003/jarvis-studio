import Accelerate
import Foundation

public enum ERLE {
    public static func decibels(microphone: [Float], cleaned: [Float]) -> Float {
        let count = min(microphone.count, cleaned.count)
        guard count > 0 else { return 0 }

        var microphoneEnergy = Float.zero
        var cleanedEnergy = Float.zero
        microphone.withUnsafeBufferPointer { micBuffer in
            cleaned.withUnsafeBufferPointer { cleanedBuffer in
                guard
                    let micBase = micBuffer.baseAddress,
                    let cleanedBase = cleanedBuffer.baseAddress
                else { return }

                vDSP_svesq(micBase, 1, &microphoneEnergy, vDSP_Length(count))
                vDSP_svesq(cleanedBase, 1, &cleanedEnergy, vDSP_Length(count))
            }
        }

        guard microphoneEnergy > 0 else { return 0 }
        let safeCleanedEnergy = max(cleanedEnergy, 1e-12)
        return 10 * log10f(microphoneEnergy / safeCleanedEnergy)
    }
}
