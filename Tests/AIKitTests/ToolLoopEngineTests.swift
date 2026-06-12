import Foundation
import Testing
@testable import AIKit

@Suite("ToolLoopEngine")
struct ToolLoopEngineTests {
    @Test("executes requested tool and sends tool result into the next provider turn")
    func executesRequestedToolAndSendsToolResult() async throws {
        let provider = ScriptedToolProvider()
        let tool = ToolDefinition(
            spec: ToolSpec(
                name: "search_live_transcript",
                description: "Search active transcript",
                parameters: .object(["type": .string("object")])
            ),
            execute: { arguments in
                #expect(arguments == .object(["query": .string("budget")]))
                return ToolExecutionResult(content: "budget is due Friday")
            }
        )
        let engine = ToolLoopEngine(
            provider: provider,
            tools: [tool],
            config: AIConfig(model: "mock"),
            maxIterations: 4,
            maxTranscriptBytes: 20_000,
            onEvent: { _ in }
        )

        let response = try await engine.run(
            messages: [ChatMessage(role: .user, content: "What was said about budget?")]
        )

        #expect(response.text == "Budget is due Friday.")
        #expect(await provider.calls.count == 2)
        let secondCall = try #require(await provider.calls.last)
        #expect(secondCall.messages.contains {
            $0.parts == [.toolResult(id: "toolu_1", content: "budget is due Friday", isError: false)]
        })
    }

    @Test("unknown tool names are folded back as error tool results")
    func unknownToolsAreFoldedBackAsErrorResults() async throws {
        let provider = UnknownToolProvider()
        let engine = ToolLoopEngine(
            provider: provider,
            tools: [],
            config: AIConfig(model: "mock"),
            maxIterations: 4,
            maxTranscriptBytes: 20_000,
            onEvent: { _ in }
        )

        _ = try await engine.run(messages: [ChatMessage(role: .user, content: "Use a tool")])

        let secondCall = try #require(await provider.calls.last)
        let resultPart = secondCall.messages.flatMap(\.parts).compactMap { part -> ChatMessage.Part? in
            guard case .toolResult = part else { return nil }
            return part
        }.first
        #expect(resultPart == .toolResult(id: "toolu_missing", content: "Unknown tool: missing_tool. Available: ", isError: true))
    }
}

private actor ToolProviderCalls {
    private(set) var calls: [(messages: [ChatMessage], tools: [ToolSpec])] = []

    var count: Int { calls.count }
    var last: (messages: [ChatMessage], tools: [ToolSpec])? { calls.last }

    func append(messages: [ChatMessage], tools: [ToolSpec]) {
        calls.append((messages, tools))
    }
}

private struct ScriptedToolProvider: AIProvider {
    let calls = ToolProviderCalls()

    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        ""
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        await calls.append(messages: messages, tools: tools)
        if await calls.calls.count == 1 {
            #expect(tools.map(\.name) == ["search_live_transcript"])
            return ChatResponse(parts: [
                .text("I will search."),
                .toolUse(.init(
                    id: "toolu_1",
                    name: "search_live_transcript",
                    arguments: .object(["query": .string("budget")])
                )),
            ], stopReason: .toolUse)
        }
        return ChatResponse(parts: [.text("Budget is due Friday.")], stopReason: .endTurn)
    }
}

private struct UnknownToolProvider: AIProvider {
    let calls = ToolProviderCalls()

    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        ""
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        await calls.append(messages: messages, tools: tools)
        if await calls.calls.count == 1 {
            return ChatResponse(parts: [
                .toolUse(.init(id: "toolu_missing", name: "missing_tool", arguments: .object([:]))),
            ], stopReason: .toolUse)
        }
        return ChatResponse(parts: [.text("Done")], stopReason: .endTurn)
    }
}
