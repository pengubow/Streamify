import SwiftUI

struct DownloadSubtitlePickerView: View {
    let tracks: [SubtitleTrack]
    let initialSelected: Set<String>
    let onCancel: () -> Void
    let onNext: (Set<String>) -> Void

    var body: some View {
        DownloadTrackPickerView(
            title: "Subtitles",
            description: "Select subtitles to download",
            tracks: tracks,
            initialSelected: initialSelected,
            onCancel: onCancel,
            onNext: onNext
        )
    }
}

struct DownloadAudioPickerView: View {
    let tracks: [AudioTrack]
    let initialSelected: Set<String>
    let onCancel: () -> Void
    let onNext: (Set<String>) -> Void

    var body: some View {
        DownloadTrackPickerView(
            title: "Audio Tracks",
            description: "Select audio tracks to download",
            tracks: tracks,
            initialSelected: initialSelected,
            onCancel: onCancel,
            onNext: onNext
        )
    }
}

private protocol DownloadPickerTrack {
    var trackId: String { get }
    var displayName: String { get }
    var languageId: String { get }
    var sourceName: String? { get }
    var showsSpatialBadge: Bool { get }
}

extension SubtitleTrack: DownloadPickerTrack {
    var showsSpatialBadge: Bool { false }
}

extension AudioTrack: DownloadPickerTrack {
    var showsSpatialBadge: Bool { isSpatial }
}

private struct DownloadTrackPickerView<Track: DownloadPickerTrack>: View {
    let title: String
    let description: String
    let tracks: [Track]
    let initialSelected: Set<String>
    let onCancel: () -> Void
    let onNext: (Set<String>) -> Void

    @State private var selected: Set<String> = []
    @State private var expandedGroup: String?

    var body: some View {
        StreamifyPickerShell(
            title: title,
            leadingTitle: "Cancel",
            trailingTitle: "Next",
            leadingAction: onCancel,
            trailingAction: { onNext(selected) }
        ) {
            Text(description)
                .streamifyPickerDescription()

            let sortedTracks = tracks.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let groupedTracks = Dictionary(grouping: sortedTracks, by: \.displayName)
            let sortedNames = groupedTracks.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }

            StreamifyPickerBatchedForEach(sortedNames, id: \.self) { displayName in
                if let groupTracks = groupedTracks[displayName] {
                    if groupTracks.count == 1 {
                        trackRow(track: groupTracks[0])
                    } else {
                        trackGroup(displayName: displayName, tracks: groupTracks)
                    }
                }
            }
        }
        .onAppear {
            selected = initialSelected
        }
    }

    private func trackGroup(displayName: String, tracks: [Track]) -> some View {
        let isExpanded = expandedGroup == displayName
        let selectedCount = tracks.filter { selected.contains($0.trackId) }.count

        return Group {
            Button {
                StreamifyPickerMotion.toggle($expandedGroup, value: displayName)
            } label: {
                HStack {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    if tracks.contains(where: \.showsSpatialBadge) {
                        SpatialAudioBadge(isSpatial: true)
                    }
                    Spacer()
                    if selectedCount > 0 {
                        Text("\(selectedCount) selected")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .streamifyPickerButtonLabel()
            }
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
            .streamifyPickerRow(selected: selectedCount > 0 || isExpanded)

            StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                StreamifyPickerBatchedForEach(tracks, id: \.trackId) { track in
                    trackRow(track: track, indented: true)
                }
            }
        }
    }

    private func trackRow(track: Track, indented: Bool = false) -> some View {
        Button {
            if selected.contains(track.trackId) {
                selected.remove(track.trackId)
            } else {
                selected.insert(track.trackId)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(track.displayName)
                            .foregroundStyle(.primary)
                        SpatialAudioBadge(isSpatial: track.showsSpatialBadge)
                        SourceBadge(sourceName: track.sourceName)
                    }
                    Text(track.languageId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .font(.body.weight(.semibold))
                    .opacity(selected.contains(track.trackId) ? 1 : 0)
                    .frame(width: 24)
            }
            .streamifyPickerButtonLabel()
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
        .streamifyPickerRow(selected: selected.contains(track.trackId))
        .streamifyPickerExpandedItem(indented: indented)
    }
}
