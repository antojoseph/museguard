import AppKit
import Foundation

/// Owns one local Unreal process. Only character pixels and animation commands
/// cross this bridge; screen contents and model credentials never enter Unreal.
@MainActor
final class UnrealCharacterRenderer: ObservableObject {
    static let shared = UnrealCharacterRenderer()
    /// Pixels, scene flags and crop coordinates from one decoded frame.
    @Published private(set) var latestFrame: CharacterFrame?
    @Published private(set) var status = "Starting Muse’s 3D renderer…"
    @Published private(set) var isReady = false
    @Published private(set) var frameIsSleeping = false
    var desktopScene: GuardianDesktopScene? { didSet { writeCommand() } }
    func configureDesktop(_ scene: GuardianDesktopScene?, state nextState: String) {
        batchingCommand = true
        state = nextState
        desktopScene = scene
        batchingCommand = false
        writeCommand()
    }
    @Published var accessory: String = UserDefaults.standard.string(forKey: "museAccessory") ?? "guard" {
        didSet { UserDefaults.standard.set(accessory, forKey: "museAccessory"); writeCommand() }
    }
    @Published var previewState = "live" { didSet { writeCommand() } }
    var state = "idle" {
        didSet {
            // Real app events always take priority over a Studio pose preview.
            if state != oldValue {
                phaseStartedAt = Date()
                if state == "idle" { idleStartedAt = Date();sleepRequested=false }
                phaseDuration = GuardianJumpTiming.duration(for: state)
                previewState = "live"
            }
            writeCommand()
        }
    }
    var prepareSleep: (() -> Void)?
    private var sleepRequested = false
    func requestNap() { prepareSleep?() }
    func deferNap() { sleepRequested=false;idleStartedAt=Date().addingTimeInterval(-50) }
    private var idleStartedAt = Date()
    private var lastSubmittedPose = "idle"
    @discardableResult
    func wakeForInteraction() -> Double {
        let wasSleeping = frameIsSleeping || lastSubmittedPose == "sleep"
        idleStartedAt = Date();sleepRequested=false
        previewState = "live"
        if wasSleeping { animate("wake",duration:0.85) }
        return wasSleeping ? 0.85 : 0
    }
    private var phaseStartedAt = Date()
    private var phaseDuration = 1.0
    private var travelDirection = 0.0
    private var batchingCommand = false
    private lazy var inferenceActivity = GuardianWorkActivity { [weak self] _ in self?.writeCommand() }
    @Published private(set) var browserProtectionActive = false

    func setInferenceWorking(_ working: Bool) { inferenceActivity.setWorking(working) }
    func ownsProcess(_ pid: pid_t) -> Bool { process?.processIdentifier == pid }
    func setBrowserProtectionActive(_ active: Bool) {
        guard browserProtectionActive != active else { return }
        idleStartedAt = Date(); sleepRequested = false
        browserProtectionActive = active
        writeCommand()
    }

    @discardableResult
    func animate(_ nextState: String, duration: Double? = nil, direction: Double? = nil) -> Date {
        batchingCommand = true
        state = nextState
        phaseStartedAt = Date()
        phaseDuration = duration ?? GuardianJumpTiming.duration(for: nextState)
        if let direction { travelDirection = min(1, max(-1, direction)) }
        batchingCommand = false
        writeCommand()
        return phaseStartedAt
    }
    private var process: Process?
    private var bridge: URL?
    private var timer: Timer?
    private var lastSequence: UInt32 = 0
    private var lastHeartbeat = Date.distantPast
    private var lastFrameAt = Date.distantPast
    private var launchDate = Date()
    private var logHandle: FileHandle?

