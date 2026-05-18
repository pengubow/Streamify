import SwiftUI

extension ContentDetailView {
    // MARK: - Resolve tracks from all available sources (metadata, sourceContent, raw sources)

    func resolveAllSubtitleTracks(for episode: EpisodeInfo? = nil) -> [SubtitleTrack] {
        // Check sourceContent FIRST (always available from Browse, most reliable)
        if let src = sourceContent {
            // Try to find the source name for this content
            let srcName = resolveSourceName(for: src.id)
            if let ep = episode {
                if let epSubs = src.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles, !epSubs.isEmpty {
                    StreamifyLogger.log("resolveAllSubtitleTracks: Found \(epSubs.count) from sourceContent episode S\(ep.season)E\(ep.episode)")
                    return tagSubtitlesWithSource(epSubs, sourceName: srcName)
                }
            }
            if let subs = src.subtitles, !subs.isEmpty {
                StreamifyLogger.log("resolveAllSubtitleTracks: Found \(subs.count) from sourceContent content-level")
                return tagSubtitlesWithSource(subs, sourceName: srcName)
            }
        }

        // Check library metadata
        let current = currentContent
        if let ep = episode {
            if let epSubs = current.metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles, !epSubs.isEmpty {
                StreamifyLogger.log("resolveAllSubtitleTracks: Found \(epSubs.count) from library metadata episode")
                return epSubs
            }
        }
        if let subs = current.metadata.subtitles, !subs.isEmpty {
            StreamifyLogger.log("resolveAllSubtitleTracks: Found \(subs.count) from library metadata content-level")
            return subs
        }

        // Ultimate fallback: check all raw sources from SourcesManager
        let allSources = SourcesManager.loadSources()
        for source in allSources {
            for src in source.movies where src.id == content.id {
                if let ep = episode {
                    if let epSubs = src.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles, !epSubs.isEmpty {
                        StreamifyLogger.log("resolveAllSubtitleTracks: Found \(epSubs.count) from SourcesManager episode (\(source.name))")
                        return tagSubtitlesWithSource(epSubs, sourceName: source.name)
                    }
                }
                if let subs = src.subtitles, !subs.isEmpty {
                    StreamifyLogger.log("resolveAllSubtitleTracks: Found \(subs.count) from SourcesManager content-level (\(source.name))")
                    return tagSubtitlesWithSource(subs, sourceName: source.name)
                }
            }
        }

        StreamifyLogger.log("resolveAllSubtitleTracks: No subtitles found anywhere (sourceContent=\(sourceContent != nil), isInLibrary=\(isInLibrary))")
        return []
    }

    func resolveAllAudioTracks(for episode: EpisodeInfo? = nil) -> [AudioTrack] {
        // Check sourceContent FIRST (always available from Browse, most reliable)
        if let src = sourceContent {
            let srcName = resolveSourceName(for: src.id)
            if let ep = episode {
                if let epAudio = src.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks, !epAudio.isEmpty {
                    StreamifyLogger.log("resolveAllAudioTracks: Found \(epAudio.count) from sourceContent episode S\(ep.season)E\(ep.episode)")
                    return tagAudioWithSource(epAudio, sourceName: srcName)
                }
            }
            if let audio = src.audioTracks, !audio.isEmpty {
                StreamifyLogger.log("resolveAllAudioTracks: Found \(audio.count) from sourceContent content-level")
                return tagAudioWithSource(audio, sourceName: srcName)
            }
        }

        // Check library metadata
        let current = currentContent
        if let ep = episode {
            if let epAudio = current.metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks, !epAudio.isEmpty {
                StreamifyLogger.log("resolveAllAudioTracks: Found \(epAudio.count) from library metadata episode")
                return epAudio
            }
        }
        if let audio = current.metadata.audioTracks, !audio.isEmpty {
            StreamifyLogger.log("resolveAllAudioTracks: Found \(audio.count) from library metadata content-level")
            return audio
        }

        // Ultimate fallback: check all raw sources from SourcesManager
        let allSources = SourcesManager.loadSources()
        for source in allSources {
            for src in source.movies where src.id == content.id {
                if let ep = episode {
                    if let epAudio = src.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks, !epAudio.isEmpty {
                        StreamifyLogger.log("resolveAllAudioTracks: Found \(epAudio.count) from SourcesManager episode (\(source.name))")
                        return tagAudioWithSource(epAudio, sourceName: source.name)
                    }
                }
                if let audio = src.audioTracks, !audio.isEmpty {
                    StreamifyLogger.log("resolveAllAudioTracks: Found \(audio.count) from SourcesManager content-level (\(source.name))")
                    return tagAudioWithSource(audio, sourceName: source.name)
                }
            }
        }

        StreamifyLogger.log("resolveAllAudioTracks: No audio tracks found anywhere (sourceContent=\(sourceContent != nil), isInLibrary=\(isInLibrary))")
        return []
    }

    /// Resolve source name for a content ID from loaded sources
    func resolveSourceName(for contentId: String) -> String? {
        for source in SourcesManager.loadSources() {
            if source.movies.contains(where: { $0.id == contentId }) {
                return source.name
            }
        }
        return nil
    }

    /// Tag subtitle tracks with a source name (only if not already tagged)
    func tagSubtitlesWithSource(_ tracks: [SubtitleTrack], sourceName: String?) -> [SubtitleTrack] {
        guard let sourceName = sourceName else { return tracks }
        return tracks.map { track in
            if track.sourceName != nil { return track }
            return SubtitleTrack(
                language: track.language,
                source: track.source,
                languageId: track.languageId,
                name: track.name,
                trackId: track.trackId,
                sourceName: sourceName
            )
        }
    }

