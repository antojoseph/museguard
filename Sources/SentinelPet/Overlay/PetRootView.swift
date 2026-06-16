import SwiftUI

/// Lays out the speech bubble above the pet, both anchored to the bottom-
/// trailing corner so the pet "sits" in the corner of the screen.
struct PetRootView: View {
    @ObservedObject var viewModel: PetViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let message = viewModel.bubbleText {
                SpeechBubbleView(text: message, mood: viewModel.bubbleMood)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            PetView(mood: viewModel.mood)
        }
        .frame(width: 344, height: 404, alignment: .bottomTrailing)
        .padding(8)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: viewModel.bubbleText)
    }
}
