import SwiftUI

/// A rounded speech bubble used for greetings and security interventions. Its
/// border color reflects the pet's mood (orange = idle, blue = scanning,
/// red = alert).
struct SpeechBubbleView: View {
    let text: String
    let mood: PetMood
    var isDismissible = false
    var acknowledgment: GuardianAcknowledgment?
    var warningDetails: GuardianWarningDetails?
    var warningActions: [GuardianWarningAction] = []
    var warningActionStatus: String? = nil
    var onWarningAction: ((String) -> Void)? = nil
    var warningAvailableSize: CGSize? = nil
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAcknowledge: ((String) -> Void)?

    var body: some View {
        Group {
            if let acknowledgment {
                warningCard(acknowledgment)
            } else {
                regularBubble
            }
        }
    }

    private var regularBubble: some View {
        let style = BubbleStyle(mood: mood)
        let shouldScroll = shouldScroll(style: style)
        let canDismiss = isDismissible

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                messageContent(style: style, shouldScroll: shouldScroll)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            }
            .padding(.trailing, canDismiss ? 34 : 0)

            if canDismiss {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width:28,height:28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss message")
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            }
        }
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .frame(maxWidth: style.maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(.thickMaterial)
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(style.fillColor)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
            }
            .shadow(color: style.shadowColor, radius: style.shadowRadius, y: 3)
    }

    private func warningCard(_ acknowledgment: GuardianAcknowledgment) -> some View {
        let ink = Color(red: 0.10, green: 0.15, blue: 0.24)
        let secondaryInk = Color(red: 0.36, green: 0.41, blue: 0.49)
        let layout = WarningCardLayout(availableSize: warningAvailableSize)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: layout.compact ? 9 : 11) {
                if layout.width >= 250 {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: layout.compact ? 16 : 19, weight: .medium))
                        .foregroundStyle(Color(red: 0.63, green: 0.43, blue: 0.13))
                        .frame(width: layout.compact ? 30 : 38, height: layout.compact ? 30 : 38)
                        .background(Color(red: 0.98, green: 0.93, blue: 0.81), in: RoundedRectangle(cornerRadius: 11))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Muse Guard")
                        .font(.system(size: layout.compact ? 9.5 : 10.5, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(secondaryInk)
                    Text("Let’s pause here")
                        .font(.system(size: layout.compact ? 16 : 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.horizontalPadding)
            .frame(height: layout.headerHeight)
            .clipped()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if let warningDetails {
                        Text(warningDetails.summary)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                            .lineSpacing(2)
                        if !warningDetails.guidance.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Next step")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(secondaryInk)
                                Text(warningDetails.guidance)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(secondaryInk)
                                    .lineSpacing(3)
                            }
                        }
                    } else {
                        Text(text)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(ink)
                            .lineSpacing(3)
                    }
                    if let status = warningActionStatus {
                        Text(status).font(.caption).foregroundStyle(secondaryInk)
                    }
                    ForEach(warningActions) { action in
                        Button(action.title) { onWarningAction?(action.id) }
                            .buttonStyle(.bordered).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            .frame(height: layout.bodyHeight)
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.bottom, layout.bodyBottomPadding)

            Rectangle().fill(ink.opacity(0.09)).frame(height: 1)

            HStack(spacing: 12) {
                if layout.width >= 240 {
                    VStack(alignment: .leading, spacing: 4) {
                        if warningDetails != nil && !layout.compact {
                            Text("I’ll stay here.")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(secondaryInk)
                        }
                        if let onOpen {
                            Button("Ask Muse", action: onOpen)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .buttonStyle(.plain)
                                .foregroundStyle(ink)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let onAcknowledge {
                    GuardianAcknowledgmentButton(acknowledgment: acknowledgment, onAcknowledge: onAcknowledge)
                        .controlSize(.large)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tint(ink)
                }
            }
            .padding(.horizontal, layout.horizontalPadding)
            .frame(height: layout.footerHeight)
            .layoutPriority(1)
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.thickMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(red: 0.995, green: 0.987, blue: 0.965).opacity(0.97))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(ink.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: ink.opacity(0.16), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func messageContent(style: BubbleStyle, shouldScroll: Bool) -> some View {
        if shouldScroll {
            ScrollView {
                messageText(style: style)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: style.maxTextHeight)
        } else {
            messageText(style: style)
                .lineLimit(style.lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shouldScroll(style: BubbleStyle) -> Bool {
        guard style.scrolls else { return false }

        let explicitLineCount = text.components(separatedBy: .newlines).count
        return text.count > style.scrollCharacterThreshold
            || explicitLineCount > style.scrollLineThreshold
    }

    private func messageText(style: BubbleStyle) -> some View {
        Text(text)
            .font(.system(size: style.fontSize, weight: style.fontWeight, design: .rounded))
            .foregroundStyle(style.textColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WarningCardLayout {
    let width: CGFloat
    let height: CGFloat
    let compact: Bool
    let horizontalPadding: CGFloat
    let headerHeight: CGFloat
    let bodyHeight: CGFloat
    let bodyBottomPadding: CGFloat
    let footerHeight: CGFloat

    init(availableSize: CGSize?) {
        width = max(0, min(360, availableSize?.width ?? 360))
        height = max(0, min(307, availableSize?.height ?? 307))
        compact = width < 300 || height < 280
        horizontalPadding = compact ? 14 : 18
        let preferredFooter: CGFloat = height < 190 ? 48 : (compact ? 52 : 60)
        footerHeight = min(height, preferredFooter)
        let preferredHeader: CGFloat = height < 190 ? 44 : (compact ? 56 : 70)
        headerHeight = min(preferredHeader, max(0, height - footerHeight - 1))
        let remaining = max(0, height - headerHeight - footerHeight - 1)
        bodyBottomPadding = min(compact ? 10 : 16, remaining)
        bodyHeight = max(0, remaining - bodyBottomPadding)
    }
}

private struct BubbleStyle {
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let maxTextHeight: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let lineLimit: Int?
    let scrolls: Bool
    let scrollCharacterThreshold: Int
    let scrollLineThreshold: Int
    let fillColor: Color
    let borderColor: Color
    let textColor: Color
    let shadowColor: Color
    let shadowRadius: CGFloat

    init(mood: PetMood) {
        switch mood {
        case .idle:
            maxWidth = 220
            maxHeight = 96
            maxTextHeight = 72
            horizontalPadding = 12
            verticalPadding = 8
            cornerRadius = 13
            borderWidth = 1.25
            fontSize = 12
            fontWeight = .medium
            lineLimit = 3
            scrolls = false
            scrollCharacterThreshold = 120
            scrollLineThreshold = 3
            fillColor = Color.green.opacity(0.12)
            borderColor = Color.green.opacity(0.45)
            textColor = .primary
            shadowColor = .black.opacity(0.14)
            shadowRadius = 5
        case .scanning:
            maxWidth = 292
            maxHeight = 184
            maxTextHeight = 152
            horizontalPadding = 13
            verticalPadding = 10
            cornerRadius = 14
            borderWidth = 1.5
            fontSize = 12
            fontWeight = .medium
            lineLimit = nil
            scrolls = true
            scrollCharacterThreshold = 220
            scrollLineThreshold = 7
            fillColor = Color.blue.opacity(0.13)
            borderColor = Color.blue.opacity(0.55)
            textColor = .primary
            shadowColor = .blue.opacity(0.18)
            shadowRadius = 7
        case .alert:
            maxWidth = 336
            maxHeight = 296
            maxTextHeight = 260
            horizontalPadding = 14
            verticalPadding = 11
            cornerRadius = 15
            borderWidth = 2
            fontSize = 12.5
            fontWeight = .semibold
            lineLimit = nil
            scrolls = true
            scrollCharacterThreshold = 260
            scrollLineThreshold = 8
            fillColor = Color.red.opacity(0.14)
            borderColor = Color.red.opacity(0.7)
            textColor = .primary
            shadowColor = .red.opacity(0.25)
            shadowRadius = 9
        }
    }
}
