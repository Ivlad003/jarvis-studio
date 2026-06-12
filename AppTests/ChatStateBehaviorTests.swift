import Foundation
import Testing
import AIKit
import TranscriptionKit
@testable import KosmoNotes

@MainActor
@Suite("ChatState behavior")
struct ChatStateBehaviorTests {

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
}
