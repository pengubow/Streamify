import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Setup Player
    func setupPlayer() {
        brightness = Double(UIScreen.main.brightness)

        if MatroskaPlaybackSupport.isMatroskaURL(currentVideoURL) {
            if !PlayerViewModel.shouldUseMPVDirectPlayback(for: currentVideoURL) {
                StreamifyLogger.log("VideoPlayerView: Matroska playback unavailable for \(currentVideoURL.lastPathComponent)")
                if !onlineUrls.isEmpty {
                    transitionMessage = "Trying stream..."
                    switchToOnlinePlay()
                    return
                }
            }
        }
        
        // Clear isWatched so that if user rewatches, the continue watching card reappears
        WatchingProgressManager.clearIsWatched(contentId: content.id)
        
        // Check if a locally downloaded file exists (not remote URL fallback)
        // Also check library in case content was opened from Browse but is downloaded
        hasLocalFile = checkHasLocalFile()
        embeddedAudioIsSpatial = false
        
        let intro = currentEpisodeInfo?.intro ?? content.metadata.intro
        let introDur = currentEpisodeInfo?.introDuration ?? content.metadata.introDuration
        let end = currentEpisodeInfo?.end ?? content.metadata.end

        // Set pre-parsed qualities before setup so it can skip re-parsing
        applyDownloadedQualityHDRForCurrentPlayback()
        viewModel.setup(url: currentVideoURL, intro: intro, introDuration: introDur, end: end, preloadedQualities: preloadedQualities, sourceNames: onlineUrlSourceNames)
        viewModel.isPlayerMuted = !viewModel.isUsingMPVPlayback
        applyDownloadedQualityHDRForCurrentPlayback()
        
        // Check for saved progress BEFORE the player is set up
        let seasonNumber = currentEpisodeInfo?.season
        let savedProgress = WatchingProgressManager.getProgress(for: content.id, seasonIndex: seasonNumber, episodeIndex: episodeNumber)
        let savedTimestamp = savedProgress?.timestamp ?? 0
        let savedDuration = savedProgress?.duration ?? 0

        // Show the saved time in the UI immediately (don't show 0:00 until player seeks)
        if savedTimestamp > 0 {
            viewModel.currentTime = savedTimestamp
        }
        if savedDuration > 0 {
            viewModel.duration = savedDuration
        }
        
        StreamifyLogger.log("VideoPlayerView: setupPlayer - contentId=\(content.id), season=\(seasonNumber ?? -1), episodeNumber=\(episodeNumber ?? -1), savedTimestamp=\(savedTimestamp)s")
        
        // Reset processed state for new episode
        hasProcessedReadyState = false
        
        // Observe when player item becomes ready to play AND has valid duration
        playerReadyCancellable = Publishers.CombineLatest(viewModel.$isReadyToPlay, viewModel.$duration)
            .filter { isReady, duration in
                isReady && (duration > 0 || viewModel.isUsingMPVPlayback)
            }
            .sink { [weak viewModel] _, readyDuration in
                guard let viewModel = viewModel else { return }
                
                // Skip if we've already processed this ready state
                guard !self.hasProcessedReadyState else { return }
                self.hasProcessedReadyState = true
                
                let duration = max(readyDuration, viewModel.duration)
                
                if savedTimestamp > 0 {
                    let clampedTime = clampedResumeTime(savedTimestamp, duration: duration)
                    StreamifyLogger.log("VideoPlayerView: Player ready with duration=\(duration)s, seeking to \(clampedTime)s (saved=\(savedTimestamp)s)")
                    
                    // Seek to saved position before starting playback.
                    viewModel.seek(to: clampedTime) {
                        Task { @MainActor in
                            // Restore audio track after seek completes (at the correct position)
                            StreamifyLogger.log("VideoPlayerView: Seek complete, restoring audio and starting playback")
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.restorePlaybackPrerequisitesAfterSeek(shouldStartPlayback: true)
                        }
                    }
                } else {
                    StreamifyLogger.log("VideoPlayerView: No saved progress, seeking to start before restoring audio")
                    viewModel.seek(to: 0) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.restorePlaybackPrerequisitesAfterSeek(shouldStartPlayback: true)
                        }
                    }
                }
            }
        
        // Start saving progress periodically
        startProgressSaving()
        
        // Controls start hidden - no need to schedule hide
        
        // Check embedded audio for spatial audio (EAC-3/Atmos) in HLS streams
        checkEmbeddedAudioForSpatial()
        
        // Parse HLS audio renditions for HLS streams (both remote and local)
        if let preloaded = preloadedAudioTracks, !preloaded.isEmpty {
            // Use pre-parsed audio tracks from ContentDetailView (already parsed before opening player)
            hlsAudioTracks = preloaded
            reapplyAudioAfterTrackDiscovery()
        } else if !hasLocalFile && (currentVideoURL.pathExtension == "m3u8" || currentVideoURL.absoluteString.contains(".m3u8")) {
            // Remote HLS: parse audio from master playlist URL
            Task {
                let result = await PlayerViewModel.parseHLSAudioRenditions(from: currentVideoURL)
                let parsed = result.renditions.map { $0.toAudioTrack(hlsBaseUrl: currentVideoURL.absoluteString) }
                await MainActor.run {
                    hlsAudioTracks = parsed
                    embeddedAudioIsSpatial = result.embeddedAudioIsSpatial
                    // Re-apply selected audio or preferred language now that HLS tracks are available
                    reapplyAudioAfterTrackDiscovery()
                }
            }
        } else if hasLocalFile {
            // Local content: check for saved master.m3u8 and parse audio renditions from it.
            // Falls back to parsing from the remote source HLS URL if no local master exists.
            Task {
                var foundLocal = false
                let folderPaths = buildFolderPaths()
                for folder in folderPaths where !folder.isEmpty {
                    let masterPath = ContentImportService.contentDirectoryURL
                        .appendingPathComponent(folder)
                        .appendingPathComponent("master.m3u8")
                    if FileManager.default.fileExists(atPath: masterPath.path) {
                        let result = await PlayerViewModel.parseHLSAudioRenditions(from: masterPath)
                        let parsed = result.renditions.map { $0.toAudioTrack(hlsBaseUrl: masterPath.absoluteString) }
                        if !parsed.isEmpty {
                            await MainActor.run {
                                hlsAudioTracks = parsed
                                embeddedAudioIsSpatial = result.embeddedAudioIsSpatial
                                reapplyAudioAfterTrackDiscovery()
                            }
                            foundLocal = true
                            break
                        }
                    }
                }
                // Fallback: parse audio from the remote source HLS URL
                if !foundLocal {
                    var remoteURL: URL? = nil
                    if let ep = currentEpisodeInfo {
                        let allSources = SourcesManager.allContent()
                        for sourceContent in allSources where sourceContent.id == content.id {
                            if let epInfo = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode }),
                               let hlsUrl = epInfo.hlsUrl, hlsUrl.hasPrefix("http"), let url = URL(string: hlsUrl) {
                                remoteURL = url; break
                            }
                            if let hlsUrl = sourceContent.hlsUrl, hlsUrl.hasPrefix("http"), let url = URL(string: hlsUrl) {
                                remoteURL = url; break
                            }
                        }
                        if remoteURL == nil, let hlsUrl = ep.hlsUrl, hlsUrl.hasPrefix("http") {
                            remoteURL = URL(string: hlsUrl)
                        }
                        if remoteURL == nil, let hlsUrl = content.metadata.hlsUrl, hlsUrl.hasPrefix("http") {
                            remoteURL = URL(string: hlsUrl)
                        }
                    } else {
                        remoteURL = ContentImportService.remoteHlsURL(for: content)
                        if remoteURL == nil, let hlsUrl = content.metadata.hlsUrl, hlsUrl.hasPrefix("http") {
                            remoteURL = URL(string: hlsUrl)
                        }
                    }
                    if let url = remoteURL {
                        let result = await PlayerViewModel.parseHLSAudioRenditions(from: url)
                        let parsed = result.renditions.map { $0.toAudioTrack(hlsBaseUrl: url.absoluteString) }
                        if !parsed.isEmpty {
                            await MainActor.run {
                                hlsAudioTracks = parsed
                                embeddedAudioIsSpatial = result.embeddedAudioIsSpatial
                                reapplyAudioAfterTrackDiscovery()
                            }
                        }
                    }
                }
            }
        }
        
        // Keep the native embedded output muted; embedded/default audio is
        // rendered by a compensated audio player after the initial seek completes.
        viewModel.isPlayerMuted = !viewModel.isUsingMPVPlayback
        
    }
    
    // Re-apply audio track after HLS audio renditions are discovered
    func reapplyAudioAfterTrackDiscovery() {
        // If already playing external audio, no need to switch
        guard externalAudioPlayer == nil else { return }
        
        // Don't apply audio until the player has processed its ready state
        // (which includes seeking to saved progress). If we apply now,
        // viewModel.currentTime is still 0 and the audio would start from
        // the beginning. restoreAudioTrackAfterPlayerReady() will handle
        // it after the seek completes.
        guard hasProcessedReadyState else { return }

        if shouldPrioritizePreferredMatroskaAudio,
           let preferred = preferredAudioTrack(in: availableAudioTracks) {
            selectedAudioLanguage = preferred.language
            selectedAudioTrackId = preferred.trackId
            applyAudioTrack(preferred)
            return
        }

        if !selectedAudioTrackId.isEmpty {
            if let track = availableAudioTracks.first(where: { $0.trackId == selectedAudioTrackId }) {
                applyAudioTrack(track)
                return
            }
        }
        if !selectedAudioLanguage.isEmpty {
            let matchingTracks = availableAudioTracks.filter {
                !$0.isEmbedded && audioTrack($0, matchesLanguage: selectedAudioLanguage)
            }
            if let track = matchingTracks.first(where: isAudioLocallyAvailable) ?? matchingTracks.first {
                applyAudioTrack(track)
                return
            }
        }
        // Auto-apply preferred audio language
        let preferredLangs = (UserDefaults.standard.string(forKey: "preferredAudioLanguages") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if !preferredLangs.isEmpty {
            let nonEmbedded = availableAudioTracks.filter { !$0.isEmbedded }
            if let preferred = nonEmbedded.first(where: { track in
                preferredLangs.contains { audioTrack(track, matchesLanguage: $0) }
            }) {
                selectedAudioLanguage = preferred.language
                selectedAudioTrackId = preferred.trackId
                applyAudioTrack(preferred)
            }
        }

        if let fallback = fallbackExternalAudioTrack(in: availableAudioTracks) {
            selectedAudioLanguage = fallback.language
            selectedAudioTrackId = fallback.trackId
            applyAudioTrack(fallback)
        }
    }
    
    // Restore previously selected audio track after player is ready and seek completes.
    func restoreAudioTrackAfterPlayerReady(shouldStartPlayback: Bool = false) {
        let tracks = availableAudioTracks

        // If external audio is already playing, re-sync it to the current (post-seek) position
        // instead of bailing. This handles the case where reapplyAudioAfterTrackDiscovery()
        // set up audio before the seek completed (at time 0).
        // Use syncExternalAudio so the seek target is realPlaybackTime and audio
        // only resumes after the video player is actually started.
        if externalAudioPlayer != nil {
            let shouldPlay = shouldStartPlayback || viewModel.playbackRate > 0
            StreamifyLogger.log("Audio: Re-syncing existing external audio after player ready (shouldPlay=\(shouldPlay))")
            syncExternalAudio(shouldResume: shouldPlay)
            return
        }

        if shouldPrioritizePreferredMatroskaAudio,
           let preferred = preferredAudioTrack(in: tracks) {
            selectedAudioLanguage = preferred.language
            selectedAudioTrackId = preferred.trackId
            StreamifyLogger.log("Audio: Auto-applying preferred Matroska audio language \(preferred.language)")
            applyAudioTrack(preferred, shouldResume: shouldStartPlayback)
            return
        }

        // Try to restore previously selected track by trackId
        if !selectedAudioTrackId.isEmpty {
            if let track = tracks.first(where: { $0.trackId == selectedAudioTrackId }) {
                StreamifyLogger.log("Audio: Restoring previously selected audio track \(track.language) after player ready")
                applyAudioTrack(track, shouldResume: shouldStartPlayback)
                return
            }
        }
        // Try to restore by language
        if !selectedAudioLanguage.isEmpty {
            let matchingTracks = tracks.filter {
                !$0.isEmbedded && audioTrack($0, matchesLanguage: selectedAudioLanguage)
            }
            if let track = matchingTracks.first(where: isAudioLocallyAvailable) ?? matchingTracks.first {
                StreamifyLogger.log("Audio: Restoring previously selected audio language \(track.language) after player ready")
                applyAudioTrack(track, shouldResume: shouldStartPlayback)
                return
            }
        }
        // Auto-apply preferred audio language if no track is explicitly selected
        let preferredLangs = (UserDefaults.standard.string(forKey: "preferredAudioLanguages") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if !preferredLangs.isEmpty {
            let nonEmbedded = tracks.filter { !$0.isEmbedded }
            if let preferred = nonEmbedded.first(where: { track in
                preferredLangs.contains { audioTrack(track, matchesLanguage: $0) }
            }) {
                selectedAudioLanguage = preferred.language
                selectedAudioTrackId = preferred.trackId
                StreamifyLogger.log("Audio: Auto-applying preferred audio language \(preferred.language) after player ready")
                applyAudioTrack(preferred, shouldResume: shouldStartPlayback)
                return
            }
        }
        if let fallback = fallbackExternalAudioTrack(in: tracks) {
            selectedAudioLanguage = fallback.language
            selectedAudioTrackId = fallback.trackId
            StreamifyLogger.log("Audio: Auto-applying available HLS audio \(fallback.language) after player ready")
            applyAudioTrack(fallback, shouldResume: shouldStartPlayback)
            return
        }
        // No matching track found — falling back to embedded audio.
        // Clear stale persisted values so the embedded option shows a checkmark.
        let hasAnyExternalTrack = tracks.contains { !$0.isEmbedded }
        if hasAnyExternalTrack && (!selectedAudioLanguage.isEmpty || !selectedAudioTrackId.isEmpty) {
            StreamifyLogger.log("Audio: Previously selected track not available — clearing selection, falling back to embedded")
            selectedAudioLanguage = ""
            selectedAudioTrackId = ""
        }
        applyAudioTrack(nil, shouldResume: shouldStartPlayback)
    }

    func audioTrack(_ track: AudioTrack, matchesLanguage language: String) -> Bool {
        let requested = normalizedAudioLanguage(language)
        let candidates = [track.language, track.languageId, track.name]
            .compactMap { $0 }
            .map(normalizedAudioLanguage)
        return candidates.contains(requested)
    }

    var shouldPrioritizePreferredMatroskaAudio: Bool {
        viewModel.isUsingMPVPlayback && MatroskaPlaybackSupport.isMatroskaURL(currentVideoURL)
    }

    func preferredAudioTrack(in tracks: [AudioTrack]) -> AudioTrack? {
        let preferredLangs = (UserDefaults.standard.string(forKey: "preferredAudioLanguages") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !preferredLangs.isEmpty else { return nil }

        let candidates = tracks.filter { !$0.isEmbedded }
        for language in preferredLangs {
            let matchingTracks = candidates.filter { audioTrack($0, matchesLanguage: language) }
            if let local = matchingTracks.first(where: isAudioLocallyAvailable) {
                return local
            }
            if let first = matchingTracks.first {
                return first
            }
        }
        return nil
    }

    func fallbackExternalAudioTrack(in tracks: [AudioTrack]) -> AudioTrack? {
        guard viewModel.isLocalFile, viewModel.isHLS else { return nil }
        let externalTracks = tracks.filter { !$0.isEmbedded }
        return externalTracks.first(where: isAudioLocallyAvailable) ?? externalTracks.first
    }

    func normalizedAudioLanguage(_ value: String) -> String {
        let tokens = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let aliases: [String: String] = [
            "en": "en", "eng": "en", "english": "en",
            "hi": "hi", "hin": "hi", "hindi": "hi",
            "es": "es", "spa": "es", "esp": "es", "spanish": "es",
            "fr": "fr", "fre": "fr", "fra": "fr", "french": "fr",
            "de": "de", "ger": "de", "deu": "de", "german": "de",
            "ja": "ja", "jpn": "ja", "japanese": "ja",
            "ko": "ko", "kor": "ko", "korean": "ko",
            "zh": "zh", "chi": "zh", "zho": "zh", "chinese": "zh",
            "pt": "pt", "por": "pt", "portuguese": "pt",
            "it": "it", "ita": "it", "italian": "it",
            "ru": "ru", "rus": "ru", "russian": "ru"
        ]
        for token in tokens {
            if let normalized = aliases[token] {
                return normalized
            }
        }
        return tokens.first ?? value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func restorePlaybackPrerequisitesAfterSeek(shouldStartPlayback: Bool) {
        restoreSubtitleTrackAfterPlayerReady {
            self.restoreAudioTrackAfterPlayerReady(shouldStartPlayback: shouldStartPlayback)
        }
    }

    // Restore previously selected subtitle track after player is ready.
    func restoreSubtitleTrackAfterPlayerReady(completion: @escaping @MainActor () -> Void = {}) {
        if !selectedSubtitleTrackId.isEmpty,
           let track = availableSubtitles.first(where: { $0.trackId == selectedSubtitleTrackId }) {
            applySubtitleTrack(track, completion: completion)
            return
        }
        guard !selectedSubtitleLanguage.isEmpty else {
            completion()
            return
        }
        if let track = availableSubtitles.first(where: { $0.language == selectedSubtitleLanguage }) {
            selectedSubtitleTrackId = track.trackId
            applySubtitleTrack(track, completion: completion)
        } else {
            completion()
        }
    }

    // MARK: - Spatial Audio Detection
    func checkEmbeddedAudioForSpatial() {
        guard let asset = viewModel.asset ?? viewModel.playerItem?.asset else { return }
        Task {
            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                for audioTrack in audioTracks {
                    let descriptions = try await audioTrack.load(.formatDescriptions)
                    for desc in descriptions {
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                        // EAC-3 (Enhanced AC-3 / Dolby Digital Plus / Dolby Atmos)
                        // kAudioFormatEnhancedAC3 = 'ec-3' = 0x65632D33
                        // AC-3 (Dolby Digital) can also carry spatial audio metadata
                        // kAudioFormatAC3 = 'ac-3' = 0x61632D33
                        if mediaSubType == kAudioFormatEnhancedAC3 || mediaSubType == kAudioFormatAC3 {
                            let codecName = mediaSubType == kAudioFormatEnhancedAC3 ? "EAC-3" : "AC-3"
                            await MainActor.run {
                                embeddedAudioIsSpatial = true
                                StreamifyLogger.log("Audio: Detected spatial audio (\(codecName)/Atmos) in embedded stream")
                            }
                            return
                        }
                    }
                }
            } catch {
                StreamifyLogger.log("Audio: Failed to check embedded audio codecs: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Progress saving
    
    func startProgressSaving() {
        saveProgressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                self.saveProgress()
            }
        }
    }
    
    func stopProgressSaving() {
        saveProgressTimer?.invalidate()
        saveProgressTimer = nil
    }
    
    func saveProgress() {
        guard !viewModel.hasAccessDeniedPlayback else {
            StreamifyLogger.log("saveProgress: skipped because source is Torrentio failed-access video")
            return
        }

        // Use realPlaybackTime so we save the actual player position.
        let realTime = viewModel.realPlaybackTime
        let duration = viewModel.duration
        
        // Save if we have valid time and duration
        guard realTime > 0 && duration > 0 else { return }

        if !isInLibrary {
            ensureInLibrary()
        }
        
        let epNumber = episodeNumber
        let seasonNumber = currentEpisodeInfo?.season
        
        StreamifyLogger.log("saveProgress: contentId=\(content.id), season=\(seasonNumber ?? -1), episode=\(epNumber ?? -1), time=\(realTime)s (raw=\(viewModel.currentTime)s), duration=\(duration)s")
        
        let watchingProgress = WatchingProgress(
            contentId: content.id,
            seasonIndex: seasonNumber,
            episodeIndex: epNumber,
            timestamp: realTime,
            duration: duration,
            lastWatched: Date()
        )
        
        WatchingProgressManager.updateProgress(watchingProgress)
        
        // Post notification so other views can refresh
        NotificationCenter.default.post(name: .watchingProgressUpdated, object: nil)
    }
    
    /// Handle end-of-playback: if progress reached the end, mark as watched or advance to next episode
    func handleEndOfPlayback() {
        guard !viewModel.hasAccessDeniedPlayback else { return }
        let realTime = viewModel.realPlaybackTime
        let duration = viewModel.duration
        guard realTime > 0 && duration > 0 else { return }
        
        let progress = WatchingProgress(
            contentId: content.id,
            seasonIndex: currentEpisodeInfo?.season,
            episodeIndex: episodeNumber,
            timestamp: realTime,
            duration: duration,
            lastWatched: Date()
        )
        
        // Use the metadata `end` field (absolute timestamp from start at which content ends)
        let endTimestamp = currentEpisodeInfo?.end ?? content.metadata.end
        guard progress.hasReachedEnd(endTimestamp: endTimestamp) else { return }
        
        // Gather all episodes from combined data (sources + metadata)
        let allEpisodes = content.metadata.allEpisodes
        
        WatchingProgressManager.handlePlaybackEnd(
            contentId: content.id,
            progress: progress,
            allEpisodes: allEpisodes,
            contentType: content.metadata.type,
            endTimestamp: endTimestamp
        )
        
        // Post notification to refresh continue watching
        NotificationCenter.default.post(name: .watchingProgressUpdated, object: nil)
    }
}
