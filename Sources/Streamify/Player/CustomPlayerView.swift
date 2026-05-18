import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Custom Player View
// UIViewRepresentable that displays the custom player's video output.
// The engine renders video via AVPlayerLayer (native HDR support) —
// we just host that view inside a container.

struct CustomPlayerView: UIViewRepresentable {
    let engine: CustomPlayerEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attachVideoView(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-attach the video view if it changed (e.g., after a player replacement)
        // or if it wasn't available when makeUIView was called.
        if let videoView = engine.videoView {
            if videoView.superview !== uiView {
                attachVideoView(to: uiView)
            }
        }
    }

    private func attachVideoView(to container: UIView) {
        // Remove any existing subviews
        container.subviews.forEach { $0.removeFromSuperview() }

        guard let videoView = engine.videoView else { return }

        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)

        // Size the video view to slightly beyond the safe area so it
        // cuts just a little into the Dynamic Island / rounded corners
        // (Netflix-style) instead of fully respecting the safe zone,
        // which over-shrinks the video. Center in the full container
        // so unequal safe-area insets don't push the video to one side.
        // The container (black) still fills edge-to-edge as background.
        let layoutBounds = container.window?.bounds ?? UIScreen.main.bounds
        let resolvedSafeArea = StreamifySafeArea.resolvedInsets(fallback: container.safeAreaInsets)
        let insetReduction: CGFloat = StreamifySafeArea.shouldCropVideoToFill(bounds: layoutBounds, safeAreaInsets: resolvedSafeArea) ? 4 : 0
        NSLayoutConstraint.activate([
            videoView.widthAnchor.constraint(equalTo: container.safeAreaLayoutGuide.widthAnchor,
                                             constant: insetReduction * 2),
            videoView.heightAnchor.constraint(equalTo: container.safeAreaLayoutGuide.heightAnchor,
                                              constant: insetReduction * 2),
            videoView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            videoView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }
}
