import SwiftUI

struct PetRootView: View {
    @ObservedObject var viewModel: PetViewModel
    let dragActions: GuardianDragActions
    var body: some View {
        PetView(mood: viewModel.mood)
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
        if viewModel.browserAction != nil { return 336 }
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
                        SentinelPetRuntime.shared.dismissPetBubble()
                    },
                    onBrowserDecision: { assessmentID, continueOnce in
                        SentinelPetRuntime.shared.resolveBrowserAction(assessmentID: assessmentID, continueOnce: continueOnce)
                    },
                    onAcknowledge: { id in
                        SentinelPetRuntime.shared.acknowledgeWarning(id: id)
                    }
                )

            } else if let message = viewModel.bubbleText {
                SpeechBubbleView(
                    text: message,
                    mood: viewModel.bubbleMood,
                    isDismissible: viewModel.bubbleIsDismissible,
                    browserAction: viewModel.browserAction,
                    acknowledgment: viewModel.acknowledgment,
                    warningDetails: viewModel.warningDetails,
                    warningAvailableSize: warningAvailableSize,
                    onOpen: { SentinelPetRuntime.shared.openPetChat() },
                    onDismiss: {
                        SentinelPetRuntime.shared.dismissPetBubble()
                    },
                    onBrowserDecision: { assessmentID, continueOnce in
                        SentinelPetRuntime.shared.resolveBrowserAction(assessmentID: assessmentID, continueOnce: continueOnce)
                    },
                    onAcknowledge: { id in
                        SentinelPetRuntime.shared.acknowledgeWarning(id: id)
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
        Button("Got it") { onAcknowledge(acknowledgment.id) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("guardian-acknowledge-\(acknowledgment.id)")
            .help("Acknowledge this warning and let Muse return home")
    }
}

/// Reuses the existing native message panel; no browser-page warning is added.
struct BrowserAvatarActionButtons: View {
    let action: BrowserAvatarAction
    let onDecision: (String, Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Stay here") { onDecision(action.assessmentID, false) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("browser-stay-here-\(action.assessmentID)")
                .help("Cancel this browser action")
            if action.canContinue {
                Button("Continue once") { onDecision(action.assessmentID, true) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("browser-continue-once-\(action.assessmentID)")
                    .help("Allow this action once")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}
