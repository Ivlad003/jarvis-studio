import AIKit
import Foundation
import StorageKit

enum KnowledgeBaseEmbeddingProviderUnavailable: Error, Equatable {
    case disabled
    case missingAPIKey
}

@available(macOS 14.0, *)
struct AppSettingsKnowledgeBaseEmbeddingProvider: KnowledgeBaseEmbeddingProvider, @unchecked Sendable {
    typealias ProviderFactory = @Sendable (String) -> any KnowledgeBaseEmbeddingProvider

    let modelIdentifier: String
    private let settings: AppSettings
    private let providerFactory: ProviderFactory

    init(
        settings: AppSettings,
        modelIdentifier: String = "text-embedding-3-small",
        providerFactory: @escaping ProviderFactory = { OpenAIEmbeddingProvider(apiKey: $0) }
    ) {
        self.settings = settings
        self.modelIdentifier = modelIdentifier
        self.providerFactory = providerFactory
    }

    func embed(_ text: String) async throws -> [Float] {
        let config = await MainActor.run {
            (
                enabled: settings.semanticSearchEnabled,
                apiKey: settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard config.enabled else {
            throw KnowledgeBaseEmbeddingProviderUnavailable.disabled
        }
        guard !config.apiKey.isEmpty else {
            throw KnowledgeBaseEmbeddingProviderUnavailable.missingAPIKey
        }
        return try await providerFactory(config.apiKey).embed(text)
    }
}
