import SwiftUI

extension ContentDetailView {
    // MARK: - Playback
    func playContent() {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        let latestContent = currentContent
        
        // Check local file first
        if !latestContent.folderPath.isEmpty {
            if let localURL = ContentImportService.videoURL(for: latestContent),
               localURL.isFileURL || localURL.host == "localhost" || localURL.host == "127.0.0.1" {
                loadingMessage = nil
                playerContext = PlayerContext(
                    content: latestContent,
                    videoURL: localURL,
                    episodeInfo: nil,
                    episodeIndex: nil,
                    totalEpisodes: 0
                )
                return
            }
        }
        
        loadingMessage = "Setting up video player..."

        let skipper = URLCheckSkipper()
        urlCheckSkipper = skipper

        let task = Task { [skipper] in
            let directUrls = PlaybackResolver.collectMovieUrls(
                content: latestContent, sourceContent: sourceContent, viewModel: viewModel)
            let sourceNames = viewModel.hlsUrlSourceNames(for: latestContent.id)
            let tmdbId = PlaybackResolver.resolveTmdbId(for: latestContent, sourceContent: sourceContent)

            let result = await PlaybackResolver.resolveMovie(
                directUrls: directUrls,
                sourceNamesMap: sourceNames,
                tmdbId: tmdbId,
                vidLinkEnabled: vidLinkEnabled,
                movies111Enabled: movies111Enabled,
                torrentioEnabled: torrentioEnabled,
                onCheckingURL: { [weak skipper] url in
                    guard self.loadingMessage != nil else { return }
                    // Show the URL being checked on the second line of the loading message
                    let display = url.count > Self.urlDisplayMaxLength
                        ? "..." + url.suffix(Self.urlDisplaySuffixLength) : url
                    self.loadingMessage = "Setting up video player...\n\(display)"
                    // Keep skipper alive if more URLs remain
                    if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
                },
                onPreparingPlayback: {
                    guard self.loadingMessage != nil else { return }
                    self.urlCheckSkipper = nil
                    self.loadingMessage = "Setting up video player..."
                },
                skipper: skipper
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                urlCheckSkipper = nil
                loadingMessage = nil
                playResolutionTask = nil
                guard let result else {
                    if !skipper.wasSkipped {
                        playError = "Unable to play \(latestContent.metadata.title). All sources failed."
                        showPlayError = true
                    }
                    return
                }
                playerContext = PlayerContext(
                    content: latestContent,
                    videoURL: result.url,
                    episodeInfo: nil,
                    episodeIndex: nil,
                    totalEpisodes: 0,
                    preloadedAudioTracks: result.preloadedAudioTracks,
                    streamingSubtitles: result.mergedSubtitles,
                    preloadedQualities: result.preloadedQualities
                )
            }
        }
        playResolutionTask = task

        // Overall timeout — covers both source URL checks and service fetches
        Task {
            try? await Task.sleep(nanoseconds: Self.playbackResolutionTimeoutNs)
            guard !task.isCancelled, loadingMessage != nil else { return }
            task.cancel()
            await MainActor.run {
                urlCheckSkipper = nil
                loadingMessage = nil
                playResolutionTask = nil
                playError = "Request timed out. Please try again."
                showPlayError = true
            }
        }
    }

    func playEpisode(at index: Int) {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        let episode = episodes[index]
        let latestContent = currentContent

        // Check local file first
        if let localURL = ContentImportService.videoURL(for: latestContent, episode: episode),
           localURL.isFileURL || localURL.host == "localhost" || localURL.host == "127.0.0.1" {
            currentEpisodeIndex = index
            playerContext = PlayerContext(
                content: latestContent,
                videoURL: localURL,
                episodeInfo: episode,
                episodeIndex: index,
                totalEpisodes: episodes.count
            )
            return
        }

        loadingMessage = "Setting up video player..."

        let skipper = URLCheckSkipper()
        urlCheckSkipper = skipper

        let task = Task { [skipper] in
            let directUrls = PlaybackResolver.collectEpisodeUrls(
                content: latestContent, episode: episode, sourceContent: sourceContent, viewModel: viewModel)
            let sourceNames = viewModel.episodeHlsUrlSourceNames(
                for: latestContent.id, season: episode.season, episode: episode.episode)
            let tmdbId = PlaybackResolver.resolveTmdbId(for: latestContent, sourceContent: sourceContent)

            let result = await PlaybackResolver.resolveEpisode(
                directUrls: directUrls,
                sourceNamesMap: sourceNames,
                tmdbId: tmdbId,
                season: episode.season,
                episode: episode.episode,
                vidLinkEnabled: vidLinkEnabled,
                movies111Enabled: movies111Enabled,
                torrentioEnabled: torrentioEnabled,
                onCheckingURL: { [weak skipper] url in
                    guard self.loadingMessage != nil else { return }
                    let display = url.count > Self.urlDisplayMaxLength
                        ? "..." + url.suffix(Self.urlDisplaySuffixLength) : url
                    self.loadingMessage = "Setting up video player...\n\(display)"
                    if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
                },
                onPreparingPlayback: {
                    guard self.loadingMessage != nil else { return }
                    self.urlCheckSkipper = nil
                    self.loadingMessage = "Setting up video player..."
                },
                skipper: skipper
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                urlCheckSkipper = nil
                loadingMessage = nil
                playResolutionTask = nil
                guard let result else {
                    if !skipper.wasSkipped {
                        playError = "Unable to play S\(episode.season) E\(episode.episode). All sources failed."
                        showPlayError = true
                    }
                    return
                }
                currentEpisodeIndex = index
                playerContext = PlayerContext(
                    content: latestContent,
                    videoURL: result.url,
                    episodeInfo: episode,
                    episodeIndex: index,
                    totalEpisodes: episodes.count,
                    preloadedAudioTracks: result.preloadedAudioTracks,
                    streamingSubtitles: result.mergedSubtitles,
                    preloadedQualities: result.preloadedQualities
                )
            }
        }
        playResolutionTask = task

        Task {
            try? await Task.sleep(nanoseconds: Self.playbackResolutionTimeoutNs)
            guard !task.isCancelled, loadingMessage != nil else { return }
            task.cancel()
            await MainActor.run {
                urlCheckSkipper = nil
                loadingMessage = nil
                playResolutionTask = nil
                playError = "Request timed out. Please try again."
                showPlayError = true
            }
        }
    }
    
