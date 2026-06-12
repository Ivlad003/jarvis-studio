import Foundation
import Testing
import AIKit
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
}
