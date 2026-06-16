import SwiftUI

/// A rounded speech bubble used for greetings and security interventions. Its
/// border color reflects the pet's mood (orange = idle, blue = scanning,
/// red = alert).
struct SpeechBubbleView: View {
    let text: String
    let mood: PetMood

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thickMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var borderColor: Color {
        switch mood {
        case .alert:    return .red.opacity(0.65)
        case .scanning: return .blue.opacity(0.45)
        case .idle:     return .orange.opacity(0.45)
        }
    }
}
