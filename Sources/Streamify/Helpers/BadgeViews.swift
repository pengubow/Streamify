import SwiftUI

// MARK: - Reusable badge components

/// A small colored pill badge used throughout the app.
///
/// Usage:
///   PillBadge("VidLink", color: .purple)
///   PillBadge("HDR", color: .blue)
///   PillBadge("Spatial", color: .orange)
struct PillBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Displays a source-name badge (purple pill) for a quality, subtitle, or audio track.
///
/// Shows `sourceName` if present. Renders nothing when sourceName is nil or empty.
///
/// Usage:
///   SourceBadge(sourceName: quality.sourceName)
///   SourceBadge(sourceName: track.sourceName)
struct SourceBadge: View {
    let sourceName: String?

    var body: some View {
        if let sn = sourceName, !sn.isEmpty {
            PillBadge(sn, color: .purple)
        }
    }
}

/// Displays a blue "HDR" badge when `isHDR` is true.
///
/// Usage:
///   HDRBadge(isHDR: quality.isHDR)
struct HDRBadge: View {
    let isHDR: Bool

    var body: some View {
        if isHDR {
            PillBadge("HDR", color: .blue)
        }
    }
}

/// Displays an orange "Spatial" badge when `isSpatial` is true.
///
/// Usage:
///   SpatialAudioBadge(isSpatial: track.isSpatial)
struct SpatialAudioBadge: View {
    let isSpatial: Bool

    var body: some View {
        if isSpatial {
            PillBadge("Spatial", color: .orange)
        }
    }
}