    /// Tag audio tracks with a source name (only if not already tagged)
    func tagAudioWithSource(_ tracks: [AudioTrack], sourceName: String?) -> [AudioTrack] {
        guard let sourceName = sourceName else { return tracks }
        return tracks.map { track in
            if track.sourceName != nil { return track }
            return AudioTrack(
                language: track.language,
                source: track.source,
                isSpatial: track.isSpatial,
                isDisabled: track.isDisabled,
                languageId: track.languageId,
                name: track.name,
                bandwidth: track.bandwidth,
                trackId: track.trackId,
                sourceName: sourceName
            )
        }
    }

    func downloadMovie() {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        let current = currentContent
        loadingMessage = "Preparing download..."
        let skipper = URLCheckSkipper()
        urlCheckSkipper = skipper

        let task = Task { [skipper] in
            let directUrls = PlaybackResolver.collectMovieUrls(
                content: current, sourceContent: sourceContent, viewModel: viewModel)
            let sourceNames = viewModel.hlsUrlSourceNames(for: current.id)
            let tmdbId = PlaybackResolver.resolveTmdbId(for: current, sourceContent: sourceContent)

            let result = await PlaybackResolver.resolveMovie(
                directUrls: directUrls,
                sourceNamesMap: sourceNames,
                tmdbId: tmdbId,
                vidLinkEnabled: vidLinkEnabled,
                movies111Enabled: movies111Enabled,
                torrentioEnabled: torrentioEnabled,
                includeTorrentioDirectOptions: true,
                onCheckingURL: { [weak skipper] candidate in
                    guard self.loadingMessage != nil else { return }
                    let display = candidate.count > Self.urlDisplayMaxLength
                        ? "..." + candidate.suffix(Self.urlDisplaySuffixLength) : candidate
                    self.loadingMessage = "Preparing download...\n\(display)"
                    if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
                },
                onPreparingPlayback: {
                    guard self.loadingMessage != nil else { return }
                    self.urlCheckSkipper = nil
                    self.loadingMessage = "Preparing download..."
                },
                skipper: skipper
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                urlCheckSkipper = nil
                playResolutionTask = nil
                guard let result else {
                    loadingMessage = nil
                    if !skipper.wasSkipped {
                        downloadError = "No download URL available"
                        showDownloadError = true
                    }
                    return
                }

                proceedWithMovieDownload(
                    urlString: result.url.absoluteString,
                    streamingSubtitles: result.mergedSubtitles ?? [],
                    vidLinkHlsUrl: result.vidLinkUrl?.absoluteString,
                    movies111HlsUrl: result.movies111Url?.absoluteString,
                    torrentioHlsUrl: result.torrentioUrl?.absoluteString,
                    streamingQualities: result.preloadedQualities ?? []
                )
            }
        }
        playResolutionTask = task
    }

    func proceedWithMovieDownload(urlString: String, streamingSubtitles: [SubtitleTrack] = [], vidLinkHlsUrl: String? = nil, movies111HlsUrl: String? = nil, torrentioHlsUrl: String? = nil, streamingQualities: [HLSQuality] = []) {
        StreamifyLogger.log("downloadMovie: Using URL: \(urlString), VidLink URL: \(vidLinkHlsUrl ?? "none"), 111Movies URL: \(movies111HlsUrl ?? "none"), Torrentio URL: \(torrentioHlsUrl ?? "none")")
        selectedEpisodeForDownload = nil
        pendingDownloadUrl = urlString
        pendingVidLinkHlsUrl = vidLinkHlsUrl
        pendingMovies111HlsUrl = movies111HlsUrl
        pendingTorrentioHlsUrl = torrentioHlsUrl?.contains(".m3u8") == true ? torrentioHlsUrl : nil
        pendingStreamingQualities = streamingQualities
        selectedDownloadSubtitles.removeAll()
        selectedDownloadAudio.removeAll()
        downloadFlowNextStep = .idle

        // Resolve available subtitle/audio tracks — check ALL sources.
        // Filter out local-source tracks (from player picker downloads) since the download
        // picker needs remote URLs. This prevents duplicates when HLS parsing finds the same
        // language track with a different languageId/displayName.
        var subtitles = resolveAllSubtitleTracks()
            .filter { $0.source.isEmpty || $0.source.hasPrefix("http") }

        // Merge VidLink subtitles (avoid duplicates by language)
        let existingSubLangs = Set(subtitles.map { $0.languageId })
        for sub in streamingSubtitles {
            if !existingSubLangs.contains(sub.languageId) {
                subtitles.append(sub)
            }
        }

        // Filter out already-downloaded subtitles (match by trackId to preserve same-language tracks from different sources)
        let downloadedSubTrackIds = Set(getLocalSubtitleTracks(for: nil).map { $0.trackId })
        if !downloadedSubTrackIds.isEmpty {
            subtitles.removeAll { downloadedSubTrackIds.contains($0.trackId) }
        }

        var audioTracks = resolveAllAudioTracks()
            .filter { !$0.isEmbedded && ($0.source.isEmpty || $0.source.hasPrefix("http")) }

        // Filter out already-downloaded audio tracks (match by trackId to preserve same-language tracks from different sources)
        let downloadedAudioTrackIds = Set(getLocalAudioTracks(for: nil).map { $0.trackId })
        if !downloadedAudioTrackIds.isEmpty {
            audioTracks.removeAll { downloadedAudioTrackIds.contains($0.trackId) }
        }

        StreamifyLogger.log("downloadMovie: Resolved \(subtitles.count) subtitles, \(audioTracks.count) audio tracks")

        // If HLS, also parse audio renditions from master playlist (async)
        let isHLS = urlString.contains(".m3u8")
        if isHLS, let hlsUrl = URL(string: urlString) {
            let isVidLinkUrl = VidLinkService.isVidLinkProxyURL(urlString)
            let hlsSourceName = isVidLinkUrl ? "VidLink" : viewModel.hlsUrlSourceNames(for: content.id)[urlString]
            loadingMessage = "Preparing download..."
            Task {
                let renditions = await PlayerViewModel.parseHLSAudioRenditions(from: hlsUrl).renditions
                let hlsTracks = renditions.map { $0.toAudioTrack(hlsBaseUrl: urlString, sourceName: hlsSourceName) }.filter { !$0.isEmbedded }
                let existingKeys = Set(audioTracks.map { "\($0.languageId)_\($0.displayName)" })
                for track in hlsTracks {
                    if !existingKeys.contains("\(track.languageId)_\(track.displayName)") {
                        // Also skip already-downloaded audio
                        if !downloadedAudioTrackIds.contains(track.trackId) {
                            audioTracks.append(track)
                        }
                    }
                }
                await MainActor.run {
                    loadingMessage = nil
                    startTrackSelectionFlow(subtitles: subtitles, audioTracks: audioTracks)
                }
            }
        } else {
            loadingMessage = nil
            startTrackSelectionFlow(subtitles: subtitles, audioTracks: audioTracks)
        }
    }

