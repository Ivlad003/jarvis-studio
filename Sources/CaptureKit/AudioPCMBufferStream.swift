@preconcurrency import AVFoundation
import Foundation

enum AudioPCMBufferStream {
    static let defaultBufferLimit = 100

    static func makeStream(
        bufferingNewest limit: Int = defaultBufferLimit
    ) -> (
        stream: AsyncStream<AVAudioPCMBuffer>,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, limit))
        )
    }
}
