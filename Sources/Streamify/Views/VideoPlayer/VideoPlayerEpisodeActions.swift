import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Skip Intro Button
    var skipIntroButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    let wasPlaying = viewModel.isPlaying
                    let hasSeparateAudio = hasSeparateAudioPlayer
                    if hasSeparateAudio {
                        pausePlayback()
                    }
                    viewModel.skipIntro(resumeAfterSeek: false) {
                        markSeekedPlaybackNeedsVideoGate()
                        guard wasPlaying else { return }
                        playWithSyncedAudio()
                    }
                } label: {
                    Text("Skip Intro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.trailing, 24)
            .padding(.bottom, 80)
        }
    }

    // MARK: - Next Episode Buttons
    var nextEpisodeButtons: some View {
        Group {
            if !isMovie {
                if hasNextEpisode {
                    if isInLibrary {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    playNextEpisode()
                                } label: {
                                    VStack(spacing: 2) {
                                        HStack(spacing: 6) {
                                            if isTransitioningToNext {
                                                ProgressView()
                                                    .tint(.black)
                                            }
                                            Text("Next Episode")
                                            Image(systemName: "forward.fill")
                                        }
                                        .font(.subheadline.weight(.semibold))
                                        if isTransitioningToNext {
                                            Text(transitionMessage)
                                                .font(.caption2)
                                                .opacity(0.6)
                                        }
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .disabled(isTransitioningToNext)
                            }
                            .padding(.trailing, 24)
                            .padding(.bottom, 80)
                        }
                    } else if onAddToLibraryAndRequestNext != nil {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    addToLibraryAndPlayNext()
                                } label: {
                                    VStack(spacing: 2) {
                                        HStack(spacing: 6) {
                                            if isTransitioningToNext {
                                                ProgressView()
                                                    .tint(.black)
                                            }
                                            Text("Add to Library & Play Next")
                                            Image(systemName: "plus.circle")
                                        }
                                        .font(.subheadline.weight(.semibold))
                                        if isTransitioningToNext {
                                            Text(transitionMessage)
                                                .font(.caption2)
                                                .opacity(0.6)
                                        }
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .disabled(isTransitioningToNext)
                            }
                            .padding(.trailing, 24)
                            .padding(.bottom, 80)
                        }
                    }
                } else {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                onGoToBrowse?()
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Watch Something Else")
                                    Image(systemName: "film")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 80)
                    }
                }
            } else if isMovie && onGoToBrowse != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            onGoToBrowse?()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Watch Something Else")
                                Image(systemName: "film")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 80)
                }
            }
        }
    }

    // MARK: - Play Next Episode (in same player)
    func playNextEpisode() {
        // Guard against multiple simultaneous transitions (e.g., rapid button taps)
        guard !isTransitioningToNext else {
            StreamifyLogger.log("playNextEpisode: Already transitioning, ignoring duplicate request")
            return
        }
        isTransitioningToNext = true
        transitionMessage = "Loading..."
        onlineSwitchFetchingURL = nil

        let skipper = URLCheckSkipper()
        onlineSwitchSkipper = skipper

        nextEpisodeTask?.cancel()
        nextEpisodeTask = Task { @MainActor in
            defer {
                nextEpisodeTask = nil
                onlineSwitchSkipper = nil
                onlineSwitchFetchingURL = nil
            }
            await performPlayNextEpisode(skipper: skipper)
        }
    }

    func cancelNextEpisode() {
        onlineSwitchSkipper?.skip()
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        onlineSwitchSkipper = nil
        onlineSwitchFetchingURL = nil
        isTransitioningToNext = false
        playWithSyncedAudio()
    }

    func performPlayNextEpisode(skipper: URLCheckSkipper) async {
        let onCheckingURL: @MainActor @Sendable (String) -> Void = { candidate in
            guard self.isTransitioningToNext else { return }
            let maxLen = VideoPlayerView.maxDisplayUrlLength
            let display = candidate.count > maxLen ? "..." + candidate.suffix(VideoPlayerView.displayUrlSuffixLength) : candidate
            self.onlineSwitchFetchingURL = String(display)
        }
        let onPreparingPlayback: @MainActor @Sendable () -> Void = {
            guard self.isTransitioningToNext else { return }
            self.onlineSwitchFetchingURL = nil
        }

        guard let currentEp = currentEpisodeInfo,
              let request = await onRequestNextEpisode?(currentEp, skipper, onCheckingURL, onPreparingPlayback) else {
            StreamifyLogger.log("playNextEpisode: No next episode request returned")
            isTransitioningToNext = false
            return
        }
        guard !Task.isCancelled else { return }
        
        StreamifyLogger.log("playNextEpisode: Transitioning from episode \(currentEpisodeInfo?.episode ?? -1) to episode \(request.episode.episode)")
        
        // Save progress for CURRENT episode before switching (using current episode number)
        if let currentEp = currentEpisodeInfo {
            let currentTime = viewModel.currentTime
            let duration = viewModel.duration
            StreamifyLogger.log("playNextEpisode: Saving progress for current episode \(currentEp.episode): time=\(currentTime)s, duration=\(duration)s")
            
            if currentTime > 0 && duration > 0 {
                let watchingProgress = WatchingProgress(
                    contentId: content.id,
                    seasonIndex: currentEp.season,
                    episodeIndex: currentEp.episode,
                    timestamp: currentTime,
                    duration: duration,
                    lastWatched: Date()
                )
                WatchingProgressManager.updateProgress(watchingProgress)
                NotificationCenter.default.post(name: .watchingProgressUpdated, object: nil)
            }
        }
        
        // Cancel old subscription before setting up new player
        playerReadyCancellable?.cancel()
        playerReadyCancellable = nil
        
        // Stop current playback
        pausePlayback()
        
        // Clear subtitle state from previous episode
        subtitleCues = []
        currentSubtitleText = ""
        
        // Clear audio state from previous episode
        externalAudioPlayer?.pause()
        externalAudioPlayer = nil
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        viewModel.isPlayerMuted = true
        
        // Update state for new episode
        transitionMessage = "Starting..."
        currentVideoURL = request.videoURL
        currentEpisodeInfo = request.episode
        
        // Resolve active quality for the new episode (source badge + picker checkmark)
        let isLocal = request.videoURL.isFileURL || request.videoURL.host == "localhost"
        if isLocal {
            activePlayingQualityName = resolveActiveLocalQualityName()
        } else {
            activePlayingQualityName = nil
            activePlayingQualityId = nil
        }
        
        // Update streaming subtitles for new episode
        currentStreamingSubtitles = request.streamingSubtitles
        
        // Apply preloaded audio tracks if available
        if let preloadedAudio = request.preloadedAudioTracks, !preloadedAudio.isEmpty {
            hlsAudioTracks = preloadedAudio
        } else {
            hlsAudioTracks = []
        }
        
        // Stop the old timer
        stopProgressSaving()
        
        // Setup player with new URL
        let intro = request.episode.intro ?? content.metadata.intro
        let introDur = request.episode.introDuration ?? content.metadata.introDuration
        let end = request.episode.end ?? content.metadata.end
        viewModel.setup(url: request.videoURL, intro: intro, introDuration: introDur, end: end, preloadedQualities: request.preloadedQualities, sourceNames: onlineUrlSourceNames)
        viewModel.isPlayerMuted = !viewModel.isUsingMPVPlayback
        let savedProgress = WatchingProgressManager.getProgress(for: content.id, seasonIndex: request.episode.season, episodeIndex: request.episode.episode)
        let savedTimestamp = savedProgress?.timestamp ?? 0
        let savedDuration = savedProgress?.duration ?? 0
        
        // Show the saved time in the UI immediately
        if savedTimestamp > 0 {
            viewModel.currentTime = savedTimestamp
        }
        if savedDuration > 0 {
            viewModel.duration = savedDuration
        }
        
        StreamifyLogger.log("playNextEpisode: New episode \(request.episode.episode) savedTimestamp=\(savedTimestamp)s")
        
        // Reset processed state
        hasProcessedReadyState = false
        
        // Observe when player is ready
        playerReadyCancellable = Publishers.CombineLatest(viewModel.$isReadyToPlay, viewModel.$duration)
            .filter { isReady, duration in
                isReady && (duration > 0 || viewModel.isUsingMPVPlayback)
            }
            .sink { [weak viewModel] _, readyDuration in
                guard let viewModel = viewModel else { return }
                guard !self.hasProcessedReadyState else { return }
                self.hasProcessedReadyState = true
                
                let duration = max(readyDuration, viewModel.duration, savedDuration)
                StreamifyLogger.log("playNextEpisode: Player ready, duration=\(duration)s")
                
                if savedTimestamp > 0 {
                    let clampedTime = clampedResumeTime(savedTimestamp, duration: duration)
                    StreamifyLogger.log("playNextEpisode: Seeking to \(clampedTime)s (saved=\(savedTimestamp)s)")
                    viewModel.seek(to: clampedTime) {
                        Task { @MainActor in
                            StreamifyLogger.log("playNextEpisode: Seek completed, starting playback")
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.isTransitioningToNext = false
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                        }
                    }
                } else {
                    StreamifyLogger.log("playNextEpisode: No saved progress, seeking to start before restoring audio")
                    viewModel.seek(to: 0) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.isTransitioningToNext = false
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                        }
                    }
                }
            }
        
        // Restart progress timer
        startProgressSaving()
    }

    // MARK: - Add to Library and Play Next
    func addToLibraryAndPlayNext() {
        isTransitioningToNext = true
        transitionMessage = "Adding to library..."
        onlineSwitchFetchingURL = nil

        let skipper = URLCheckSkipper()
        onlineSwitchSkipper = skipper

        nextEpisodeTask?.cancel()
        nextEpisodeTask = Task { @MainActor in
            defer {
                nextEpisodeTask = nil
                onlineSwitchSkipper = nil
                onlineSwitchFetchingURL = nil
            }
            await performAddToLibraryAndPlayNext(skipper: skipper)
        }
    }

    func performAddToLibraryAndPlayNext(skipper: URLCheckSkipper) async {
        let onCheckingURL: @MainActor @Sendable (String) -> Void = { candidate in
            guard self.isTransitioningToNext else { return }
            let maxLen = VideoPlayerView.maxDisplayUrlLength
            let display = candidate.count > maxLen ? "..." + candidate.suffix(VideoPlayerView.displayUrlSuffixLength) : candidate
            self.onlineSwitchFetchingURL = String(display)
        }
        let onPreparingPlayback: @MainActor @Sendable () -> Void = {
            guard self.isTransitioningToNext else { return }
            self.onlineSwitchFetchingURL = nil
        }

        guard let currentEp = currentEpisodeInfo,
              let request = await onAddToLibraryAndRequestNext?(currentEp, skipper, onCheckingURL, onPreparingPlayback) else {
            StreamifyLogger.log("addToLibraryAndPlayNext: No next episode request returned")
            isTransitioningToNext = false
            return
        }
        guard !Task.isCancelled else { return }
        
        // Save progress for CURRENT episode before switching
        if let currentEp = currentEpisodeInfo {
            let realTime = viewModel.realPlaybackTime
            let duration = viewModel.duration
            
            if realTime > 0 && duration > 0 {
                let watchingProgress = WatchingProgress(
                    contentId: content.id,
                    seasonIndex: currentEp.season,
                    episodeIndex: currentEp.episode,
                    timestamp: realTime,
                    duration: duration,
                    lastWatched: Date()
                )
                WatchingProgressManager.updateProgress(watchingProgress)
                NotificationCenter.default.post(name: .watchingProgressUpdated, object: nil)
            }
        }
        
        playerReadyCancellable?.cancel()
        playerReadyCancellable = nil
        pausePlayback()
        
        transitionMessage = "Starting..."
        
        // Clear subtitle state from previous episode
        subtitleCues = []
        currentSubtitleText = ""
        
        // Clear audio state from previous episode
        externalAudioPlayer?.pause()
        externalAudioPlayer = nil
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        viewModel.isPlayerMuted = true
        
        currentVideoURL = request.videoURL
        currentEpisodeInfo = request.episode
        stopProgressSaving()
        
        // Update streaming subtitles for new episode
        currentStreamingSubtitles = request.streamingSubtitles
        
        // Apply preloaded audio tracks if available
        if let preloadedAudio = request.preloadedAudioTracks, !preloadedAudio.isEmpty {
            hlsAudioTracks = preloadedAudio
        } else {
            hlsAudioTracks = []
        }
        
        let intro = request.episode.intro ?? content.metadata.intro
        let introDur = request.episode.introDuration ?? content.metadata.introDuration
        let end = request.episode.end ?? content.metadata.end
        viewModel.setup(url: request.videoURL, intro: intro, introDuration: introDur, end: end, preloadedQualities: request.preloadedQualities, sourceNames: onlineUrlSourceNames)
        viewModel.isPlayerMuted = !viewModel.isUsingMPVPlayback
        
        let savedProgress = WatchingProgressManager.getProgress(for: content.id, seasonIndex: request.episode.season, episodeIndex: request.episode.episode)
        let savedTimestamp = savedProgress?.timestamp ?? 0
        let savedDuration = savedProgress?.duration ?? 0
        
        // Show the saved time in the UI immediately
        if savedTimestamp > 0 {
            viewModel.currentTime = savedTimestamp
        }
        if savedDuration > 0 {
            viewModel.duration = savedDuration
        }
        
        hasProcessedReadyState = false
        
        playerReadyCancellable = Publishers.CombineLatest(viewModel.$isReadyToPlay, viewModel.$duration)
            .filter { isReady, duration in
                isReady && (duration > 0 || viewModel.isUsingMPVPlayback)
            }
            .sink { [weak viewModel] _, readyDuration in
                guard let viewModel = viewModel else { return }
                guard !self.hasProcessedReadyState else { return }
                self.hasProcessedReadyState = true
                
                if savedTimestamp > 0 {
                    let duration = max(readyDuration, viewModel.duration, savedDuration)
                    let clampedTime = clampedResumeTime(savedTimestamp, duration: duration)
                    viewModel.seek(to: clampedTime) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.isTransitioningToNext = false
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                        }
                    }
                } else {
                    StreamifyLogger.log("addToLibraryAndPlayNext: No saved progress, seeking to start before restoring audio")
                    viewModel.seek(to: 0) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.isTransitioningToNext = false
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                        }
                    }
                }
            }
        
        startProgressSaving()
    }
}
