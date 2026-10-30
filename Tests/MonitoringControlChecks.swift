import Foundation

@main struct MonitoringControlChecks {
    @MainActor static func main() throws {
        let suite = "MuseMonitoringTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let control = MonitoringControl(defaults: defaults, now: { now })
        assert(!control.isPaused && control.state.revision == 1)
        control.pause(for: 1800)
        let first = control.state
        assert(control.isPaused && first.pauseUntil == 2_000_001_800_000 && control.syncPending)
        let restored = MonitoringControl(defaults: defaults, now: { now })
        assert(restored.state == first)
        let reply = control.handle(.init(id: "poll", type: "monitoring-state", monitoringRevision: first.revision))!
        assert(reply.ok && reply.monitoring == first && !control.syncPending && control.browserConnected)
        _ = control.handle(.init(id:"unconfirmed",type:"monitoring-state"))
        assert(control.syncPending, "A reconnect or unconfirmed browser-only change must revoke the old acknowledgement.")
        now.addTimeInterval(1801)
        assert(!control.isPaused && control.state.revision > first.revision)
        let resumed = control.state
        _ = control.handle(.init(id:"old-ack",type:"monitoring-state",monitoringRevision:first.revision))
        assert(control.syncPending && control.state == resumed)
        let pause = control.handle(.init(id:"pause",type:"monitoring-control",monitoringCommand:"pause",pauseDurationMS:0))!
        assert(pause.ok && control.isPaused && control.state.pauseUntil == 0)
        let persisted = MonitoringControl(defaults: defaults, now: { now })
        assert(persisted.isPaused && persisted.state == control.state)
        let unchanged = control.state
        for bad in [BrowserRequest(id:"bad-duration",type:"monitoring-control",monitoringCommand:"pause",pauseDurationMS:500),
                    BrowserRequest(id:"bad-command",type:"monitoring-control",monitoringCommand:"toggle"),
                    BrowserRequest(id:"poll-evidence",type:"monitoring-state",page:.init(url:"https://example.test",title:"",text:"")),
                    BrowserRequest(id:"bad-ack",type:"monitoring-state",monitoringRevision:-1)] {
            assert(control.handle(bad)?.ok == false && control.state == unchanged)
        }
        assert(control.handle(.init(id:"resume",type:"monitoring-control",monitoringCommand:"resume"))?.ok == true)
        assert(!control.isPaused && control.state.revision > unchanged.revision)
        let newest = control.state
        let stalePause = control.handle(.init(id:"stale-pause",type:"monitoring-control",monitoringCommand:"pause",pauseDurationMS:0,monitoringRevision:unchanged.revision))!
        assert(!stalePause.ok && stalePause.monitoring == newest && control.state == newest)
        print("PASS: one persisted monitoring switch, native/browser commands, expiry, stale acknowledgement and strict control validation")
    }
}
