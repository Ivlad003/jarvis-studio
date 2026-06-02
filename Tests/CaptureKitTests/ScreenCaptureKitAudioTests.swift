import AVFoundation
import Testing
@testable import CaptureKit

@Suite("ScreenCaptureKit audio conversion")
struct ScreenCaptureKitAudioTests {
    @Test("AudioBufferList storage uses requested byte count")
    func audioBufferListStorageUsesRequestedByteCount() throws {
        let requestedBytes = MemoryLayout<AudioBufferList>.size + (2 * MemoryLayout<AudioBuffer>.size)

        let storage = try #require(AudioBufferListStorage(byteCount: requestedBytes))

        #expect(storage.byteCount == requestedBytes)
        #expect(Int(bitPattern: storage.pointer) % 16 == 0)
    }

    @Test("AudioBufferList storage rejects undersized allocations")
    func audioBufferListStorageRejectsUndersizedAllocations() {
        #expect(AudioBufferListStorage(byteCount: MemoryLayout<AudioBufferList>.size - 1) == nil)
    }
}
