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
}
