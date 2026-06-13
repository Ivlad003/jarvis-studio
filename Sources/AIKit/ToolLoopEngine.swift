import Foundation

public struct ToolExecutionResult: Sendable, Equatable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct ToolDefinition: Sendable {
    public let spec: ToolSpec
    public let execute: @Sendable (JSONValue) async -> ToolExecutionResult

    public init(
        spec: ToolSpec,
        execute: @escaping @Sendable (JSONValue) async -> ToolExecutionResult
    ) {
        self.spec = spec
        self.execute = execute
    }
}

public struct ToolLoopEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case assistantText
        case toolCall
        case toolResult
        case error
        case stop
    }

    public let kind: Kind
    public let text: String
    public let toolName: String?

    public init(kind: Kind, text: String, toolName: String? = nil) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
    }
}

public struct ToolLoopRunResult: Sendable, Equatable {
    public let response: ChatResponse
    public let transcript: [ChatMessage]

    public init(response: ChatResponse, transcript: [ChatMessage]) {
        self.response = response
        self.transcript = transcript
    }
}

public actor ToolLoopEngine {
    public typealias EventHandler = @Sendable (ToolLoopEvent) -> Void

    public static let defaultMaxTranscriptBytes = 200_000

    private let provider: any AIProvider
    private let tools: [ToolDefinition]
    private let config: AIConfig
    private let maxIterations: Int
    private let maxTranscriptBytes: Int
    private let onEvent: EventHandler

    public init(
        provider: any AIProvider,
        tools: [ToolDefinition],
        config: AIConfig,
        maxIterations: Int = 12,
        maxTranscriptBytes: Int = ToolLoopEngine.defaultMaxTranscriptBytes,
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.provider = provider
        self.tools = tools
        self.config = config
        self.maxIterations = max(1, maxIterations)
        self.maxTranscriptBytes = max(1_000, maxTranscriptBytes)
        self.onEvent = onEvent
    }

    public func run(messages initialMessages: [ChatMessage]) async throws -> ChatResponse {
        try await runWithTranscript(messages: initialMessages).response
    }

    public func runWithTranscript(messages initialMessages: [ChatMessage]) async throws -> ToolLoopRunResult {
        var transcript = initialMessages
        let specs = tools.map(\.spec)

        for _ in 0..<maxIterations {
            try enforceByteBudget(transcript)
            let response = try await provider.chat(messages: transcript, tools: specs, config: config)

            for part in response.parts {
                switch part {
                case .text(let text) where !text.isEmpty:
                    emit(.init(kind: .assistantText, text: text))
                case .toolUse(let call):
                    emit(.init(kind: .toolCall, text: call.argumentsDescription, toolName: call.name))
                case .text, .image, .toolResult:
                    break
                }
            }

            let calls = response.parts.compactMap { part -> ToolCall? in
                guard case .toolUse(let call) = part else { return nil }
                return call
            }
            transcript.append(ChatMessage(role: .assistant, parts: response.parts))

            guard response.stopReason == .toolUse, !calls.isEmpty else {
                emit(.init(kind: .stop, text: "Tool loop finished (\(response.stopReason.rawValue))."))
                return ToolLoopRunResult(response: response, transcript: transcript)
            }

            var resultParts: [ChatMessage.Part] = []
            for call in calls {
                let result = await execute(call)
                emit(.init(kind: .toolResult, text: result.content, toolName: call.name))
                resultParts.append(.toolResult(id: call.id, content: result.content, isError: result.isError))
            }
            transcript.append(ChatMessage(role: .user, parts: resultParts))
        }

        emit(.init(kind: .error, text: "Tool loop reached max iterations (\(maxIterations))."))
        throw AIError.sendFailed(message: "Tool loop reached max iterations (\(maxIterations))")
    }

    private func execute(_ call: ToolCall) async -> ToolExecutionResult {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return ToolExecutionResult(
                content: "Unknown tool: \(call.name). Available: \(tools.map(\.spec.name).joined(separator: ", "))",
                isError: true
            )
        }
        return await tool.execute(call.arguments)
    }

    private func enforceByteBudget(_ transcript: [ChatMessage]) throws {
        let data = try JSONEncoder().encode(transcript)
        guard data.count <= maxTranscriptBytes else {
            throw AIError.sendFailed(
                message: "Tool loop transcript exceeded \(maxTranscriptBytes) bytes"
            )
        }
    }

    private func emit(_ event: ToolLoopEvent) {
        onEvent(event)
    }
}

private extension ToolCall {
    var argumentsDescription: String {
        (try? arguments.jsonString()) ?? String(describing: arguments)
    }
}
