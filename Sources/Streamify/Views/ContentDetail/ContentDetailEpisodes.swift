import SwiftUI

extension ContentDetailView {
    // MARK: - Episode Section
    var episodeSection: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if hasSeasons {
                seasonPicker

                ForEach(selectedSeasonEpisodes) { episode in
                    episodeRowWithThumbnail(episode: episode)
                }
            } else {
                Text("Episodes")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    episodeRow(episode: episode, index: index)
                }
            }
        }
    }

    // MARK: - Season Picker
    var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seasons")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.top, 8)

            Menu {
                ForEach(seasonNumbers, id: \.self) { seasonNum in
                    Button {
                        selectedSeason = seasonNum
                    } label: {
                        HStack {
                            if let seasonInfo = currentContent.metadata.seasonInfo(for: seasonNum) {
                                Text(seasonInfo.displayTitle)
                            } else {
                                Text("Season \(seasonNum)")
                            }
                            if selectedSeason == seasonNum {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let seasonInfo = currentContent.metadata.seasonInfo(for: selectedSeason) {
                        Text(seasonInfo.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    } else {
                        Text("Season \(selectedSeason)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Spacer()

                    Text("\(selectedSeasonEpisodes.count) episodes")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .streamifyPanel(cornerRadius: 8, materialOpacity: 0)
            }
        }
    }

    // MARK: - Episode Row With Thumbnail
    func episodeRowWithThumbnail(episode: EpisodeInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Thumbnail + action buttons below it
            VStack(spacing: 6) {
                episodeThumbnail(episode: episode)

                // Action buttons under thumbnail
                HStack(spacing: 6) {
                    if hasAnyDownloadedContent(episode) {
                        Button {
                            viewModel.refreshLibrary()
                            removePickerEpisode = episode
                            showRemovePicker = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.callout)
                                .foregroundStyle(.red.opacity(0.8))
                        }
                    }
                    if let activeDownload = getActiveEpisodeDownload(episode) {
                        if activeDownload.status != .queued {
                            Button {
                                downloadManager.pauseDownload(activeDownload)
                            } label: {
                                Image(systemName: "pause.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.yellow)
                            }
                            Button {
                                downloadManager.cancelDownload(activeDownload)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.gray)
                            }
                        } else if let trackDL = getActiveEpisodeTrackDownload(episode) {
                            // Video queued + track downloading — show track buttons
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
                                downloadManager.cancelDownload(activeDownload)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if let pausedDownload = getPausedEpisodeDownload(episode) {
                        Button {
                            downloadManager.resumeDownload(pausedDownload)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.yellow)
                        }
                        Button {
                            downloadManager.cancelDownload(pausedDownload)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.gray)
                        }
                    } else if let trackDL = getActiveEpisodeTrackDownload(episode) {
                        // Track download in progress — show pause + cancel buttons
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
                    } else if (episode.hlsUrl != nil || content.metadata.hlsUrl != nil || sourceContent?.hlsUrl != nil || (resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled || torrentioEnabled))) {
                        Button {
                            downloadEpisode(episode)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    if isEpisodePlayable(episode) {
                        Button {
                            if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
                                playEpisode(at: idx)
                            }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(episode.description)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(5)

                // Compact download status indicators
                episodeDownloadIndicator(episode)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
                    playEpisode(at: idx)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .streamifyPanel(cornerRadius: 10, materialOpacity: 0)
    }

    // MARK: - Episode Thumbnail
    func episodeThumbnail(episode: EpisodeInfo) -> some View {
        let latestContent = currentContent
        let localThumbURL = ContentImportService.episodeThumbnailURL(for: latestContent, episode: episode)
        let remoteThumbURL = episode.thumbnailUrl.flatMap { URL(string: $0) }
        let episodeProgress = WatchingProgressManager.getProgress(for: latestContent.id, seasonIndex: episode.season, episodeIndex: episode.episode)
        let progressPercent = episodeProgress?.progressPercent ?? 0

        return ZStack(alignment: .bottom) {
            Group {
                if let url = localThumbURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            episodeThumbnailPlaceholder(episode: episode)
                        }
                    }
                } else if let url = remoteThumbURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            episodeThumbnailPlaceholder(episode: episode)
                        }
                    }
                } else {
                    episodeThumbnailPlaceholder(episode: episode)
                }
            }
            .frame(width: 120, height: 68)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if progressPercent > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.3))
                            .frame(height: 3)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: geo.size.width * CGFloat(progressPercent), height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    func episodeThumbnailPlaceholder(episode: EpisodeInfo) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(StreamifySurface.panelFill)
            .frame(width: 120, height: 68)
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("E\(episode.episode)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
    }

    // MARK: - Episode Row (Flat List)
    func episodeRow(episode: EpisodeInfo, index: Int?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(episode.episode)")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(episode.description)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(5)

                // Compact download status indicators
                episodeDownloadIndicator(episode)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let idx = index {
                    playEpisode(at: idx)
                } else if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
                    playEpisode(at: idx)
                }
            }

            Spacer()

            if hasAnyDownloadedContent(episode) {
                Button {
                    viewModel.refreshLibrary()
                    removePickerEpisode = episode
                    showRemovePicker = true
                } label: {
                    Image(systemName: "trash")
                        .font(.callout)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            if let activeDownload = getActiveEpisodeDownload(episode) {
                if activeDownload.status != .queued {
                    HStack(spacing: 8) {
                        Button {
                            downloadManager.pauseDownload(activeDownload)
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.yellow)
                        }
                        Button {
                            downloadManager.cancelDownload(activeDownload)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.gray)
                        }
                    }
                } else if let trackDL = getActiveEpisodeTrackDownload(episode) {
                    // Video queued + track downloading — show track buttons
                    HStack(spacing: 8) {
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
                    }
                } else {
                    Button {
                        downloadManager.cancelDownload(activeDownload)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.gray)
                    }
                }
            } else if let pausedDownload = getPausedEpisodeDownload(episode) {
                Button {
                    downloadManager.resumeDownload(pausedDownload)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
                Button {
                    downloadManager.cancelDownload(pausedDownload)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.gray)
                }
            } else if let trackDL = getActiveEpisodeTrackDownload(episode) {
                // Track download in progress — show pause + cancel buttons
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
            } else if (episode.hlsUrl != nil || content.metadata.hlsUrl != nil || sourceContent?.hlsUrl != nil || (resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled || torrentioEnabled))) {
                Button {
                    downloadEpisode(episode)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if isEpisodePlayable(episode) {
                Button {
                    if let idx = index {
                        playEpisode(at: idx)
                    } else if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
                        playEpisode(at: idx)
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10, materialOpacity: 0)
    }

    // MARK: - Episode Download Indicator (shared between episode card layouts)
    @ViewBuilder
    func episodeDownloadIndicator(_ episode: EpisodeInfo) -> some View {
        if let activeDownload = getActiveEpisodeDownload(episode) {
            VStack(alignment: .leading, spacing: 2) {
                if activeDownload.status == .queued {
                    if let trackDL = getActiveEpisodeTrackDownload(episode) {
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
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(formatQueuedText(for: activeDownload))
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        StreamifyDownloadMetadataStrip(download: activeDownload)
                        DownloadProgressBar(progress: 0, color: .orange, height: 3)
                    }
                } else {
                    Text(formatDownloadingText(for: activeDownload))
                        .font(.caption2)
                        .foregroundStyle(.green)

                    StreamifyDownloadMetadataStrip(download: activeDownload)
                    DownloadProgressBar(progress: activeDownload.progress, height: 3)
                }
            }
        } else if let pausedDownload = getPausedEpisodeDownload(episode) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption2)
                    Text("Paused at \(pausedDownload.progressPercent)%")
                        .font(.caption2)
                }
                .foregroundStyle(.yellow)
                StreamifyDownloadMetadataStrip(download: pausedDownload)
            }
        } else if let trackDL = getActiveEpisodeTrackDownload(episode) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trackDL.status == .queued ? formatTrackDownloadText(for: trackDL, queued: true) : formatTrackDownloadText(for: trackDL))
                    .font(.caption2)
                    .foregroundStyle(trackDL.status == .queued ? .orange : .green)
                if trackDL.status == .downloading {
                    DownloadProgressBar(progress: trackDL.progress, height: 3)
                }
            }
        }
    }

    // MARK: - Download Status Checks
    /// Check if episode has ANY downloaded content (video, audio tracks, or subtitles)
    func hasAnyDownloadedContent(_ episode: EpisodeInfo) -> Bool {
        if isEpisodeDownloaded(episode) { return true }
        if !getLocalAudioTracks(for: episode).isEmpty { return true }
        if !getLocalSubtitleTracks(for: episode).isEmpty { return true }
        if !getDownloadedQualities(for: episode).isEmpty { return true }
        return false
    }

    /// Check if episode has ANY downloaded content for movies (video, audio tracks, or subtitles)
    func hasAnyDownloadedMovieContent() -> Bool {
        if hasLocalVideoFile() { return true }
        if !getLocalAudioTracks(for: nil).isEmpty { return true }
        if !getLocalSubtitleTracks(for: nil).isEmpty { return true }
        if !getDownloadedQualities(for: nil).isEmpty { return true }
        return false
    }

    /// Check if movie has a downloaded video file specifically (not just tracks)
    func hasDownloadedMovieVideo() -> Bool {
        if hasLocalVideoFile() { return true }
        if !getDownloadedQualities(for: nil).isEmpty { return true }
        return false
    }

    /// Format queued download status text.
    func formatQueuedText(for download: DownloadItem) -> String {
        "Queued"
    }

    /// Format downloading video text.
    func formatDownloadingText(for download: DownloadItem) -> String {
        "Downloading \(download.progressPercent)%"
    }

    /// Format track download status text
    func formatTrackDownloadText(for trackDL: TrackDownloadItem, queued: Bool = false) -> String {
        let typeLabel = trackDL.trackType == "subtitle" ? "Subtitle" : (trackDL.trackType == "video" ? "Video" : "Audio")
        // Video tracks show quality name, not language
        let detail = trackDL.trackType == "video" ? trackDL.language : ": \(trackDL.language)"
        if queued {
            return "Queued — \(typeLabel) \(detail)"
        }
        return "Downloading \(typeLabel) \(detail) \(Int(trackDL.progress * 100))%"
    }

    func getPausedEpisodeDownload(_ episode: EpisodeInfo) -> DownloadItem? {
        let episodeDownloadId = "\(content.id)_ep\(episode.episode)"
        return downloadManager.downloads.first { download in
            download.contentId == episodeDownloadId && download.seasonIndex == episode.season && download.status == .paused
        }
    }

    func getActiveEpisodeDownload(_ episode: EpisodeInfo) -> DownloadItem? {
        let episodeDownloadId = "\(content.id)_ep\(episode.episode)"
        let matching = downloadManager.downloads.filter { download in
            download.contentId == episodeDownloadId &&
            download.seasonIndex == episode.season &&
            (download.status == .downloading || download.status == .pending || download.status == .queued)
        }
        // Prefer the actively downloading item over queued/pending ones
        // so the episode card shows real progress instead of "Queued"
        return matching.first(where: { $0.status == .downloading })
            ?? matching.first(where: { $0.status == .pending })
            ?? matching.first
    }

    /// Check if any player-initiated track downloads are active for the given episode
    func getActiveEpisodeTrackDownload(_ episode: EpisodeInfo) -> TrackDownloadItem? {
        let matching = downloadManager.trackDownloads.filter { item in
            item.contentId == content.id &&
            item.episodeNumber == episode.episode &&
            item.seasonNumber == episode.season &&
            (item.status == .downloading || item.status == .queued || item.status == .pending)
        }
        // Prefer actively downloading over queued/pending
        return matching.first(where: { $0.status == .downloading })
            ?? matching.first(where: { $0.status == .pending })
            ?? matching.first
    }

    /// Check if any player-initiated track downloads are active for the movie
    func getActiveMovieTrackDownload() -> TrackDownloadItem? {
        let matching = downloadManager.trackDownloads.filter { item in
            item.contentId == content.id &&
            item.seasonNumber == nil &&
            item.episodeNumber == nil &&
            (item.status == .downloading || item.status == .queued || item.status == .pending)
        }
        // Prefer actively downloading over queued/pending
        return matching.first(where: { $0.status == .downloading })
            ?? matching.first(where: { $0.status == .pending })
            ?? matching.first
    }

    func getPausedMovieDownload() -> DownloadItem? {
        return downloadManager.downloads.first { download in
            download.contentId == content.id && download.status == .paused
        }
    }

    func getActiveMovieDownload() -> DownloadItem? {
        let matching = downloadManager.downloads.filter { download in
            download.contentId == content.id &&
            (download.status == .downloading || download.status == .pending || download.status == .queued)
        }
        // Prefer the actively downloading item over queued/pending ones
        // so the movie card shows real progress instead of "Queued"
        return matching.first(where: { $0.status == .downloading })
            ?? matching.first(where: { $0.status == .pending })
            ?? matching.first
    }

    func hasLocalVideoFile() -> Bool {
        let latestContent = currentContent
        guard !latestContent.folderPath.isEmpty else { return false }

        let folderPath = ContentImportService.contentDirectoryURL
            .appendingPathComponent(latestContent.folderPath)

        let hlsPath = folderPath.appendingPathComponent("video.m3u8")
        if FileManager.default.fileExists(atPath: hlsPath.path) {
            return true
        }

        // Check metadata hlsUrl for quality-subfolder downloads (e.g., video_1080p/video.m3u8)
        if let hlsUrl = latestContent.metadata.hlsUrl, !hlsUrl.hasPrefix("http") {
            let localHLS = folderPath.appendingPathComponent(hlsUrl)
            if FileManager.default.fileExists(atPath: localHLS.path) {
                return true
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath.path) {
            for file in files {
                let lowercased = file.lowercased()
                guard lowercased.hasSuffix(".mp4") ||
                        lowercased.hasSuffix(".mov") ||
                        lowercased.hasSuffix(".m4v") ||
                        lowercased.hasSuffix(".mkv") ||
                        lowercased.hasSuffix(".webm") else {
                    continue
                }
                return true
            }
        }

        return false
    }

    func hasRemoteVideoUrl() -> Bool {
        if content.metadata.hlsUrl != nil || content.metadata.file != nil {
            return true
        }
        if content.metadata.remoteHlsUrl != nil || content.metadata.remoteFileUrl != nil {
            return true
        }
        if ContentImportService.remoteHlsURL(for: content) != nil {
            return true
        }
        if sourceContent?.hlsUrl != nil || sourceContent?.fileUrl != nil {
            return true
        }
        // Streaming providers: playable if we have a TMDB ID and any provider is enabled
        if resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled || torrentioEnabled) {
            return true
        }
        return false
    }

    func hasRemotePlaybackVideoUrl() -> Bool {
        if content.metadata.hlsUrl != nil || content.metadata.file != nil {
            return true
        }
        if content.metadata.remoteHlsUrl != nil || content.metadata.remoteFileUrl != nil {
            return true
        }
        if ContentImportService.remoteHlsURL(for: content) != nil {
            return true
        }
        if sourceContent?.hlsUrl != nil || sourceContent?.fileUrl != nil {
            return true
        }
        return resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled)
    }

    func hasSeriesPlayableUrl() -> Bool {
        // Check if any episode has a stream URL
        if episodes.contains(where: { $0.hlsUrl != nil || $0.file != nil }) {
            return true
        }
        // Check content-level stream URL
        if content.metadata.hlsUrl != nil || content.metadata.file != nil || ContentImportService.remoteHlsURL(for: content) != nil {
            return true
        }
        if sourceContent?.hlsUrl != nil || sourceContent?.fileUrl != nil {
            return true
        }
        // Check if any episode is downloaded locally
        if episodes.contains(where: { isEpisodeDownloaded($0) }) {
            return true
        }
        // Streaming providers: playable if we have a TMDB ID and an automatic playback provider is enabled
        if resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled) {
            return true
        }
        return false
    }

    func isEpisodePlayable(_ episode: EpisodeInfo) -> Bool {
        isEpisodeDownloaded(episode) ||
            episode.hlsUrl != nil ||
            episode.file != nil ||
            content.metadata.hlsUrl != nil ||
            content.metadata.file != nil ||
            sourceContent?.hlsUrl != nil ||
            sourceContent?.fileUrl != nil ||
            (resolveTmdbId() != nil && (vidLinkEnabled || movies111Enabled))
    }

    /// Resolve TMDB ID from metadata or source content
    func resolveTmdbId() -> Int? {
        PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent)
    }

    /// Fetch TMDB seasons/episodes for series that have a tmdbId but no existing episodes
    func fetchTMDBSeasonsIfNeeded() {
        let current = currentContent
        guard current.metadata.type == .series,
              current.metadata.allEpisodes.isEmpty,
              (current.metadata.seasons ?? []).isEmpty,
              let tmdbId = resolveTmdbId(),
              TMDBService.isConfigured,
              !isFetchingTMDBDetails else { return }

        isFetchingTMDBDetails = true
        Task {
            guard let detail = await TMDBService.fetchTVShowDetail(tmdbId: tmdbId) else {
                await MainActor.run { isFetchingTMDBDetails = false }
                return
            }

            let validSeasons = detail.seasons?.filter { $0.seasonNumber > 0 } ?? []
            var enrichedSeasons: [SeasonInfo] = []

            for season in validSeasons {
                if let seasonDetail = await TMDBService.fetchSeasonDetail(tmdbId: tmdbId, seasonNumber: season.seasonNumber) {
                    let episodes: [EpisodeInfo] = (seasonDetail.episodes ?? []).map { ep in
                        EpisodeInfo(
                            season: season.seasonNumber,
                            episode: ep.episodeNumber,
                            title: ep.name ?? "",
                            description: ep.overview ?? "",
                            thumbnailUrl: ep.thumbnailURL?.absoluteString
                        )
                    }
                    enrichedSeasons.append(SeasonInfo(
                        season: season.seasonNumber,
                        title: TMDBService.normalizedSeasonTitle(
                            for: season,
                            showTitle: detail.name,
                            allSeasons: validSeasons
                        ),
                        thumbnailUrl: season.posterPath.map { "\(TMDBService.imageBaseURL)/w342\($0)" },
                        episodes: episodes
                    ))
                }
            }

            await MainActor.run {
                if !enrichedSeasons.isEmpty {
                    tmdbFetchedSeasons = enrichedSeasons
                    // Default to season 1 if available
                    if let firstSeason = enrichedSeasons.first?.season {
                        selectedSeason = firstSeason
                    }
                    // Persist TMDB-fetched seasons to library metadata so they survive
                    // across views (e.g. Continue Watching can find episodes)
                    persistTMDBSeasons(enrichedSeasons)
                }
                isFetchingTMDBDetails = false
            }
        }
    }

    /// Save TMDB-fetched seasons back to library metadata on disk + in-memory viewModel.
    func persistTMDBSeasons(_ seasons: [SeasonInfo]) {
        let current = currentContent
        // Only persist if content is in library and currently has no seasons
        guard isInLibrary,
              current.metadata.allEpisodes.isEmpty,
              (current.metadata.seasons ?? []).isEmpty else { return }

        let updatedMetadata = current.metadata.copying(seasons: .some(seasons))
        let updatedContent = SavedContent(
            id: current.id,
            metadata: updatedMetadata,
            folderPath: current.folderPath,
            dateAdded: current.dateAdded
        )

        // Persist to disk
        ContentImportService.saveMetadata(updatedMetadata, to: current.folderPath)

        // Update in-memory library
        if let idx = viewModel.library.firstIndex(where: { $0.id == current.id }) {
            viewModel.library[idx] = updatedContent
        }
    }

    func isEpisodeDownloaded(_ episode: EpisodeInfo) -> Bool {
        if let localFile = episode.localFile {
            let episodeFolder = "\(currentContent.folderPath)/\(DownloadManager.episodeSubfolder(season: episode.season, episode: episode.episode))"
            let episodeSpecificPath = ContentImportService.contentDirectoryURL
                .appendingPathComponent(episodeFolder)
            let localFilePath = episodeSpecificPath.appendingPathComponent(localFile)

            if FileManager.default.fileExists(atPath: localFilePath.path) {
                return true
            }
        }

        // Check for downloaded video qualities in metadata
        if let ep = currentContent.metadata.allEpisodes.first(where: { $0.season == episode.season && $0.episode == episode.episode }),
           let qualities = ep.downloadedVideoQualities, !qualities.isEmpty {
            return true
        }

        return false
    }
}
