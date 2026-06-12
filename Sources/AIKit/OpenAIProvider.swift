import Foundation

// MARK: - OpenAIProvider

/// `AIProvider` for OpenAI's Chat Completions API (`POST /v1/chat/completions`).
///
/// OpenAI treats "system" as a regular role in the messages array. When
/// `config.systemPrompt` is set it is prepended as the first message.
///
/// Supports multipart messages: text parts become `{"type":"text","text":"..."}`,
/// image parts become `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}`.
public final class OpenAIProvider: AIProvider, Sendable {

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Stored

    private let apiKey: String
    private let endpoint: URL
    private let httpClient: HTTPClient

    // MARK: Init

    public init(
        apiKey: String,
        endpoint: URL = OpenAIProvider.defaultEndpoint,
        httpClient: @escaping HTTPClient = OpenAIProvider.defaultHTTPClient
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    // MARK: Defaults

    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    public static let defaultModel = "gpt-4o-mini"

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
            throw AIError.sendFailed(message: "Non-HTTP response from OpenAI API")
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Prepend config.systemPrompt as a system message if present.
        // OpenAI treats system as a regular role, so it lives in the array.
        var allMessages = messages
        if let systemPrompt = config.systemPrompt {
            allMessages.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_completion_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": try allMessages.map(Self.serializeMessage),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(Self.serializeTool)
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    // MARK: - Response parser (internal for tests)

    static func parse(data: Data) throws -> String {
        try parseResponse(data: data).text
    }

    static func parseResponse(data: Data) throws -> ChatResponse {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct ToolCallPayload: Decodable {
                        struct FunctionPayload: Decodable {
                            let name: String
                            let arguments: String
                        }

                        let id: String
                        let type: String
                        let function: FunctionPayload
                    }

                    let role: String
                    let content: String?
                    let toolCalls: [ToolCallPayload]?

                    private enum CodingKeys: String, CodingKey {
                        case role
                        case content
                        case toolCalls = "tool_calls"
                    }
                }
                let message: Message
                let finishReason: String?

                private enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIError.decodingFailed(message: error.localizedDescription)
        }

        guard let first = response.choices.first else {
            throw AIError.decodingFailed(message: "No choices in response")
        }

        var parts: [ChatMessage.Part] = []
        if let content = first.message.content, !content.isEmpty {
            parts.append(.text(content))
        }
        for call in first.message.toolCalls ?? [] where call.type == "function" {
            parts.append(.toolUse(.init(
                id: call.id,
                name: call.function.name,
                arguments: try JSONValue.parseJSONString(call.function.arguments)
            )))
        }

        return ChatResponse(
            parts: parts,
            stopReason: Self.stopReason(from: first.finishReason)
        )
    }

    // MARK: - Private: part serialization

    private static func serializeTool(_ tool: ToolSpec) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters.anyValue,
            ] as [String: Any],
        ]
    }

    private static func serializeMessage(_ message: ChatMessage) throws -> [String: Any] {
        if case .toolResult(let id, let content, _) = message.parts.first, message.parts.count == 1 {
            return [
                "role": ChatMessage.Role.tool.rawValue,
                "tool_call_id": id,
                "content": content,
            ]
        }

        var serialized: [String: Any] = [
            "role": message.role.rawValue,
            "content": serializeParts(message.parts),
        ]
        let toolCalls = try message.parts.compactMap { part -> [String: Any]? in
            guard case .toolUse(let call) = part else { return nil }
            return [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": try call.arguments.jsonString(),
                ] as [String: Any],
            ]
        }
        if !toolCalls.isEmpty {
            serialized["tool_calls"] = toolCalls
            if !message.parts.contains(where: { if case .text = $0 { true } else { false } }) {
                serialized["content"] = NSNull()
            }
        }
        return serialized
    }

    private static func stopReason(from raw: String?) -> StopReason {
        switch raw {
        case "stop": return .endTurn
        case "tool_calls", "function_call": return .toolUse
        case "length": return .maxTokens
        default: return .unknown
        }
    }

    /// Convert structured message parts to OpenAI content-part JSON objects.
    /// text → {"type":"text","text":"..."}
    /// image → {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}
    private static func serializeParts(_ parts: [ChatMessage.Part]) -> Any {
        // Single text-only part: send as plain string for maximum API compatibility.
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
            case .toolUse:
                return [:]
            case .toolResult(_, let content, _):
                return ["type": "text", "text": content]
            }
        }.filter { !$0.isEmpty }
    }
}
