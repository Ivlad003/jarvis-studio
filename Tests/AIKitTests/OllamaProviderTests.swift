import Foundation
import Testing
@testable import AIKit

// MARK: - Endpoint validation

@Suite("OllamaProvider endpoint validation")
struct OllamaProviderValidationTests {

    @Test("localhost HTTP is allowed")
    func localhostAllowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://localhost:11434")!)
        }
    }

    @Test("127.0.0.1 HTTP is allowed")
    func loopbackAllowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://127.0.0.1:11434")!)
        }
    }

    @Test("10.x.x.x HTTP is allowed")
    func rfc1918_10_allowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://10.0.1.5:11434")!)
        }
    }

    @Test("192.168.x.x HTTP is allowed")
    func rfc1918_192168_allowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://192.168.1.100:11434")!)
        }
    }

    @Test("172.20.x.x HTTP is allowed")
    func rfc1918_172_allowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://172.20.0.5:11434")!)
        }
    }

    @Test("172.16.x.x HTTP is allowed (lower bound)")
    func rfc1918_172_lowerBound() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://172.16.0.1:11434")!)
        }
    }

    @Test("172.31.x.x HTTP is allowed (upper bound)")
    func rfc1918_172_upperBound() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "http://172.31.255.1:11434")!)
        }
    }

    @Test("172.32.x.x HTTP throws invalidEndpoint (outside private range)")
    func rfc1918_172_outOfRange() throws {
        #expect(throws: AIError.invalidEndpoint) {
            try OllamaProvider.validate(endpoint: URL(string: "http://172.32.0.1:11434")!)
        }
    }

    @Test("Public IP HTTP throws invalidEndpoint")
    func publicIPThrows() throws {
        #expect(throws: AIError.invalidEndpoint) {
            try OllamaProvider.validate(endpoint: URL(string: "http://93.184.216.34:11434")!)
        }
    }

    @Test("Public hostname HTTP throws invalidEndpoint")
    func publicHostnameThrows() throws {
        #expect(throws: AIError.invalidEndpoint) {
            try OllamaProvider.validate(endpoint: URL(string: "http://my-server.example.com:11434")!)
        }
    }

    @Test("HTTPS to public host is allowed")
    func httpsPublicAllowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "https://ollama.example.com:443")!)
        }
    }

    @Test("HTTPS to localhost is allowed")
    func httpsLocalhostAllowed() throws {
        #expect(throws: Never.self) {
            try OllamaProvider.validate(endpoint: URL(string: "https://localhost:11434")!)
        }
    }
}

// MARK: - Native mode request builder

@Suite("OllamaProvider native request builder")
struct OllamaProviderNativeRequestTests {

    private let baseConfig = AIConfig(model: "qwen2.5:14b", temperature: 0.7, maxTokens: 512)

    @Test("Builds POST to /api/chat")
    func buildsCorrectURL() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: baseConfig
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/chat")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test("Body has messages array, stream=false, options with temperature and num_predict")
    func bodyShape() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let config = AIConfig(model: "qwen2.5:14b", temperature: 0.5, maxTokens: 1024)
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["model"] as? String == "qwen2.5:14b")
        #expect(body["stream"] as? Bool == false)
        let msgs = body["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 1)
        #expect(msgs[0]["role"] as? String == "user")
        let options = body["options"] as? [String: Any]
        let temp = options?["temperature"] as? Double ?? 0
        #expect(abs(temp - 0.5) < 0.001)
        #expect(options?["num_predict"] as? Int == 1024)
    }

    @Test("Bearer header set when token provided")
    func bearerHeaderSet() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: "my-secret",
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: baseConfig
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret")
    }

    @Test("No Authorization header when bearer token is nil")
    func noBearerHeader() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: baseConfig
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("config.systemPrompt prepended as system message")
    func systemPromptPrepended() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let config = AIConfig(model: "qwen2.5:14b", systemPrompt: "You are helpful.")
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 2)
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[0]["content"] as? String == "You are helpful.")
        #expect(msgs[1]["role"] as? String == "user")
    }

    @Test("Multipart message: text parts joined, images array emitted")
    func multipartNative() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, parts: [
                .text("What do you see?"),
                .image(jpegData: jpegData, mimeType: "image/jpeg"),
            ])
        ]
        let request = try OllamaProvider.buildNativeRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: messages,
            config: baseConfig
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        #expect(msgs.count == 1)
        #expect(msgs[0]["content"] as? String == "What do you see?")
        let images = msgs[0]["images"] as? [String]
        #expect(images?.count == 1)
        #expect(images?[0] == jpegData.base64EncodedString())
    }
}

