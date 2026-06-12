#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
import Foundation
import Testing
@testable import CaptureKit

@Suite("SCStream stop delegate")
struct SCStreamStopDelegateTests {
    @Test("Delegate records external stream stop as sendable failure")
    func delegateRecordsFailure() {
        guard #available(macOS 12.3, *) else { return }

        let store = StopFailureStore()
        let delegate = SCStreamStopDelegate { failure in
            store.set(failure)
        }

        delegate.recordStop(error: TestStopError.externalStop)

        let failure = store.failure
        #expect(failure?.message == "external stop")
    }

    @Test("ScreenRecorder marks external stream stop terminal for mic supervisor")
    func screenRecorderMarksExternalStopTerminal() async {
        guard #available(macOS 12.3, *) else { return }

        let recorder = ScreenRecorder()
        let failure = SCStreamStopFailure(message: "external stop")

        await recorder.recordExternalStreamStop(failure)

        #expect(await recorder.streamStopError == failure)
        #expect(await recorder.micRecoveryGaveUp == true)
    }

    @Test("CaptureSession stores terminal system-audio stream stop failure")
    func captureSessionStoresSystemAudioStopFailure() async throws {
        guard #available(macOS 12.3, *) else { return }

        let dir = URL.temporaryDirectory.appendingPathComponent("KosmoNotesSCKitStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = CaptureSession(
            config: .init(
                micEnabled: false,
                systemAudioEnabled: false,
                sessionDir: dir
            )
        )
        let failure = SCStreamStopFailure(message: "system audio stopped")

        await session.recordSystemAudioStopErrorForTesting(failure)

        let stored = await session.systemAudioError as? SCStreamStopFailure
        #expect(stored == failure)
    }
}

@available(macOS 12.3, *)
private final class StopFailureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SCStreamStopFailure?

    func set(_ failure: SCStreamStopFailure) {
        lock.lock()
        stored = failure
        lock.unlock()
    }

    var failure: SCStreamStopFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private enum TestStopError: LocalizedError {
    case externalStop

    var errorDescription: String? {
        "external stop"
    }
}
#endif
