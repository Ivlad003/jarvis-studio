import Foundation
import TranscriptionKit

@available(macOS 14.0, *)
struct RecorderLiveAdapter: Sendable {
    typealias SnapshotSource = @Sendable () async -> LiveTranscriptState

    struct DisplayState: Sendable, Equatable {
        var stableText: String
        var mutableText: String
        var statusText: String?
        var isDelayed: Bool

        static let empty = DisplayState(
            stableText: "",
            mutableText: "",
            statusText: nil,
            isDelayed: false
        )

        var shouldSurface: Bool {
            !stableText.isEmpty || !mutableText.isEmpty || statusText != nil
        }
    }

    private let snapshotSource: SnapshotSource?
    private let unavailableMessage: String?

    init(
        snapshotSource: SnapshotSource? = nil,
        unavailableMessage: String? = nil
    ) {
        self.snapshotSource = snapshotSource
        self.unavailableMessage = unavailableMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayState() async -> DisplayState {
        if let snapshotSource {
            return Self.displayState(for: await snapshotSource())
        }
        if let unavailableMessage, !unavailableMessage.isEmpty {
            return DisplayState(
                stableText: "",
                mutableText: "",
                statusText: unavailableMessage,
                isDelayed: false
            )
        }
        return .empty
    }

    static func displayState(for snapshot: LiveTranscriptState) -> DisplayState {
        // Speaker-labeled ("You:" / "Them:") when the live transcript merges two
        // sources; identical to plain text for single-source transcripts.
        let stableText = snapshot.labeledStableText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mutableText = snapshot.labeledMutableText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch snapshot.status {
        case .healthy:
            return DisplayState(
                stableText: stableText,
                mutableText: mutableText,
                statusText: nil,
                isDelayed: false
            )
        case .delayed:
            return DisplayState(
                stableText: stableText,
                mutableText: mutableText,
                statusText: "Live transcript delayed",
                isDelayed: true
            )
        case .failed:
            return DisplayState(
                stableText: stableText,
                mutableText: mutableText,
                statusText: "Live transcript unavailable",
                isDelayed: false
            )
        }
    }
}
