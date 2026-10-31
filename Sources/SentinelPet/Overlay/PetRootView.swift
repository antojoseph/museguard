import SwiftUI

struct PetRootView: View {
    let dragActions: GuardianDragActions
    var body: some View {
        PetView()
            .overlay { GuardianDragSurface(actions: dragActions) }
    }
}

private struct MessageSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct GuardianMessageView: View {
    @ObservedObject var viewModel: PetViewModel
    let onSize: (CGSize) -> Void
    private var warningPanelSize: CGSize {
        viewModel.isChatOpen
            ? CGSize(width: MuseLayout.chatContentSize.width + 20, height: MuseLayout.chatContentSize.height + 20)
            : CGSize(width: 380, height: 327)
    }
    private var width: CGFloat {
        if viewModel.isChatOpen { return MuseLayout.chatContentSize.width }
        if viewModel.acknowledgment != nil { return 360 }
        switch viewModel.bubbleMood {
        case .idle: return 220
        case .scanning: return 292
        case .alert: return 336
        }
    }
    var body: some View {
        if viewModel.acknowledgment != nil {
            // Placement can shrink the panel to keep it beside Muse. Report its
            // preferred size separately so a clamped layout never becomes the
            // preferred size for the next placement pass.
            GeometryReader { bounds in
                PetMessageView(viewModel: viewModel, warningAvailableSize: CGSize(
                    width: max(0, bounds.size.width - 20),
                    height: max(0, bounds.size.height - 20)
                ))
                .padding(10)
            }
            .onAppear { onSize(warningPanelSize) }
            .onChange(of: viewModel.acknowledgment?.id) { _ in onSize(warningPanelSize) }
            .onChange(of: viewModel.isChatOpen) { _ in onSize(warningPanelSize) }
        } else {
            PetMessageView(viewModel:viewModel)
                .frame(width:width, alignment:.leading)
                .fixedSize(horizontal:false,vertical:true)
                .padding(10)
                .background(GeometryReader { p in Color.clear.preference(key:MessageSizeKey.self,value:p.size) })
                .onPreferenceChange(MessageSizeKey.self,perform:onSize)
        }
    }
}

struct PetMessageView: View {
    @ObservedObject var viewModel: PetViewModel
    var warningAvailableSize: CGSize? = nil
    var body: some View {
        Group {
            if viewModel.isChatOpen {
                PetChatBubbleView(
                    viewModel: viewModel,
                    acknowledgmentAvailableSize: warningAvailableSize,
                    onSend: { question in
                        SentinelPetRuntime.shared.askPetChat(question)
                    },
                    onDismiss: {
                        SentinelPetRuntime.shared.closePetChat()
                    },
                    onStop: { SentinelPetRuntime.shared.stopPetChatReply() },
                    onNewChat: { SentinelPetRuntime.shared.resetPetChat() },
                    onBack: { SentinelPetRuntime.shared.returnToWarning() },
                    onAcknowledge: { id in
                        SentinelPetRuntime.shared.acknowledgeWarning(id: id)
                    },
                    onFalsePositive: { id in
                        SentinelPetRuntime.shared.dismissWarningAsFalsePositive(id: id)
                    }
                )

            } else if let message = viewModel.bubbleText {
                SpeechBubbleView(
                    text: message,
                    mood: viewModel.bubbleMood,
                    isDismissible: viewModel.bubbleIsDismissible,
                    acknowledgment: viewModel.acknowledgment,
                    warningDetails: viewModel.warningDetails,
                    warningActions: viewModel.warningActions,
                    warningActionStatus: viewModel.warningActionStatus,
                    onWarningAction: { SentinelPetRuntime.shared.performWarningAction(id: $0) },
                    warningAvailableSize: warningAvailableSize,
                    onOpen: { SentinelPetRuntime.shared.openPetChat() },
                    onDismiss: {
                        SentinelPetRuntime.shared.dismissPetBubble()
                    },
                    onAcknowledge: { id in
                        SentinelPetRuntime.shared.acknowledgeWarning(id: id)
                    },
                    onFalsePositive: { id in
                        SentinelPetRuntime.shared.dismissWarningAsFalsePositive(id: id)
                    }
                )

            }
        }
    }
}

struct GuardianAcknowledgmentButton: View {
    let acknowledgment: GuardianAcknowledgment
    let onAcknowledge: (String) -> Void

    var body: some View {
        Button { onAcknowledge(acknowledgment.id) } label: {
            Text("Got it")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GuardianAcknowledgmentStyle())
        .accessibilityIdentifier("guardian-acknowledge-\(acknowledgment.id)")
        .help("Acknowledge this warning and let Muse return home")
    }
}

private struct GuardianAcknowledgmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Native prominent controls lose their accent in an inactive
            // overlay. Keep the primary decision readable before the first
            // click, including while the browser remains the active app.
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed
                    ? Color(red: 0.11, green: 0.27, blue: 0.65)
                    : Color(red: 0.16, green: 0.35, blue: 0.78)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct GuardianFalsePositiveButton: View {
    let acknowledgment: GuardianAcknowledgment
    let onFalsePositive: (String) -> Void

    var body: some View {
        Button { onFalsePositive(acknowledgment.id) } label: {
            Text("Dismiss as false positive")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("guardian-false-positive-\(acknowledgment.id)")
        .help("Dismiss and save this warning as incorrect on this Mac. This does not allow the flagged action.")
    }
}