    /// Ensure content is in the library before downloading.
    func addToLibraryIfNeeded() async {
        if let sourceContent = sourceContent, !isInLibrary {
            isAddingToLibrary = true
            // If we've fetched TMDB seasons, include them when adding to library
            if let tmdbSeasons = tmdbFetchedSeasons, sourceContent.seasons == nil || (sourceContent.seasons ?? []).isEmpty {
                let enriched = SourceContent(
                    id: sourceContent.id,
                    title: sourceContent.title,
                    description: sourceContent.description,
                    type: sourceContent.type,
                    genres: sourceContent.genres,
                    thumbnailUrl: sourceContent.thumbnailUrl,
                    posterThumbnailUrl: sourceContent.posterThumbnailUrl,
                    fileUrl: sourceContent.fileUrl,
                    hlsUrl: sourceContent.hlsUrl,
                    intro: sourceContent.intro,
                    introDuration: sourceContent.introDuration,
                    end: sourceContent.end,
                    seasons: tmdbSeasons,
                    episodes: sourceContent.episodes,
                    subtitles: sourceContent.subtitles,
                    audioTracks: sourceContent.audioTracks,
                    embeddedAudioDisabled: sourceContent.embeddedAudioDisabled,
                    tmdbId: sourceContent.tmdbId
                )
                await viewModel.addToLibrary(from: enriched)
            } else {
                await viewModel.addToLibrary(from: sourceContent)
            }
            isAddingToLibrary = false
        }
    }

    func downloadEpisode(_ episode: EpisodeInfo) {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        let current = currentContent
        loadingMessage = "Preparing download..."
        let skipper = URLCheckSkipper()
        urlCheckSkipper = skipper

        let task = Task { [skipper] in
            let directUrls = PlaybackResolver.collectEpisodeUrls(
                content: current, episode: episode, sourceContent: sourceContent, viewModel: viewModel)
            let sourceNames = viewModel.episodeHlsUrlSourceNames(
                for: current.id, season: episode.season, episode: episode.episode)
            let tmdbId = PlaybackResolver.resolveTmdbId(for: current, sourceContent: sourceContent)

            let result = await PlaybackResolver.resolveEpisode(
                directUrls: directUrls,
                sourceNamesMap: sourceNames,
                tmdbId: tmdbId,
                season: episode.season,
                episode: episode.episode,
                vidLinkEnabled: vidLinkEnabled,
                movies111Enabled: movies111Enabled,
                torrentioEnabled: torrentioEnabled,
                includeTorrentioDirectOptions: true,
                onCheckingURL: { [weak skipper] candidate in
                    guard self.loadingMessage != nil else { return }
                    let display = candidate.count > Self.urlDisplayMaxLength
                        ? "..." + candidate.suffix(Self.urlDisplaySuffixLength) : candidate
                    self.loadingMessage = "Preparing download...\n\(display)"
                    if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
                },
                onPreparingPlayback: {
                    guard self.loadingMessage != nil else { return }
                    self.urlCheckSkipper = nil
                    self.loadingMessage = "Preparing download..."
                },
                skipper: skipper
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                urlCheckSkipper = nil
                playResolutionTask = nil
                guard let result else {
                    loadingMessage = nil
                    if !skipper.wasSkipped {
                        downloadError = "No download URL available for this episode"
                        showDownloadError = true
                    }
                    return
                }

                proceedWithEpisodeDownload(
                    episode: episode,
                    urlString: result.url.absoluteString,
                    streamingSubtitles: result.mergedSubtitles ?? [],
                    vidLinkHlsUrl: result.vidLinkUrl?.absoluteString,
                    movies111HlsUrl: result.movies111Url?.absoluteString,
                    torrentioHlsUrl: result.torrentioUrl?.absoluteString,
                    streamingQualities: result.preloadedQualities ?? []
                )
            }
        }
        playResolutionTask = task
    }

