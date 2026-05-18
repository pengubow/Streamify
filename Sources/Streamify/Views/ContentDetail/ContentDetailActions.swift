import SwiftUI

extension ContentDetailView {
    // MARK: - Movie Action Buttons
    var movieActionButtons: some View {
        VStack(spacing: 12) {
            // Play/Continue button - only show if there's a playable URL
            let hasProgress = savedProgress != nil && (savedProgress?.timestamp ?? 0) > 0

            if hasLocalVideoFile() || hasRemotePlaybackVideoUrl() {
                Button {
                    playContent()
                } label: {
                    HStack(spacing: 8) {
                        if isAddingToLibrary {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(hasProgress ? "Continue" : "Play")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isAddingToLibrary)
            }

            // Download button with states
            let hasLocalContent = !currentContent.folderPath.isEmpty && hasAnyDownloadedMovieContent()
            let hasLocalVideo = hasDownloadedMovieVideo()

            if hasLocalContent {
                VStack(alignment: .center, spacing: 10) {
                    if hasLocalVideo {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Downloaded")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if let activeDownload = getActiveMovieDownload() {
                        let trackDL = getActiveMovieTrackDownload()
                        if activeDownload.status == .queued, let trackDL = trackDL {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trackDL.status == .queued ? formatTrackDownloadText(for: trackDL, queued: true) : formatTrackDownloadText(for: trackDL))
                                        .font(.caption2)
                                        .foregroundStyle(trackDL.status == .queued ? .orange : .green)
                                    if trackDL.status == .downloading {
                                        DownloadProgressBar(progress: trackDL.progress, height: 3)
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                            .font(.caption2)
                                        Text("Video \(formatQueuedText(for: activeDownload))")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(.orange)
                                    StreamifyDownloadMetadataStrip(download: activeDownload)
                                }
                                .layoutPriority(1)

                                Spacer(minLength: 0)

                                if trackDL.status == .downloading {
                                    Button {
                                        downloadManager.pauseTrackDownload(id: trackDL.id)
                                    } label: {
                                        Image(systemName: "pause.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                    }
                                }
                                Button {
                                    downloadManager.cancelTrackDownload(id: trackDL.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if activeDownload.status == .queued {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(formatQueuedText(for: activeDownload))
                                    .font(.caption2)
                                Spacer()
                                Button {
                                    cancelMovieDownload()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            StreamifyDownloadMetadataStrip(download: activeDownload)
                        } else {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(formatDownloadingText(for: activeDownload))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                    StreamifyDownloadMetadataStrip(download: activeDownload)
                                    DownloadProgressBar(progress: activeDownload.progress, height: 3)
                                }
                                .layoutPriority(1)

                                Spacer(minLength: 0)

                                Button {
                                    downloadManager.pauseDownload(activeDownload)
                                } label: {
                                    Image(systemName: "pause.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                }
                                Button {
                                    cancelMovieDownload()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let trackDL = getActiveMovieTrackDownload() {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trackDL.status == .queued ? formatTrackDownloadText(for: trackDL, queued: true) : formatTrackDownloadText(for: trackDL))
                                    .font(.caption2)
                                    .foregroundStyle(trackDL.status == .queued ? .orange : .green)
                                if trackDL.status == .downloading {
                                    DownloadProgressBar(progress: trackDL.progress, height: 3)
                                }
                            }
                            .layoutPriority(1)

                            Spacer(minLength: 0)

                            if trackDL.status == .downloading {
                                Button {
                                    downloadManager.pauseTrackDownload(id: trackDL.id)
                                } label: {
                                    Image(systemName: "pause.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                }
                            }
                            Button {
                                downloadManager.cancelTrackDownload(id: trackDL.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        if hasRemoteVideoUrl() {
                            Button {
                                downloadMovie()
                            } label: {
                                Label("Download More", systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }

                        Button {
                            viewModel.refreshLibrary()
                            removePickerEpisode = nil
                            showRemovePicker = true
                        } label: {
                            Label("Manage", systemImage: "trash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
                .background((hasLocalVideo ? Color.green : Color.blue).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let pausedDownload = getPausedMovieDownload() {
                // Paused download - show continue + cancel buttons
                HStack(spacing: 12) {
                    Button {
                        downloadManager.resumeDownload(pausedDownload)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                            Text("Continue")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.yellow.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        cancelMovieDownload()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Cancel")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.gray)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Paused status text
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                    Text("Paused at \(pausedDownload.progressPercent)%")
                        .font(.caption)
                }
                .foregroundStyle(.yellow)

                StreamifyDownloadMetadataStrip(download: pausedDownload)
            } else if let activeDownload = getActiveMovieDownload() {
                if activeDownload.status == .queued {
                    // Video queued — check if a track is actively downloading
                    let trackDL = getActiveMovieTrackDownload()
                    VStack(alignment: .leading, spacing: 6) {
                        if let trackDL = trackDL {
                            // Show the track download as the primary indicator
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trackDL.status == .queued ? formatTrackDownloadText(for: trackDL, queued: true) : formatTrackDownloadText(for: trackDL))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(trackDL.status == .queued ? .orange : .green)
                                if trackDL.status == .downloading {
                                    DownloadProgressBar(progress: trackDL.progress, height: 3)
                                }
                            }
                        }

                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                    Text("Video \(formatQueuedText(for: activeDownload))")
                                        .font(trackDL != nil ? .caption2 : .subheadline.weight(.semibold))
                                }
                                .foregroundStyle(.orange)

                                StreamifyDownloadMetadataStrip(download: activeDownload)

                                if trackDL == nil {
                                    DownloadProgressBar(progress: 0, color: .orange, height: 3)
                                }
                            }
                            .layoutPriority(1)

                            Spacer(minLength: 0)

                            if let trackDL {
                                if trackDL.status == .downloading {
                                    Button {
                                        downloadManager.pauseTrackDownload(id: trackDL.id)
                                    } label: {
                                        Image(systemName: "pause.circle.fill")
                                            .font(.callout)
                                            .foregroundStyle(.yellow)
                                    }
                                }
                                Button {
                                    downloadManager.cancelTrackDownload(id: trackDL.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.gray)
                                }
                            } else {
                                Button {
                                    cancelMovieDownload()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.gray)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    // Video actively downloading — show progress bar + buttons
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatDownloadingText(for: activeDownload))
                                .font(.caption2)
                                .foregroundStyle(.green)

                            StreamifyDownloadMetadataStrip(download: activeDownload)

                            DownloadProgressBar(progress: activeDownload.progress, height: 3)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 0)

                        Button {
                            downloadManager.pauseDownload(activeDownload)
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.yellow)
                        }

                        Button {
                            cancelMovieDownload()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.gray)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else if let trackDL = getActiveMovieTrackDownload() {
                // Track download in progress (from player or download flow)
                VStack(spacing: 4) {
                    HStack {
                        Text(trackDL.status == .queued ? formatTrackDownloadText(for: trackDL, queued: true) : formatTrackDownloadText(for: trackDL))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(trackDL.status == .queued ? .orange : .green)
                        Spacer()
                        if trackDL.status == .downloading {
                            Button {
                                downloadManager.pauseTrackDownload(id: trackDL.id)
                            } label: {
                                Image(systemName: "pause.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                        Button {
                            downloadManager.cancelTrackDownload(id: trackDL.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.gray)
                        }
                    }
                    if trackDL.status == .downloading {
                        DownloadProgressBar(progress: trackDL.progress)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background((trackDL.status == .queued ? Color.orange : Color.green).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if hasRemoteVideoUrl() {
                // Download button
                Button {
                    downloadMovie()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Series Action Buttons
    var seriesActionButtons: some View {
        VStack(spacing: 12) {
            let hasProgress = savedProgress != nil && (savedProgress?.timestamp ?? 0) > 0

            if hasSeriesPlayableUrl() {
                Button {
                    if let progress = savedProgress, progress.timestamp > 0 {
                        if let epNumber = progress.episodeIndex, let seasonNum = progress.seasonIndex {
                            if let epIndex = episodes.firstIndex(where: { $0.season == seasonNum && $0.episode == epNumber }) {
                                playEpisode(at: epIndex)
                            } else {
                                playEpisode(at: 0)
                            }
                        } else if let epNumber = progress.episodeIndex {
                            if let epIndex = episodes.firstIndex(where: { $0.episode == epNumber }) {
                                playEpisode(at: epIndex)
                            } else {
                                playEpisode(at: 0)
                            }
                        } else {
                            playEpisode(at: 0)
                        }
                    } else {
                        playEpisode(at: 0)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isAddingToLibrary {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(hasProgress ? "Continue" : "Play")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isAddingToLibrary)
            }
        }
    }

    // MARK: - Quality Picker Sheet
    func downloadSourceRank(_ sourceName: String?) -> Int {
        StreamifySourceGrouping.rank(sourceName)
    }

    func sortedDownloadQualityNames(for grouped: [String: [MultiSourceQuality]]) -> [String] {
        grouped.keys.sorted { key1, key2 in
            let items1 = grouped[key1] ?? []
            let items2 = grouped[key2] ?? []
            let hdr1 = items1.contains { $0.isHDR }
            let hdr2 = items2.contains { $0.isHDR }
            if hdr1 != hdr2 { return hdr1 }
            let bw1 = items1.map(\.bandwidth).max() ?? 0
            let bw2 = items2.map(\.bandwidth).max() ?? 0
            if bw1 != bw2 { return bw1 > bw2 }
            return key1.localizedCaseInsensitiveCompare(key2) == .orderedAscending
        }
    }

    var qualityPickerSheet: some View {
        StreamifyPickerShell(
            title: "Download Quality",
            leadingTitle: "Cancel",
            trailingTitle: "Download",
            leadingAction: {
                showQualityPicker = false
                selectedEpisodeForDownload = nil
            },
            trailingAction: {
                let selected = filteredMultiSourceQualities.filter { selectedDownloadQualities.contains($0.id) }
                let episode = selectedEpisodeForDownload
                showQualityPicker = false
                selectedEpisodeForDownload = nil
                Task {
                    await MainActor.run {
                        downloadManager.beginTrackSetup()
                    }
                    for quality in selected {
                        await addQueuedVideoDownload(quality, episode: episode)
                    }
                    await startSelectedTrackDownloads(episode: episode)
                    await MainActor.run {
                        downloadManager.endTrackSetup()
                        downloadManager.triggerProcessQueue()
                    }
                }
            }
        ) {
                if filteredMultiSourceQualities.isEmpty {
                    Text("No quality options found")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    Text("Select qualities to download")
                        .streamifyPickerDescription()
                    let sorted = filteredMultiSourceQualities.sorted {
                        if $0.isHDR != $1.isHDR { return $0.isHDR }
                        let r0 = downloadSourceRank($0.sourceName)
                        let r1 = downloadSourceRank($1.sourceName)
                        if r0 != r1 { return r0 < r1 }
                        if $0.bandwidth != $1.bandwidth { return $0.bandwidth > $1.bandwidth }
                        return ($0.sourceName ?? "") < ($1.sourceName ?? "")
                    }
                        let grouped = Dictionary(grouping: sorted, by: { $0.name })
                        let sortedKeys = sortedDownloadQualityNames(for: grouped)

                        StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { qualityName in
                            let qualities = grouped[qualityName] ?? []
                            if qualities.count == 1 {
                                // Single source — show directly
                                downloadQualityRow(quality: qualities[0])
                            } else {
                                // Multi-source — show expandable group
                                let isExpanded = expandedDownloadQualityGroup == qualityName
                                let selectedCount = qualities.filter { selectedDownloadQualities.contains($0.id) }.count
                                Button {
                                    StreamifyPickerMotion.toggle($expandedDownloadQualityGroup, value: qualityName)
                                } label: {
                                    HStack {
                                        Text(qualityName)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        if let res = qualities.first?.resolution {
                                            Text(res)
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                        if qualities.first?.isHDR == true {
                                            HDRBadge(isHDR: true)
                                        }
                                        if selectedCount > 0 {
                                            Text("\(selectedCount)")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.white.opacity(0.14))
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                        Spacer()
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .streamifyPickerButtonLabel()
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                                .streamifyPickerRow(selected: selectedCount > 0 || isExpanded)

                                StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                    StreamifyPickerBatchedForEach(qualities, id: \.id) { quality in
                                        downloadQualityRow(quality: quality, indented: true)
                                    }
                                }
                            }
                        }
                }
        }
    }

    /// Qualities from multiSourceQualities with already-downloaded ones filtered out
    var filteredMultiSourceQualities: [MultiSourceQuality] {
        // Use disk-based check to avoid stale library cache
        let downloadedQualities = getDownloadedQualitiesFromDisk(for: selectedEpisodeForDownload)
        return multiSourceQualities.filter { quality in
            !downloadedQualities.contains { downloadQuality($0, matches: quality) }
        }
    }

    func downloadQuality(_ downloaded: DownloadedVideoQuality, matches quality: MultiSourceQuality) -> Bool {
        if let sourceUrl = quality.sourceUrls.first, downloaded.sourceUrl == sourceUrl {
            return true
        }

        // Legacy metadata did not store sourceUrl. Keep the fallback for normal HLS
        // sources, but never collapse Torrentio releases by name/source alone.
        guard downloaded.sourceUrl == nil, quality.sourceName != "Torrentio" else { return false }
        return downloaded.name == quality.name &&
            downloaded.sourceName == quality.sourceName &&
            downloaded.resolution == quality.resolution
    }

    @ViewBuilder
    func downloadQualityRow(quality: MultiSourceQuality, indented: Bool = false) -> some View {
        Button {
            if selectedDownloadQualities.contains(quality.id) {
                selectedDownloadQualities.remove(quality.id)
            } else {
                selectedDownloadQualities.insert(quality.id)
            }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(quality.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let res = quality.resolution {
                            Text(res)
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }

                        if quality.isHDR {
                            HDRBadge(isHDR: true)
                        }

                        SourceBadge(sourceName: quality.sourceName)
                    }

                    if let detail = quality.displayDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.gray)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let frameRate = quality.frameRate {
                        Text("\(frameRate) fps")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
                .layoutPriority(1)
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .font(.body.weight(.semibold))
                    .opacity(selectedDownloadQualities.contains(quality.id) ? 1 : 0)
                    .frame(width: 24)
            }
            .streamifyPickerButtonLabel()
            .padding(.vertical, 4)
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
        .streamifyPickerRow(selected: selectedDownloadQualities.contains(quality.id))
        .streamifyPickerExpandedItem(indented: indented)
    }

    // MARK: - Download Actions
    func cancelMovieDownload() {
        if let download = downloadManager.downloads.first(where: { $0.contentId == content.id && ($0.status == .downloading || $0.status == .pending || $0.status == .queued || $0.status == .paused) }) {
            downloadManager.cancelDownload(download)
        }
    }
}
