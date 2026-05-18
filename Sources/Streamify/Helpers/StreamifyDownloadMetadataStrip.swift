import SwiftUI

struct StreamifyDownloadMetadataStrip: View {
    private let chips: [StreamifyDownloadMetadataChip]

    init(download: DownloadItem) {
        self.chips = Self.makeChips(
            qualityName: download.qualityName,
            fallbackQualityName: download.quality == .auto ? nil : download.quality.rawValue,
            resolution: download.selectedResolution,
            videoRange: download.selectedVideoRange,
            isHDR: nil,
            sourceName: download.sourceName,
            bandwidth: download.selectedBandwidth
        )
    }

    init(
        downloadedQuality: DownloadedVideoQuality?,
        fallbackQualityName: String? = nil
    ) {
        self.chips = Self.makeChips(
            qualityName: downloadedQuality?.name ?? fallbackQualityName,
            fallbackQualityName: nil,
            resolution: downloadedQuality?.resolution,
            videoRange: nil,
            isHDR: downloadedQuality?.isHDR,
            sourceName: downloadedQuality?.sourceName,
            bandwidth: downloadedQuality?.bandwidth
        )
    }

    init(
        qualityName: String?,
        resolution: String? = nil,
        isHDR: Bool? = nil,
        sourceName: String? = nil,
        bandwidth: Double? = nil
    ) {
        self.chips = Self.makeChips(
            qualityName: qualityName,
            fallbackQualityName: nil,
            resolution: resolution,
            videoRange: nil,
            isHDR: isHDR,
            sourceName: sourceName,
            bandwidth: bandwidth
        )
    }

    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Text(chip.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(chip.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(chip.tint.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .frame(height: 22)
        }
    }

    private static func makeChips(
        qualityName: String?,
        fallbackQualityName: String?,
        resolution: String?,
        videoRange: String?,
        isHDR: Bool?,
        sourceName: String?,
        bandwidth: Double?
    ) -> [StreamifyDownloadMetadataChip] {
        var items: [StreamifyDownloadMetadataChip] = []

        if let quality = nonEmpty(qualityName) ?? nonEmpty(fallbackQualityName) {
            items.append(.init(label: quality, tint: .blue))
        }

        if let resolution = resolutionLabel(from: resolution),
           !items.contains(where: { $0.label.localizedCaseInsensitiveContains(resolution) }) {
            items.append(.init(label: resolution, tint: .cyan))
        }

        if let range = videoRangeLabel(from: videoRange, isHDR: isHDR) {
            items.append(.init(label: range, tint: range == "SDR" ? .gray : .blue))
        }

        if let source = nonEmpty(sourceName) {
            items.append(.init(label: source, tint: .orange))
        }

        if let bandwidth, bandwidth > 0, isFileSizeValue(sourceName: sourceName) {
            items.append(.init(label: fileSizeLabel(byteCount: bandwidth), tint: .purple))
        } else if let bandwidth, bandwidth > 0 {
            let mbps = bandwidth / 1_000_000
            items.append(.init(label: String(format: "%.1f Mbps", mbps), tint: .purple))
        }

        return items
    }

    private static func resolutionLabel(from value: String?) -> String? {
        guard let resolution = nonEmpty(value) else { return nil }
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let height = parts.last else { return resolution }
        return "\(height)p"
    }

    private static func videoRangeLabel(from value: String?, isHDR: Bool?) -> String? {
        if let isHDR {
            return isHDR ? "HDR" : "SDR"
        }

        guard let range = nonEmpty(value)?.uppercased() else { return nil }
        switch range {
        case "PQ": return "HDR10"
        case "HLG": return "HLG"
        case "HDR": return "HDR"
        case "SDR": return "SDR"
        default: return range
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isFileSizeValue(sourceName: String?) -> Bool {
        nonEmpty(sourceName)?.localizedCaseInsensitiveContains("Torrentio") == true
    }

    private static func fileSizeLabel(byteCount: Double) -> String {
        let gigabytes = byteCount / 1_000_000_000
        if gigabytes < 1 {
            return String(format: "%.2f GB", gigabytes)
        }
        return String(format: gigabytes >= 10 ? "%.0f GB" : "%.1f GB", gigabytes)
    }
}

private struct StreamifyDownloadMetadataChip: Identifiable {
    let label: String
    let tint: Color

    var id: String { label }
}