    func proceedWithEpisodeDownload(episode: EpisodeInfo, urlString: String, streamingSubtitles: [SubtitleTrack] = [], vidLinkHlsUrl: String? = nil, movies111HlsUrl: String? = nil, torrentioHlsUrl: String? = nil, streamingQualities: [HLSQuality] = []) {
        selectedEpisodeForDownload = episode
        pendingDownloadUrl = urlString
        pendingVidLinkHlsUrl = vidLinkHlsUrl
        pendingMovies111HlsUrl = movies111HlsUrl
        pendingTorrentioHlsUrl = torrentioHlsUrl?.contains(".m3u8") == true ? torrentioHlsUrl : nil
        pendingStreamingQualities = streamingQualities
        selectedDownloadSubtitles.removeAll()
        selectedDownloadAudio.removeAll()
        downloadFlowNextStep = .idle

        // Resolve available subtitle/audio tracks — check ALL sources.
        var subtitles = resolveAllSubtitleTracks(for: episode)
            .filter { $0.source.isEmpty || $0.source.hasPrefix("http") }

        // Merge VidLink subtitles (avoid duplicates by language)
        let existingSubLangs = Set(subtitles.map { $0.languageId })
        for sub in streamingSubtitles {
            if !existingSubLangs.contains(sub.languageId) {
                subtitles.append(sub)
            }
        }

        // Filter out already-downloaded subtitles (match by trackId to handle same-language tracks from different sources)
        let downloadedSubTrackIds = Set(getLocalSubtitleTracks(for: episode).map { $0.trackId })
        if !downloadedSubTrackIds.isEmpty {
            subtitles.removeAll { downloadedSubTrackIds.contains($0.trackId) }
        }

        var audioTracks = resolveAllAudioTracks(for: episode)
            .filter { !$0.isEmbedded && ($0.source.isEmpty || $0.source.hasPrefix("http")) }

        // Filter out already-downloaded audio tracks (match by trackId to handle same-language tracks from different sources)
        let downloadedAudioTrackIds = Set(getLocalAudioTracks(for: episode).map { $0.trackId })
        if !downloadedAudioTrackIds.isEmpty {
            audioTracks.removeAll { downloadedAudioTrackIds.contains($0.trackId) }
        }

        StreamifyLogger.log("downloadEpisode: Resolved \(subtitles.count) subtitles, \(audioTracks.count) audio tracks for S\(episode.season)E\(episode.episode)")

        // If HLS, also parse audio renditions from master playlist (async)
        let isHLS = urlString.contains(".m3u8")
        if isHLS, let hlsUrl = URL(string: urlString) {
            let isVidLinkUrl = VidLinkService.isVidLinkProxyURL(urlString)
            let hlsSourceName = isVidLinkUrl ? "VidLink" : viewModel.episodeHlsUrlSourceNames(for: content.id, season: episode.season, episode: episode.episode)[urlString]
            loadingMessage = "Preparing download..."
            Task {
                let renditions = await PlayerViewModel.parseHLSAudioRenditions(from: hlsUrl).renditions
                let hlsTracks = renditions.map { $0.toAudioTrack(hlsBaseUrl: urlString, sourceName: hlsSourceName) }.filter { !$0.isEmbedded }
                let existingKeys = Set(audioTracks.map { "\($0.languageId)_\($0.displayName)" })
                for track in hlsTracks {
                    if !existingKeys.contains("\(track.languageId)_\(track.displayName)") {
                        // Also skip already-downloaded audio
                        if !downloadedAudioTrackIds.contains(track.trackId) {
                            audioTracks.append(track)
                        }
                    }
                }
                await MainActor.run {
                    loadingMessage = nil
                    startTrackSelectionFlow(subtitles: subtitles, audioTracks: audioTracks)
                }
            }
        } else {
            loadingMessage = nil
            startTrackSelectionFlow(subtitles: subtitles, audioTracks: audioTracks)
        }
    }

    /// Add a video download as queued without starting it immediately.
    /// Used when downloading tracks + video together so all items appear in UI right away.
    func addQueuedVideoDownload(_ quality: MultiSourceQuality, episode: EpisodeInfo? = nil) async {
        guard let primaryUrl = quality.sourceUrls.first else {
            downloadError = "No source URL available"
            showDownloadError = true
            return
        }

        let fallbackUrls = Array(quality.sourceUrls.dropFirst())
        let sourceName = quality.sourceName
        let needsProviderRefresh = VidLinkService.isVidLinkProxyURL(primaryUrl) || sourceName == "Torrentio"
        let downloadTmdbId = needsProviderRefresh ? resolveTmdbId() : nil

        await addToLibraryIfNeeded()

        let contentId: String
        let allEpisodes: [EpisodeInfo]?
        if let episode = episode {
            contentId = "\(content.id)_ep\(episode.episode)"
            allEpisodes = content.metadata.episodes ?? sourceContent?.episodes
        } else {
            contentId = content.id
            allEpisodes = nil
        }

        downloadManager.addQueuedDownload(
            contentId: contentId,
            videoUrl: primaryUrl,
            episodeIndex: episode?.episode,
            seasonIndex: episode?.season,
            episodeTitle: episode?.title,
            selectedBandwidth: quality.bandwidth,
            qualityName: quality.name,
            allEpisodes: allEpisodes,
            fallbackUrls: fallbackUrls,
            tmdbId: downloadTmdbId,
            sourceName: sourceName,
            selectedResolution: quality.resolution,
            selectedVideoRange: quality.videoRange
        )
    }

    // MARK: - Separate Track Downloads (subtitle/audio as individual track downloads, like VideoPlayerView)

