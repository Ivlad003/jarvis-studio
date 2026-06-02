import Foundation

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
}
