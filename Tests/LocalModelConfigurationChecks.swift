import Foundation

@main struct LocalModelConfigurationChecks {
    static func main() {
        // A custom installation path must remain an argument, including spaces.
        // No key contents or model files are read by these checks.
        let root = URL(fileURLWithPath: "/tmp/Muse configuration check/LocalModel", isDirectory: true)
        let arguments = LocalModelConfiguration.serverArguments(directory: root)
        func value(_ flag: String) -> String {
            let positions = arguments.indices.filter { arguments[$0] == flag }
            precondition(positions.count == 1, "Expected exactly one \(flag) argument")
            let position = positions[0]
            precondition(position + 1 < arguments.count, "Missing value for \(flag)")
            return arguments[position + 1]
        }
        func weight(_ filename: String) -> String {
            root.appendingPathComponent("weights").appendingPathComponent(filename).path
        }
        assert(LocalModelConfiguration.mainModelFilename == "Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf")
        assert(value("-m") == weight(LocalModelConfiguration.mainModelFilename))
        assert(value("--mmproj") == weight(LocalModelConfiguration.visionModelFilename))
        assert(value("-md") == weight(LocalModelConfiguration.draftModelFilename))
        assert(value("--spec-type") == "draft-dflash")
        assert(value("--spec-draft-n-max") == "3", "The production draft length must remain the tested three tokens")
        assert(value("-ngl") == "99" && value("-ngld") == "99", "Both target and draft must use Metal offload")
        assert(value("--api-key-file") == root.appendingPathComponent("api-key").path)

        let required = Set(LocalModelConfiguration.requiredFiles)
        assert(required.count == LocalModelConfiguration.requiredFiles.count)
        for file in ["runtime/llama-server", "api-key",
                     "weights/" + LocalModelConfiguration.mainModelFilename,
                     "weights/" + LocalModelConfiguration.visionModelFilename,
                     "weights/" + LocalModelConfiguration.draftModelFilename] {
            assert(required.contains(file), "Readiness must require the complete DFlash installation")
        }

        func properties(alias: Any = LocalModelConfiguration.model,
                        path: Any? = nil, speculative: Any = "none") -> [String: Any] {
            ["model_alias": alias,
             "model_path": path ?? weight(LocalModelConfiguration.mainModelFilename),
             "default_generation_settings": ["params": ["speculative.types": speculative]]]
        }
        let activeSlots: [[String: Any]] = [["speculative": true, "is_processing": false]]
        func matches(_ properties: [String: Any], slots: [[String: Any]] = activeSlots) -> Bool {
            LocalModelConfiguration.matchesServerProperties(properties, slots: slots, directory: root)
        }
        // In b11946, /props reports the per-request default as "none" even
        // when the global DFlash draft is active. Actual slot state is required.
        assert(matches(properties()))
        assert(matches(properties(speculative: "draft-dflash")))
        assert(matches(properties(), slots: [["speculative": true, "is_processing": true]]))
        assert(matches(properties(), slots: [["speculative": true], ["speculative": true]]))
        assert(!matches(properties(), slots: [["speculative": false]]),
               "The old non-speculative server must not be accepted merely because its alias matches")
        assert(!matches(properties(speculative: "draft-dflash"), slots: [["speculative": false]]),
               "Claimed request defaults cannot substitute for an active draft slot")
        assert(!matches(properties(), slots: []))
        assert(!matches(properties(), slots: [[:]]))
        assert(!matches(properties(), slots: [["speculative": true], ["speculative": false]]))
        assert(!matches(properties(), slots: [["speculative": true], [:]]))
        assert(!matches(properties(), slots: [["speculative": "true"]]))
        assert(!matches(properties(alias: "other-model")))
        assert(!matches(properties(path: "/tmp/other/Q4_K_M.gguf")))
        assert(!matches(properties(path: "/tmp/other/" + LocalModelConfiguration.mainModelFilename)))
        assert(!matches(properties(alias: [LocalModelConfiguration.model])))
        for key in ["model_alias", "model_path"] {
            var missing = properties()
            missing.removeValue(forKey: key)
            assert(!matches(missing))
        }
        var identityOnly = properties()
        identityOnly.removeValue(forKey: "default_generation_settings")
        assert(matches(identityOnly), "Readiness must use actual slots rather than unavailable per-request speculative defaults")
        assert(!matches([:]))
        print("PASS: DFlash launch keeps Q4_K_M, three GPU draft tokens, complete installation requirements and actual speculative slot identity")
    }
}