    /// Download selected subtitles and audio tracks as separate track downloads.
    /// Each track gets its own TrackDownloadItem visible in DownloadsView.
    /// Downloads run sequentially (one at a time) to avoid resource contention.
    func startSelectedTrackDownloads(episode: EpisodeInfo? = nil) async {
        await addToLibraryIfNeeded()

        let currentContent = content

        // Resolve destination folder
        let folderPath: String
        if let ep = episode {
            folderPath = DownloadManager.episodeFolderPath(contentId: currentContent.id, season: ep.season, episode: ep.episode)
        } else {
            let fp = currentContent.folderPath
            folderPath = fp.isEmpty ? (currentContent.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? currentContent.id) : fp
        }
        let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let prefix = episode.map { "ep\($0.episode)_" } ?? ""
        let metadataFolder = currentContent.folderPath.isEmpty ? (currentContent.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? currentContent.id) : currentContent.folderPath

        // Collect all tracks to download
        let selectedSubIds = selectedDownloadSubtitles
        let subtitleTracks = pendingSubtitleTracks.filter { selectedSubIds.contains($0.trackId) && $0.source.hasPrefix("http") }
        let selectedAudioIds = selectedDownloadAudio
        let audioTracks = pendingAudioTracks.filter { selectedAudioIds.contains($0.trackId) && !$0.isEmbedded && $0.source.hasPrefix("http") }

        // Register all track downloads upfront (queued status) so they appear in UI
        var subtitleDownloadIds: [(SubtitleTrack, String)] = []
        for track in subtitleTracks {
            let trackDownloadId = downloadManager.addTrackDownload(
                contentId: currentContent.id,
                contentTitle: currentContent.metadata.title,
                trackType: "subtitle",
                language: track.displayName,
                episodeInfo: episode,
                downloadURL: track.source,
                destFolderPath: folderPath,
                filePrefix: prefix,
                metadataFolder: metadataFolder,
                trackId: track.trackId,
                languageId: track.languageId
            )
            subtitleDownloadIds.append((track, trackDownloadId))
        }
        var audioDownloadIds: [(AudioTrack, String)] = []
        for track in audioTracks {
            let url = URL(string: track.source)
            let isHLS = url?.pathExtension.lowercased() == "m3u8" || track.source.contains(".m3u8")
            let trackDownloadId = downloadManager.addTrackDownload(
                contentId: currentContent.id,
                contentTitle: currentContent.metadata.title,
                trackType: "audio",
                language: track.displayName,
                episodeInfo: episode,
                downloadURL: track.source,
                destFolderPath: folderPath,
                filePrefix: prefix,
                metadataFolder: metadataFolder,
                trackId: track.trackId,
                languageId: track.languageId,
                isHLS: isHLS
            )
            audioDownloadIds.append((track, trackDownloadId))
        }

        // Download sequentially — one track at a time. Each download is wrapped in its own
        // Task stored on TrackDownloadItem so pause/cancel from DownloadsView actually stops it.
        // Before starting each download, waits for any other active track download (including
        // from other episodes) to finish, ensuring tracks are queued rather than concurrent.

        /// Wait for any active track downloads to finish before starting `trackDownloadId`.
        /// Returns `false` if the track was cancelled while waiting.
        @Sendable func waitForTrackTurn(_ trackDownloadId: String) async -> Bool {
            while await MainActor.run(body: {
                DownloadManager.shared.trackDownloads.contains { $0.status == .downloading && $0.id != trackDownloadId }
            }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // Check if this track was cancelled while waiting in the queue
            return await MainActor.run {
                DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId }) != nil
            }
        }

