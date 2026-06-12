import Foundation

/// Decides whether the mic should be captured by SCStream (single-HAL path)
/// or by AVAudioEngine. Echo cancellation forces the AVAudioEngine path
/// because SCStream exposes no AEC; the start-order mitigation (screen first,
/// HAL settle, mic engine second) and AudioEngine supervisors carry the
/// HAL-contention risk that SCStream-mic was originally built to avoid.
enum MicPathPlan {
    static func shouldUseSCStreamMic(
        screenRecordingEnabled: Bool,
        micEnabled: Bool,
        echoCancellationEnabled: Bool,
        isMacOS15OrNewer: Bool
    ) -> Bool {
        guard screenRecordingEnabled, micEnabled, isMacOS15OrNewer else { return false }
        return !echoCancellationEnabled
    }
}
