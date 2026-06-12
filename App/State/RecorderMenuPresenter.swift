import Foundation
import CaptureKit

enum RecorderMenuPresenter {
    static func screenRecordingWarningTitle(for warning: String?) -> String? {
        guard let warning else { return nil }

        let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefix = "Screen: "
        let limit = 96
        let remaining = max(0, limit - prefix.count)
        if trimmed.count <= remaining {
            return prefix + trimmed
        }
        return prefix + trimmed.prefix(max(0, remaining - 1)) + "…"
    }

    /// Format a menu-bar line describing mic health. Returns nil while
    /// healthy / idle / warming up so the menu stays quiet on the happy path.
    /// The coloured emoji acts as the "dot" — NSMenuItem doesn't reliably
    /// render tinted SF symbols in all themes.
    static func micHealthTitle(health: MicHealth, message: String?) -> String? {
        switch health {
        case .idle, .warmingUp, .ok, .muted:
            return nil
        case .degraded(let reason):
            return clipMicLine("🟡 Mic: \(message ?? reason)")
        case .dead(let reason):
            return clipMicLine("🔴 Mic dead: \(message ?? reason)")
        }
    }

    private static func clipMicLine(_ line: String) -> String {
        let limit = 96
        if line.count <= limit { return line }
        return line.prefix(max(0, limit - 1)) + "…"
    }
}
