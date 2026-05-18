import SwiftUI

/// Reusable capsule-shaped download progress bar.
///
/// Usage:
///   DownloadProgressBar(progress: 0.5) // green, 4pt
///   DownloadProgressBar(progress: 0.5, color: .orange, height: 3)
struct DownloadProgressBar: View {
    let progress: Double
    var color: Color = .green
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: height)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)), height: height)
                    .animation(.linear(duration: 0.3), value: progress)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}
