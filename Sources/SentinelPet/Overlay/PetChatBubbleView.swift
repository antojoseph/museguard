import SwiftUI

struct PetChatBubbleView: View {
    @ObservedObject var viewModel: PetViewModel
    var acknowledgmentAvailableSize: CGSize? = nil
    let onSend: (String) -> Void
    let onDismiss: () -> Void
    var onBrowserDecision: ((String, Bool) -> Void)?
    var onAcknowledge: ((String) -> Void)?

    @State private var draft = ""

    private var acknowledgmentSize: CGSize? {
        guard viewModel.acknowledgment != nil, let acknowledgmentAvailableSize else { return nil }
        return CGSize(width: max(0, min(MuseLayout.chatContentSize.width, acknowledgmentAvailableSize.width)),
                      height: max(0, min(MuseLayout.chatContentSize.height, acknowledgmentAvailableSize.height)))
    }

    private var acknowledgmentTranscriptHeight: CGFloat? {
        // Keep the header, acknowledgement and question field reachable when
        // placement reduces the panel height; only the transcript gets shorter.
        acknowledgmentSize.map { max(0, min(152, $0.height - 136)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment:.leading,spacing:2) {
                    Text("Muse Guard").font(.caption.weight(.semibold))
                    if let label = viewModel.chatContextLabel {
                        Text(label).font(.system(size:10)).lineLimit(1).help(label)
                    }
                }
                .foregroundStyle(.secondary)

                Spacer()

                if viewModel.acknowledgment == nil {
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
                                Text(viewModel.isChatStreaming ? "Replying…" : "Checking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: acknowledgmentTranscriptHeight)
                .frame(maxHeight: viewModel.browserAction == nil && viewModel.acknowledgment == nil ? 196 : 152)
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
                GuardianAcknowledgmentButton(acknowledgment: acknowledgment, onAcknowledge: onAcknowledge)
                    .layoutPriority(1)
            } else if viewModel.acknowledgment == nil, let action = viewModel.browserAction, let onBrowserDecision {
                BrowserAvatarActionButtons(action: action, onDecision: onBrowserDecision)
            }

            HStack(spacing: 6) {
                TextField("Ask about this", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isChatThinking)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isChatThinking)
            }
            .layoutPriority(viewModel.acknowledgment == nil ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

        draft = ""
        onSend(question)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if viewModel.isChatThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = viewModel.chatMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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
