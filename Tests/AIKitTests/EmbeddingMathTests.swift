import Foundation
import Testing
@testable import AIKit

@Suite("EmbeddingMath")
struct EmbeddingMathTests {
    @Test("pack and unpack round-trip float32 vectors")
    func packUnpackRoundTrip() {
        let vector: [Float] = [0.25, -1.5, 42.0]
        #expect(EmbeddingMath.unpack(EmbeddingMath.pack(vector)) == vector)
    }

    @Test("unpack ignores trailing partial float bytes")
    func unpackIgnoresTrailingPartialBytes() {
        var data = EmbeddingMath.pack([1.0, 2.0])
        data.append(0xFF)

        #expect(EmbeddingMath.unpack(data) == [1.0, 2.0])
    }
}
