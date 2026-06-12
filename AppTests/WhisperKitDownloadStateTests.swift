import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("WhisperKitDownloadState")
struct WhisperKitDownloadStateTests {
    @Test("late progress from an older generation is ignored")
    func lateProgressFromOlderGenerationIsIgnored() {
        #expect(WhisperKitDownloadState.shouldApplyProgress(
            callbackGeneration: 1,
            currentGeneration: 2,
            callbackVariant: "openai_whisper-base",
            currentInFlightVariant: "openai_whisper-base"
        ) == false)
    }

    @Test("progress applies only to the current variant generation")
    func progressAppliesOnlyToCurrentVariantGeneration() {
        #expect(WhisperKitDownloadState.shouldApplyProgress(
            callbackGeneration: 2,
            currentGeneration: 2,
            callbackVariant: "openai_whisper-base",
            currentInFlightVariant: "openai_whisper-small"
        ) == false)

        #expect(WhisperKitDownloadState.shouldApplyProgress(
            callbackGeneration: 2,
            currentGeneration: 2,
            callbackVariant: "openai_whisper-base",
            currentInFlightVariant: "openai_whisper-base"
        ) == true)
    }
}
