import SwiftUI

/// Real-time transparent frames from the local Unreal 3D scene, not a sprite sheet.
struct PetView: View {
    @ObservedObject private var renderer = UnrealCharacterRenderer.shared
    @State private var homeImage: CGImage?
    var body: some View {
        ZStack {
            if let image = homeImage {
                Image(decorative: image, scale: 2, orientation: .up)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(renderer.status).font(.system(size: 11, design: .rounded)).multilineTextAlignment(.center)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(width: MuseLayout.characterSize, height: MuseLayout.characterSize)
        .accessibilityLabel("Muse Guard 3D companion")
        .onReceive(renderer.$latestFrame) { frame in
            // Keep the home camera's last image while Unreal renders a cropped
            // desktop journey; never resize that crop into the home panel.
            if let frame, !frame.isDesktopScene { homeImage = frame.image }
        }
    }
}
