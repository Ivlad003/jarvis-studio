import Foundation

/// Decides whether the mic should be captured by SCStream (single-HAL path)
/// or by AVAudioEngine. Echo cancellation is now post-capture DSP in
/// CaptureSession, so it does not force the old VoiceProcessingIO path and
/// should preserve the single-HAL SCStream mic route when that route is
/// otherwise available.
enum MicPathPlan {
    static func shouldUseSCStreamMic(
        screenRecordingEnabled: Bool,
        micEnabled: Bool,
        echoCancellationEnabled: Bool,
        isMacOS15OrNewer: Bool
    ) -> Bool {
        // SCStream's mic output IS entangled with its system-audio capture
        // (one stream/clock → the mic carries a bit-exact digital copy of the
        // system audio; confirmed on-device 2026-06-13). The "clean" alternative
        // — capturing the mic via AVAudioEngine alongside SCStream's system
        // capture — was tried and FAILED: the two HAL clients contend and the
        // AVAudioEngine input tap never fires (dead mic, recording aborts at the
        // 8 s deadline). So we keep the single-HAL SCStream mic (working mic) and
        // remove the system-audio DOUBLING in the mix instead (see ScreenAudioMixer:
        // the SCStream mic already contains the remote, so the mix must not add
        // the system track on top). echoCancellationEnabled no longer forces a path.
        _ = echoCancellationEnabled
        guard screenRecordingEnabled, micEnabled, isMacOS15OrNewer else { return false }
        return true
    }
}