// MARK: - OpenAI-compat mode request builder

@Suite("OllamaProvider OpenAI-compat request builder")
struct OllamaProviderOpenAICompatRequestTests {

    private let baseConfig = AIConfig(model: "qwen2.5:14b", temperature: 0.7, maxTokens: 512)

    @Test("Builds POST to /v1/chat/completions")
    func buildsCorrectURL() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildOpenAICompatRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: baseConfig
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/chat/completions")
    }

    @Test("Body matches OpenAI shape with model, max_tokens, temperature, messages")
    func bodyShape() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let config = AIConfig(model: "llama3:8b", temperature: 0.3, maxTokens: 2048)
        let request = try OllamaProvider.buildOpenAICompatRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["model"] as? String == "llama3:8b")
        #expect(body["max_tokens"] as? Int == 2048)
        let temp = body["temperature"] as? Double ?? 0
        #expect(abs(temp - 0.3) < 0.001)
    }

    @Test("Bearer token set in Authorization header")
    func bearerHeader() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildOpenAICompatRequest(
            endpoint: endpoint,
            bearerToken: "tok-abc",
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: baseConfig
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-abc")
    }

    @Test("No Authorization header when bearer is nil")
    func noBearerHeader() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildOpenAICompatRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: baseConfig
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Multipart message serialized as image_url blocks")
    func multipartOpenAICompat() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, parts: [
                .text("Describe this"),
                .image(jpegData: jpegData, mimeType: "image/jpeg"),
            ])
        ]
        let request = try OllamaProvider.buildOpenAICompatRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: messages,
            config: baseConfig
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        let content = msgs[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "image_url")
        let imageUrl = content[1]["image_url"] as! [String: Any]
        let expected = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        #expect(imageUrl["url"] as? String == expected)
    }
}

@Suite("OllamaProvider Anthropic-compat request builder")
struct OllamaProviderAnthropicCompatRequestTests {

    private let baseConfig = AIConfig(model: "qwen3-coder", temperature: 0.2, maxTokens: 1024)

    @Test("Builds POST to /v1/messages with Anthropic tool schema")
    func buildsMessagesRequestWithTools() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildAnthropicCompatRequest(
            endpoint: endpoint,
            bearerToken: nil,
            messages: [ChatMessage(role: .user, content: "Search the live transcript")],
            tools: [
                ToolSpec(
                    name: "search_live_transcript",
                    description: "Search active transcript",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object(["query": .object(["type": .string("string")])]),
                        "required": .array([.string("query")]),
                    ])
                ),
            ],
            config: baseConfig
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["model"] as? String == "qwen3-coder")
        #expect(body["max_tokens"] as? Int == 1024)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "search_live_transcript")
        #expect(tools[0]["input_schema"] != nil)
    }

    @Test("Tool result parts serialize as Anthropic content blocks")
    func serializesToolResults() throws {
        let endpoint = URL(string: "http://localhost:11434")!
        let request = try OllamaProvider.buildAnthropicCompatRequest(
            endpoint: endpoint,
            bearerToken: "ollama-cloud-token",
            messages: [
                ChatMessage(role: .user, parts: [
                    .toolResult(id: "toolu_123", content: "Found budget at 00:14.", isError: false),
                ]),
            ],
            tools: [],
            config: baseConfig
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-cloud-token")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "tool_result")
        #expect(content[0]["tool_use_id"] as? String == "toolu_123")
        #expect(content[0]["content"] as? String == "Found budget at 00:14.")
        #expect(content[0]["is_error"] as? Bool == false)
    }
}

// MARK: - Response parsers

@Suite("OllamaProvider native response parser")
struct OllamaProviderNativeParserTests {

    @Test("Parses message.content from native response")
    func parsesContent() throws {
        let json = """
        {
          "model": "qwen2.5:14b",
          "created_at": "2024-01-01T00:00:00Z",
          "message": {"role": "assistant", "content": "Hello from Ollama!"},
          "done": true
        }
        """
        let result = try OllamaProvider.parseNative(data: Data(json.utf8))
        #expect(result == "Hello from Ollama!")
    }

