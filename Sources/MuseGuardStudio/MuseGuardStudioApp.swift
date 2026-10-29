import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct MuseGuardStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Muse Guard Studio") {
            StudioView().frame(width: 620, height: 770)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class StudioDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { DesktopAvatarController.shared.stop(); UnrealCharacterRenderer.shared.stop() }
}

@MainActor
private final class StudioControls: ObservableObject {
    let renderer = UnrealCharacterRenderer.shared
    @Published var accessory = "guard"
    @Published var pose = "idle"
    @Published var ready = false
    @Published var status = "Starting Muse’s 3D renderer…"
    private var subscriptions = Set<AnyCancellable>()
    private var sequence: Task<Void, Never>?

    init() {
        renderer.$accessory.removeDuplicates().sink { [weak self] in self?.accessory = $0 }.store(in: &subscriptions)
        renderer.$isReady.removeDuplicates().sink { [weak self] in self?.ready = $0 }.store(in: &subscriptions)
        renderer.$status.removeDuplicates().sink { [weak self] in self?.status = $0 }.store(in: &subscriptions)
    }
    func start() { renderer.previewState = "idle"; renderer.start(); DesktopAvatarController.shared.start() }
    func performDesktop(_ action: () -> Void) { sequence?.cancel(); sequence = nil; pose = "idle"; action() }
    func selectAccessory(_ value: String) { renderer.accessory = value }
    func selectPose(_ value: String) {
        sequence?.cancel()
        pose = value
        DesktopAvatarController.shared.prepareForPose()
        renderer.previewState = "live"
        renderer.animate(value, duration: value == "climb" ? 6 : 20)
        if value == "idle" { renderer.previewState = "idle" }
        if value == "yawn" || value == "climb" {
            sequence = Task { [weak self] in
                guard await Self.pause(value == "yawn" ? 3 : 6), let self else { return }
                self.renderer.animate("idle"); self.renderer.previewState = "idle"; self.pose = "idle"
            }
        }
    }
    func jump() {
        sequence?.cancel()
        pose = "jump"
        DesktopAvatarController.shared.prepareForPose()
        sequence = Task { [weak self] in
            guard let self else { return }
            let wakeDelay = self.renderer.wakeForInteraction()
            guard await Self.pause(wakeDelay) else { return }
            for (state, duration) in [("notice", GuardianJumpTiming.anticipation), ("jump", GuardianJumpTiming.flight), ("land", GuardianJumpTiming.landing)] {
                self.renderer.animate(state, duration: duration, direction: 1)
                guard await Self.pause(duration) else { return }
            }
            self.renderer.animate("stop"); self.pose = "stop"
        }
    }
    func wake() {
        sequence?.cancel()
        pose = "wake"
        DesktopAvatarController.shared.prepareForPose()
        renderer.animate("wake", duration: 1.1)
        sequence = Task { [weak self] in
            guard await Self.pause(1.1), let self else { return }
            self.renderer.animate("idle"); self.renderer.previewState = "idle"; self.pose = "idle"
        }
    }
    private static func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return !Task.isCancelled }
        catch { return false }
    }
}

@MainActor
private struct StudioView: View {
    @StateObject private var controls = StudioControls()
    @ObservedObject private var desktop = DesktopAvatarController.shared
    private let poses: [(String, String)] = [("Idle", "idle"), ("Look", "scanning"), ("Stretch", "stretch"), ("Walk", "walk"), ("Climb", "climb"), ("Yawn", "yawn"), ("Sleep", "sleep"), ("Guard", "stop"), ("Explain", "explain")]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Meet your little Muse.").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("A plush companion, brought to life in 3D.").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.orange)
            }
            RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.93, green: 0.94, blue: 0.97))
                .frame(height: 320)
                .overlay {
                    AvatarPreview().frame(width: 310, height: 310).opacity(desktop.isOnJourney ? 0.3 : 1)
                    if desktop.isOnJourney {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title2)
                            Text("Playing on your desktop").font(.subheadline.weight(.medium))
                        }.foregroundStyle(.secondary)
                    }
                    if !controls.ready { ProgressView(controls.status).padding() }
                }
            HStack(spacing: 14) {
                Text("Accessory").font(.subheadline.weight(.medium))
                Picker("Accessory", selection: Binding(get: { controls.accessory }, set: { controls.selectAccessory($0) })) {
                    Text("Guard").tag("guard")
                    Text("Focus").tag("focus")
                    Text("Just Muse").tag("none")
                }.pickerStyle(.segmented).labelsHidden()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(poses, id: \.1) { label, state in
                    Button(label) { controls.selectPose(state) }
                        .buttonStyle(.bordered)
                        .tint(controls.pose == state ? .accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }.disabled(!controls.ready)
            HStack {
                Button("Jump & stop", action: controls.jump).buttonStyle(.borderedProminent)
                Button("Wake & return", action: controls.wake)
                Spacer()
                Text(controls.status).font(.caption).foregroundStyle(.secondary)
            }.disabled(!controls.ready)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("On your desktop").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(desktop.isVisible ? "Hide avatar" : "Show avatar") { controls.performDesktop { desktop.toggleVisibility() } }
                }
                HStack {
                    Button("Jump to center") { controls.performDesktop { desktop.jumpToCenter() } }.buttonStyle(.borderedProminent)
                    Button("Walk across screen") { controls.performDesktop { desktop.walkAcrossScreen() } }
                    Button("Climb edge") { controls.performDesktop { desktop.climbEdge() } }
                }.disabled(!controls.ready)
                HStack {
                    Button("Return home") { controls.performDesktop { desktop.returnHome() } }.disabled(!controls.ready)
                    Spacer()
                    Text(desktop.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                }
            }
            HStack {
                Text("Live rendered character · No prerecorded animation").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restart renderer") { controls.performDesktop { desktop.prepareForPose(); controls.renderer.restart() } }.font(.caption)
            }
        }
        .padding(28)
        .onAppear(perform: controls.start)
    }
}

private struct AvatarPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> AvatarFrameView { AvatarFrameView() }
    func updateNSView(_ nsView: AvatarFrameView, context: Context) {}
}

private final class AvatarFrameView: NSView {
    private var subscription: AnyCancellable?
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        subscription = UnrealCharacterRenderer.shared.$latestFrame.compactMap { $0 }.sink { [weak self] frame in
            // A desktop crop is a different camera. Keep the last home preview
            // while the real avatar is travelling outside this window.
            if !frame.isDesktopScene { self?.layer?.contents = frame.image }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
