import AppKit
import SwiftUI

@MainActor final class MockLab {
    static let shared = MockLab()
    private var window: NSWindow?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 570), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Muse Guard Mock Lab"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MockLabView())
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MockLabView: View {
    @ObservedObject var runtime = SentinelPetRuntime.shared
    @ObservedObject var model = LocalModelService.shared
    @State private var scenario = MockScenario.phishing
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try your guardian.").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Synthetic examples, analyzed by Muse Glimmer on this Mac.").foregroundStyle(.secondary)
            Picker("Example", selection: $scenario) {
                ForEach(MockScenario.allCases) { Text($0.title).tag($0) }
            }
            ScrollView { Text(scenario.text).font(.system(size: 14, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                .frame(height: 220).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button(runtime.isAnalyzing ? "Analyzing locally…" : "Analyze example") { runtime.analyzeMock(scenario) }
                    .buttonStyle(.borderedProminent).disabled(!model.isReady || runtime.isAnalyzing)
                Button("Return guardian home") { runtime.dismissPetBubble() }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            if let result = runtime.lastMockResult { Text(result).font(.callout).textSelection(.enabled).frame(maxHeight: 100, alignment: .top) }
            else { Text("A risky result triggers the jump and stop gesture. Benign content leaves Muse at home.").font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(28).frame(width: 660, height: 570)
    }
}
