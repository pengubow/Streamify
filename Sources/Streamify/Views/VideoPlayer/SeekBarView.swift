import SwiftUI

// MARK: - Custom seek bar
struct SeekBarView: View {
    @Binding var progress: Double
    @Binding var currentTime: Double
    var duration: Double
    @Binding var previewTime: Double
    var loadedRanges: [(start: Double, end: Double)]
    var onSeekStarted: () -> Void
    var onSeekEnded: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragProgress: Double = 0
    @State private var dragTime: Double = 0
    @State private var thumbX: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    if isDragging && duration > 0 {
                        Text(formatTime(dragTime))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 24)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .position(x: thumbX, y: 12)
                    }
                }
            }
            .frame(height: 24)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: isDragging ? 6 : 3)

                    // Loaded/buffered ranges - lighter gray
                    ForEach(Array(loadedRanges.enumerated()), id: \.offset) { _, range in
                        let startFraction = duration > 0 ? range.start / duration : 0
                        let endFraction = duration > 0 ? range.end / duration : 0
                        let clampedStart = min(max(startFraction, 0), 1)
                        let clampedEnd = min(max(endFraction, 0), 1)
                        let width = geo.size.width * CGFloat(clampedEnd - clampedStart)
                        let offset = geo.size.width * CGFloat(clampedStart)
                        
                        Capsule()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: max(width, 0), height: isDragging ? 6 : 3)
                            .offset(x: offset)
                    }

                    Capsule()
                        .fill(Color.red)
                        .frame(
                            width: geo.size.width * CGFloat(isDragging ? dragProgress : clampedProgress),
                            height: isDragging ? 6 : 3
                        )

                    Circle()
                        .fill(Color.red)
                        .frame(width: isDragging ? 16 : 10, height: isDragging ? 16 : 10)
                        .offset(x: geo.size.width * CGFloat(isDragging ? dragProgress : clampedProgress) - (isDragging ? 8 : 5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onSeekStarted()
                            }
                            let pct = Double(value.location.x / geo.size.width)
                            dragProgress = min(max(pct, 0), 1)
                            dragTime = dragProgress * duration
                            previewTime = dragTime
                            thumbX = geo.size.width * CGFloat(dragProgress)
                        }
                        .onEnded { _ in
                            isDragging = false
                            // Update currentTime immediately for UI (progress getter
                            // reads viewModel.currentTime so the thumb stays in place).
                            // Do NOT set progress = dragProgress here — that triggers
                            // an async seek through the binding, and onSeekEnded would
                            // call play() before the seek completes, causing a snap-back.
                            currentTime = dragTime
                            onSeekEnded()
                        }
                )
                .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 20)
        }
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        TimeFormatting.formatTime(seconds)
    }
}
