import Testing
@testable import KosmoNotes

@available(macOS 14.0, *)
@Test func screenRecordingWarningMenuTitleClipsLongWarning() throws {
    let warning = String(repeating: "Screen recording unavailable. ", count: 6)

    let title = try #require(RecorderMenuPresenter.screenRecordingWarningTitle(for: warning))

    #expect(title.hasPrefix("Screen: Screen recording unavailable."))
    #expect(title.count <= 96)
}

@available(macOS 14.0, *)
@Test func screenRecordingWarningMenuTitleReturnsNilForEmptyWarning() {
    #expect(RecorderMenuPresenter.screenRecordingWarningTitle(for: nil) == nil)
    #expect(RecorderMenuPresenter.screenRecordingWarningTitle(for: "   ") == nil)
}
