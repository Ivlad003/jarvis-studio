import Foundation
import os
import AIKit
import StorageKit

private let exporterLog = Logger(subsystem: "dev.kosmonotes.studio", category: "MarkdownExporter")

// MARK: - MarkdownExporter

/// Optional post-recording pipeline step that runs the cleaned transcript
/// through the user's configured LLM with **user-defined** system + user
/// prompts, then atomic-writes the result as a `.md` file at the user's
/// chosen folder. Independent of the built-in `summary.md` (which uses our
/// PromptTemplates and lives inside the session dir).
///
/// Failures are non-fatal — caller (RecorderState.stop) ignores the return
/// value when nil. Cost-capped via the same `costCapUSD` mechanism as
/// summary generation, but silently skips on overage rather than prompting.
@available(macOS 14.0, *)
@MainActor
enum MarkdownExporter {

    static let maximumOutputTokens = 16_384

    /// Run the export. Returns the URL of the written `.md` on success,
    /// nil on any failure (disabled, missing prompt placeholder, missing
    /// API key, LLM failure, write failure).
    static func export(
        transcript: String,
        settings: AppSettings,
        sessionID: String,
        sessionMode: SessionMode,
        recordedAt: Date
    ) async -> URL? {
        guard settings.markdownExportEnabled else { return nil }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            exporterLog.info("MarkdownExporter: skipping — transcript is empty")
            return nil
        }

        // Resolve the user prompt template. Fall back to the default if the
        // user accidentally cleared it — better than sending an empty user
        // message which most LLMs reject.
        let userTemplate = settings.markdownExportUserPrompt.isEmpty
            ? AppSettings.defaultMarkdownExportUserPrompt
            : settings.markdownExportUserPrompt
        let systemPrompt = settings.markdownExportSystemPrompt.isEmpty
            ? AppSettings.defaultMarkdownExportSystemPrompt
            : settings.markdownExportSystemPrompt

        // Substitute `{transcript}`. If the user removed the token, append
        // the transcript so the model still has it — better than producing
        // an LLM hallucination from an empty user message.
        let userMessage: String
        if userTemplate.contains("{transcript}") {
            userMessage = userTemplate.replacingOccurrences(of: "{transcript}", with: trimmed)
        } else {
            userMessage = userTemplate + "\n\n" + trimmed
        }

        // Build provider + cost guard. Same per-provider model defaults as
        // tryGenerateSummary so the export honors the AI Providers tab.
        guard let resolved = AIProviderResolver.resolve(settings.aiProviderConfig) else {
            exporterLog.error("MarkdownExporter: no LLM provider available (missing API key)")
            return nil
        }
        let provider = resolved.provider
        let model = resolved.model
        let pricing = resolved.pricing

        let inputTokens = CostEstimator.estimateTokens(text: systemPrompt)
            + CostEstimator.estimateTokens(text: userMessage)
        let outputCap = outputTokenCap(forInputTokens: inputTokens)
        let estCost = CostEstimator.estimate(
            inputTokens: inputTokens,
            outputTokens: outputCap,
            pricing: pricing
        )
        if estCost > settings.costCapUSD {
            exporterLog.error("MarkdownExporter: skipping — estimated cost $\(estCost, privacy: .public) exceeds cap $\(settings.costCapUSD, privacy: .public)")
            return nil
        }

        let config = AIConfig(
            model: model,
            temperature: 0.3,
            maxTokens: outputCap,
            systemPrompt: systemPrompt
        )
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: userMessage)]

        let markdown: String
        do {
            markdown = try await provider.chat(messages: messages, config: config)
        } catch {
            exporterLog.error("MarkdownExporter: LLM call failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmedMD = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMD.isEmpty else {
            exporterLog.error("MarkdownExporter: LLM returned empty output")
            return nil
        }

        // Resolve target folder. Empty setting → ~/Documents/KosmoNotes.
        let folderURL = resolveExportFolder(settings: settings)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            exporterLog.error("MarkdownExporter: could not create folder \(folderURL.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let filename = makeFilename(sessionID: sessionID, mode: sessionMode, recordedAt: recordedAt)
        let outURL = folderURL.appendingPathComponent(filename)

        do {
            try AtomicWriter.write(Data(trimmedMD.utf8), to: outURL)
            exporterLog.info("MarkdownExporter: wrote \(outURL.path, privacy: .public) (\(trimmedMD.count, privacy: .public) chars)")
            return outURL
        } catch {
            exporterLog.error("MarkdownExporter: AtomicWriter failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private helpers

    static func outputTokenCap(forInputTokens inputTokens: Int) -> Int {
        min(maximumOutputTokens, max(2_048, Int(Double(inputTokens) * 1.5)))
    }

    /// Resolve `settings.markdownExportFolder` to an absolute file URL.
    /// Empty → fall back to `~/Documents/KosmoNotes`. `~` is expanded.
    private static func resolveExportFolder(settings: AppSettings) -> URL {
        let raw = settings.markdownExportFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
            return docs.appendingPathComponent("KosmoNotes")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// "2026-05-03_1442_meeting_e0123456.md" — sortable date prefix, mode
    /// label, then a short session-id suffix so two same-minute recordings
    /// don't collide.
    private static func makeFilename(sessionID: String, mode: SessionMode, recordedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: recordedAt)
        let modeStr = mode.rawValue
        let shortID = String(sessionID.prefix(8))
        return "\(date)_\(modeStr)_\(shortID).md"
    }

}
