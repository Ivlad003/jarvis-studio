import Foundation
import StorageKit
import Testing
import TranscriptionKit
@testable import KosmoNotes

@Suite("Agent search tools")
struct AgentSearchToolTests {
    private func makeTempDir() throws -> URL {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesAgentToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    @Test("search_live_transcript returns timestamped stable and draft matches")
    func searchLiveTranscriptReturnsTimestampedStableAndDraftMatches() async throws {
        let state = LiveTranscriptState(
            stableUnits: [
                LiveTranscriptUnit(start: 1, end: 5, text: "The launch budget is due Friday.", state: .stable),
                LiveTranscriptUnit(start: 8, end: 11, text: "Unrelated hiring note.", state: .stable),
            ],
            draftUnits: [
                LiveTranscriptUnit(start: 12, end: 15, text: "Mutable tail mentions customer onboarding.", state: .draft),
            ],
            status: .healthy
        )
        let tool = SearchLiveTranscriptTool(snapshotProvider: { state })

        let stableOutput = try await tool.execute(input: ["query": "launch budget", "limit": 5])
        #expect(stableOutput.contains("[1] [00:01-00:05] stable"))
        #expect(stableOutput.contains("The launch budget is due Friday."))
        #expect(!stableOutput.contains("Unrelated hiring note."))

        let draftOutput = try await tool.execute(input: ["query": "customer onboarding", "limit": 5])
        #expect(draftOutput.contains("[1] [00:12-00:15] draft"))
        #expect(draftOutput.contains("Mutable tail mentions customer onboarding."))
    }

    @Test("search_live_transcript reports when no live snapshot is available")
    func searchLiveTranscriptReportsNoSnapshotAvailable() async throws {
        let tool = SearchLiveTranscriptTool(snapshotProvider: { nil })
        let output = try await tool.execute(input: ["query": "launch budget"])

        #expect(output == "No live transcript is available.")
    }

    @Test("builtin agent tool registry includes live transcript search when a provider is available")
    func builtinToolRegistryIncludesLiveTranscriptSearchWhenProviderAvailable() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tools = await AgentToolRegistry.makeBuiltinTools(
            workspace: workspace,
            knowledgeBaseStore: nil,
            liveTranscriptProvider: { .empty }
        )

        #expect(tools.map(\.name).contains("search_live_transcript"))
    }

    @Test("search_knowledge_base returns formatted KB hits")
    func searchKnowledgeBaseReturnsFormattedHits() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = try AppDatabase(path: tmpDir.appendingPathComponent("sessions.sqlite"))
        try await db.migrate()
        let store = KnowledgeBaseStore(database: db)

        let sourceDir = tmpDir.appendingPathComponent("knowledge")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "launch budget is due Friday".write(
            to: sourceDir.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await store.addSource(kind: .document, path: sourceDir)
        try await store.reindexAll()

        let tool = SearchKnowledgeBaseTool(store: store)
        let output = try await tool.execute(input: ["query": "budget Friday", "limit": 5])

        #expect(output.contains("notes.md"))
        #expect(output.contains("budget"))
    }

    @Test("search_code finds identifiers and rejects paths outside configured roots")
    func searchCodeFindsIdentifiersAndRejectsOutsidePaths() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let codeDir = tmpDir.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try """
        func search_user_by_id(_ id: String) -> User? {
            nil
        }
        """.write(
            to: codeDir.appendingPathComponent("UserService.swift"),
            atomically: true,
            encoding: .utf8
        )

        let tool = SearchCodeTool(roots: [codeDir])
        let output = try await tool.execute(input: ["query": "search_user_by_id", "limit": 5])
        #expect(output.contains("UserService.swift"))
        #expect(output.contains("search_user_by_id"))

        let outsideDir = tmpDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        do {
            _ = try await tool.execute(input: [
                "query": "search_user_by_id",
                "path": outsideDir.path,
            ])
            Issue.record("search_code accepted a path outside its configured roots")
        } catch let error as AgentToolError {
            #expect(error.localizedDescription.contains("outside workspace"))
        }
    }
}
