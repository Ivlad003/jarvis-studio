import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("MarkdownExporter")
struct MarkdownExporterTests {

    @Test("output token cap has a floor and ceiling")
    func outputTokenCapHasFloorAndCeiling() {
        #expect(MarkdownExporter.outputTokenCap(forInputTokens: 10) == 2_048)
        #expect(MarkdownExporter.outputTokenCap(forInputTokens: 20_000) == MarkdownExporter.maximumOutputTokens)
    }
}
