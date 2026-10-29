import AppKit
import Foundation

@MainActor
final class LocalModelService: ObservableObject {
    static let shared = LocalModelService()
    @Published private(set) var isReady = false
    @Published private(set) var status = "Local model stopped"
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var log: FileHandle?
    var isInstalled: Bool {
        let root = LocalModelConfiguration.directory
        return ["runtime/llama-server", "weights/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf", "weights/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf", "api-key"].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    func start() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            guard let self else { return }
            if await self.checkHealth() { self.status = "Muse Glimmer · on this Mac"; self.isReady = true; self.healthTask = nil; return }
            self.isReady = false
            guard self.isInstalled else { self.status = "Run scripts/setup-local-model.sh to install Muse Glimmer"; self.healthTask = nil; return }
            guard self.process == nil else {
                self.status = "Muse Glimmer is not responding yet; check model logs"
                self.healthTask = nil
                return
            }
            self.status = "Loading Muse Glimmer locally…"
            let root = LocalModelConfiguration.directory
            do {
                let task = Process()
                task.executableURL = root.appendingPathComponent("runtime/llama-server")
                task.arguments = ["-m", root.appendingPathComponent("weights/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf").path,
                                  "--mmproj", root.appendingPathComponent("weights/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf").path,
                                  "--alias", LocalModelConfiguration.model, "--host", "127.0.0.1", "--port", "8787",
                                  "--api-key-file", root.appendingPathComponent("api-key").path,
                                  "-ngl", "99", "-c", "16384", "-np", "1", "--jinja", "--no-webui",
                                  "--chat-template-kwargs", "{\"reasoning_strength\":\"low\"}", "--reasoning-budget", "256"]
                let logURL = root.appendingPathComponent("server.log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                self.log = try FileHandle(forWritingTo: logURL)
                task.standardOutput = self.log; task.standardError = self.log
                task.terminationHandler = { [weak self] process in
                    Task { @MainActor in
                        guard let self, self.process === process else { return }
                        self.process = nil; self.isReady = false
                        self.status = "Local model stopped (\(process.terminationStatus)); open model logs for details"
                    }
                }
                self.process = task
                try task.run()
                for _ in 0..<180 {
                    guard !Task.isCancelled, task.isRunning else { break }
                    if await self.checkHealth() { self.isReady = true; self.status = "Muse Glimmer · on this Mac"; break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !self.isReady && task.isRunning { self.status = "Model is still loading; check model status or logs" }
            } catch { self.process = nil; self.status = "Local model could not start: \(error.localizedDescription)" }
            self.healthTask = nil
        }
    }
    func stop() {
        healthTask?.cancel(); healthTask = nil
        let owned = process; process = nil
        if owned?.isRunning == true { owned?.terminate() }
        try? log?.close(); log = nil
        isReady = false; status = "Local model stopped"
    }
    func showLogs() { NSWorkspace.shared.open(LocalModelConfiguration.directory) }
    private func checkHealth() async -> Bool {
        var request = LocalModelConfiguration.request(path: "v1/models")
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return false }
        return models.contains { $0["id"] as? String == LocalModelConfiguration.model }
    }
}
