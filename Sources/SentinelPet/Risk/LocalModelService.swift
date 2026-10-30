import AppKit
import Foundation

@MainActor
final class LocalModelService: ObservableObject {
    static let shared = LocalModelService()
    @Published private(set) var isReady = false
    @Published private(set) var status = "Local model stopped"
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var startupID = UUID()
    private var log: FileHandle?
    var isInstalled: Bool {
        let root = LocalModelConfiguration.directory
        return LocalModelConfiguration.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    func start() {
        guard healthTask == nil else { return }
        let id = UUID(); startupID = id
        healthTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.startupID == id { self.healthTask = nil } }
            let existing = await self.checkServer()
            guard !Task.isCancelled, self.startupID == id else { return }
            if existing == .ready { self.status = "Muse Glimmer · on this Mac"; self.isReady = true; return }
            self.isReady = false
            if existing == .incompatible { self.status = "The running model uses older settings. Stop it and reopen Muse Guard to apply the update."; return }
            guard self.isInstalled else { self.status = "Run scripts/setup-local-model.sh to install Muse Glimmer and its draft model"; return }
            guard self.process == nil else {
                self.status = "Muse Glimmer is not responding yet; check model logs"
                return
            }
            if existing == .loading {
                self.status = "Waiting for the local model…"
                await self.waitUntilReady(startupID: id)
                return
            }
            self.status = "Loading Muse Glimmer locally…"
            let root = LocalModelConfiguration.directory
            do {
                let task = Process()
                task.executableURL = root.appendingPathComponent("runtime/llama-server")
                task.arguments = LocalModelConfiguration.serverArguments(directory: root)
                let logURL = root.appendingPathComponent("server.log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                self.log = try FileHandle(forWritingTo: logURL)
                try self.log?.truncate(atOffset: 0)
                task.standardOutput = self.log; task.standardError = self.log
                task.terminationHandler = { [weak self] process in
                    Task { @MainActor in
                        guard let self, self.process === process else { return }
                        self.process = nil; self.isReady = false
                        self.status = "Local model stopped (\(process.terminationStatus)); open model logs for details"
                    }
                }
                self.process = task
                guard !Task.isCancelled, self.startupID == id else { self.process = nil; return }
                try task.run()
                await self.waitUntilReady(startupID: id, owned: task)
            } catch { self.process = nil; self.status = "Local model could not start: \(error.localizedDescription)" }
        }
    }
    func stop() {
        healthTask?.cancel(); healthTask = nil
        startupID = UUID()
        let owned = process; process = nil
        if owned?.isRunning == true { owned?.terminate() }
        try? log?.close(); log = nil
        isReady = false; status = "Local model stopped"
    }
    func showLogs() { NSWorkspace.shared.open(LocalModelConfiguration.directory) }
    private enum ServerState { case ready, loading, incompatible, unavailable }
    private func waitUntilReady(startupID id: UUID, owned: Process? = nil) async {
        for _ in 0..<180 {
            guard !Task.isCancelled, startupID == id else { return }
            if let owned, !owned.isRunning { return }
            let state = await checkServer()
            guard !Task.isCancelled, startupID == id else { return }
            if state == .ready { isReady = true; status = "Muse Glimmer · on this Mac"; return }
            if state == .incompatible { status = "The running model uses older settings. Stop it and reopen Muse Guard to apply the update."; return }
            if owned == nil, state == .unavailable { status = "The local model stopped responding. Choose Start local model to retry."; return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard !Task.isCancelled, startupID == id else { return }
        status = "Model is still loading; check model status or logs"
    }
    private func checkServer() async -> ServerState {
        var request = LocalModelConfiguration.request(path: "props")
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse else { return .unavailable }
        if response.statusCode == 503 { return .loading }
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .incompatible }
        var slotsRequest = LocalModelConfiguration.request(path: "slots")
        slotsRequest.timeoutInterval = 2
        guard let (slotsData, slotsResponse) = try? await URLSession.shared.data(for: slotsRequest),
              let slotsResponse = slotsResponse as? HTTPURLResponse else { return .unavailable }
        if slotsResponse.statusCode == 503 { return .loading }
        guard slotsResponse.statusCode == 200,
              let slots = try? JSONSerialization.jsonObject(with: slotsData) as? [[String: Any]] else { return .incompatible }
        return LocalModelConfiguration.matchesServerProperties(json, slots: slots) ? .ready : .incompatible
    }
}
