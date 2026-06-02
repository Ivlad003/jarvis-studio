import Testing
@testable import CaptureKit

@Suite("SC sample task bag")
struct SCSampleTaskBagTests {
    @Test("Completed sample tasks are removed before stop drains")
    func completedSampleTasksAreRemovedBeforeDrain() async throws {
        let bag = SCSampleTaskBag()

        bag.add { }

        try await waitUntil {
            bag.activeTaskCount == 0
        }
        #expect(bag.drain().isEmpty)
    }

    @Test("Drain closes the bag against late stream callbacks")
    func drainClosesBagAgainstLateAdds() async throws {
        let bag = SCSampleTaskBag()

        let inFlight = bag.add {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(inFlight != nil)
        #expect(bag.activeTaskCount == 1)

        let drained = bag.drain()
        #expect(drained.count == 1)

        let late = bag.add { }
        #expect(late == nil)
        #expect(bag.activeTaskCount == 0)

        drained.forEach { $0.cancel() }
    }

    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition was not met", sourceLocation: sourceLocation)
    }
}
