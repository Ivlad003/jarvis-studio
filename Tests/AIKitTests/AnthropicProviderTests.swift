import Foundation
import Testing
@testable import AIKit

// MARK: - Request builder

@Suite("AnthropicProvider request builder")
struct AnthropicProviderRequestTests {

    private let baseConfig = AIConfig(model: "claude-sonnet-4-6", temperature: 0.7, maxTokens: 512)

    @Test("Builds POST with x-api-key and anthropic-version headers")
    func buildsAuthHeaders() throws {
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-test",
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: baseConfig
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test("System messages are removed from messages array and placed in top-level system field")
    func systemMessageSeparated() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "Hi"),
        ]
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-x",
            messages: messages,
            config: baseConfig
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let system = body["system"] as? String
        #expect(system == "You are helpful.")

        let msgs = body["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 1)
        #expect(msgs[0]["role"] as? String == "user")
    }

    @Test("config.systemPrompt takes precedence over system ChatMessage")
    func configSystemPromptWins() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "From message."),
            ChatMessage(role: .user, content: "Hi"),
        ]
        let config = AIConfig(model: "claude-sonnet-4-6", systemPrompt: "From config.")
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-x",
            messages: messages,
            config: config
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["system"] as? String == "From config.")
    }

    @Test("No system field when no system prompt and no system messages")
    func noSystemFieldWhenAbsent() throws {
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hey")]
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-x",
            messages: messages,
            config: baseConfig
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["system"] == nil)
    }

    @Test("model, max_tokens, temperature are serialized correctly")
    func parametersSerialised() throws {
        let config = AIConfig(model: "claude-opus-4", temperature: 0.3, maxTokens: 2048)
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-x",
            messages: [ChatMessage(role: .user, content: "x")],
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["model"] as? String == "claude-opus-4")
        #expect(body["max_tokens"] as? Int == 2048)
        let temp = body["temperature"] as? Double ?? 0
        #expect(abs(temp - 0.3) < 0.001)
    }

    @Test("Multipart user message: text + image serialized as content block array")
    func multipartImageBlock() throws {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])  // minimal JPEG header bytes
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, parts: [
                .text("What is on screen at 0:30?"),
                .image(jpegData: jpegData, mimeType: "image/jpeg"),
            ])
        ]
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-x",
            messages: messages,
            config: baseConfig
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        #expect(msgs.count == 1)
        #expect(msgs[0]["role"] as? String == "user")

        // content must be an array of blocks (not a plain string) when there are image parts.
        let content = msgs[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "What is on screen at 0:30?")
        #expect(content[1]["type"] as? String == "image")
        let source = content[1]["source"] as! [String: Any]
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == jpegData.base64EncodedString())
    }

    @Test("Tool specs are serialized as Anthropic input schemas")
    func toolSpecsSerializedAsInputSchemas() throws {
        let request = try AnthropicProvider.buildRequest(
            endpoint: AnthropicProvider.defaultEndpoint,
            apiKey: "sk-ant-x",
            messages: [ChatMessage(role: .user, content: "Search")],
            tools: [
                ToolSpec(
                    name: "search_live_transcript",
                    description: "Search the active transcript",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object(["type": .string("string")]),
                        ]),
                    ])
                ),
            ],
            config: baseConfig
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "search_live_transcript")
        #expect(tools[0]["description"] as? String == "Search the active transcript")
        let inputSchema = tools[0]["input_schema"] as! [String: Any]
        #expect(inputSchema["type"] as? String == "object")
    }
}

// MARK: - Response parser

@Suite("AnthropicProvider response parser")
struct AnthropicProviderParserTests {

    @Test("Parses single text block")
    func parsesSingleBlock() throws {
        let json = """
        {
          "id": "msg_01",
          "type": "message",
          "role": "assistant",
          "content": [{"type": "text", "text": "Hello there!"}],
          "stop_reason": "end_turn",
          "model": "claude-sonnet-4-6",
          "usage": {"input_tokens": 5, "output_tokens": 3}
        }
        """
        let result = try AnthropicProvider.parse(data: Data(json.utf8))
        #expect(result == "Hello there!")
    }

    @Test("Concatenates multiple text blocks in order")
    func concatenatesMultipleBlocks() throws {
        let json = """
        {
          "id": "msg_02",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "Part one. "},
            {"type": "text", "text": "Part two."}
          ],
          "stop_reason": "end_turn",
          "model": "claude-sonnet-4-6",
          "usage": {"input_tokens": 5, "output_tokens": 6}
        }
        """
        let result = try AnthropicProvider.parse(data: Data(json.utf8))
        #expect(result == "Part one. Part two.")
    }

    @Test("Ignores non-text content blocks (e.g. tool_use)")
    func ignoresNonTextBlocks() throws {
        let json = """
        {
          "id": "msg_03",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "tool_use", "id": "tu_1", "name": "search", "input": {}},
            {"type": "text", "text": "After tool."}
          ],
          "stop_reason": "tool_use",
          "model": "claude-sonnet-4-6",
          "usage": {"input_tokens": 10, "output_tokens": 3}
        }
        """
        let result = try AnthropicProvider.parse(data: Data(json.utf8))
        #expect(result == "After tool.")
    }

