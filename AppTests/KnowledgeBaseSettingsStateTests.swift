import Foundation
import StorageKit
import Testing
@testable import KosmoNotes

@MainActor
@Suite("KnowledgeBaseSettingsState")
struct KnowledgeBaseSettingsStateTests {
    private func makeStore() async throws -> (KnowledgeBaseStore, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesKBSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let db = try AppDatabase(path: tmpDir.appendingPathComponent("sessions.sqlite"))
        try await db.migrate()
        return (KnowledgeBaseStore(database: db), tmpDir)
    }

    @Test("addSource indexes immediately and refreshes visible sources")
    func addSourceIndexesImmediatelyAndRefreshesVisibleSources() async throws {
        let (store, tmpDir) = try await makeStore()

        let sourceDir = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "roadmap budget for live chat".write(
            to: sourceDir.appendingPathComponent("roadmap.md"),
            atomically: true,
            encoding: .utf8
        )

        let state = KnowledgeBaseSettingsState(store: store)
        await state.addSource(kind: .document, path: sourceDir)

        #expect(state.lastError == nil)
        #expect(state.sources.count == 1)
        #expect(state.sources[0].kind == .document)
        #expect(state.statusMessage?.contains("Indexed") == true)
        let hits = try await store.search(query: "live chat", limit: 10)
        #expect(hits.contains { $0.relPath == "roadmap.md" })
    }

    @Test("removeSource removes visible source and indexed chunks")
    func removeSourceRemovesVisibleSourceAndIndexedChunks() async throws {
        let (store, tmpDir) = try await makeStore()

        let sourceDir = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "private launch memo".write(
            to: sourceDir.appendingPathComponent("memo.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = KnowledgeBaseSettingsState(store: store)
        await state.addSource(kind: .document, path: sourceDir)
        let sourceID = try #require(state.sources.first?.id)

        await state.removeSource(id: sourceID)

        #expect(state.lastError == nil)
        #expect(state.sources.isEmpty)
        #expect(try await store.search(query: "launch memo", limit: 10).isEmpty)
    }
}
