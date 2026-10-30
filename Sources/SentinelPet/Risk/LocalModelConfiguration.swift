import Foundation

enum LocalModelConfiguration {
    static let model = "muse-glimmer"
    static let mainModelFilename = "Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf"
    static let visionModelFilename = "mmproj-Muse-Glimmer-30B-Q4_K_M.gguf"
    static let draftModelFilename = "dflash-Muse-Glimmer-30B-Q4_K_M.gguf"
    static let requiredFiles = ["runtime/llama-server", "weights/\(mainModelFilename)",
                                "weights/\(visionModelFilename)", "weights/\(draftModelFilename)", "api-key"]
    static let baseURL = URL(string: "http://127.0.0.1:8787")!
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/LocalModel", isDirectory: true)
    }
    static var key: String? {
        try? String(contentsOf: directory.appendingPathComponent("api-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func serverArguments(directory root: URL = LocalModelConfiguration.directory) -> [String] {
        ["-m", root.appendingPathComponent("weights/\(mainModelFilename)").path,
         "--mmproj", root.appendingPathComponent("weights/\(visionModelFilename)").path,
         "-md", root.appendingPathComponent("weights/\(draftModelFilename)").path,
         "-ngld", "99", "--spec-type", "draft-dflash", "--spec-draft-n-max", "3",
         "--alias", model, "--host", "127.0.0.1", "--port", "8787",
         "--api-key-file", root.appendingPathComponent("api-key").path,
         "-ngl", "99", "-c", "16384", "-np", "1", "--jinja", "--no-webui",
         "--chat-template-kwargs", "{\"reasoning_strength\":\"low\"}", "--reasoning-budget", "256"]
    }
    static func matchesServerProperties(_ properties: [String: Any], slots: [[String: Any]], directory root: URL = LocalModelConfiguration.directory) -> Bool {
        guard properties["model_alias"] as? String == model,
              let path = properties["model_path"] as? String,
              URL(fileURLWithPath: path).standardizedFileURL.path == root.appendingPathComponent("weights/\(mainModelFilename)").standardizedFileURL.path else { return false }
        // b11946's /props reports fresh request defaults, not the active
        // speculative pipeline. /slots derives this flag from its live context.
        return !slots.isEmpty && slots.allSatisfy { $0["speculative"] as? Bool == true }
    }
    static func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