    @Test("Parses text and tool_use blocks with stop reason")
    func parsesTextAndToolUseBlocks() throws {
        let json = """
        {
          "id": "msg_04",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "I will search."},
            {
              "type": "tool_use",
              "id": "toolu_1",
              "name": "search_live_transcript",
              "input": {"query": "budget"}
            }
          ],
          "stop_reason": "tool_use",
          "model": "claude-sonnet-4-6",
          "usage": {"input_tokens": 10, "output_tokens": 3}
        }
        """

        let response = try AnthropicProvider.parseResponse(data: Data(json.utf8))

        #expect(response.stopReason == .toolUse)
        #expect(response.parts == [
            .text("I will search."),
            .toolUse(.init(
                id: "toolu_1",
                name: "search_live_transcript",
                arguments: .object(["query": .string("budget")])
            )),
        ])
    }

    @Test("Throws decodingFailed on malformed JSON")
    func malformedJSON() {
        #expect(throws: AIError.self) {
            try AnthropicProvider.parse(data: Data("{bogus".utf8))
        }
    }
}

// MARK: - End-to-end with mock HTTP client

@Suite("AnthropicProvider end-to-end with mock HTTP")
struct AnthropicProviderE2ETests {

    private let config = AIConfig(model: "claude-sonnet-4-6")

    private func successResponse(_ text: String) -> Data {
        Data("""
        {
          "id": "msg_ok",
          "type": "message",
          "role": "assistant",
          "content": [{"type": "text", "text": "\(text)"}],
          "stop_reason": "end_turn",
          "model": "claude-sonnet-4-6",
          "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """.utf8)
    }

    @Test("200 response returns assistant text")
    func successfulResponse() async throws {
        let provider = AnthropicProvider(apiKey: "sk-ant-test", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (successResponse("Great question!"), resp)
        })
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "What is Swift?")],
            config: config
        )
        #expect(reply == "Great question!")
    }

    @Test("401 response throws authenticationFailed")
    func unauthorised() async throws {
        let provider = AnthropicProvider(apiKey: "sk-bad", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"error\":{\"type\":\"authentication_error\"}}".utf8), resp)
        })
        await #expect(throws: AIError.authenticationFailed) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hello")],
                config: config
            )
        }
    }

    @Test("429 response throws rateLimited")
    func rateLimited() async throws {
        let provider = AnthropicProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"error\":{\"type\":\"rate_limit_error\"}}".utf8), resp)
        })
        await #expect(throws: AIError.rateLimited) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hello")],
                config: config
            )
        }
    }

    @Test("500 response throws sendFailed with body")
    func serverError() async throws {
        let provider = AnthropicProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (Data("internal server error".utf8), resp)
        })
        await #expect(throws: AIError.self) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hello")],
                config: config
            )
        }
    }

    @Test("Correct API key is sent in x-api-key header")
    func apiKeyInHeader() async throws {
        final class Box: @unchecked Sendable { var captured: URLRequest? }
        let box = Box()

        let provider = AnthropicProvider(apiKey: "sk-ant-captured", httpClient: { request in
            box.captured = request
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("""
            {"id":"m","type":"message","role":"assistant",
             "content":[{"type":"text","text":"ok"}],
             "stop_reason":"end_turn","model":"c","usage":{"input_tokens":1,"output_tokens":1}}
            """.utf8), resp)
        })

        _ = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config
        )
        #expect(box.captured?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-captured")
    }

    @Test("Multipart message with image is sent and response is parsed as text")
    func multipartRoundTrip() async throws {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()

        let provider = AnthropicProvider(apiKey: "sk-ant-x", httpClient: { request in
            box.body = request.httpBody
            let resp = HTTPURLResponse(
                url: AnthropicProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("""
            {"id":"m","type":"message","role":"assistant",
             "content":[{"type":"text","text":"I see a code editor."}],
             "stop_reason":"end_turn","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":10}}
            """.utf8), resp)
        })

        let jpegBytes = Data([0xFF, 0xD8, 0xFF])
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, parts: [
                .text("Describe the screen."),
                .image(jpegData: jpegBytes, mimeType: "image/jpeg"),
            ])],
            config: AIConfig(model: "claude-sonnet-4-6")
        )
        #expect(reply == "I see a code editor.")

        // Verify the request body contained an image block.
        let bodyObj = try JSONSerialization.jsonObject(with: box.body ?? Data()) as! [String: Any]
        let msgs = bodyObj["messages"] as! [[String: Any]]
        let content = msgs[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[1]["type"] as? String == "image")
    }
}

// MARK: - ChatMessage.text accessor

@Suite("ChatMessage.text accessor")
struct ChatMessageTextTests {

    @Test("text-only message returns the text")
    func textOnly() {
        let msg = ChatMessage(role: .user, content: "Hello world")
        #expect(msg.text == "Hello world")
    }

    @Test("image-only message returns empty text")
    func imageOnly() {
        let msg = ChatMessage(role: .user, parts: [.image(jpegData: Data([0x00]), mimeType: "image/jpeg")])
        #expect(msg.text == "")
    }

    @Test("mixed parts joins text parts with space")
    func mixedParts() {
        let msg = ChatMessage(role: .user, parts: [
            .text("First"),
            .image(jpegData: Data([0x00]), mimeType: "image/jpeg"),
            .text("Second"),
        ])
        #expect(msg.text == "First Second")
    }
}
