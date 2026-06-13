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

    @Test("runWithTranscript returns tool turns for UI display")
    func runWithTranscriptReturnsToolTurnsForUIDisplay() async throws {
        let provider = ScriptedToolProvider()
        let tool = ToolDefinition(
            spec: ToolSpec(
                name: "search_live_transcript",
                description: "Search active transcript",
                parameters: .object(["type": .string("object")])
            ),
            execute: { _ in ToolExecutionResult(content: "budget is due Friday") }
        )
        let engine = ToolLoopEngine(
            provider: provider,
            tools: [tool],
            config: AIConfig(model: "mock"),
            maxIterations: 4,
            maxTranscriptBytes: 20_000
        )

        let result = try await engine.runWithTranscript(
            messages: [ChatMessage(role: .user, content: "What was said about budget?")]
        )

        #expect(result.response.text == "Budget is due Friday.")
        #expect(result.transcript.count == 4)
        #expect(result.transcript[1].parts.contains {
            guard case .toolUse(let call) = $0 else { return false }
            return call.name == "search_live_transcript"
        })
        #expect(result.transcript[2].parts == [
            .toolResult(id: "toolu_1", content: "budget is due Friday", isError: false),
        ])
        #expect(result.transcript[3].text == "Budget is due Friday.")
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

    @Test("tool results can carry image attachments into the next provider turn")
    func toolResultsCanCarryImageAttachmentsIntoNextProviderTurn() async throws {
        let provider = ScreenFrameToolProvider()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let tool = ToolDefinition(
            spec: ToolSpec(
                name: "get_screen_frame",
                description: "Extract a screen frame",
                parameters: .object(["type": .string("object")])
            ),
            execute: { _ in
                ToolExecutionResult(
                    content: "Frame extracted at 00:05.",
                    attachments: [.image(jpegData: jpeg, mimeType: "image/jpeg")]
                )
            }
        )
        let engine = ToolLoopEngine(
            provider: provider,
            tools: [tool],
            config: AIConfig(model: "mock"),
            maxIterations: 4,
            maxTranscriptBytes: 20_000
        )

        _ = try await engine.run(messages: [
            ChatMessage(role: .user, content: "Show me the screen at 00:05"),
        ])

        let secondCall = try #require(await provider.calls.last)
        #expect(secondCall.messages.contains {
            $0.parts == [.toolResult(id: "toolu_frame", content: "Frame extracted at 00:05.", isError: false)]
        })
        #expect(secondCall.messages.contains {
            $0.parts.contains(.image(jpegData: jpeg, mimeType: "image/jpeg"))
        })
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

private struct ScreenFrameToolProvider: AIProvider {
    let calls = ToolProviderCalls()

    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        ""
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        await calls.append(messages: messages, tools: tools)
        if await calls.calls.count == 1 {
            #expect(tools.map(\.name) == ["get_screen_frame"])
            return ChatResponse(parts: [
                .toolUse(.init(
                    id: "toolu_frame",
                    name: "get_screen_frame",
                    arguments: .object(["timestamp": .number(5)])
                )),
            ], stopReason: .toolUse)
        }
        return ChatResponse(parts: [.text("I can see the frame.")], stopReason: .endTurn)
    }
}