    func start() {
        guard process == nil else { return }
        guard let configURL = Bundle.main.url(forResource: "MuseRenderer", withExtension: "json"),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              FileManager.default.isExecutableFile(atPath: config.executable),
              FileManager.default.fileExists(atPath: config.project) else {
            status = "Muse’s 3D renderer is missing. Rebuild the app using the source setup guide."
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muse-guard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            bridge = directory
            writeCommand()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: config.executable)
            task.arguments = [config.project, "/Game/Maps/MuseStage", "-game", "-RenderOffscreen", "-windowed", "-ResX=448", "-ResY=448", "-nosound", "-unattended", "-NoSplash", "-NoLoadingScreen", "-MuseBridge=\(directory.path)", "-log", "-abslog=\(directory.appendingPathComponent("unreal.log").path)"]
            let stdoutURL = directory.appendingPathComponent("stdout.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: stdoutURL)
            task.standardOutput = logHandle
            task.standardError = logHandle
            task.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self, self.process === process else { return }
                    self.isReady = false
                    self.status = "Muse’s renderer stopped (\(process.terminationStatus)). Use Restart 3D renderer."
                    self.timer?.invalidate()
                    self.timer = nil
                    self.process = nil
                }
            }
            launchDate = Date()
            process = task
            try task.run()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } catch {
            process = nil
            status = "Unable to start 3D renderer: \(error.localizedDescription)"
        }
    }

    func restart() { stop(); latestFrame = nil; isReady = false; status = "Starting Muse’s 3D renderer…"; start() }
    func stop() {
        timer?.invalidate(); timer = nil
        let ownedProcess = process
        process = nil
        if ownedProcess?.isRunning == true { ownedProcess?.terminate() }
        try? logHandle?.close(); logHandle = nil
        // Preserve logs for debugging. The OS temp directory holds only one latest frame.
    }
    private func writeCommand() {
        guard !batchingCommand, let bridge else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let gaze = screen.map { Double((mouse.x - $0.frame.midX) / ($0.frame.width / 2)) } ?? 0
        var pose = previewState != "live" ? previewState : (state == "idle" ? GuardianIdlePolicy.pose(after:Date().timeIntervalSince(idleStartedAt),protectionActive:browserProtectionActive) : state)
        if pose == "sleep", state == "idle", previewState == "live", prepareSleep != nil {
            pose="drowsy"
            if !sleepRequested {
                sleepRequested=true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state == "idle", self.previewState == "live", self.sleepRequested, !self.browserProtectionActive else { return }
                    self.prepareSleep?()
                }
            }
        }
        lastSubmittedPose = pose
        var payload: [String: Any] = ["state": pose, "accessory": accessory, "gaze": gaze, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "debugMotion": BuildConfiguration.visualTestingEnabled, "phaseStart": phaseStartedAt.timeIntervalSince1970, "phaseDuration": phaseDuration, "travelDirection": travelDirection, "heartbeat": Date().timeIntervalSince1970]
        // Only an activity bit enters the renderer; source evidence stays in
        // the native analyzer. Explicit previews retain complete pose control.
        payload["working"] = previewState == "live" && inferenceActivity.isActive
        payload["protectionActive"] = previewState == "live" && browserProtectionActive
        payload["desktopScene"] = desktopScene?.command ?? ["enabled": false]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: bridge.appendingPathComponent("command.json"), options: .atomic)
        }
        lastHeartbeat = Date()
    }
    private func poll() {
        if Date().timeIntervalSince(lastHeartbeat) > 0.25 { writeCommand() }
        guard let bridge, let data = try? Data(contentsOf: bridge.appendingPathComponent("frame.rgba")), data.count >= 24,
              data.withUnsafeBytes({ UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:16,as:UInt32.self)) }) != lastSequence,
              let frame = CharacterFrame.decode(data) else {
            if isReady && Date().timeIntervalSince(lastFrameAt) > 5 { isReady = false; status = "Waiting for Muse’s renderer…" }
            if !isReady && Date().timeIntervalSince(launchDate) > 90 { status = "Unreal is still starting. Renderer logs are available from the menu." }
            return
        }
        lastSequence = frame.sequence
        lastFrameAt = Date()
        frameIsSleeping = frame.isSleeping
        isReady = true
        status = "Live Unreal 3D"
        latestFrame = frame
    }
    func showLogs() { if let bridge { NSWorkspace.shared.open(bridge) } }
    private struct Configuration: Decodable { let executable: String; let project: String }
}

/// Versioned and bounded frame decoding; atomic rename prevents partial reads.
struct CharacterFrame {
    let sequence: UInt32
    let image: CGImage
    let isDesktopScene: Bool
    let isSleeping: Bool
    let desktopRect: CGRect?
    /// Normalized, Y-up bounds. Placement requests this only when its cached
    /// message envelope changes, so ordinary frame decoding never scans pixels.
    var silhouette: CGRect? {
        guard let bytes = image.dataProvider?.data, let base = CFDataGetBytePtr(bytes) else { return nil }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        return withExtendedLifetime(bytes) {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                let row = base.advanced(by: y * stride + 3)
                var left = 0, alpha = row
                while left < width && alpha.pointee <= 24 { left += 1; alpha = alpha.advanced(by: 4) }
                guard left < width else { continue }
                var right = width - 1
                alpha = row.advanced(by: right * 4)
                while right > left && alpha.pointee <= 24 { right -= 1; alpha = alpha.advanced(by: -4) }
                if left < minX { minX = left }
                if right > maxX { maxX = right }
                if y < minY { minY = y }
                maxY = y
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: Double(minX) / Double(width), y: Double(height - maxY - 1) / Double(height),
                          width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        }
    }
    func silhouette(in rect: CGRect) -> CGRect? {
        guard let silhouette else { return nil }
        return CGRect(x: rect.minX + silhouette.minX * rect.width,
                      y: rect.minY + silhouette.minY * rect.height,
                      width: silhouette.width * rect.width,
                      height: silhouette.height * rect.height)
    }
    static func decode(_ data: Data) -> CharacterFrame? {
        guard data.count >= 24 else { return nil }
        let header = data.prefix(24).withUnsafeBytes { bytes in
            (0..<6).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard header[0] == 0x4D555345, (header[1] == 1 || header[1] == 2),
              header[2] > 0, header[2] <= 2048, header[3] > 0, header[3] <= 2048 else { return nil }
        let width = Int(header[2]), height = Int(header[3])
        let headerSize = header[1] == 2 ? 40 : 24
        guard data.count == headerSize + width * height * 4 else { return nil }
        var desktopRect: CGRect?
        if header[1] == 2 {
            guard header[5] & 1 != 0 else { return nil }
            let values = data.withUnsafeBytes { bytes in
                (0..<4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset:24+$0*4,as:UInt32.self))) }
            }
            guard values.allSatisfy({ $0.isFinite }), values[2] > 0, values[3] > 0,
                  values[2] <= 2048, values[3] <= 2048 else { return nil }
            desktopRect = CGRect(x:Double(values[0]),y:Double(values[1]),width:Double(values[2]),height:Double(values[3]))
        }
        guard let provider = CGDataProvider(data: data.dropFirst(headerSize) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return CharacterFrame(sequence: header[4], image: image, isDesktopScene: header[5] & 1 != 0, isSleeping: header[5] & 2 != 0, desktopRect: desktopRect)
    }
}
