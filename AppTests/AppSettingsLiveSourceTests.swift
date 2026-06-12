import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("AppSettings live streaming source", .serialized)
struct AppSettingsLiveSourceTests {
    private let transcriptionProviderKey = "transcriptionProvider"
    private let summaryLanguageKey = "summaryLanguage"

    @Test("Deepgram settings create a streaming live source")
    func deepgramSettingsCreateStreamingLiveSource() {
        let priorProvider = UserDefaults.standard.object(forKey: transcriptionProviderKey)
        let priorLanguage = UserDefaults.standard.object(forKey: summaryLanguageKey)
        defer {
            restore(priorProvider, forKey: transcriptionProviderKey)
            restore(priorLanguage, forKey: summaryLanguageKey)
        }

        let settings = AppSettings()
        settings.transcriptionProvider = .deepgram
        settings.deepgramApiKey = " dg_test_key "
        settings.summaryLanguage = "uk"

        #expect(settings.makeStreamingLiveSource() != nil)
    }

    @Test("non-streaming providers do not create a streaming live source")
    func nonStreamingProvidersDoNotCreateStreamingLiveSource() {
        let priorProvider = UserDefaults.standard.object(forKey: transcriptionProviderKey)
        defer { restore(priorProvider, forKey: transcriptionProviderKey) }

        let settings = AppSettings()
        settings.transcriptionProvider = .openaiWhisper
        settings.deepgramApiKey = "dg_test_key"

        #expect(settings.makeStreamingLiveSource() == nil)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
