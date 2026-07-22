import Foundation
import AIKit
import StorageKit

// MARK: - RecorderState — AI summary generation
//
// Pulled out of RecorderState.swift so the main file stays focused on
// capture lifecycle. The method is invoked from `stop()` after the
// transcript is finalized; on failure the session is marked complete
// without a summary.md sidecar (still browseable in Library).
//
// Access modifier dropped from `private` to module-internal so the call
// site in `RecorderState.stop()` can see it across files. Calls
// `Self.confirmCostOverage` which lives in the main file (also
// internal-default after Phase E).

@available(macOS 14.0, *)
extension RecorderState {

    /// Calls the configured LLM to produce a Markdown summary and atomically
    /// writes it to `<sessionDir>/summary.md`. Returns the file URL on success,
    /// nil on any failure (missing key, cost cap exceeded, network error, etc.).
    func tryGenerateSummary(
        transcript: String,
        sessionDir: URL,
        sourceLanguage: String?
    ) async -> URL? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Resolve target language: nil means "auto" — let PromptTemplates decide.
        let target: String? = settings.summaryLanguage == "auto" ? nil : settings.summaryLanguage
        // Meeting and dictation both use the meeting-summary template.
        let system = PromptTemplates.meetingSummary(sourceLanguage: sourceLanguage, targetLanguage: target)
        let userMsg = PromptTemplates.meetingUserMessage(transcript: trimmed)

        // Select provider and pricing based on user preference.
        guard let resolved = AIProviderResolver.resolve(settings.aiProviderConfig) else {
            return nil
        }
        let provider = resolved.provider
        let model = resolved.model
        let pricing = resolved.pricing

        // Estimate cost before sending. If it exceeds the cap, surface a modal
        // so the user can either bump the cap or skip this run. Ollama is free
        // (pricing zero), so this branch is a no-op for local inference.
        let inputTokens = CostEstimator.estimateTokens(text: system) + CostEstimator.estimateTokens(text: userMsg)
        let outputTokensCap = 1500
        let estimatedCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputTokensCap,
            pricing: pricing
        )
        if estimatedCost > settings.costCapUSD {
            let proceed = await Self.confirmCostOverage(
                estimated: estimatedCost,
                cap: settings.costCapUSD,
                onIncrease: { [weak self] newCap in
                    self?.settings.costCapUSD = newCap
                }
            )
            if !proceed { return nil }
        }

        let messages: [ChatMessage] = [ChatMessage(role: .user, content: userMsg)]
        let config = AIConfig(model: model, temperature: 0.3, maxTokens: outputTokensCap, systemPrompt: system)

        do {
            let summary = try await provider.chat(messages: messages, config: config)
            let summaryURL = sessionDir.appendingPathComponent("summary.md")
            try AtomicWriter.write(Data(summary.utf8), to: summaryURL)
            return summaryURL
        } catch {
            // Summary failures are non-fatal; the session is still usable without one.
            return nil
        }
    }
}
