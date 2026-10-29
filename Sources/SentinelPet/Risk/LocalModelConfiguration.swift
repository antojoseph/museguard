import Foundation

enum LocalModelConfiguration {
    static let model = "muse-glimmer"
    static let baseURL = URL(string: "http://127.0.0.1:8787")!
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/LocalModel", isDirectory: true)
    }
    static var key: String? {
        try? String(contentsOf: directory.appendingPathComponent("api-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
