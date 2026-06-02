import Foundation
import Testing
@testable import KosmoNotes

@available(macOS 14.0, *)
private actor ScreenMixProbe {
    private(set) var didStart = false
    private(set) var didFinish = false
    private(set) var receivedScreenURL: URL?
    private(set) var receivedAudioURL: URL?

    func run(screenURL: URL, audioURL: URL) async {
        didStart = true
        receivedScreenURL = screenURL
        receivedAudioURL = audioURL
        try? await Task.sleep(for: .milliseconds(100))
        didFinish = true
    }
}

@available(macOS 14.0, *)
@Test func recorderScreenAudioMix_waitsForMixerBeforeReturning() async throws {
    let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesScreenMix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let screenURL = dir.appendingPathComponent("screen.mp4")
    let audioURL = dir.appendingPathComponent("audio.m4a")
    FileManager.default.createFile(atPath: screenURL.path, contents: Data())
    FileManager.default.createFile(atPath: audioURL.path, contents: Data())

    let probe = ScreenMixProbe()

    let result = await RecorderState.mixScreenAudioIfPresent(
        screenURL: screenURL,
        audioFile: audioURL,
        mixer: { screen, audio in
            await probe.run(screenURL: screen, audioURL: audio)
        }
    )

    #expect(result == .mixed)
    #expect(await probe.didStart)
    #expect(await probe.didFinish)
    #expect(await probe.receivedScreenURL == screenURL)
    #expect(await probe.receivedAudioURL == audioURL)
}

@available(macOS 14.0, *)
@Test func recorderScreenAudioMix_skipsWhenScreenFileMissing() async {
    let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesScreenMix-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let probe = ScreenMixProbe()
    let result = await RecorderState.mixScreenAudioIfPresent(
        screenURL: dir.appendingPathComponent("screen.mp4"),
        audioFile: dir.appendingPathComponent("audio.m4a"),
        mixer: { screen, audio in
            await probe.run(screenURL: screen, audioURL: audio)
        }
    )

    #expect(result == .skipped)
    #expect(await probe.didStart == false)
}
