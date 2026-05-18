import SwiftUI

// MARK: - Remove Selection Model

struct RemoveSelection {
    var removeVideo: Bool = false
    var removeQualityIds: Set<String> = []
    var audioTrackIds: Set<String> = []
    var subtitleTrackIds: Set<String> = []
	    
    var isEmpty: Bool {
        !removeVideo && removeQualityIds.isEmpty && audioTrackIds.isEmpty && subtitleTrackIds.isEmpty
    }
}

// MARK: - Remove Download Picker

struct RemoveDownloadPickerView: View {
    let episode: EpisodeInfo?
    let hasVideo: Bool
    let qualityName: String?
    let downloadedQualities: [DownloadedVideoQuality]
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]
    let onRemove: (RemoveSelection) -> Void
    let onCancel: (() -> Void)?

    init(
        episode: EpisodeInfo?,
        hasVideo: Bool,
        qualityName: String?,
        downloadedQualities: [DownloadedVideoQuality],
        audioTracks: [AudioTrack],
        subtitleTracks: [SubtitleTrack],
        onRemove: @escaping (RemoveSelection) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.episode = episode
        self.hasVideo = hasVideo
        self.qualityName = qualityName
        self.downloadedQualities = downloadedQualities
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    @State var selection = RemoveSelection()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        StreamifyPickerShell(
            title: "Remove Downloads",
            leadingTitle: "Cancel",
            trailingTitle: "Remove",
            leadingAction: {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            },
            trailingAction: {
                guard !selection.isEmpty else { return }
                onRemove(selection)
            }
        ) {
            if hasVideo {
                Text("Video")
                    .streamifyPickerSectionTitle()

                if downloadedQualities.count > 1 {
                    let sortedQualities = downloadedQualities.sorted { q1, q2 in
                        if q1.bandwidth != q2.bandwidth { return q1.bandwidth > q2.bandwidth }
                        return (q1.sourceName ?? "") < (q2.sourceName ?? "")
                    }

                    Button {
                        if selection.removeVideo {
                            selection.removeVideo = false
                            selection.removeQualityIds.removeAll()
                        } else {
                            selection.removeVideo = true
                            selection.removeQualityIds = Set(downloadedQualities.map { $0.qualityId })
                        }
                    } label: {
                        HStack {
                            Text("All Video Qualities")
                                .foregroundStyle(.primary)
                            Spacer()
                            removeCheckmark(selected: selection.removeVideo)
                        }
                        .streamifyPickerButtonLabel()
                    }
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .streamifyPickerRow(selected: selection.removeVideo, destructive: true)

                    StreamifyPickerBatchedForEach(sortedQualities, id: \.qualityId) { dq in
                        Button {
                            if selection.removeQualityIds.contains(dq.qualityId) {
                                selection.removeQualityIds.remove(dq.qualityId)
                                selection.removeVideo = false
                            } else {
                                selection.removeQualityIds.insert(dq.qualityId)
                                if selection.removeQualityIds.count == downloadedQualities.count {
                                    selection.removeVideo = true
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(dq.name)
                                            .foregroundStyle(.primary)
                                        if let sn = dq.sourceName {
                                            SourceBadge(sourceName: sn)
                                        }
                                        if dq.isHDR {
                                            HDRBadge(isHDR: true)
                                        }
                                    }
                                    if let res = dq.resolution {
                                        Text(res)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                removeCheckmark(selected: selection.removeQualityIds.contains(dq.qualityId))
                            }
                            .streamifyPickerButtonLabel()
                        }
                        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                        .streamifyPickerRow(selected: selection.removeQualityIds.contains(dq.qualityId), destructive: true)
                        .streamifyPickerExpandedItem(indented: true)
                    }
                } else {
                    Button {
                        selection.removeVideo.toggle()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("Video")
                                        .foregroundStyle(.primary)
                                    if let sn = downloadedQualities.first?.sourceName {
                                        SourceBadge(sourceName: sn)
                                    }
                                }
                                if let quality = qualityName ?? downloadedQualities.first?.name, !quality.isEmpty {
                                    Text(quality)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            removeCheckmark(selected: selection.removeVideo)
                        }
                        .streamifyPickerButtonLabel()
                    }
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .streamifyPickerRow(selected: selection.removeVideo, destructive: true)
                }
            }

            if !subtitleTracks.isEmpty {
                Text("Subtitles")
                    .streamifyPickerSectionTitle()

                let sortedSubs = subtitleTracks.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                StreamifyPickerBatchedForEach(sortedSubs, id: \.trackId) { track in
                    Button {
                        if selection.subtitleTrackIds.contains(track.trackId) {
                            selection.subtitleTrackIds.remove(track.trackId)
                        } else {
                            selection.subtitleTrackIds.insert(track.trackId)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(track.displayName)
                                        .foregroundStyle(.primary)
                                    if let sn = track.sourceName {
                                        SourceBadge(sourceName: sn)
                                    }
                                }
                                Text(track.languageId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            removeCheckmark(selected: selection.subtitleTrackIds.contains(track.trackId))
                        }
                        .streamifyPickerButtonLabel()
                    }
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .streamifyPickerRow(selected: selection.subtitleTrackIds.contains(track.trackId), destructive: true)
                }
            }

            if !audioTracks.isEmpty {
                Text("Audio Tracks")
                    .streamifyPickerSectionTitle()

                let sortedAudio = audioTracks.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                StreamifyPickerBatchedForEach(sortedAudio, id: \.trackId) { track in
                    Button {
                        if selection.audioTrackIds.contains(track.trackId) {
                            selection.audioTrackIds.remove(track.trackId)
                        } else {
                            selection.audioTrackIds.insert(track.trackId)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(track.displayName)
                                        .foregroundStyle(.primary)
                                    if track.isSpatial {
                                        SpatialAudioBadge(isSpatial: true)
                                    }
                                    if let sn = track.sourceName {
                                        SourceBadge(sourceName: sn)
                                    }
                                }
                                Text(track.languageId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            removeCheckmark(selected: selection.audioTrackIds.contains(track.trackId))
                        }
                        .streamifyPickerButtonLabel()
                    }
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .streamifyPickerRow(selected: selection.audioTrackIds.contains(track.trackId), destructive: true)
                }
            }
        }
    }

    @ViewBuilder
    private func removeCheckmark(selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .foregroundStyle(.red)
            .font(.body.weight(.semibold))
            .opacity(selected ? 1 : 0)
            .frame(width: 24)
    }
}
