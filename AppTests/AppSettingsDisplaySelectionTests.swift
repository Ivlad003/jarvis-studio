import Foundation
import AIKit
import Testing
@testable import KosmoNotes

@MainActor
@Suite("AppSettings display selection")
struct AppSettingsDisplaySelectionTests {
    private let screenCaptureDisplayIDKey = "screenCaptureDisplayID"
    private let ollamaApiModeKey = "ollamaApiMode"

    @Test("screen capture display selection persists across AppSettings instances")
    func screenCaptureDisplaySelectionPersists() {
        UserDefaults.standard.removeObject(forKey: screenCaptureDisplayIDKey)
        defer { UserDefaults.standard.removeObject(forKey: screenCaptureDisplayIDKey) }

        let settings = AppSettings()
        #expect(settings.screenCaptureDisplayID == 0)

        settings.screenCaptureDisplayID = 42

        let reloaded = AppSettings()
        #expect(reloaded.screenCaptureDisplayID == 42)
    }

    @Test("Ollama Anthropic-compatible mode persists and feeds the AI resolver")
    func ollamaAnthropicCompatibleModePersistsAndFeedsResolver() {
        let prior = UserDefaults.standard.object(forKey: ollamaApiModeKey)
        UserDefaults.standard.removeObject(forKey: ollamaApiModeKey)
        defer { restore(prior, forKey: ollamaApiModeKey) }

        let settings = AppSettings()
        settings.ollamaApiMode = .anthropicCompat

        let reloaded = AppSettings()
        #expect(reloaded.ollamaApiMode == .anthropicCompat)
        #expect(reloaded.aiProviderConfig.ollamaAPIMode == OllamaProvider.APIMode.anthropicCompat)
        #expect(AppSettings.OllamaAPIMode.anthropicCompat.displayName.contains("/v1/messages"))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
