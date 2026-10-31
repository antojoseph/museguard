import SwiftUI
import AppKit

struct PetChatBubbleView: View {
    @ObservedObject var viewModel: PetViewModel
    var acknowledgmentAvailableSize: CGSize? = nil
    let onSend: (String) -> Void
    let onDismiss: () -> Void
    let onStop: () -> Void
    let onNewChat: () -> Void
    let onBack: () -> Void
    var onAcknowledge: ((String) -> Void)?
    var onFalsePositive: ((String) -> Void)?

    @State private var draft = ""
    @State private var followsLatest = true

    private var acknowledgmentSize: CGSize? {
        guard viewModel.acknowledgment != nil, let acknowledgmentAvailableSize else { return nil }
        return CGSize(width: max(0, min(MuseLayout.chatContentSize.width, acknowledgmentAvailableSize.width)),
                      height: max(0, min(MuseLayout.chatContentSize.height, acknowledgmentAvailableSize.height)))
    }

    private var acknowledgmentTranscriptHeight: CGFloat? {
        // Keep the header, acknowledgement and question field reachable when
        // placement reduces the panel height; only the transcript gets shorter.
        acknowledgmentSize.map { max(0, min(152, $0.height - (compactAcknowledgment ? 150 : 200))) }
    }
    private var compactAcknowledgment: Bool { (acknowledgmentSize?.height ?? .infinity) < 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: compactAcknowledgment ? 2 : 8) {
            HStack(spacing: 8) {
                VStack(alignment:.leading,spacing:2) {
                    Text("Muse Guard").font(.caption.weight(.semibold))
                    if let label = viewModel.chatContextLabel, !compactAcknowledgment {
                        Text(label).font(.system(size:10)).lineLimit(1).help(label)
                    }
                }
                .foregroundStyle(.secondary)

                Spacer()

                if viewModel.acknowledgment != nil {
                    Button(action: onBack) { Label("Back", systemImage: "chevron.backward") }
                        .buttonStyle(.plain)
                        .help("Back to warning without acknowledging it (Esc)")
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        followsLatest = true
                        draft = ""
                        onNewChat()
                    } label: { Text("New chat") }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .help("Start a new conversation")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width:28,height:28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close chat")
                    .help("Close chat (Esc)")
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(viewModel.chatMessages) { message in
                                ChatRow(message: message)
                                    .id(message.id)
                            }

                            if viewModel.isChatThinking {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.55)
                                    Text(viewModel.isChatStreaming ? "Replying…" : "Checking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("chat-latest")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ChatScrollObserver { followsLatest = $0 })
                    }
                    if !followsLatest {
                        Button {
                            followsLatest = true
                            scrollToBottom(proxy, force: true)
                        } label: { Label("Latest", systemImage: "arrow.down") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(height: acknowledgmentTranscriptHeight)
                .frame(maxHeight: viewModel.acknowledgment == nil ? 196 : 152)
                .onAppear { scrollToBottom(proxy, force: true) }
                .onChange(of: viewModel.chatMessages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.chatMessages.last?.text) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.isChatThinking) { _ in
                    scrollToBottom(proxy)
                }
            }

            if let acknowledgment = viewModel.acknowledgment, let onAcknowledge {
                VStack(alignment: .leading, spacing: compactAcknowledgment ? 4 : 7) {
                    GuardianAcknowledgmentButton(acknowledgment: acknowledgment, onAcknowledge: onAcknowledge)
                    if let onFalsePositive {
                        GuardianFalsePositiveButton(acknowledgment: acknowledgment, onFalsePositive: onFalsePositive)
                    }
                }.layoutPriority(1)
            }

            HStack(spacing: 6) {
                TextField("Ask about this", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isChatThinking)
                    .onSubmit(send)

                if viewModel.isChatThinking {
                    Button("Stop", action: onStop)
                        .accessibilityLabel("Stop reply")
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                    }
                    .accessibilityLabel("Send message")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .layoutPriority(viewModel.acknowledgment == nil ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compactAcknowledgment ? 4 : 10)
        .frame(width: acknowledgmentSize?.width ?? MuseLayout.chatContentSize.width,
               height: acknowledgmentSize?.height ?? MuseLayout.chatContentSize.height, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.thickMaterial)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.58), lineWidth: 1.6)
        }
        .shadow(color: .blue.opacity(0.2), radius: 8, y: 3)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !viewModel.isChatThinking else { return }

        followsLatest = true
        draft = ""
        onSend(question)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        DispatchQueue.main.async {
            guard force || followsLatest else { return }
            proxy.scrollTo("chat-latest", anchor: .bottom)
        }
    }
}

/// Observe actual scrolling, rather than treating growing streamed text as a
/// request to leave the bottom. The zero-sized anchor never receives input.
private struct ChatScrollObserver: NSViewRepresentable {
    var onFollowChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFollowChanged) }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onConnect = { [weak coordinator = context.coordinator] anchor in coordinator?.connect(anchor) }
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.onFollowChanged = onFollowChanged
        view.connectLater()
    }
    final class Anchor: NSView {
        var onConnect: ((NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectLater() }
        func connectLater() { DispatchQueue.main.async { [weak self] in if let self { self.onConnect?(self) } } }
    }
    final class Coordinator {
        var onFollowChanged: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var previousOrigin = NSPoint.zero
        init(_ callback: @escaping (Bool) -> Void) { onFollowChanged = callback }
        func connect(_ anchor: NSView) {
            var parent = anchor.superview
            while let view = parent, !(view is NSScrollView) { parent = view.superview }
            guard let scroll = parent as? NSScrollView, scroll !== scrollView else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scrollView = scroll
            previousOrigin = scroll.contentView.bounds.origin
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in self?.didScroll() }
        }
        private func didScroll() {
            guard let scroll = scrollView, let document = scroll.documentView else { return }
            let origin = scroll.contentView.bounds.origin
            guard origin != previousOrigin else { return }
            previousOrigin = origin
            let visible = document.visibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            onFollowChanged(distance <= 28)
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

private struct ChatRow: View {
    let message: PetChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 22)
            }

            Text(message.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
                // AppKit's selectable SwiftUI text can retain its initial
                // value while a stable transcript row streams new content.
                // Refresh the text child, retaining the row's message ID.
                .id(message.text)

            if message.role == .assistant {
                Spacer(minLength: 22)
            }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.2)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor).opacity(0.82)
        }
    }
}
