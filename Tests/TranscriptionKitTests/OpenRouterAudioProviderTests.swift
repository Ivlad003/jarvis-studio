import Foundation
import Testing
@testable import TranscriptionKit

@Suite("OpenRouterAudioProvider")
struct OpenRouterAudioProviderTests {
    @Test("request uses max_completion_tokens instead of deprecated max_tokens")
    func requestUsesMaxCompletionTokens() async throws {
        let audioURL = URL.temporaryDirectory.appendingPathComponent("openrouter-audio-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let capture = RequestBodyCapture()
        let provider = OpenRouterAudioProvider(apiKey: "test") { request in
            capture.store(request.httpBody)
            let content = #"{"language":"en","segments":[{"start":0,"end":1,"text":"hello"}],"full_text":"hello"}"#
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [
                    ["message": ["content": content]],
                ],
            ])
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, http)
        }

        _ = try await provider.transcribe(audioFile: audioURL, config: TranscriptionConfig(language: "en"))

        let body = try #require(capture.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["max_completion_tokens"] as? Int == 16_384)
        #expect(json?["max_tokens"] == nil)
    }
}

private final class RequestBodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    var body: Data? {
        lock.withLock { value }
    }

    func store(_ body: Data?) {
        lock.withLock {
            value = body
        }
    }
}
