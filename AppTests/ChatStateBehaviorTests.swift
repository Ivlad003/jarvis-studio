import Foundation
import Testing
import AIKit
import StorageKit
import TranscriptionKit
@testable import KosmoNotes

@MainActor
@Suite("ChatState behavior")
struct ChatStateBehaviorTests {

    private func makeChatState(
        provider: any AIProvider,
        liveState: LiveTranscriptState? = nil
    ) async throws -> (ChatState, URL) {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesChatStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let db = try AppDatabase(path: tmpDir.appendingPathComponent("sessions.sqlite"))
        try await db.migrate()
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let store = try SessionStore(rootDir: recordingsDir, database: db)
        let settings = AppSettings()
        let recorder = RecorderState(database: db, sessionStore: store, settings: settings)
        let chat = ChatState(
            settings: settings,
            database: db,
            sessionStore: store,
            recorder: recorder,
            liveContextProvider: { liveState },
            providerResolver: { _ in
                AIProviderResolver.Resolved(
                    provider: provider,
                    model: "mock-chat",
                    pricing: .init(inputPerMillion: 0, outputPerMillion: 0)
                )
            }
        )
        chat.autoSearchSessions = false
        return (chat, tmpDir)
    }

    @Test("timestamp parser rejects impossible mm:ss and h:mm:ss values")
    func timestampParserRejectsImpossibleSecondsAndMinutes() {
        let parsed = ChatState.parseTimestampMentions(
            from: "valid 5:32 and 1:02:03, invalid 5:75 and 1:75:03 and 1:02:75"
        )

        #expect(parsed == [332, 3_723])
    }

    @Test("chat provider config uses a roomier response budget")
    func chatProviderConfigUsesRoomierResponseBudget() {
        #expect(ChatState.defaultChatMaxTokens >= 4_096)
    }

    @Test("send actions are mutually exclusive")
    func sendActionsAreMutuallyExclusive() {
        #expect(ChatState.canStartTextSend(isSending: false, isSnapshotting: false))
        #expect(!ChatState.canStartTextSend(isSending: true, isSnapshotting: false))
        #expect(!ChatState.canStartTextSend(isSending: false, isSnapshotting: true))
        #expect(ChatState.canStartSnapshotSend(isSending: false, isSnapshotting: false))
        #expect(!ChatState.canStartSnapshotSend(isSending: true, isSnapshotting: false))
        #expect(!ChatState.canStartSnapshotSend(isSending: false, isSnapshotting: true))
    }

    @Test("rollback removes the failed user message by identity")
    func rollbackRemovesFailedUserMessageByIdentity() {
        let oldAssistant = ChatMessage(role: .assistant, content: "older")
        let failedUser = ChatMessage(role: .user, content: "will fail")
        let laterSystem = ChatMessage(role: .system, content: "diagnostic")
        var messages = [oldAssistant, failedUser, laterSystem]

        ChatState.rollbackUserMessage(at: 1, matching: failedUser, from: &messages)

        #expect(messages == [oldAssistant, laterSystem])
    }

    @Test("live transcript context includes stable and draft text")
    func liveTranscriptContextIncludesStableAndDraftText() {
        let state = LiveTranscriptState(
            stableUnits: [
                .init(start: 1, end: 2, text: "first committed point", state: .stable),
            ],
            draftUnits: [
                .init(start: 2, end: 3, text: "mutable tail", state: .draft),
            ],
            status: .healthy
        )

        let section = ChatState.liveTranscriptPromptSection(from: state, maxCharacters: 1_000)

        #expect(section?.contains("== Active recording live transcript ==") == true)
        #expect(section?.contains("first committed point") == true)
        #expect(section?.contains("[draft] mutable tail") == true)
    }

    @Test("empty live transcript context is omitted")
    func emptyLiveTranscriptContextIsOmitted() {
        #expect(ChatState.liveTranscriptPromptSection(from: .empty, maxCharacters: 1_000) == nil)
    }

    @Test("context prompt can be reused by normal chat and live snapshots")
    func contextPromptCanBeReusedByNormalChatAndLiveSnapshots() {
        let prompt = ChatState.contextPrompt(
            liveSection: "== Active recording live transcript ==\ncurrent point",
            attachedSessionSections: [
                "[2026-06-12T20:00:00Z · meeting · 90s · en]\nfinished context",
            ]
        )

        #expect(prompt?.contains("access to the user's audio recording transcripts") == true)
        #expect(prompt?.contains("== Active recording live transcript ==") == true)
        #expect(prompt?.contains("== Attached sessions ==") == true)
        #expect(prompt?.contains("finished context") == true)
    }

    @Test("send executes live transcript tools through the shared tool loop")
    func sendExecutesLiveTranscriptToolsThroughSharedToolLoop() async throws {
        let calls = ToolLoopChatProviderCalls()
        let provider = ToolLoopChatProvider(calls: calls)
        let liveState = LiveTranscriptState(
            stableUnits: [
                .init(start: 1, end: 5, text: "The launch budget is due Friday.", state: .stable),
            ],
            draftUnits: [],
            status: .healthy
        )
        let (chat, _) = try await makeChatState(provider: provider, liveState: liveState)

        chat.inputDraft = "What was said about the launch budget?"
        await chat.send()

        #expect(chat.lastError == nil)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.text == "Budget is due Friday.")
        #expect(await calls.toolNamesByTurn.first == ["search_live_transcript"])
        #expect(await calls.receivedToolResult(containing: "The launch budget is due Friday."))
    }

