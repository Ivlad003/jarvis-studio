import Foundation

// MARK: - AIProvider

/// Single-shot (non-streaming) chat completion. Streaming is v1.1.
public protocol AIProvider: Sendable {
    /// Returns the assistant's reply text. Throws `AIError` on failure.
    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String

    /// Returns structured assistant response parts. Providers that do not
    /// support tools can rely on the default text-only wrapper.
    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse
}

public extension AIProvider {
    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        let text = try await chat(messages: messages, config: config)
        return ChatResponse(parts: [.text(text)], stopReason: .endTurn)
    }
}
