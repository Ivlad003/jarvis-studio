import Foundation

// MARK: - Anthropic Messages codec

enum AnthropicMessagesCodec {
    static let version = "2023-06-01"

    static func buildRequest(
        endpoint: URL,
        apiKey: String?,
        bearerToken: String? = nil,
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        config: AIConfig
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let systemMessages = messages.filter { $0.role == .system }
        let conversationMessages = messages.filter { $0.role != .system }
        let systemField: String? = config.systemPrompt ?? systemMessages.last?.text

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": conversationMessages.map { msg -> [String: Any] in
                ["role": msg.role.rawValue, "content": serializeParts(msg.parts)]
            },
        ]
        if let system = systemField {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map(serializeTool)
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    static func parseResponse(data: Data) throws -> ChatResponse {
        struct Response: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
                let id: String?
                let name: String?
                let input: JSONValue?
            }
            let content: [ContentBlock]
            let stopReason: String?

            private enum CodingKeys: String, CodingKey {
                case content
                case stopReason = "stop_reason"
            }
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIError.decodingFailed(message: error.localizedDescription)
        }

        let parts: [ChatMessage.Part] = response.content.compactMap { block in
            switch block.type {
            case "text":
                guard let text = block.text else { return nil }
                return .text(text)
            case "tool_use":
                guard let id = block.id, let name = block.name else { return nil }
                return .toolUse(.init(
                    id: id,
                    name: name,
                    arguments: block.input ?? .object([:])
                ))
            default:
                return nil
            }
        }

        return ChatResponse(
            parts: parts,
            stopReason: stopReason(from: response.stopReason)
        )
    }

    private static func serializeTool(_ tool: ToolSpec) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.parameters.anyValue,
        ]
    }

    private static func stopReason(from raw: String?) -> StopReason {
        switch raw {
        case "end_turn", "stop_sequence": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        default: return .unknown
        }
    }

    static func serializeParts(_ parts: [ChatMessage.Part]) -> Any {
        if parts.count == 1, case .text(let s) = parts[0] {
            return s
        }
        return parts.map { part -> [String: Any] in
            switch part {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let jpegData, let mimeType):
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": jpegData.base64EncodedString(),
                    ] as [String: Any],
                ]
            case .toolUse(let call):
                return [
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": call.arguments.anyValue,
                ]
            case .toolResult(let id, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": content,
                    "is_error": isError,
                ]
            }
        }
    }
}

// MARK: - AnthropicProvider

/// `AIProvider` for Anthropic's Messages API (`POST /v1/messages`).
///
/// Anthropic does not allow "system" role in the messages array — it must be
/// a top-level "system" field. This provider filters system messages out of
/// the array and uses the last system message's content as the top-level field.
///
/// Supports multipart messages: text parts become `{"type":"text","text":"..."}`,
/// image parts become `{"type":"image","source":{"type":"base64",...}}`.
/// System messages are always text-only (Anthropic API constraint).
public final class AnthropicProvider: AIProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Stored

    private let apiKey: String
    private let endpoint: URL
    private let httpClient: HTTPClient

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = AnthropicProvider.defaultEndpoint,
        httpClient: @escaping HTTPClient = AnthropicProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-sonnet-4-6"

    public static let defaultHTTPClient: HTTPClient = { request in
        try await URLSession.shared.data(for: request)
    }

    // MARK: AIProvider

    public func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        try await chat(messages: messages, tools: [], config: config).text
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        let request = try Self.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            messages: messages,
            tools: tools,
            config: config
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw AIError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.sendFailed(message: "Non-HTTP response from Anthropic API")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data: data)
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
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        config: AIConfig
    ) throws -> URLRequest {
        try AnthropicMessagesCodec.buildRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            messages: messages,
            tools: tools,
            config: config
        )
    }

    // MARK: - Response parser (internal for tests)

    static func parse(data: Data) throws -> String {
        try parseResponse(data: data).text
    }

    static func parseResponse(data: Data) throws -> ChatResponse {
        try AnthropicMessagesCodec.parseResponse(data: data)
    }
}
