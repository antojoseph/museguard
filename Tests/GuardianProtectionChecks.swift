import Foundation

@main struct GuardianProtectionChecks {
    @MainActor static func main() async throws {
        var events:[Bool] = []
        let lease = GuardianProtectionActivity(duration:0.16) { events.append($0) }
        lease.refreshFromAutomaticCheck()
        assert(lease.isActive && events == [true])
        lease.update(enabled:true)
        try await Task.sleep(nanoseconds:100_000_000)
        lease.update(enabled:true)
        try await Task.sleep(nanoseconds:100_000_000)
        assert(lease.isActive && events == [true],"Heartbeats keep the session active across tabs and idle inference gaps.")
        lease.update(enabled:false)
        lease.refreshFromAutomaticCheck()
        assert(!lease.isActive && events == [true,false],"Pause immediately wins over late legacy activity.")
        lease.update(enabled:true)
        try await Task.sleep(nanoseconds:210_000_000)
        assert(!lease.isActive && events == [true,false,true,false],"Disconnects cannot leave a permanent awake session.")
        lease.refreshFromAutomaticCheck()
        assert(lease.isActive)
        lease.update(enabled:false)
        for seconds in [0.0,28,55,600,3600] {
            assert(GuardianIdlePolicy.pose(after:seconds,protectionActive:true) == "idle")
        }
        assert(GuardianIdlePolicy.pose(after:55) == "sleep")
        print("PASS: browser protection stays awake across heartbeat renewals, honors Pause, expires disconnects and blocks automatic naps")
    }
}
