import SwiftUI

struct PetChatBubbleView: View {
    @ObservedObject var viewModel: PetViewModel
    let onSend: (String) -> Void
    let onDismiss: () -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Sentinel Pet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                                Text("Checking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 196)
                .onChange(of: viewModel.chatMessages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.isChatThinking) { _ in
                    scrollToBottom(proxy)
                }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 336, height: 296, alignment: .topLeading)
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
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)

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
