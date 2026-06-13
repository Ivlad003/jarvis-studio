import Foundation
import AIKit

@available(macOS 14.0, *)
enum RecordingStartWarningPolicy {
    static let speakerEchoWarningMessage = "Playing through speakers — enable Echo cancellation in Settings → Transcription or use headphones to avoid echo in the recording."
    static let streamingCostProjectionSeconds: TimeInterval = 60 * 60

    static func speakerEchoWarning(
        systemAudioEnabled: Bool,
        echoCancellationEnabled: Bool,
        defaultOutputBuiltIn: Bool
    ) -> String? {
        guard systemAudioEnabled, !echoCancellationEnabled, defaultOutputBuiltIn else { return nil }
        return speakerEchoWarningMessage
    }

    static func streamingTranscriptionStartCostOverage(
        provider: AppSettings.TranscriptionProviderChoice,
        costCapUSD: Double,
        projectedDurationSec: TimeInterval = streamingCostProjectionSeconds
    ) -> Double? {
        guard let pricing = streamingPricing(for: provider) else { return nil }
        let estimated = CostEstimator.estimateTranscription(
            durationSec: projectedDurationSec,
            pricing: pricing
        )
        return estimated > costCapUSD ? estimated : nil
    }

    private static func streamingPricing(
        for provider: AppSettings.TranscriptionProviderChoice
    ) -> CostEstimator.TranscriptionPricing? {
        switch provider {
        case .deepgram:
            return CostEstimator.deepgram_nova_2_streaming
        case .openaiWhisper, .gemini, .openrouterAudio, .whisperKit:
            return nil
        }
    }
}
