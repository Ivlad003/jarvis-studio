#if canImport(ScreenCaptureKit)
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 12.3, *)
public struct SCStreamStopFailure: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    init(error: any Error) {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = localized.isEmpty ? String(describing: error) : localized
    }

    public var errorDescription: String? {
        message
    }
}

@available(macOS 12.3, *)
final class SCStreamStopDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (SCStreamStopFailure) -> Void

    init(onStop: @escaping @Sendable (SCStreamStopFailure) -> Void) {
        self.onStop = onStop
    }

    func recordStop(error: any Error) {
        onStop(SCStreamStopFailure(error: error))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        recordStop(error: error)
    }
}
#endif