    @Test("send exposes knowledge-base and code tools through the shared tool loop")
    func sendExposesKnowledgeBaseAndCodeToolsThroughSharedToolLoop() async throws {
        let tmpDir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesChatKBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let db = try AppDatabase(path: tmpDir.appendingPathComponent("sessions.sqlite"))
        try await db.migrate()
        let sessionStore = try SessionStore(rootDir: tmpDir.appendingPathComponent("recordings"), database: db)
        let settings = AppSettings()
        let recorder = RecorderState(database: db, sessionStore: sessionStore, settings: settings)
        let kbStore = KnowledgeBaseStore(database: db)

        let docsDir = tmpDir.appendingPathComponent("docs")
        let codeDir = tmpDir.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try "Quarterly roadmap says launch budget is due Friday.".write(
            to: docsDir.appendingPathComponent("roadmap.md"),
            atomically: true,
            encoding: .utf8
        )
        try "func launchBudgetStatus() -> String { \"due Friday\" }".write(
            to: codeDir.appendingPathComponent("Budget.swift"),
            atomically: true,
            encoding: .utf8
        )

        _ = try await kbStore.addSource(kind: .document, path: docsDir)
        _ = try await kbStore.addSource(kind: .codeFolder, path: codeDir)
        try await kbStore.reindexAll()

        let calls = KnowledgeToolChatProviderCalls()
        let provider = KnowledgeToolChatProvider(calls: calls)
        let chat = ChatState(
            settings: settings,
            database: db,
            sessionStore: sessionStore,
            recorder: recorder,
            knowledgeBaseStore: kbStore,
            providerResolver: { _ in
                AIProviderResolver.Resolved(
                    provider: provider,
                    model: "mock-chat",
                    pricing: .init(inputPerMillion: 0, outputPerMillion: 0)
                )
            }
        )
        chat.autoSearchSessions = false

        chat.inputDraft = "Check the roadmap and launchBudgetStatus implementation."
        await chat.send()

        #expect(chat.lastError == nil)
        #expect(chat.messages.last?.text == "Roadmap and code agree.")
        #expect(await calls.toolNamesByTurn.first == ["search_knowledge_base", "search_code"])
        #expect(await calls.receivedToolResult(containing: "roadmap.md"))
        #expect(await calls.receivedToolResult(containing: "launchBudgetStatus"))
    }
}

private actor ToolLoopChatProviderCalls {
    private var turns: [(messages: [ChatMessage], tools: [ToolSpec])] = []

    var toolNamesByTurn: [[String]] {
        turns.map { $0.tools.map(\.name) }
    }

    var count: Int { turns.count }

    func append(messages: [ChatMessage], tools: [ToolSpec]) {
        turns.append((messages, tools))
    }

    func receivedToolResult(containing needle: String) -> Bool {
        turns.contains { turn in
            turn.messages.flatMap(\.parts).contains { part in
                guard case .toolResult(_, let content, _) = part else { return false }
                return content.contains(needle)
            }
        }
    }
}

private struct ToolLoopChatProvider: AIProvider {
    let calls: ToolLoopChatProviderCalls

    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        "plain chat path should not be used"
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        await calls.append(messages: messages, tools: tools)
        if await calls.count == 1 {
            return ChatResponse(parts: [
                .toolUse(.init(
                    id: "toolu_live",
                    name: "search_live_transcript",
                    arguments: .object(["query": .string("launch budget")])
                )),
            ], stopReason: .toolUse)
        }
        return ChatResponse(parts: [.text("Budget is due Friday.")], stopReason: .endTurn)
    }
}

private actor KnowledgeToolChatProviderCalls {
    private var turns: [(messages: [ChatMessage], tools: [ToolSpec])] = []

    var toolNamesByTurn: [[String]] {
        turns.map { $0.tools.map(\.name) }
    }

    var count: Int { turns.count }

    func append(messages: [ChatMessage], tools: [ToolSpec]) {
        turns.append((messages, tools))
    }

    func receivedToolResult(containing needle: String) -> Bool {
        turns.contains { turn in
            turn.messages.flatMap(\.parts).contains { part in
                guard case .toolResult(_, let content, _) = part else { return false }
                return content.contains(needle)
            }
        }
    }
}

private struct KnowledgeToolChatProvider: AIProvider {
    let calls: KnowledgeToolChatProviderCalls

    func chat(messages: [ChatMessage], config: AIConfig) async throws -> String {
        "plain chat path should not be used"
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec], config: AIConfig) async throws -> ChatResponse {
        await calls.append(messages: messages, tools: tools)
        if await calls.count == 1 {
            return ChatResponse(parts: [
                .toolUse(.init(
                    id: "toolu_kb",
                    name: "search_knowledge_base",
                    arguments: .object(["query": .string("launch budget"), "limit": .number(5)])
                )),
                .toolUse(.init(
                    id: "toolu_code",
                    name: "search_code",
                    arguments: .object(["query": .string("launchBudgetStatus"), "limit": .number(5)])
                )),
            ], stopReason: .toolUse)
        }
        return ChatResponse(parts: [.text("Roadmap and code agree.")], stopReason: .endTurn)
    }
}