    @Test("Throws decodingFailed when message key missing")
    func missingMessageKey() {
        let json = #"{"model":"q","done":true}"#
        #expect(throws: AIError.self) {
            try OllamaProvider.parseNative(data: Data(json.utf8))
        }
    }

    @Test("Throws decodingFailed on malformed JSON")
    func malformedJSON() {
        #expect(throws: AIError.self) {
            try OllamaProvider.parseNative(data: Data("{bogus".utf8))
        }
    }
}

@Suite("OllamaProvider OpenAI-compat response parser")
struct OllamaProviderOpenAICompatParserTests {

    @Test("Parses first choice content")
    func parsesFirstChoice() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "choices": [
            {"index": 0, "message": {"role": "assistant", "content": "Ollama compat reply"}, "finish_reason": "stop"}
          ],
          "usage": {"prompt_tokens": 5, "completion_tokens": 4, "total_tokens": 9}
        }
        """
        let result = try OllamaProvider.parseOpenAICompat(data: Data(json.utf8))
        #expect(result == "Ollama compat reply")
    }

    @Test("Throws decodingFailed when choices empty")
    func emptyChoices() {
        let json = """
        {"id":"x","object":"chat.completion","choices":[],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
        """
        #expect(throws: AIError.self) {
            try OllamaProvider.parseOpenAICompat(data: Data(json.utf8))
        }
    }

    @Test("Throws decodingFailed on malformed JSON")
    func malformedJSON() {
        #expect(throws: AIError.self) {
            try OllamaProvider.parseOpenAICompat(data: Data("{bogus".utf8))
        }
    }
}

// MARK: - End-to-end with mock HTTP client

@Suite("OllamaProvider end-to-end native mode")
struct OllamaProviderNativeE2ETests {

    private let endpoint = URL(string: "http://localhost:11434")!

    private func nativeSuccessResponse(_ text: String) -> Data {
        Data("""
        {
          "model": "qwen2.5:14b",
          "created_at": "2024-01-01T00:00:00Z",
          "message": {"role": "assistant", "content": "\(text)"},
          "done": true
        }
        """.utf8)
    }

    @Test("200 native response returns assistant text")
    func successfulNativeResponse() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (nativeSuccessResponse("Native reply"), resp)
            }
        )
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: AIConfig(model: "qwen2.5:14b")
        )
        #expect(reply == "Native reply")
    }

    @Test("401 throws authenticationFailed")
    func unauthorised() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
        )
        await #expect(throws: AIError.authenticationFailed) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: AIConfig(model: "qwen2.5:14b")
            )
        }
    }

    @Test("429 throws rateLimited")
    func rateLimited() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
        )
        await #expect(throws: AIError.rateLimited) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: AIConfig(model: "qwen2.5:14b")
            )
        }
    }

    @Test("500 throws sendFailed")
    func serverError() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data("internal error".utf8), resp)
            }
        )
        await #expect(throws: AIError.self) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: AIConfig(model: "qwen2.5:14b")
            )
        }
    }

    @Test("Bearer token set in native request when provided")
    func bearerInNativeRequest() async throws {
        final class Box: @unchecked Sendable { var captured: URLRequest? }
        let box = Box()

        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            bearerToken: "secret-token",
            httpClient: { request in
                box.captured = request
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("""
                {"model":"q","created_at":"","message":{"role":"assistant","content":"ok"},"done":true}
                """.utf8), resp)
            }
        )
        _ = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: AIConfig(model: "qwen2.5:14b")
        )
        #expect(box.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("Multipart message with image in native mode sends images array")
    func multipartNativeE2E() async throws {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()

        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .native,
            httpClient: { request in
                box.body = request.httpBody
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("""
                {"model":"q","created_at":"","message":{"role":"assistant","content":"I see it."},"done":true}
                """.utf8), resp)
            }
        )

        let jpegBytes = Data([0xFF, 0xD8, 0xFF])
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, parts: [
                .text("Describe the screen."),
                .image(jpegData: jpegBytes, mimeType: "image/jpeg"),
            ])],
            config: AIConfig(model: "qwen2.5:14b")
        )
        #expect(reply == "I see it.")

        let bodyObj = try JSONSerialization.jsonObject(with: box.body ?? Data()) as! [String: Any]
        let msgs = bodyObj["messages"] as! [[String: Any]]
        let images = msgs[0]["images"] as? [String]
        #expect(images?.count == 1)
        #expect(images?[0] == jpegBytes.base64EncodedString())
    }
}

@Suite("OllamaProvider end-to-end OpenAI-compat mode")
struct OllamaProviderCompatE2ETests {

    private let endpoint = URL(string: "http://localhost:11434")!

    private func compatSuccessResponse(_ text: String) -> Data {
        Data("""
        {
          "id": "chatcmpl-ok",
          "object": "chat.completion",
          "choices": [
            {"index": 0, "message": {"role": "assistant", "content": "\(text)"}, "finish_reason": "stop"}
          ],
          "usage": {"prompt_tokens": 5, "completion_tokens": 4, "total_tokens": 9}
        }
        """.utf8)
    }

    @Test("200 compat response returns assistant text")
    func successfulCompatResponse() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .openaiCompat,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/v1/chat/completions")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (compatSuccessResponse("Compat reply"), resp)
            }
        )
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: AIConfig(model: "qwen2.5:14b")
        )
        #expect(reply == "Compat reply")
    }

    @Test("Request URL ends in /v1/chat/completions in compat mode")
    func requestURLCompat() async throws {
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()

        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .openaiCompat,
            httpClient: { request in
                box.url = request.url
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/v1/chat/completions")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("""
                {"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
                """.utf8), resp)
            }
        )
        _ = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: AIConfig(model: "qwen2.5:14b")
        )
        #expect(box.url?.path == "/v1/chat/completions")
    }
}

@Suite("OllamaProvider end-to-end Anthropic-compat mode")
struct OllamaProviderAnthropicCompatE2ETests {

    private let endpoint = URL(string: "http://localhost:11434")!

    @Test("chat with tools posts to /v1/messages and parses tool_use response")
    func chatWithToolsParsesToolUse() async throws {
        final class Box: @unchecked Sendable {
            var request: URLRequest?
        }
        let box = Box()
        let provider = try OllamaProvider(
            endpoint: endpoint,
            apiMode: .anthropicCompat,
            httpClient: { request in
                box.request = request
                let response = HTTPURLResponse(
                    url: URL(string: "http://localhost:11434/v1/messages")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data("""
                {
                  "id": "msg_ollama_tool",
                  "type": "message",
                  "role": "assistant",
                  "content": [
                    {
                      "type": "tool_use",
                      "id": "toolu_live",
                      "name": "search_live_transcript",
                      "input": { "query": "budget" }
                    }
                  ],
                  "stop_reason": "tool_use"
                }
                """.utf8), response)
            }
        )

        let tool = ToolSpec(
            name: "search_live_transcript",
            description: "Search active transcript",
            parameters: .object(["type": .string("object")])
        )

        let response = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "What did we say about budget?")],
            tools: [tool],
            config: AIConfig(model: "qwen3-coder")
        )

        #expect(box.request?.url?.path == "/v1/messages")
        #expect(response.stopReason == .toolUse)
        #expect(response.parts == [
            .toolUse(.init(
                id: "toolu_live",
                name: "search_live_transcript",
                arguments: .object(["query": .string("budget")])
            )),
        ])
    }
}

// MARK: - listModels

@Suite("OllamaProvider listModels")
struct OllamaProviderListModelsTests {

    private let endpoint = URL(string: "http://localhost:11434")!

    @Test("Parses model names from /api/tags response")
    func parsesModelNames() async throws {
        let json = """
        {
          "models": [
            {"name": "qwen2.5:14b", "modified_at": "2024-01-01", "size": 1234},
            {"name": "llama3:8b", "modified_at": "2024-01-01", "size": 5678}
          ]
        }
        """
        let provider = try OllamaProvider(
            endpoint: endpoint,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/tags")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(json.utf8), resp)
            }
        )
        let models = try await provider.listModels()
        #expect(models == ["qwen2.5:14b", "llama3:8b"])
    }

    @Test("Returns empty array when models list is empty")
    func emptyModels() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/tags")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"models":[]}"#.utf8), resp)
            }
        )
        let models = try await provider.listModels()
        #expect(models.isEmpty)
    }

    @Test("Non-200 from /api/tags throws sendFailed")
    func nonSuccessThrows() async throws {
        let provider = try OllamaProvider(
            endpoint: endpoint,
            httpClient: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/tags")!,
                    statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data("error".utf8), resp)
            }
        )
        await #expect(throws: AIError.self) {
            _ = try await provider.listModels()
        }
    }
}
