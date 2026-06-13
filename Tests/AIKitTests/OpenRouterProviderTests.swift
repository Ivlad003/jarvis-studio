import Foundation
import Testing
@testable import AIKit

@Suite("OpenRouterProvider request builder")
struct OpenRouterProviderRequestTests {

    @Test("serializes max_completion_tokens instead of deprecated max_tokens")
    func serializesMaxCompletionTokens() throws {
        let request = try OpenRouterProvider.buildRequest(
            endpoint: OpenRouterProvider.defaultEndpoint,
            apiKey: "sk-openrouter-test",
            referer: "https://kosmonotes.test",
            title: "KosmoNotes Test",
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: AIConfig(model: "openai/gpt-4o", temperature: 0.2, maxTokens: 777)
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        #expect(body["max_completion_tokens"] as? Int == 777)
        #expect(body["max_tokens"] == nil)
    }

    @Test("chat with tools sends tool schema and parses tool calls")
    func chatWithToolsSendsToolSchemaAndParsesToolCalls() async throws {
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()
        let provider = OpenRouterProvider(apiKey: "sk-openrouter-test", httpClient: { request in
            box.body = request.httpBody
            let response = HTTPURLResponse(
                url: OpenRouterProvider.defaultEndpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("""
            {
              "id": "or-tool-call",
              "object": "chat.completion",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [
                      {
                        "id": "call_search",
                        "type": "function",
                        "function": {
                          "name": "search_live_transcript",
                          "arguments": "{\\"query\\":\\"budget\\"}"
                        }
                      }
                    ]
                  },
                  "finish_reason": "tool_calls"
                }
              ]
            }
            """.utf8), response)
        })
        let tool = ToolSpec(
            name: "search_live_transcript",
            description: "Search active transcript",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]),
            ])
        )

        let response = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "What about budget?")],
            tools: [tool],
            config: AIConfig(model: "anthropic/claude-3.5-sonnet")
        )

        let body = try JSONSerialization.jsonObject(with: box.body ?? Data()) as! [String: Any]
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "search_live_transcript")
        #expect(response.stopReason == .toolUse)
        #expect(response.parts == [
            .toolUse(.init(
                id: "call_search",
                name: "search_live_transcript",
                arguments: .object(["query": .string("budget")])
            )),
        ])
    }
}
