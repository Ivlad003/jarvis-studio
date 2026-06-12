import Foundation
import Observation
import StorageKit

@available(macOS 14.0, *)
@Observable
@MainActor
final class KnowledgeBaseSettingsState {
    var sources: [KnowledgeBaseSource] = []
    var isBusy = false
    var statusMessage: String?
    var lastError: String?

    private let store: KnowledgeBaseStore?

    init(store: KnowledgeBaseStore?) {
        self.store = store
    }

    func refresh() async {
        guard let store = availableStore() else { return }
        await perform(statusOnSuccess: nil) {
            self.sources = try await store.listSources()
        }
    }

    func addSource(kind: KnowledgeBaseSourceKind, path: URL) async {
        guard let store = availableStore() else { return }
        await perform(statusOnSuccess: "Indexed \(Self.displayName(for: kind)) source.") {
            _ = try await store.addSource(kind: kind, path: path)
            try await store.reindexAll()
            self.sources = try await store.listSources()
        }
    }

    func removeSource(id: String) async {
        guard let store = availableStore() else { return }
        await perform(statusOnSuccess: "Removed knowledge source.") {
            try await store.removeSource(id: id)
            self.sources = try await store.listSources()
        }
    }

    func reindexAll() async {
        guard let store = availableStore() else { return }
        await perform(statusOnSuccess: "Reindexed \(sources.count) knowledge source\(sources.count == 1 ? "" : "s").") {
            try await store.reindexAll()
            self.sources = try await store.listSources()
        }
    }

    static func displayName(for kind: KnowledgeBaseSourceKind) -> String {
        switch kind {
        case .document:
            return "document"
        case .codeFolder:
            return "code folder"
        }
    }

    private func availableStore() -> KnowledgeBaseStore? {
        guard let store else {
            statusMessage = nil
            lastError = "Knowledge base is unavailable."
            return nil
        }
        return store
    }

    private func perform(statusOnSuccess: String?, _ body: () async throws -> Void) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await body()
            statusMessage = statusOnSuccess
        } catch {
            statusMessage = nil
            lastError = error.localizedDescription
        }
    }
}
