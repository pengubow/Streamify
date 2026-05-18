import SwiftUI

struct StreamifyBarMaterial: View {
    var progress: Double = 1
    var edges: Edge.Set = []

    var body: some View {
        let clampedProgress = min(1, max(0, progress))

        ZStack {
            Color.black
                .opacity(0.42 * clampedProgress)

            Rectangle()
                .fill(.regularMaterial)
                .opacity(clampedProgress)

            Color(white: 0.16)
                .opacity(0.58 * clampedProgress)
        }
        .ignoresSafeArea(edges: edges)
    }
}

struct StreamifyBarHairline: View {
    var progress: Double = 1

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08 * progress))
            .frame(height: 1)
    }
}
