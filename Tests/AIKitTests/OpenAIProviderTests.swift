import Foundation
import Testing
@testable import AIKit

// MARK: - Request builder

@Suite("OpenAIProvider request builder")
struct OpenAIProviderRequestTests {

    private let baseConfig = AIConfig(model: "gpt-4o-mini", temperature: 0.7, maxTokens: 512)

    @Test("Builds POST with Bearer auth header")
    func buildsBearerAuth() throws {
        let request = try OpenAIProvider.buildRequest(
            endpoint: OpenAIProvider.defaultEndpoint,
            apiKey: "sk-openai-test",
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: baseConfig
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai-test")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test("System role messages are kept in messages array (not separated)")
    func systemInMessagesArray() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "Be concise."),
            ChatMessage(role: .user, content: "Hi"),
        ]
        let request = try OpenAIProvider.buildRequest(
            endpoint: OpenAIProvider.defaultEndpoint,
            apiKey: "sk-x",
            messages: messages,
            config: baseConfig
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 2)
        #expect(msgs[0]["role"] as? String == "system")
        // single text-only part serializes as a plain string
        #expect(msgs[0]["content"] as? String == "Be concise.")
        #expect(msgs[1]["role"] as? String == "user")
    }

    @Test("config.systemPrompt is prepended as first system message")
    func configSystemPromptPrepended() throws {
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Hi")]
        let config = AIConfig(model: "gpt-4o-mini", systemPrompt: "You are a poet.")
        let request = try OpenAIProvider.buildRequest(
            endpoint: OpenAIProvider.defaultEndpoint,
            apiKey: "sk-x",
            messages: messages,
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 2)
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[0]["content"] as? String == "You are a poet.")
        #expect(msgs[1]["role"] as? String == "user")
    }

    @Test("model, max_completion_tokens, temperature are serialized correctly")
    func parametersSerialised() throws {
        let config = AIConfig(model: "gpt-4o", temperature: 0.5, maxTokens: 1000)
        let request = try OpenAIProvider.buildRequest(
            endpoint: OpenAIProvider.defaultEndpoint,
            apiKey: "sk-x",
            messages: [ChatMessage(role: .user, content: "x")],
            config: config
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["model"] as? String == "gpt-4o")
        #expect(body["max_completion_tokens"] as? Int == 1000)
        #expect(body["max_tokens"] == nil)
        let temp = body["temperature"] as? Double ?? 0
        #expect(abs(temp - 0.5) < 0.001)
    }

    @Test("Multipart user message: text + image serialized as content block array")
    func multipartImageBlock() throws {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, parts: [
                .text("What's on screen at 0:30?"),
                .image(jpegData: jpegData, mimeType: "image/jpeg"),
            ])
        ]
        let request = try OpenAIProvider.buildRequest(
            endpoint: OpenAIProvider.defaultEndpoint,
            apiKey: "sk-x",
            messages: messages,
            config: baseConfig
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        #expect(msgs.count == 1)
        #expect(msgs[0]["role"] as? String == "user")

        let content = msgs[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "What's on screen at 0:30?")
        #expect(content[1]["type"] as? String == "image_url")
        let imageUrl = content[1]["image_url"] as! [String: Any]
        let expectedURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        #expect(imageUrl["url"] as? String == expectedURL)
    }
}

// MARK: - Response parser

@Suite("OpenAIProvider response parser")
struct OpenAIProviderParserTests {

    @Test("Parses first choice content")
    func parsesFirstChoice() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": "Hello!"},
              "finish_reason": "stop"
            }
          ],
          "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}
        }
        """
        let result = try OpenAIProvider.parse(data: Data(json.utf8))
        #expect(result == "Hello!")
    }

    @Test("Throws decodingFailed on malformed JSON")
    func malformedJSON() {
        #expect(throws: AIError.self) {
            try OpenAIProvider.parse(data: Data("{bogus".utf8))
        }
    }

    @Test("Throws decodingFailed when choices array is empty")
    func emptyChoices() {
        let json = """
        {"id":"x","object":"chat.completion","choices":[],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
        """
        #expect(throws: AIError.self) {
            try OpenAIProvider.parse(data: Data(json.utf8))
        }
    }
}

// MARK: - End-to-end with mock HTTP client

@Suite("OpenAIProvider end-to-end with mock HTTP")
struct OpenAIProviderE2ETests {

    private let config = AIConfig(model: "gpt-4o-mini")

    private func successResponse(_ text: String) -> Data {
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

    @Test("200 response returns assistant text")
    func successfulResponse() async throws {
        let provider = OpenAIProvider(apiKey: "sk-test", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (successResponse("Hi there!"), resp)
        })
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: config
        )
        #expect(reply == "Hi there!")
    }

    @Test("401 response throws authenticationFailed")
    func unauthorised() async throws {
        let provider = OpenAIProvider(apiKey: "sk-bad", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
                statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"error\":{\"message\":\"Incorrect API key\"}}".utf8), resp)
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
        let provider = OpenAIProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
                statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (Data("{\"error\":{\"message\":\"Rate limit exceeded\"}}".utf8), resp)
        })
        await #expect(throws: AIError.rateLimited) {
            _ = try await provider.chat(
                messages: [ChatMessage(role: .user, content: "Hello")],
                config: config
            )
        }
    }

    @Test("500 response throws sendFailed")
    func serverError() async throws {
        let provider = OpenAIProvider(apiKey: "sk-x", httpClient: { _ in
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
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

    @Test("Bearer token is sent in Authorization header")
    func apiKeyInHeader() async throws {
        final class Box: @unchecked Sendable { var captured: URLRequest? }
        let box = Box()

        let provider = OpenAIProvider(apiKey: "sk-captured", httpClient: { request in
            box.captured = request
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("""
            {"id":"x","object":"chat.completion",
             "choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
            """.utf8), resp)
        })

        _ = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config
        )
        #expect(box.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-captured")
    }

    @Test("Multipart message with image is sent and response is parsed as text")
    func multipartRoundTrip() async throws {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()

        let provider = OpenAIProvider(apiKey: "sk-x", httpClient: { request in
            box.body = request.httpBody
            let resp = HTTPURLResponse(
                url: OpenAIProvider.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("""
            {"id":"x","object":"chat.completion",
             "choices":[{"index":0,"message":{"role":"assistant","content":"A terminal window."},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":50,"completion_tokens":5,"total_tokens":55}}
            """.utf8), resp)
        })

        let jpegBytes = Data([0xFF, 0xD8, 0xFF])
        let reply = try await provider.chat(
            messages: [ChatMessage(role: .user, parts: [
                .text("Describe the screen."),
                .image(jpegData: jpegBytes, mimeType: "image/jpeg"),
            ])],
            config: AIConfig(model: "gpt-4o-mini")
        )
        #expect(reply == "A terminal window.")

        // Verify the request body contained an image_url block.
        let bodyObj = try JSONSerialization.jsonObject(with: box.body ?? Data()) as! [String: Any]
        let msgs = bodyObj["messages"] as! [[String: Any]]
        let content = msgs[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[1]["type"] as? String == "image_url")
    }
}
