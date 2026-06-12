import Foundation
import Testing
@testable import AIKit

@Suite("AIKit tool model")
struct ToolModelTests {
    @Test("JSONValue round trips nested tool schemas")
    func jsonValueRoundTripsNestedToolSchemas() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query"),
                ]),
            ]),
            "required": .array([.string("query")]),
        ])

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == schema)
    }

    @Test("chat message parts can carry tool calls and tool results")
    func chatMessagePartsCanCarryToolCallsAndToolResults() throws {
        let call = ToolCall(
            id: "call_1",
            name: "search_live_transcript",
            arguments: .object(["query": .string("budget")])
        )
        let message = ChatMessage(role: .assistant, parts: [
            .text("I will check."),
            .toolUse(call),
            .toolResult(id: "call_1", content: "No budget mention yet.", isError: false),
        ])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(decoded == message)
        #expect(decoded.text == "I will check.")
    }

    @Test("AIProvider tool overload defaults to text response")
    func aiProviderToolOverloadDefaultsToTextResponse() async throws {
        let provider = TextOnlyProvider()

        let response = try await provider.chat(
            messages: [ChatMessage(role: .user, content: "Hello")],
            tools: [
                ToolSpec(
                    name: "search",
                    description: "Search",
                    parameters: .object(["type": .string("object")])
                ),
            ],
            config: AIConfig(model: "mock")
        )

        #expect(response.text == "plain reply")
        #expect(response.parts == [.text("plain reply")])
        #expect(response.stopReason == .endTurn)
    }
}

private struct TextOnlyProvider: AIProvider {
    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        "plain reply"
    }
}