    func getNextEpisodeRequest(
        currentEpisode: EpisodeInfo,
        skipper: URLCheckSkipper? = nil,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil
    ) async -> EpisodeChangeRequest? {
        let currentEp = currentEpisode
        guard let currentIndex = episodes.firstIndex(where: { $0.season == currentEp.season && $0.episode == currentEp.episode }) else { return nil }
        
        let nextIndex = currentIndex + 1
        guard nextIndex < episodes.count else { return nil }
        
        let nextEpisode = episodes[nextIndex]
        let latestContent = currentContent
        
        // Check local file first
        if let localURL = ContentImportService.videoURL(for: latestContent, episode: nextEpisode),
           localURL.isFileURL || localURL.host == "localhost" {
            return EpisodeChangeRequest(episode: nextEpisode, videoURL: localURL)
        }
        
        let directUrls = PlaybackResolver.collectEpisodeUrls(
            content: latestContent, episode: nextEpisode, sourceContent: sourceContent, viewModel: viewModel)
        let sourceNames = viewModel.episodeHlsUrlSourceNames(
            for: latestContent.id, season: nextEpisode.season, episode: nextEpisode.episode)
        let tmdbId = PlaybackResolver.resolveTmdbId(for: latestContent, sourceContent: sourceContent)
        
        guard let result = await PlaybackResolver.resolveEpisode(
            directUrls: directUrls,
            sourceNamesMap: sourceNames,
            tmdbId: tmdbId,
            season: nextEpisode.season,
            episode: nextEpisode.episode,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        ) else { return nil }
        
        return EpisodeChangeRequest(
            episode: nextEpisode,
            videoURL: result.url,
            preloadedAudioTracks: result.preloadedAudioTracks,
            streamingSubtitles: result.mergedSubtitles,
            preloadedQualities: result.preloadedQualities
        )
    }
    
    func addLibraryAndGetNextEpisodeRequest(
        currentEpisode: EpisodeInfo,
        skipper: URLCheckSkipper? = nil,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil
    ) async -> EpisodeChangeRequest? {
        guard let sourceContent = sourceContent else { return nil }
        let currentEp = currentEpisode
        guard let currentIndex = episodes.firstIndex(where: { $0.season == currentEp.season && $0.episode == currentEp.episode }) else { return nil }
        
        let nextIndex = currentIndex + 1
        guard nextIndex < episodes.count else { return nil }
        
        let nextEpisode = episodes[nextIndex]
        
        let directUrls = PlaybackResolver.collectEpisodeUrls(
            content: content, episode: nextEpisode, sourceContent: sourceContent, viewModel: viewModel)
        let sourceNames = viewModel.episodeHlsUrlSourceNames(
            for: content.id, season: nextEpisode.season, episode: nextEpisode.episode)
        let tmdbId = PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent)
        
        guard let result = await PlaybackResolver.resolveEpisode(
            directUrls: directUrls,
            sourceNamesMap: sourceNames,
            tmdbId: tmdbId,
            season: nextEpisode.season,
            episode: nextEpisode.episode,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        ) else { return nil }

        isAddingToLibrary = true
        await viewModel.addToLibrary(from: sourceContent)
        await MainActor.run {
            viewModel.loadLibrary()
            isAddingToLibrary = false
        }
        
        return EpisodeChangeRequest(
            episode: nextEpisode,
            videoURL: result.url,
            preloadedAudioTracks: result.preloadedAudioTracks,
            streamingSubtitles: result.mergedSubtitles,
            preloadedQualities: result.preloadedQualities
        )
    }
}
