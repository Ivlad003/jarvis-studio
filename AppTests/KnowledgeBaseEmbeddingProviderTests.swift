import Foundation
import Testing
import StorageKit
@testable import KosmoNotes

@MainActor
@Suite("Knowledge base embedding provider", .serialized)
struct KnowledgeBaseEmbeddingProviderTests {
    @Test("settings-gated provider refuses embedding when semantic search is disabled")
    func refusesWhenSemanticSearchDisabled() async {
        let prior = UserDefaults.standard.object(forKey: "semanticSearchEnabled")
        defer { restore(prior, forKey: "semanticSearchEnabled") }

        let settings = AppSettings()
        settings.semanticSearchEnabled = false
        settings.openaiApiKey = "sk-test"
        let provider = AppSettingsKnowledgeBaseEmbeddingProvider(
            settings: settings,
            providerFactory: { _ in FixedKnowledgeBaseEmbedder(vector: [1, 0]) }
        )

        await #expect(throws: KnowledgeBaseEmbeddingProviderUnavailable.disabled) {
            _ = try await provider.embed("roadmap")
        }
    }

    @Test("settings-gated provider delegates with the current OpenAI key")
    func delegatesWithCurrentOpenAIKey() async throws {
        let prior = UserDefaults.standard.object(forKey: "semanticSearchEnabled")
        defer { restore(prior, forKey: "semanticSearchEnabled") }

        let settings = AppSettings()
        settings.semanticSearchEnabled = true
        settings.openaiApiKey = "  sk-live-test  "
        let box = CapturedEmbeddingKeys()
        let provider = AppSettingsKnowledgeBaseEmbeddingProvider(
            settings: settings,
            providerFactory: { key in
                FixedKnowledgeBaseEmbedder(vector: [0.25, 0.75], onEmbed: {
                    await box.append(key)
                })
            }
        )

        let vector = try await provider.embed("roadmap")

        #expect(vector == [0.25, 0.75])
        #expect(await box.keys == ["sk-live-test"])
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor CapturedEmbeddingKeys {
    private(set) var keys: [String] = []

    func append(_ key: String) {
        keys.append(key)
    }
}

private struct FixedKnowledgeBaseEmbedder: KnowledgeBaseEmbeddingProvider {
    let modelIdentifier = "fixed-test-embedder"
    let vector: [Float]
    let onEmbed: (@Sendable () async -> Void)?

    init(vector: [Float], onEmbed: (@Sendable () async -> Void)? = nil) {
        self.vector = vector
        self.onEmbed = onEmbed
    }

    func embed(_ text: String) async throws -> [Float] {
        await onEmbed?()
        return vector
    }
}
