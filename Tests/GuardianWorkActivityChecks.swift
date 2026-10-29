import Foundation

@main struct GuardianWorkActivityChecks {
    @MainActor static func main() async throws {
        var events: [Bool] = []
        let activity = GuardianWorkActivity(delay:0.02,minimumDuration:0.12,settlingDelay:0.04) { events.append($0) }
        // A cached or very short request does not flash the character.
        activity.setWorking(true)
        activity.setWorking(false)
        try await Task.sleep(nanoseconds:40_000_000)
        assert(!activity.isActive && events.isEmpty)

        activity.setWorking(true)
        try await Task.sleep(nanoseconds:40_000_000)
        assert(activity.isActive && events == [true])
        activity.setWorking(true)
        activity.setWorking(false)
        try await Task.sleep(nanoseconds:30_000_000)
        assert(activity.isActive, "A short finished request remains visible long enough to read.")
        activity.setWorking(true)
        try await Task.sleep(nanoseconds:130_000_000)
        assert(activity.isActive && events == [true], "A newer job cancels the old hide timer.")
        activity.setWorking(false)
        try await Task.sleep(nanoseconds:65_000_000)
        assert(!activity.isActive && events == [true,false])

        // Repeated start/stop transitions cannot revive an obsolete timer.
        activity.setWorking(true)
        activity.setWorking(false)
        activity.setWorking(true)
        try await Task.sleep(nanoseconds:40_000_000)
        assert(activity.isActive && events == [true,false,true])
        activity.setWorking(false)
        try await Task.sleep(nanoseconds:150_000_000)
        assert(!activity.isActive && events == [true,false,true,false])
        print("PASS: inference activity debounces, holds briefly, merges adjacent jobs and cancels stale transitions")
    }
}
