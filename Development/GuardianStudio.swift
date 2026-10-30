import AppKit
import SwiftUI
import Combine

@MainActor
final class GuardianStudio {
    static let shared = GuardianStudio()
    private var window: NSWindow?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 630), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Muse Guard Studio"
        window.isReleasedWhenClosed = false
        let size = NSSize(width:620,height:630)
        let hosting = NSHostingView(rootView: GuardianStudioView())
        // AppKit owns the fixed window size. A new video frame must never
        // negotiate a different intrinsic/minimum size with the hosting view.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct GuardianStudioView: View {
    @ObservedObject var pet = SentinelPetRuntime.shared.petViewModel
    private let renderer = UnrealCharacterRenderer.shared
    @State private var accessory = UnrealCharacterRenderer.shared.accessory
    @State private var previewState = UnrealCharacterRenderer.shared.previewState
    @State private var isReady = UnrealCharacterRenderer.shared.isReady
    @State private var status = UnrealCharacterRenderer.shared.status
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Meet your little guardian.").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("One Muse. A different outfit for every role.").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.blue)
            }
            RoundedRectangle(cornerRadius:24)
                .fill(Color(red:0.9,green:0.94,blue:0.98))
                .frame(width:564,height:290)
                .overlay {
                    GuardianStudioPreview().frame(width:282,height:282)
                    if !isReady { ProgressView(status).padding() }
                }
            Picker("Accessory", selection: Binding(get:{accessory},set:{renderer.accessory=$0})) {
                Text("Guard").tag("guard")
                Text("Headphones").tag("focus")
                Text("Just Muse").tag("none")
            }.pickerStyle(.segmented)
            Picker("Animation", selection: Binding(get:{previewState},set:{renderer.previewState=$0})) {
                Text("Live").tag("live")
                Text("Idle").tag("idle")
                Text("Looking").tag("scanning")
                Text("Stretch").tag("stretch")
                Text("Sleep").tag("sleep")
                Text("Guard").tag("stop")
                Text("Explain").tag("explain")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Animation").disabled(!isReady || pet.acknowledgment != nil)
            HStack {
                Button("Preview jump & stop") { renderer.previewState = "live"; SentinelPetRuntime.shared.previewGuardianIntervention() }
                    .buttonStyle(.borderedProminent).disabled(!isReady || pet.isAvatarHidden || pet.acknowledgment != nil)
                Button("Return home") { renderer.previewState = "live"; SentinelPetRuntime.shared.dismissPetBubble() }
                    .disabled(pet.acknowledgment != nil)
                Button(pet.isAvatarHidden ? "Show Muse" : "Hide Muse") { SentinelPetRuntime.shared.toggleAvatarVisibility() }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Automatic placement", isOn:$pet.automaticallyPositions).toggleStyle(.switch)
                Spacer()
                Text(pet.automaticallyPositions ? "Avoids your active window and pointer." : "Pinned where you dragged it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Preview nap") { renderer.requestNap() }
                    .disabled(!isReady || pet.isAvatarHidden || pet.acknowledgment != nil)
                Spacer()
                Text("Yawn, walk or climb, then settle into bed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(28).frame(width: 620, height: 630)
            // Subscribe only to control changes; renderer frames publish at
            // 30 fps and is consumed directly by the preview's CALayer below.
            .onReceive(renderer.$accessory.removeDuplicates()) { accessory=$0 }
            .onReceive(renderer.$previewState.removeDuplicates()) { previewState=$0 }
            .onReceive(renderer.$isReady.removeDuplicates()) { isReady=$0 }
            .onReceive(renderer.$status.removeDuplicates()) { status=$0 }
    }
}

private struct GuardianStudioPreview: NSViewRepresentable {
    func makeNSView(context:Context) -> StudioFrameView { StudioFrameView() }
    func updateNSView(_ view:StudioFrameView,context:Context) {}
}

/// Video pixels have no intrinsic layout size and no implicit layer animation.
/// Updating them cannot invalidate the Studio's SwiftUI control layout.
private final class StudioFrameView: NSView {
    private var frames: AnyCancellable?
    init() {
        super.init(frame:.zero)
        wantsLayer=true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
        layer?.actions = ["contents":NSNull(),"bounds":NSNull(),"position":NSNull()]
        frames=UnrealCharacterRenderer.shared.$latestFrame.sink { [weak self] frame in
            if let frame, !frame.isDesktopScene { self?.layer?.contents=frame.image }
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
}
