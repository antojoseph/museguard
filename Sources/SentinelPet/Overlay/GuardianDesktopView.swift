import SwiftUI

@MainActor
final class GuardianDesktopPresentation: ObservableObject {
    @Published var size: CGSize = .zero
    @Published var showsMessage = false
}

/// One stationary transparent surface. Both lateral travel and depth are
/// rendered by Unreal. Each frame carries its crop rectangle; compositing
/// that crop preserves the fixed camera and two pixels per desktop point.
struct GuardianDesktopView: View {
    @ObservedObject var renderer = UnrealCharacterRenderer.shared
    @ObservedObject var presentation: GuardianDesktopPresentation
    @ObservedObject var viewModel: PetViewModel
    let dragActions: GuardianDragActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = renderer.latestFrame, frame.isDesktopScene {
                let rect = frame.desktopRect ?? CGRect(origin:.zero,size:presentation.size)
                Image(decorative: frame.image, scale: 2).resizable().interpolation(.high)
                    .frame(width:rect.width,height:rect.height)
                    .position(x:rect.midX,y:presentation.size.height-rect.midY)
            }
        }.frame(width: presentation.size.width, height: presentation.size.height)
            .overlay { GuardianDragSurface(actions: dragActions) }
    }
}
