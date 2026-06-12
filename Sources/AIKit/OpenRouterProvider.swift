import Foundation

// MARK: - OpenRouterProvider

/// `AIProvider` for OpenRouter (`POST https://openrouter.ai/api/v1/chat/completions`).
///
/// OpenRouter is OpenAI-compatible: same body shape, same response parser. The two
/// notable differences are (a) the model identifier is `vendor/model` instead of a
/// bare model name, and (b) OpenRouter rate-limits more aggressively unless you set
/// the `HTTP-Referer` / `X-Title` headers, which they use to attribute requests on
/// the dashboard.
public final class OpenRouterProvider: AIProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Stored

    private let apiKey: String
    private let endpoint: URL
    private let referer: String
    private let title: String
    private let httpClient: HTTPClient

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = OpenRouterProvider.defaultEndpoint,
        referer: String = "https://kosmonotes.studio",
        title: String = "KosmoNotes",
        httpClient: @escaping HTTPClient = OpenRouterProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.referer = referer
        self.title = title
        self.httpClient = httpClient
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: AIProvider

    public func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        let request = try Self.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            referer: referer,
            title: title,
            messages: messages,
            config: config
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw AIError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.sendFailed(message: "Non-HTTP response from OpenRouter")
        }

        switch httpResponse.statusCode {
        case 200:
            // Same response shape as OpenAI — reuse its parser.
            return try OpenAIProvider.parse(data: data)
        case 401:
            throw AIError.authenticationFailed
        case 429:
            throw AIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw AIError.sendFailed(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    // MARK: - Request builder (internal for tests)

    static func buildRequest(
        endpoint: URL,
        apiKey: String,
        referer: String,
        title: String,
        messages: [ChatMessage],
        config: AIConfig
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(title, forHTTPHeaderField: "X-Title")

        var allMessages = messages
        if let systemPrompt = config.systemPrompt {
            allMessages.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }

        let body: [String: Any] = [
            "model": config.model,
            "max_completion_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": allMessages.map { msg -> [String: Any] in
                ["role": msg.role.rawValue, "content": serializeParts(msg.parts)]
            },
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    // MARK: - Private: part serialization

    private static func serializeParts(_ parts: [ChatMessage.Part]) -> Any {
        if parts.count == 1, case .text(let s) = parts[0] {
            return s
        }
        return parts.map { part -> [String: Any] in
            switch part {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let jpegData, let mimeType):
                let dataURL = "data:\(mimeType);base64,\(jpegData.base64EncodedString())"
                return [
                    "type": "image_url",
                    "image_url": ["url": dataURL] as [String: Any],
                ]
            }
        }
    }
}
