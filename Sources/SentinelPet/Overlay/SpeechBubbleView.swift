import SwiftUI

/// A rounded speech bubble used for greetings and security interventions. Its
/// border color reflects the pet's mood (orange = idle, blue = scanning,
/// red = alert).
struct SpeechBubbleView: View {
    let text: String
    let mood: PetMood
    var isDismissible = false
    var onDismiss: (() -> Void)?

    var body: some View {
        let style = BubbleStyle(mood: mood)
        let shouldScroll = shouldScroll(style: style)

        ZStack(alignment: .topTrailing) {
            messageContent(style: style, shouldScroll: shouldScroll)
                .padding(.trailing, isDismissible ? 20 : 0)

            if isDismissible {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
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
