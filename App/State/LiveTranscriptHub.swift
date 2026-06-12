import Foundation
import TranscriptionKit

@available(macOS 14.0, *)
actor LiveTranscriptHub {
    typealias FinalSegmentSink = @Sendable (TranscriptSegment) async throws -> Void

    private let onFinalSegment: FinalSegmentSink?
    private var state = LiveTranscriptState.empty
    private var finals: [TranscriptSegment] = []

    init(onFinalSegment: FinalSegmentSink? = nil) {
        self.onFinalSegment = onFinalSegment
    }

    func snapshot() -> LiveTranscriptState {
        state
    }

    func finalSegments() -> [TranscriptSegment] {
        finals
    }

    func reset() {
        state = .empty
        finals = []
    }

    func apply(_ segment: TranscriptSegment) async {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let unit = LiveTranscriptUnit(
            start: segment.start,
            end: segment.end,
            text: text,
            state: segment.isFinal ? .stable : .draft
        )

        if segment.isFinal {
            finals.append(segment)
            state.stableUnits.append(unit)
            state.draftUnits.removeAll()
            state.status = .healthy
            do {
                try await onFinalSegment?(segment)
            } catch {
                state.status = .failed(lastError: error.localizedDescription)
            }
        } else {
            state.draftUnits = [unit]
            state.status = .healthy
        }
    }

    func markFailed(_ message: String) {
        state.status = .failed(lastError: message)
    }
}
