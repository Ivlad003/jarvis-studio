import Foundation

// MARK: - OllamaProvider

/// `AIProvider` for Ollama's local inference server.
///
/// Supports two API modes picked at runtime:
///   - `.native`       POST /api/chat  (Ollama-native JSON, stream=false)
///   - `.openaiCompat` POST /v1/chat/completions  (OpenAI-compat)
///
/// Endpoint validation: HTTP is allowed only for localhost / RFC-1918 ranges.
/// HTTPS is allowed for any host.
///
/// Multipart messages in native mode: text parts are joined; image parts are
/// sent as a top-level `images` array of base64 strings on the message object.
public final class OllamaProvider: AIProvider, Sendable {

    // MARK: - API mode

    public enum APIMode: String, Sendable {
        case native        // POST /api/chat
        case openaiCompat  // POST /v1/chat/completions
    }

    public typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: - Stored

    private let endpoint: URL
    private let apiMode: APIMode
    private let bearerToken: String?
    private let httpClient: HTTPClient

    // MARK: - Init

    public init(
        endpoint: URL,
        apiMode: APIMode = .native,
        bearerToken: String? = nil,
        httpClient: @escaping HTTPClient = { try await URLSession.shared.data(for: $0) }
    ) throws {
        try Self.validate(endpoint: endpoint)
        self.endpoint = endpoint
        self.apiMode = apiMode
        self.bearerToken = bearerToken
        self.httpClient = httpClient
    }

    // MARK: - AIProvider

    public func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        let request: URLRequest
        switch apiMode {
        case .native:
            request = try Self.buildNativeRequest(
                endpoint: endpoint,
                bearerToken: bearerToken,
                messages: messages,
                config: config
            )
        case .openaiCompat:
            request = try Self.buildOpenAICompatRequest(
                endpoint: endpoint,
                bearerToken: bearerToken,
                messages: messages,
                config: config
            )
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw AIError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.sendFailed(message: "Non-HTTP response from Ollama")
        }

        switch httpResponse.statusCode {
        case 200:
            switch apiMode {
            case .native:       return try Self.parseNative(data: data)
            case .openaiCompat: return try Self.parseOpenAICompat(data: data)
            }
        case 401:
            throw AIError.authenticationFailed
        case 429:
            throw AIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw AIError.sendFailed(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    /// Lists available models via GET /api/tags. Used by Settings to populate the model picker.
    public func listModels() async throws -> [String] {
        let url = endpoint.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await httpClient(request)
        } catch {
            throw AIError.sendFailed(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.sendFailed(message: "listModels failed: \(body)")
        }

        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        do {
            let parsed = try JSONDecoder().decode(TagsResponse.self, from: data)
            return parsed.models.map { $0.name }
        } catch {
            throw AIError.decodingFailed(message: error.localizedDescription)
        }
    }

    // MARK: - Endpoint validation

    public static func validate(endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased() else { throw AIError.invalidEndpoint }
        if scheme == "https" { return }
        if scheme == "http" {
            guard let host = endpoint.host else { throw AIError.invalidEndpoint }
            if host == "localhost" || host == "127.0.0.1"
                || host.hasPrefix("10.")
                || host.hasPrefix("192.168.")
                || isPrivate172(host) {
                return
            }
            throw AIError.invalidEndpoint
        }
        throw AIError.invalidEndpoint
    }

    // MARK: - Native mode (/api/chat)

    static func buildNativeRequest(
        endpoint: URL,
        bearerToken: String?,
        messages: [ChatMessage],
        config: AIConfig
    ) throws -> URLRequest {
        let url = endpoint.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Prepend config.systemPrompt as a system message if present.
        var allMessages = messages
        if let systemPrompt = config.systemPrompt {
            allMessages.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }

        let serialized: [[String: Any]] = allMessages.map { msg -> [String: Any] in
            serializeNativeMessage(msg)
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": serialized,
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "num_predict": config.maxTokens,
            ] as [String: Any],
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    /// Serialize a single message for the Ollama native /api/chat format.
    /// Text parts are joined; image parts become base64 strings in the `images` array.
    private static func serializeNativeMessage(_ msg: ChatMessage) -> [String: Any] {
        var textParts: [String] = []
        var imageBase64: [String] = []

        for part in msg.parts {
            switch part {
            case .text(let s):
                textParts.append(s)
            case .image(let jpegData, _):
                imageBase64.append(jpegData.base64EncodedString())
            case .toolUse, .toolResult:
                continue
            }
        }

        var result: [String: Any] = [
            "role": msg.role.rawValue,
            "content": textParts.joined(separator: "\n"),
        ]
        if !imageBase64.isEmpty {
            result["images"] = imageBase64
        }
        return result
    }

    static func parseNative(data: Data) throws -> String {
        struct Response: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.message.content
        } catch {
            throw AIError.decodingFailed(message: error.localizedDescription)
        }
    }

    // MARK: - OpenAI-compat mode (/v1/chat/completions)

    static func buildOpenAICompatRequest(
        endpoint: URL,
        bearerToken: String?,
        messages: [ChatMessage],
        config: AIConfig
    ) throws -> URLRequest {
        let url = endpoint.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Use bearer token if set; otherwise omit Authorization header entirely.
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Prepend config.systemPrompt as a system message if present.
        var allMessages = messages
        if let systemPrompt = config.systemPrompt {
            allMessages.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": allMessages.map { msg -> [String: Any] in
                ["role": msg.role.rawValue, "content": serializeOpenAICompatParts(msg.parts)]
            },
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.sendFailed(message: "Could not serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    /// Mirrors OpenAIProvider's serialization: single text → plain string; mixed → array of blocks.
    private static func serializeOpenAICompatParts(_ parts: [ChatMessage.Part]) -> Any {
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
            case .toolUse, .toolResult:
                return [:]
            }
        }.filter { !$0.isEmpty }
    }

    static func parseOpenAICompat(data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String
                }
                let message: Message
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
        return first.message.content
    }

    // MARK: - Private helpers

    /// Returns true for 172.16.x.x – 172.31.x.x (RFC-1918 range).
    private static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "172",
              let second = Int(parts[1]),
              second >= 16, second <= 31 else { return false }
        return true
    }

    // Internal exposure for tests.
    static func isPrivate172Public(_ host: String) -> Bool { isPrivate172(host) }
}