        /// Wrap a download operation in a Task, store it on the TrackDownloadItem, and
        /// await its completion. This makes pause/cancel actually stop the download.
        @Sendable func runTrackDownload(id trackDownloadId: String, download: @escaping @Sendable () async -> Void) async {
            let task = Task<Void, Never> {
                await MainActor.run {
                    DownloadManager.shared.startTrackDownload(id: trackDownloadId)
                }
                await download()
            }
            await MainActor.run {
                if let item = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId }) {
                    item.downloadTask = task
                }
            }
            await task.value
        }

        // Download subtitles first
        for (track, trackDownloadId) in subtitleDownloadIds {
                guard await waitForTrackTurn(trackDownloadId) else { continue }

                let dm = downloadManager
                await runTrackDownload(id: trackDownloadId) {
                    do {
                        let localName = try await dm.downloadSingleSubtitleTrack(
                            track: track, to: destDir, prefix: prefix,
                            onProgress: { progress in
                                Task { @MainActor in
                                    DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                                }
                            }
                        )
                        guard let fileName = localName else {
                            await MainActor.run {
                                DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid")
                            }
                            return
                        }
                        await MainActor.run {
                            self.updateTrackInMetadata(metadataFolder: metadataFolder, episode: episode, subtitleTrack: track, localSource: fileName)
                            DownloadManager.shared.completeTrackDownload(id: trackDownloadId)
                            DownloadManager.shared.libraryRefreshNeeded = true
                            NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                            StreamifyLogger.log("ContentDetail: Downloaded subtitle \(track.displayName) -> \(fileName)")
                        }
                    } catch {
                        await MainActor.run {
                            let wasPaused = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId })?.status == .paused
                            if wasPaused {
                                StreamifyLogger.log("ContentDetail: Subtitle download paused for \(track.displayName)")
                            } else if !(error is CancellationError) {
                                DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: error.localizedDescription)
                                StreamifyLogger.log("ContentDetail: Failed subtitle \(track.displayName): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }

            // Then download audio tracks
            for (track, trackDownloadId) in audioDownloadIds {
                guard let url = URL(string: track.source) else {
                    await MainActor.run {
                        DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: "Invalid audio URL")
                    }
                    continue
                }
                let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")

                guard await waitForTrackTurn(trackDownloadId) else { continue }

                let dm = downloadManager
                await runTrackDownload(id: trackDownloadId) {
                    do {
                        let localSource: String
                        if isHLS {
                            localSource = try await dm.downloadHLSAudioPlaylist(
                                from: url, track: track, to: destDir, prefix: prefix,
                                download: nil, downloadedCount: 0, totalToDownload: 1,
                                onProgress: { progress in
                                    Task { @MainActor in
                                        DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                                    }
                                }
                            )
                        } else {
                            guard let name = try await dm.downloadSingleAudioFile(
                                track: track, to: destDir, prefix: prefix,
                                onProgress: { progress in
                                    Task { @MainActor in
                                        DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                                    }
                                }
                            ) else {
                                await MainActor.run {
                                    DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid")
                                }
                                return
                            }
                            localSource = name
                        }
                        await MainActor.run {
                            self.updateTrackInMetadata(metadataFolder: metadataFolder, episode: episode, audioTrack: track, localSource: localSource)
                            DownloadManager.shared.completeTrackDownload(id: trackDownloadId)
                            DownloadManager.shared.libraryRefreshNeeded = true
                            NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                            StreamifyLogger.log("ContentDetail: Downloaded audio \(track.displayName) -> \(localSource)")
                        }
                    } catch {
                        await MainActor.run {
                            let wasPaused = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId })?.status == .paused
                            if wasPaused {
                                StreamifyLogger.log("ContentDetail: Audio download paused for \(track.displayName)")
                            } else if !(error is CancellationError) {
                                DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: error.localizedDescription)
                                StreamifyLogger.log("ContentDetail: Failed audio \(track.displayName): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
    }

    /// Update metadata to reflect a newly downloaded subtitle or audio track.
    /// Matches by trackId to handle same-language tracks from different sources correctly.
    func updateTrackInMetadata(metadataFolder: String, episode: EpisodeInfo? = nil, subtitleTrack: SubtitleTrack? = nil, audioTrack: AudioTrack? = nil, localSource: String) {
        guard var metadata = ContentImportService.loadMetadata(from: metadataFolder) else { return }

        if let ep = episode {
            // Episode - update both seasons and flat episodes
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var eps = seasons[sIdx].episodes {
                        for eIdx in eps.indices {
                            if seasons[sIdx].season == ep.season && eps[eIdx].episode == ep.episode {
                                if let sub = subtitleTrack {
                                    var s = eps[eIdx].subtitles ?? []
                                    if let i = s.firstIndex(where: { $0.trackId == sub.trackId }) {
                                        s[i] = SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName)
                                    } else {
                                        s.append(SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName))
                                    }
                                    eps[eIdx] = eps[eIdx].copying(subtitles: s)
                                }
                                if let aud = audioTrack {
                                    var a = eps[eIdx].audioTracks ?? []
                                    if let i = a.firstIndex(where: { $0.trackId == aud.trackId }) {
                                        a[i] = AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName)
                                    } else {
                                        a.append(AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName))
                                    }
                                    eps[eIdx] = eps[eIdx].copying(audioTracks: a)
                                }
                            }
                        }
                        seasons[sIdx] = SeasonInfo(season: seasons[sIdx].season, title: seasons[sIdx].title,
                                                    thumbnailUrl: seasons[sIdx].thumbnailUrl, episodes: eps)
                    }
                }
                metadata = metadata.copying(seasons: seasons)
            }
            if var episodes = metadata.episodes {
                for eIdx in episodes.indices {
                    if episodes[eIdx].season == ep.season && episodes[eIdx].episode == ep.episode {
                        if let sub = subtitleTrack {
                            var s = episodes[eIdx].subtitles ?? []
                            if let i = s.firstIndex(where: { $0.trackId == sub.trackId }) {
                                s[i] = SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName)
                            } else {
                                s.append(SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName))
                            }
                            episodes[eIdx] = episodes[eIdx].copying(subtitles: s)
                        }
                        if let aud = audioTrack {
                            var a = episodes[eIdx].audioTracks ?? []
                            if let i = a.firstIndex(where: { $0.trackId == aud.trackId }) {
                                a[i] = AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName)
                            } else {
                                a.append(AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName))
                            }
                            episodes[eIdx] = episodes[eIdx].copying(audioTracks: a)
                        }
                    }
                }
                metadata = metadata.copying(episodes: episodes)
            }
        } else {
            // Movie - update content-level tracks
            if let sub = subtitleTrack {
                var subs = metadata.subtitles ?? []
                if let i = subs.firstIndex(where: { $0.trackId == sub.trackId }) {
                    subs[i] = SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName)
                } else {
                    subs.append(SubtitleTrack(language: sub.language, source: localSource, languageId: sub.languageId, name: sub.name, trackId: sub.trackId, sourceName: sub.sourceName))
                }
                metadata = metadata.copying(subtitles: subs)
            }
            if let aud = audioTrack {
                var tracks = metadata.audioTracks ?? []
                if let i = tracks.firstIndex(where: { $0.trackId == aud.trackId }) {
                    tracks[i] = AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName)
                } else {
                    tracks.append(AudioTrack(language: aud.language, source: localSource, isSpatial: aud.isSpatial, languageId: aud.languageId, name: aud.name, trackId: aud.trackId, sourceName: aud.sourceName))
                }
                metadata = metadata.copying(audioTracks: tracks)
            }
        }

        ContentImportService.saveMetadata(metadata, to: metadataFolder)
        DownloadManager.shared.refreshLocalMasterPlaylist(metadataFolder: metadataFolder, episode: episode)
    }

    // MARK: - Track Selection Flow

    /// Start the track selection flow. No timers — uses sheet(item:) so data IS the trigger.
    /// Pre-selected IDs are computed and included in the picker data structs so they're
    /// available when the sheet renders (avoids SwiftUI state-batching timing issues).
    func startTrackSelectionFlow(subtitles: [SubtitleTrack], audioTracks: [AudioTrack]) {
        // Re-check metadata from disk for already-downloaded tracks (library might be stale)
        let episode = selectedEpisodeForDownload
        let liveLocalSubs = getLocalSubtitleTracksFromDisk(for: episode)
        let liveLocalAudio = getLocalAudioTracksFromDisk(for: episode)
        let downloadedSubTrackIds = Set(liveLocalSubs.map { $0.trackId })
        let downloadedAudioTrackIds = Set(liveLocalAudio.map { $0.trackId })
        // Also match by languageId+sourceName as fallback (trackIds may differ between online resolution and metadata)
        let downloadedSubKeys = Set(liveLocalSubs.map { "\($0.languageId)_\($0.sourceName ?? "")" })
        let downloadedAudioKeys = Set(liveLocalAudio.map { "\($0.languageId)_\($0.sourceName ?? "")" })

        let filteredSubs = subtitles.filter { sub in
            !downloadedSubTrackIds.contains(sub.trackId) &&
            !downloadedSubKeys.contains("\(sub.languageId)_\(sub.sourceName ?? "")")
        }
        let filteredAudio = audioTracks.filter { audio in
            !downloadedAudioTrackIds.contains(audio.trackId) &&
            !downloadedAudioKeys.contains("\(audio.languageId)_\(audio.sourceName ?? "")")
        }

        let hasSubtitles = !filteredSubs.isEmpty
        let hasAudio = !filteredAudio.isEmpty

        StreamifyLogger.log("startTrackSelectionFlow: \(filteredSubs.count) subtitles, \(filteredAudio.count) audio, hasSubtitles=\(hasSubtitles), hasAudio=\(hasAudio)")

        // Store tracks for later use by download calls and sheet chaining
        pendingSubtitleTracks = filteredSubs
        pendingAudioTracks = filteredAudio
        userConfirmedPicker = false

        // Compute pre-selections and apply them BEFORE triggering sheets.
        // Setting @State before the picker data ensures SwiftUI sees both in the same transaction.
        let subPreSelected = computePreferredSubtitleIds(filteredSubs)
        let audioPreSelected = computePreferredAudioIds(filteredAudio)
        selectedDownloadSubtitles = subPreSelected
        selectedDownloadAudio = audioPreSelected

        if hasSubtitles {
            downloadFlowNextStep = hasAudio ? .showAudioPicker : .showQualityPicker
            subtitlePickerData = SubtitlePickerData(tracks: filteredSubs, preSelectedIds: subPreSelected)
        } else if hasAudio {
            downloadFlowNextStep = .showQualityPicker
            audioPickerData = AudioPickerData(tracks: filteredAudio, preSelectedIds: audioPreSelected)
        } else {
            proceedToQualityPicker(urlString: pendingDownloadUrl ?? "")
        }
    }

    /// Pure function: returns trackIds matching preferred subtitle languages.
    func computePreferredSubtitleIds(_ tracks: [SubtitleTrack]) -> Set<String> {
        let prefStr = UserDefaults.standard.string(forKey: "preferredSubtitleLanguages") ?? ""
        let preferred = prefStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !preferred.isEmpty else { return [] }

        var selected = Set<String>()
        for track in tracks {
            let matchesLang = preferred.contains(track.language.lowercased())
            let matchesId = preferred.contains(track.languageId.lowercased())
            let matchesName = preferred.contains(track.displayName.lowercased())
            if matchesLang || matchesId || matchesName {
                selected.insert(track.trackId)
            }
        }
        return selected
    }

    /// Pure function: returns trackIds matching preferred audio languages (excludes embedded).
    func computePreferredAudioIds(_ tracks: [AudioTrack]) -> Set<String> {
        let prefStr = UserDefaults.standard.string(forKey: "preferredAudioLanguages") ?? ""
        let preferred = prefStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !preferred.isEmpty else { return [] }

        var selected = Set<String>()
        for track in tracks {
            if track.isEmbedded { continue }
            let matchesLang = preferred.contains(track.language.lowercased())
            let matchesId = preferred.contains(track.languageId.lowercased())
            let matchesName = preferred.contains(track.displayName.lowercased())
            if matchesLang || matchesId || matchesName {
                selected.insert(track.trackId)
            }
        }
        return selected
    }

    /// Called by subtitle sheet's onDismiss — decides what to show next.
    func handleSubtitlePickerDismissed() {
        guard userConfirmedPicker else {
            // User swiped down to dismiss — cancel entire download flow
            downloadFlowNextStep = .idle
            StreamifyLogger.log("handleSubtitlePickerDismissed: user swiped down, cancelling flow")
            return
        }
        userConfirmedPicker = false

        let nextStep = downloadFlowNextStep
        downloadFlowNextStep = .idle

        switch nextStep {
        case .showQualityPicker:
            proceedToQualityPicker(urlString: pendingDownloadUrl ?? "")
        case .showAudioPicker:
            let audioPreSelected = computePreferredAudioIds(pendingAudioTracks)
            selectedDownloadAudio = audioPreSelected
            audioPickerData = AudioPickerData(tracks: pendingAudioTracks, preSelectedIds: audioPreSelected)
            downloadFlowNextStep = .showQualityPicker
        case .idle:
            break
        }
    }

    /// Called by audio sheet's onDismiss — decides what to show next.
    func handleAudioPickerDismissed() {
        guard userConfirmedPicker else {
            // User swiped down to dismiss — cancel entire download flow
            downloadFlowNextStep = .idle
            StreamifyLogger.log("handleAudioPickerDismissed: user swiped down, cancelling flow")
            return
        }
        userConfirmedPicker = false

        let nextStep = downloadFlowNextStep
        downloadFlowNextStep = .idle

        switch nextStep {
        case .showQualityPicker:
            proceedToQualityPicker(urlString: pendingDownloadUrl ?? "")
        case .showAudioPicker:
            StreamifyLogger.log("handleAudioPickerDismissed: unexpected .showAudioPicker step")
        case .idle:
            break
        }
    }

    func proceedToQualityPicker(urlString: String) {
        let isHLS = urlString.contains(".m3u8")
        let hasVidLinkHls = pendingVidLinkHlsUrl != nil
        let hasMovies111Hls = pendingMovies111HlsUrl != nil
        let hasTorrentioHls = pendingTorrentioHlsUrl != nil
        let directQualities = pendingStreamingQualities.filter { $0.isDirectFileSource }

        if isHLS || hasVidLinkHls || hasMovies111Hls || hasTorrentioHls || !directQualities.isEmpty {
            loadingMessage = "Preparing download..."
            isLoadingQualities = true

            var allUrls: [String]
            if let episode = selectedEpisodeForDownload {
                allUrls = viewModel.allEpisodeHlsUrls(for: content.id, season: episode.season, episode: episode.episode)
            } else {
                allUrls = viewModel.allHlsUrls(for: content.id)
            }
            if isHLS, !allUrls.contains(urlString) {
                allUrls.insert(urlString, at: 0)
            }

            // Include VidLink HLS URL as a source for quality parsing
            if let vidLinkUrl = pendingVidLinkHlsUrl, !allUrls.contains(vidLinkUrl) {
                allUrls.append(vidLinkUrl)
            }

            // Include 111Movies HLS URL as a source for quality parsing
            if let movies111Url = pendingMovies111HlsUrl, !allUrls.contains(movies111Url) {
                allUrls.append(movies111Url)
            }

            if let torrentioUrl = pendingTorrentioHlsUrl, !allUrls.contains(torrentioUrl) {
                allUrls.append(torrentioUrl)
            }

            Task {
                // Build source name mapping
                var sourceNames: [String: String]
                if let episode = selectedEpisodeForDownload {
                    sourceNames = viewModel.episodeHlsUrlSourceNames(for: content.id, season: episode.season, episode: episode.episode)
                } else {
                    sourceNames = viewModel.hlsUrlSourceNames(for: content.id)
                }
                // Add VidLink source name
                if let vidLinkUrl = pendingVidLinkHlsUrl {
                    sourceNames[vidLinkUrl] = "VidLink"
                }
                // Add 111Movies source name
                if let movies111Url = pendingMovies111HlsUrl {
                    sourceNames[movies111Url] = "111Movies"
                }
                if let torrentioUrl = pendingTorrentioHlsUrl {
                    sourceNames[torrentioUrl] = "Torrentio"
                }

                let parsedHlsQualities = await PlayerViewModel.parseAllSourceQualities(from: allUrls, sourceNames: sourceNames)
                let allQualities = parsedHlsQualities + directQualities

                // Convert to MultiSourceQuality for the download flow (one per source per quality level)
                let merged = allQualities.map { q in
                    MultiSourceQuality(
                        name: q.name,
                        bandwidth: q.bandwidth,
                        resolution: q.resolution,
                        videoRange: q.videoRange,
                        frameRate: q.frameRate,
                        sourceUrls: [q.sourceUrl].compactMap { $0 },
                        sourceName: q.sourceName,
                        displayDetail: q.displayDetail
                    )
                }

                // Don't show quality picker if no qualities were found — source fetching failed
                await MainActor.run {
                    guard isLoadingQualities, loadingMessage != nil else { return }
                    multiSourceQualities = merged
                    isLoadingQualities = false
                    loadingMessage = nil
                    if merged.isEmpty {
                        StreamifyLogger.log("Quality picker: No qualities found from any source, not showing picker")
                    } else {
                        // Pre-select the highest bandwidth quality
                        selectedDownloadQualities.removeAll()
                        if let highest = merged.max(by: { $0.bandwidth < $1.bandwidth }) {
                            // Filter out already-downloaded, then pre-select highest available
                            let downloadedQualities = getDownloadedQualities(for: selectedEpisodeForDownload)
                            let available = merged.filter { quality in
                                !downloadedQualities.contains { dq in
                                    downloadQuality(dq, matches: quality)
                                }
                            }
                            if let highestAvailable = available.max(by: { $0.bandwidth < $1.bandwidth }) {
                                selectedDownloadQualities.insert(highestAvailable.id)
                            } else {
                                selectedDownloadQualities.insert(highest.id)
                            }
                        }
                        showQualityPicker = true
                    }
                }
            }
        } else {
            if let episode = selectedEpisodeForDownload {
                Task {
                    // Prevent processQueue() from prematurely starting the video
                    // while we're still setting up track downloads.
                    await MainActor.run {
                        downloadManager.beginTrackSetup()
                    }
                    // Add video download queued first so it's visible immediately
                    await addToLibraryIfNeeded()
                    let allEpisodes = content.metadata.episodes ?? sourceContent?.episodes
                    downloadManager.addQueuedDownload(
                        contentId: "\(content.id)_ep\(episode.episode)",
                        videoUrl: urlString,
                        episodeIndex: episode.episode,
                        seasonIndex: episode.season,
                        episodeTitle: episode.title,
                        quality: .high,
                        allEpisodes: allEpisodes
                    )
                    await startSelectedTrackDownloads(episode: episode)
                    await MainActor.run {
                        downloadManager.endTrackSetup()
                        downloadManager.triggerProcessQueue()
                    }
                }
            } else {
                Task {
                    // Prevent processQueue() from prematurely starting the video
                    // while we're still setting up track downloads.
                    await MainActor.run {
                        downloadManager.beginTrackSetup()
                    }
                    // Add video download queued first so it's visible immediately
                    await addToLibraryIfNeeded()
                    downloadManager.addQueuedDownload(
                        contentId: content.id,
                        videoUrl: urlString,
                        quality: .high
                    )
                    await startSelectedTrackDownloads(episode: nil)
                    await MainActor.run {
                        downloadManager.endTrackSetup()
                        downloadManager.triggerProcessQueue()
                    }
                }
            }
        }
    }

    // MARK: - Download Track Picker Sheets

    func downloadSubtitlePickerSheet(data: SubtitlePickerData) -> some View {
        DownloadSubtitlePickerView(
            tracks: data.tracks,
            initialSelected: data.preSelectedIds,
            onCancel: {
                subtitlePickerData = nil
            },
            onNext: { selected in
                selectedDownloadSubtitles = selected
                userConfirmedPicker = true
                subtitlePickerData = nil  // dismiss
            }
        )
    }

    func downloadAudioPickerSheet(data: AudioPickerData) -> some View {
        DownloadAudioPickerView(
            tracks: data.tracks,
            initialSelected: data.preSelectedIds,
            onCancel: {
                audioPickerData = nil
            },
            onNext: { selected in
                selectedDownloadAudio = selected
                userConfirmedPicker = true
                audioPickerData = nil  // dismiss
            }
        )
    }
}
