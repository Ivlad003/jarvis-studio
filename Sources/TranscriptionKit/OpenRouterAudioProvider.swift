import Foundation
import os

private let openrouterAudioLog = Logger(subsystem: "dev.kosmonotes.studio", category: "OpenRouterAudioProvider")

// MARK: - OpenRouterAudioProvider

/// `BatchTranscriptionProvider` adapter for OpenRouter's multimodal `input_audio`
/// content type. Routes the recording's audio through OpenRouter's standard
/// `/api/v1/chat/completions` endpoint to a multimodal model (default
/// `google/gemini-2.5-flash`) that returns transcript + segments in one call.
///
/// Why this exists in addition to the direct `GeminiAudioProvider`:
/// - One billing relationship (OpenRouter handles all model invoices)
/// - Easy to swap models — try Gemini today, Claude tomorrow, GPT-4o-Audio
///   next week, all by changing the `model` parameter
/// - Same `openrouterApiKey` already used for LLM cleanup / summary
///
/// Limit: same inline-base64 ceiling as Gemini direct (~18 MB of audio).
/// Anything larger needs the file-upload API (TODO; not implemented).
public final class OpenRouterAudioProvider: BatchTranscriptionProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum AudioError: Error, Sendable {
        case audioReadFailed(underlying: Error)
        case audioTooLargeForInline(bytes: Int)
        case invalidEndpoint
        case unexpectedResponse(status: Int, body: String?)
        case parseFailed(underlying: Error)
        case noTranscript
    }

    /// 18 MB — OpenRouter passes through to model providers; we inherit the
    /// strictest of those caps. ~3–4 hours of HE-AAC mono fit under this.
    public static let inlineAudioByteCap = 18 * 1024 * 1024

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let referer: String
    private let title: String
    private let httpClient: HTTPClient

    public init(
        apiKey: String,
        model: String = "google/gemini-2.5-flash",
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        referer: String = "https://kosmonotes.dev",
        title: String = "KosmoNotes",
        httpClient: @escaping HTTPClient = OpenRouterAudioProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.referer = referer
        self.title = title
        self.httpClient = httpClient
    }

    public func transcribe(audioFile: URL, config: TranscriptionConfig) async throws -> BatchTranscriptResult {
        openrouterAudioLog.info("OpenRouterAudioProvider.transcribe: file=\(audioFile.lastPathComponent, privacy: .public) model=\(self.model, privacy: .public) language=\(config.language ?? "auto", privacy: .public)")

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFile)
        } catch {
            openrouterAudioLog.error("OpenRouterAudioProvider: read failed — \(error.localizedDescription, privacy: .public)")
            throw AudioError.audioReadFailed(underlying: error)
        }
        guard audioData.count <= Self.inlineAudioByteCap else {
            openrouterAudioLog.error("OpenRouterAudioProvider: audio is \(audioData.count, privacy: .public) bytes, over the inline cap")
            throw AudioError.audioTooLargeForInline(bytes: audioData.count)
        }

        let format = audioFormatHint(for: audioFile)
        let prompt = buildPrompt(language: config.language)
        let body = buildRequestBody(format: format, audioBase64: audioData.base64EncodedString(), prompt: prompt)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter expects HTTP-Referer + X-Title to attribute the request to
        // an app — required for some routes and helpful for usage analytics.
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await httpClient(request)
        guard let http = response as? HTTPURLResponse else {
            throw AudioError.unexpectedResponse(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            openrouterAudioLog.error("OpenRouterAudioProvider: HTTP \(http.statusCode, privacy: .public) — \(bodyStr ?? "<nil>", privacy: .public)")
            throw AudioError.unexpectedResponse(status: http.statusCode, body: bodyStr)
        }

        return try Self.parse(data: data)
    }

    // MARK: - Defaults

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: - Request building

    /// OpenRouter's `input_audio.format` field expects a short codec hint —
    /// the actual MIME is inferred from this. Map common extensions.
    private func audioFormatHint(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "m4a"
        case "wav":               return "wav"
        case "mp3":               return "mp3"
        case "ogg", "opus":       return "ogg"
        case "flac":              return "flac"
        case "webm":              return "webm"
        default:                  return "m4a"
        }
    }

    private func buildPrompt(language: String?) -> String {
        let langClause: String
        if let l = language, !l.isEmpty, l.lowercased() != "auto" {
            langClause = "The audio is primarily in language code \"\(l)\". Output transcript in that same language without translating."
        } else {
            langClause = "Detect the spoken language and output transcript in the same language without translating."
        }
        return """
        Transcribe the attached audio precisely. \(langClause)

        Return ONLY a single JSON object matching this schema, with no surrounding markdown, no commentary, no code fences:
        {
          "language": "<detected BCP-47 code>",
          "segments": [
            { "start": <seconds, number>, "end": <seconds, number>, "text": "<utterance>" }
          ],
          "full_text": "<entire transcript joined>"
        }

        Rules:
        - Segment by natural pauses or speaker turns; aim for 5–15 s per segment.
        - "start" / "end" are seconds from the start of the audio (floating point).
        - Use punctuation and capitalization native to the language. Preserve filler words and meaning, but skip pure background noise.
        - If you can't transcribe a portion, omit that segment rather than guessing.
        """
    }

    private func buildRequestBody(format: String, audioBase64: String, prompt: String) -> [String: Any] {
        return [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": audioBase64,
                                "format": format,
                            ],
                        ],
                    ],
                ],
            ],
            "temperature": 0.0,
            // OpenRouter passes through; some models don't honor very large maxTokens
            // but 16k is enough for most multi-hour transcripts.
            "max_completion_tokens": 16384,
            "response_format": ["type": "json_object"],
        ]
    }

    // MARK: - Response parsing

    /// Parse an OpenAI-compatible chat-completions response and pull out
    /// the JSON transcript object embedded in the assistant's content.
    static func parse(data: Data) throws -> BatchTranscriptResult {
        struct Envelope: Decodable {
            let choices: [Choice]?
            let error: APIError?
        }
        struct Choice: Decodable {
            let message: Message?
        }
        struct Message: Decodable {
            let content: String?
        }
        struct APIError: Decodable {
            let message: String?
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            openrouterAudioLog.error("OpenRouterAudioProvider.parse: top-level decode failed — \(error.localizedDescription, privacy: .public)")
            throw AudioError.parseFailed(underlying: error)
        }

        if let apiErr = envelope.error?.message, !apiErr.isEmpty {
            openrouterAudioLog.error("OpenRouterAudioProvider.parse: API error — \(apiErr, privacy: .public)")
            throw AudioError.noTranscript
        }

        guard let raw = envelope.choices?.first?.message?.content, !raw.isEmpty else {
            throw AudioError.noTranscript
        }

        let cleaned = stripMarkdownFence(raw)

        struct Inner: Decodable {
            let language: String?
            let segments: [InnerSegment]?
            let full_text: String?
        }
        struct InnerSegment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        let inner: Inner
        do {
            inner = try JSONDecoder().decode(Inner.self, from: Data(cleaned.utf8))
        } catch {
            openrouterAudioLog.error("OpenRouterAudioProvider.parse: inner JSON decode failed — \(error.localizedDescription, privacy: .public). raw head: \(String(cleaned.prefix(200)), privacy: .public)")
            throw AudioError.parseFailed(underlying: error)
        }

        let segments: [TranscriptSegment] = (inner.segments ?? []).map { s in
            TranscriptSegment(
                start: s.start,
                end: s.end,
                text: s.text,
                confidence: 1.0,
                isFinal: true,
                speaker: nil
            )
        }
        let duration = segments.last?.end ?? 0
        let fullText = inner.full_text ?? segments.map { $0.text }.joined(separator: " ")

        return BatchTranscriptResult(
            language: inner.language,
            duration: duration,
            segments: segments,
            text: fullText
        )
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
