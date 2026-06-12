import Foundation

@available(macOS 14.0, *)
enum RecordingStartWarningPolicy {
    static let speakerEchoWarningMessage = "Playing through speakers — enable Echo cancellation in Settings → Transcription or use headphones to avoid echo in the recording."

    static func speakerEchoWarning(
        systemAudioEnabled: Bool,
        echoCancellationEnabled: Bool,
        defaultOutputBuiltIn: Bool
    ) -> String? {
        guard systemAudioEnabled, !echoCancellationEnabled, defaultOutputBuiltIn else { return nil }
        return speakerEchoWarningMessage
    }
}
