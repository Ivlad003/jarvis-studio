import Foundation

// MARK: - CostEstimator

/// Rough cost projection for a single chat call, used to gate expensive requests
/// against the user's per-session cost cap before sending anything to the API.
public enum CostEstimator {

    // MARK: - Pricing table

    /// USD pricing per 1 000 000 tokens. Values cached locally; update when providers
    /// change list prices rather than fetching at runtime (avoids network dependency).
    public struct Pricing: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double

        public init(inputPerMillion: Double, outputPerMillion: Double) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    /// Anthropic claude-sonnet-4-6 pricing as of 2026-04.
    public static let anthropic_claude_sonnet_4_6 = Pricing(inputPerMillion: 3.0, outputPerMillion: 15.0)

    /// OpenAI gpt-4o-mini pricing as of 2026-04.
    public static let openai_gpt_4o_mini = Pricing(inputPerMillion: 0.15, outputPerMillion: 0.60)

    /// OpenRouter passes through the upstream provider's pricing with a small surcharge.
    /// We use a conservative rate matching their flagship Sonnet route as a safe upper bound;
    /// users on cheaper models will under-spend the cap, which is the right direction.
    public static let openrouter_default = Pricing(inputPerMillion: 3.5, outputPerMillion: 17.0)

    // MARK: - Token estimation

    /// Rough token count heuristic: ~4 chars/token for Latin scripts, ~3 for non-Latin
    /// (CJK, Cyrillic, Arabic, etc.). Errs on the conservative (larger) side so the
    /// cost estimate is slightly above actual, making the cap a safe upper bound.
    public static func estimateTokens(text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let nonLatin = text.unicodeScalars.filter { scalar in
            // Covers Cyrillic (0400-04FF), CJK (4E00-9FFF), Arabic (0600-06FF), Hebrew (0590-05FF), etc.
            scalar.value >= 0x0400
        }.count
        // If more than 30 % of the string is non-Latin, use the 3-char ratio.
        let ratio: Double = Double(nonLatin) / Double(text.unicodeScalars.count) > 0.3 ? 3.0 : 4.0
        return max(1, Int(ceil(Double(text.unicodeScalars.count) / ratio)))
    }

    // MARK: - Cost calculation

    /// USD cost for one call given exact input/output token counts.
    public static func estimate(inputTokens: Int, outputTokens: Int, pricing: Pricing) -> Double {
        let inputCost = Double(inputTokens) / 1_000_000.0 * pricing.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000.0 * pricing.outputPerMillion
        return inputCost + outputCost
    }

    // MARK: - Transcription pricing (per-minute audio)

    /// USD pricing per minute of audio for hosted speech-to-text providers.
    /// Used by RecorderState to gate `provider.transcribe(...)` against the
    /// per-session cost cap before paying the upload + transcription bill on
    /// long recordings.
    public struct TranscriptionPricing: Sendable {
        public let perMinute: Double

        public init(perMinute: Double) {
            self.perMinute = perMinute
        }
    }

    /// OpenAI `whisper-1` (legacy hosted Whisper Large-v2). $0.006 / minute as
    /// of 2026-04 — unchanged since Whisper API launch.
    public static let openai_whisper_1 = TranscriptionPricing(perMinute: 0.006)

    /// OpenAI `gpt-4o-transcribe`. Released March 2025; ~$0.006 / minute audio
    /// input plus a small text-output charge folded into the per-minute rate
    /// here for simplicity. Conservative upper bound.
    public static let openai_gpt_4o_transcribe = TranscriptionPricing(perMinute: 0.006)

    /// OpenAI `gpt-4o-mini-transcribe`. Released March 2025; ~$0.003 / minute —
    /// roughly half of `gpt-4o-transcribe` at comparable accuracy, which is why
    /// it's the default in `AppSettings.openaiTranscribeModel`.
    public static let openai_gpt_4o_mini_transcribe = TranscriptionPricing(perMinute: 0.003)

    /// Deepgram Nova-2 batch (`/v1/listen`). $0.0043 / minute as of 2026-04.
    public static let deepgram_nova_2_batch = TranscriptionPricing(perMinute: 0.0043)

    /// Deepgram Nova-2 streaming uses the same per-minute listen pricing as
    /// batch transcription. Kept separate so start-time streaming gates do not
    /// accidentally depend on a post-stop batch label.
    public static let deepgram_nova_2_streaming = TranscriptionPricing(perMinute: 0.0043)

    /// Estimate USD cost for transcribing `durationSec` of audio at the given
    /// per-minute rate.
    public static func estimateTranscription(durationSec: Double, pricing: TranscriptionPricing) -> Double {
        guard durationSec > 0 else { return 0 }
        return (durationSec / 60.0) * pricing.perMinute
    }
}
