import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("ShareCoordinator")
struct ShareCoordinatorTests {
    @Test("presign TTL hours are clamped to the S3 SigV4 maximum")
    func presignTTLHoursAreClamped() {
        #expect(ShareCoordinator.clampedPresignTTLHours(0) == 1)
        #expect(ShareCoordinator.clampedPresignTTLHours(12) == 12)
        #expect(ShareCoordinator.clampedPresignTTLHours(999) == 168)
    }
}
