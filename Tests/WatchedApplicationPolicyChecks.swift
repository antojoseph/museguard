import Foundation

@main struct WatchedApplicationPolicyChecks {
    static func main() {
        let own: Int32 = 1, fixture: Int32 = 10, other: Int32 = 20, renderer: Int32 = 99
        func resolve(front: Int32?, open: Bool = true, key: String? = WatchedApplicationPolicy.chatWindowIdentifier,
            previous: Int32? = 10, menuTracking: Bool = false) -> Int32? {
            WatchedApplicationPolicy.processToWatch(frontmost: front, ownProcess: own, chatOpen: open,
                keyWindowIdentifier: key, lastExternal: previous, ignoredProcesses: [renderer], menuTracking: menuTracking)
        }
        assert(resolve(front: fixture, open: false, key: nil) == fixture)
        let beforeChat = resolve(front: fixture)
        let whileChatIsKey = resolve(front: own)
        assert(beforeChat == fixture && whileChatIsKey == fixture,
            "An in-flight watched source remains current when only Muse chat takes focus.")
        assert(resolve(front: own, key: "muse.settings") == nil,
            "Opening Settings must not keep inspecting the old app behind it.")
        assert(resolve(front: own, key: nil) == nil,
            "Menus and missing key-window information cannot authorize a background source.")
        assert(resolve(front: own, menuTracking: true) == nil,
            "Opening a menu can leave chat key, but must not authorize its background context.")
        assert(resolve(front: own, open: false) == nil)
        assert(resolve(front: other) == other,
            "A newly activated external app wins even if the old chat remains open.")
        assert(resolve(front: nil) == nil)
        assert(resolve(front: own, previous: nil) == nil,
            "A terminated or absent last external app cannot become a source.")
        assert(resolve(front: own, previous: own) == nil)
        assert(resolve(front: own, previous: renderer) == nil)
        assert(resolve(front: renderer, previous: fixture) == nil,
            "The renderer is not permission to inspect an unrelated background app.")
        assert(resolve(front: fixture, key: "muse.settings", previous: other) == fixture)
        print("PASS: watched source survives chat focus only; Settings, menus, other apps, termination and renderer sources remain separate")
    }
}
