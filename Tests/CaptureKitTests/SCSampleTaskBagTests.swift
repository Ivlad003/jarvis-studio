import Testing
@testable import CaptureKit

@Suite("SC sample task bag")
struct SCSampleTaskBagTests {
    @Test("Sample tasks run in FIFO order even when later work is faster")
    func sampleTasksRunInFIFOOrder() async throws {
        let bag = SCSampleTaskBag()
        let recorder = OrderedSampleRecorder()

        for index in 0..<4 {
            let delayMs = 40 - (index * 10)
            bag.add {
                try? await Task.sleep(for: .milliseconds(delayMs))
                await recorder.append(index)
            }
        }

        for task in bag.drain() {
            _ = await task.value
        }

        #expect(await recorder.values == [0, 1, 2, 3])
    }

    @Test("Queued sample backlog is bounded by dropping oldest pending work")
    func queuedSampleBacklogDropsOldestPendingWork() async throws {
        let bag = SCSampleTaskBag(maxQueuedOperations: 2)
        let gate = AsyncGate()
        let recorder = OrderedSampleRecorder()

        let first = bag.add {
            await gate.wait()
            await recorder.append(0)
        }
        #expect(first != nil)

        try await waitUntil {
            await gate.hasWaiter
        }

        for index in 1...4 {
            bag.add {
                await recorder.append(index)
            }
        }

        #expect(bag.activeTaskCount == 3)

        await gate.open()
        for task in bag.drain() {
            _ = await task.value
        }

        #expect(await recorder.values == [0, 3, 4])
    }

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

    private func waitUntil(
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition was not met", sourceLocation: sourceLocation)
    }
}

private actor OrderedSampleRecorder {
    private var appended: [Int] = []

    func append(_ value: Int) {
        appended.append(value)
    }

    var values: [Int] {
        appended
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var hasWaiter: Bool {
        continuation != nil
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
