import Testing
@testable import KosmoNotes

@Test func screenRecordingPreflightRunsForEachStartupPermissionCheck() {
    final class Counter {
        var count = 0
    }

    let counter = Counter()

    #expect(StartupPermissionPolicy.screenRecordingGranted {
        counter.count += 1
        return false
    } == false)

    #expect(StartupPermissionPolicy.screenRecordingGranted {
        counter.count += 1
        return true
    } == true)

    #expect(counter.count == 2)
}
