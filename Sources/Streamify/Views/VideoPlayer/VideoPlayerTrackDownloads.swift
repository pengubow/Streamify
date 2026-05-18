import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Download track locally from picker

    /// Find a matching in-progress track download from DownloadManager for the given track type and language.
    /// Returns the TrackDownloadItem if found and currently downloading.
    /// For series, also matches on the current episode to avoid cross-episode false positives.
    func findMatchingTrackDownload(trackType: String, language: String, sourceUrl: String? = nil) -> TrackDownloadItem? {
        let ep = currentEpisodeInfo
        return downloadManager.trackDownloads.first { item in
            item.contentId == content.id &&
            item.trackType == trackType &&
            item.language == language &&
            item.status == .downloading &&
            item.episodeNumber == ep?.episode &&
            item.seasonNumber == ep?.season &&
            (sourceUrl == nil || item.sourceUrl == sourceUrl)
        }
    }

    /// Find a main DownloadManager download (from ContentDetailView) for the current content/episode.
    /// When qualityName/sourceName are provided, finds a download matching that specific quality.
    /// Otherwise returns any active download for this content.
    func findMatchingMainDownload(qualityName: String? = nil, sourceName: String? = nil, sourceUrl: String? = nil) -> DownloadItem? {
        let ep = currentEpisodeInfo
        let contentFilter: (DownloadItem) -> Bool
        if let ep = ep {
            let episodeDownloadId = "\(content.id)_ep\(ep.episode)"
            contentFilter = { item in
                item.contentId == episodeDownloadId &&
                (item.status == .downloading || item.status == .queued || item.status == .pending || item.status == .paused)
            }
        } else {
            contentFilter = { item in
                item.contentId == self.content.id &&
                (item.status == .downloading || item.status == .queued || item.status == .pending || item.status == .paused)
            }
        }
        let matching = downloadManager.downloads.filter(contentFilter)
        if let sourceUrl,
           let sourceMatch = matching.first(where: { mainDownload($0, matchesSourceUrl: sourceUrl, sourceName: sourceName) }) {
            return sourceMatch
        }
        if isTorrentioSource(sourceName: sourceName, urlString: sourceUrl) {
            return nil
        }
        if let qn = qualityName {
            // Try to find a download matching this specific quality
            if let exact = matching.first(where: { $0.qualityName == qn && $0.sourceName == sourceName }) {
                return exact
            }
            // Fall back to any download with matching quality name (for "Auto" row)
            return nil
        }
        return matching.first
    }

    func mainDownload(_ item: DownloadItem, matchesSourceUrl sourceUrl: String, sourceName: String?) -> Bool {
        if item.videoUrl == sourceUrl {
            return true
        }
        guard isTorrentioSource(sourceName: sourceName, urlString: sourceUrl) ||
                isTorrentioSource(sourceName: item.sourceName, urlString: item.videoUrl) else {
            return false
        }
        return torrentioSourceUrlsMatch(sourceUrl, item.videoUrl)
    }

    func downloadedQuality(_ quality: DownloadedVideoQuality, matchesSourceUrl sourceUrl: String, sourceName: String?) -> Bool {
        guard let downloadedSourceUrl = quality.sourceUrl else { return false }
        if downloadedSourceUrl == sourceUrl {
            return true
        }
        guard isTorrentioSource(sourceName: sourceName, urlString: sourceUrl) ||
                isTorrentioSource(sourceName: quality.sourceName, urlString: downloadedSourceUrl) else {
            return false
        }
        return torrentioSourceUrlsMatch(sourceUrl, downloadedSourceUrl)
    }

    func torrentioSourceUrlsMatch(_ requestedUrl: String, _ existingUrl: String) -> Bool {
        guard let requested = TorrentioService.streamIdentity(from: requestedUrl),
              let existing = TorrentioService.streamIdentity(from: existingUrl) else {
            return false
        }
        if let requestedHash = requested.infoHash,
           let existingHash = existing.infoHash,
           requestedHash == existingHash {
            if let requestedIndex = requested.fileIndex,
               let existingIndex = existing.fileIndex {
                return requestedIndex == existingIndex
            }
            return requested.fileName == nil || existing.fileName == nil || requested.fileName == existing.fileName
        }
        return requested.fileName != nil && requested.fileName == existing.fileName
    }

    func isTorrentioSource(sourceName: String?, urlString: String?) -> Bool {
        if sourceName?.localizedCaseInsensitiveContains("Torrentio") == true {
            return true
        }
        return urlString?.localizedCaseInsensitiveContains("torrentio.strem.fun") == true
    }

    func cancelPickerDownload() {
        downloadingTrackTask?.cancel()
        downloadingTrackTask = nil
        if let id = downloadingTrackId {
            DownloadManager.shared.cancelTrackDownload(id: id)
        }
        resetTrackDownloadState()
    }

    func pausePickerDownload() {
        downloadingTrackTask?.cancel()
        downloadingTrackTask = nil
        if let id = downloadingTrackId {
            DownloadManager.shared.pauseTrackDownload(id: id)
        }
        resetTrackDownloadState()
    }

    /// Reset the track download UI state variables back to idle.
    func resetTrackDownloadState() {
        downloadingTrackLanguage = nil
        downloadingTrackProgress = 0
        downloadingTrackTask = nil
        downloadingTrackId = nil
    }

    /// Resolve the TMDB ID for the current content, checking metadata and source data.
    /// Mirrors the logic in ContentDetailView.resolveTmdbId() for consistency.
    func resolveTmdbId() -> Int? {
        PlaybackResolver.resolveTmdbId(for: content)
    }

    func ensureInLibrary() {
        // If not in library, add with a proper folderPath
        let library = ContentImportService.loadLibrary()
        if !library.contains(where: { $0.id == content.id }) {
            let safeId = content.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content.id
            let folderPath = content.folderPath.isEmpty ? safeId : content.folderPath
            let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let properContent = SavedContent(
                id: content.id,
                metadata: content.metadata,
                folderPath: folderPath,
                dateAdded: Date()
            )
            ContentImportService.addToLibrary(properContent)
        }
    }

    // Resolve the effective folderPath (handles empty folderPath from source content)
    var effectiveFolderPath: String {
        if !content.folderPath.isEmpty { return content.folderPath }
        return content.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content.id
    }

    func downloadTrackLocally(subtitle track: SubtitleTrack) {
        guard resolveRemoteSubtitleURL(for: track) != nil else { return }
        downloadingTrackLanguage = track.language
        downloadingTrackProgress = 0

        // Ensure content is in library BEFORE registering the download,
        // so metadata exists on disk and DownloadsView can resolve thumbnails
        if !isInLibrary {
            ensureInLibrary()
        }

        // Register with DownloadManager for visibility in DownloadsView
        // Compute destination info upfront so it's persisted for resume
        let folderPath: String
        if let ep = currentEpisodeInfo {
            folderPath = resolveEpisodeFolderPath(for: ep)
        } else {
            folderPath = effectiveFolderPath
        }
        let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
        let metadataFolder = effectiveFolderPath

        let trackDownloadId = DownloadManager.shared.addTrackDownload(
            contentId: content.id,
            contentTitle: content.metadata.title,
            trackType: "subtitle",
            language: track.displayName,
            episodeInfo: currentEpisodeInfo,
            downloadURL: track.source,
            destFolderPath: folderPath,
            filePrefix: prefix,
            metadataFolder: metadataFolder,
            trackId: track.trackId,
            languageId: track.languageId
        )
        DownloadManager.shared.startTrackDownload(id: trackDownloadId)
        downloadingTrackId = trackDownloadId

        let task = Task {

            let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            do {
                let localName = try await DownloadManager.shared.downloadSingleSubtitleTrack(
                    track: track, to: destDir, prefix: prefix,
                    onProgress: { progress in
                        Task { @MainActor in
                            downloadingTrackProgress = progress
                            DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                        }
                    }
                )

                guard let fileName = localName else {
                    await MainActor.run {
                        resetTrackDownloadState()
                        DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid")
                    }
                    return
                }

                await MainActor.run {
                    updateTrackInMetadata(metadataFolder: metadataFolder, subtitleLanguage: track.language, localSource: fileName, sourceName: track.sourceName)
                    resetTrackDownloadState()
                    pickerRefreshId += 1
                    DownloadManager.shared.completeTrackDownload(id: trackDownloadId)
                    DownloadManager.shared.libraryRefreshNeeded = true
                    NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                    StreamifyLogger.log("Subtitle: Downloaded \(track.language) locally -> \(fileName)")
                }
            } catch {
                await MainActor.run {
                    let wasPaused = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId })?.status == .paused
                    if wasPaused {
                        StreamifyLogger.log("Subtitle: Download paused for \(track.language)")
                    } else {
                        resetTrackDownloadState()
                        if !(error is CancellationError) {
                            DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: error.localizedDescription)
                        }
                        StreamifyLogger.log("Subtitle: Failed to download \(track.language): \(error.localizedDescription)")
                    }
                }
            }
        }
        downloadingTrackTask = task
        // Store task reference on the track download item for external cancellation
        if let item = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId }) {
            item.downloadTask = task
        }
    }

    func downloadTrackLocally(audio track: AudioTrack) {
        guard let url = resolveRemoteAudioURL(for: track) else { return }
        downloadingTrackLanguage = track.language
        downloadingTrackProgress = 0

        // Ensure content is in library BEFORE registering the download,
        // so metadata exists on disk and DownloadsView can resolve thumbnails
        if !isInLibrary {
            ensureInLibrary()
        }

        // Register with DownloadManager for visibility in DownloadsView
        // Compute destination info upfront so it's persisted for resume
        let folderPath: String
        if let ep = currentEpisodeInfo {
            folderPath = resolveEpisodeFolderPath(for: ep)
        } else {
            folderPath = effectiveFolderPath
        }
        let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
        let metadataFolder = effectiveFolderPath
        let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")

        let trackDownloadId = DownloadManager.shared.addTrackDownload(
            contentId: content.id,
            contentTitle: content.metadata.title,
            trackType: "audio",
            language: track.displayName,
            episodeInfo: currentEpisodeInfo,
            downloadURL: track.source,
            destFolderPath: folderPath,
            filePrefix: prefix,
            metadataFolder: metadataFolder,
            trackId: track.trackId,
            languageId: track.languageId,
            isHLS: isHLS
        )
        DownloadManager.shared.startTrackDownload(id: trackDownloadId)
        downloadingTrackId = trackDownloadId

        let task = Task {

            let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            do {
                let localSource: String
                if isHLS {
                    // HLS audio: download playlist + segments via DownloadManager helper
                    localSource = try await DownloadManager.shared.downloadHLSAudioPlaylist(
                        from: url, track: track, to: destDir, prefix: prefix,
                        download: nil, downloadedCount: 0, totalToDownload: 1,
                        onProgress: { progress in
                            Task { @MainActor in
                                downloadingTrackProgress = progress
                                DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                            }
                        }
                    )
                } else {
                    // Single file audio — use shared helper
                    guard let name = try await DownloadManager.shared.downloadSingleAudioFile(
                        track: track, to: destDir, prefix: prefix,
                        onProgress: { progress in
                            Task { @MainActor in
                                downloadingTrackProgress = progress
                                DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                            }
                        }
                    ) else {
                        await MainActor.run {
                            resetTrackDownloadState()
                            DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid")
                        }
                        return
                    }
                    localSource = name
                }

                await MainActor.run {
                    updateTrackInMetadata(metadataFolder: metadataFolder, audioLanguage: track.language, localSource: localSource, sourceName: track.sourceName)
                    resetTrackDownloadState()
                    pickerRefreshId += 1
                    DownloadManager.shared.completeTrackDownload(id: trackDownloadId)
                    DownloadManager.shared.libraryRefreshNeeded = true
                    NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                    StreamifyLogger.log("Audio: Downloaded \(track.language) locally -> \(localSource)")
                }
            } catch {
                await MainActor.run {
                    let wasPaused = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId })?.status == .paused
                    if wasPaused {
                        StreamifyLogger.log("Audio: Download paused for \(track.language)")
                    } else {
                        resetTrackDownloadState()
                        if !(error is CancellationError) {
                            DownloadManager.shared.failTrackDownload(id: trackDownloadId, error: error.localizedDescription)
                        }
                        StreamifyLogger.log("Audio: Failed to download \(track.language): \(error.localizedDescription)")
                    }
                }
            }
        }
        downloadingTrackTask = task
        // Store task reference on the track download item for external cancellation
        if let item = DownloadManager.shared.trackDownloads.first(where: { $0.id == trackDownloadId }) {
            item.downloadTask = task
        }
    }

    // Generic metadata update for downloaded subtitle/audio tracks
    func updateTrackInMetadata(metadataFolder: String, subtitleLanguage: String? = nil, audioLanguage: String? = nil, localSource: String, sourceName: String? = nil) {
        guard var metadata = ContentImportService.loadMetadata(from: metadataFolder) else { return }

        if let ep = currentEpisodeInfo {
            // Update episodes in seasons
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var eps = seasons[sIdx].episodes {
                        for eIdx in eps.indices {
                            if seasons[sIdx].season == ep.season && eps[eIdx].episode == ep.episode {
                                var subs = eps[eIdx].subtitles
                                var audio = eps[eIdx].audioTracks
                                if let lang = subtitleLanguage {
                                    var s = subs ?? []
                                    if let i = s.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                                        s[i] = SubtitleTrack(language: lang, source: localSource, languageId: s[i].languageId, name: s[i].name, trackId: s[i].trackId, sourceName: sourceName ?? s[i].sourceName)
                                    } else {
                                        s.append(SubtitleTrack(language: lang, source: localSource, sourceName: sourceName))
                                    }
                                    subs = s
                                }
                                if let lang = audioLanguage {
                                    var a = audio ?? []
                                    if let i = a.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                                        a[i] = AudioTrack(language: lang, source: localSource, isSpatial: a[i].isSpatial, languageId: a[i].languageId, name: a[i].name, trackId: a[i].trackId, sourceName: sourceName ?? a[i].sourceName)
                                    } else {
                                        a.append(AudioTrack(language: lang, source: localSource, sourceName: sourceName))
                                    }
                                    audio = a
                                }
                                eps[eIdx] = eps[eIdx].copying(subtitles: subs, audioTracks: audio)
                            }
                        }
                        seasons[sIdx] = SeasonInfo(season: seasons[sIdx].season, title: seasons[sIdx].title,
                                                    thumbnailUrl: seasons[sIdx].thumbnailUrl, episodes: eps)
                    }
                }
                metadata = metadata.copying(seasons: seasons)
            }
            // Also update flat episodes
            if var episodes = metadata.episodes {
                for eIdx in episodes.indices {
                    if episodes[eIdx].season == ep.season && episodes[eIdx].episode == ep.episode {
                        var subs = episodes[eIdx].subtitles
                        var audio = episodes[eIdx].audioTracks
                        if let lang = subtitleLanguage {
                            var s = subs ?? []
                            if let i = s.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                                s[i] = SubtitleTrack(language: lang, source: localSource, languageId: s[i].languageId, name: s[i].name, trackId: s[i].trackId, sourceName: sourceName ?? s[i].sourceName)
                            } else {
                                s.append(SubtitleTrack(language: lang, source: localSource, sourceName: sourceName))
                            }
                            subs = s
                        }
                        if let lang = audioLanguage {
                            var a = audio ?? []
                            if let i = a.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                                a[i] = AudioTrack(language: lang, source: localSource, isSpatial: a[i].isSpatial, languageId: a[i].languageId, name: a[i].name, trackId: a[i].trackId, sourceName: sourceName ?? a[i].sourceName)
                            } else {
                                a.append(AudioTrack(language: lang, source: localSource, sourceName: sourceName))
                            }
                            audio = a
                        }
                        episodes[eIdx] = episodes[eIdx].copying(subtitles: subs, audioTracks: audio)
                    }
                }
                metadata = metadata.copying(episodes: episodes)
            }
        } else {
            // Movie - update content-level tracks
            if let lang = subtitleLanguage {
                var subs = metadata.subtitles ?? []
                if let i = subs.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                    subs[i] = SubtitleTrack(language: lang, source: localSource, languageId: subs[i].languageId, name: subs[i].name, trackId: subs[i].trackId, sourceName: sourceName ?? subs[i].sourceName)
                } else {
                    subs.append(SubtitleTrack(language: lang, source: localSource, sourceName: sourceName))
                }
                metadata = metadata.copying(subtitles: subs)
            }
            if let lang = audioLanguage {
                var tracks = metadata.audioTracks ?? []
                if let i = tracks.firstIndex(where: { $0.language.lowercased() == lang.lowercased() }) {
                    tracks[i] = AudioTrack(language: lang, source: localSource, isSpatial: tracks[i].isSpatial, languageId: tracks[i].languageId, name: tracks[i].name, trackId: tracks[i].trackId, sourceName: sourceName ?? tracks[i].sourceName)
                } else {
                    tracks.append(AudioTrack(language: lang, source: localSource, sourceName: sourceName))
                }
                metadata = metadata.copying(audioTracks: tracks)
            }
        }

        ContentImportService.saveMetadata(metadata, to: metadataFolder)
        DownloadManager.shared.refreshLocalMasterPlaylist(metadataFolder: metadataFolder, episode: currentEpisodeInfo)
    }

    // Sync external audio player with video player
    /// Sync external audio player position to current video time.
    /// - Parameter shouldResume: Override for play state. Pass `true` when the video
    ///   is temporarily paused (e.g. during a seek/skip) but WILL resume, so external
    ///   audio should also resume after syncing. When `nil`, uses current isPlaying state.
    func syncExternalAudio(shouldResume: Bool? = nil) {
        guard let audioPlayer = externalAudioPlayer else { return }
        let willPlay = shouldResume ?? (viewModel.isPlaying || viewModel.playbackRate > 0)
        guard willPlay || viewModel.customEngine != nil else { return }
        syncAudioPlayerToVideo(audioPlayer, shouldResume: willPlay)
    }

    func resumeWithAudioPlayer(_ audioPlayer: AVPlayer, at videoSeconds: Double) {
        syncAudioPlayerToVideo(audioPlayer, at: videoSeconds, shouldResume: true)
    }

    func playWithSyncedAudio() {
        guard !pausePlaybackForPresentedPicker() else { return }
        if viewModel.isUsingMPVPlayback {
            if externalAudioPlayer != nil {
                viewModel.isPlayerMuted = true
                viewModel.disableMPVAudioOutput()
                syncExternalAudio(shouldResume: true)
                return
            }
            viewModel.isPlayerMuted = false
            viewModel.play()
            return
        }
        restoreSeparateAudioBuffers()

        if hasSeparateAudioPlayer {
            syncSeparateAudio(shouldResume: true)
            return
        }

        guard !isEmbeddedAudioDisabled else {
            viewModel.play()
            return
        }

        startCompensatedEmbeddedAudio(shouldResume: true)
    }

    func pausePlayback() {
        skipBurstShouldResume = false
        cancelSkipAudioSyncTasks()
        cancelPendingAudioSync()
        viewModel.pause()
        pauseSeparateAudio()
        trimSeparateAudioBuffers()
    }

    var hasSeparateAudioPlayer: Bool {
        externalAudioPlayer != nil || embeddedAudioPlayer != nil
    }

    func ownsSeparateAudioPlayer(_ audioPlayer: AVPlayer) -> Bool {
        externalAudioPlayer === audioPlayer || embeddedAudioPlayer === audioPlayer
    }

    func pauseSeparateAudio(cancelSync: Bool = true) {
        if cancelSync {
            cancelPendingAudioSync()
        }
        externalAudioPlayer?.pause()
        embeddedAudioPlayer?.pause()
    }

    /// Shrink each separate audio player's forward buffer to 1 s while paused.
    func trimSeparateAudioBuffers() {
        externalAudioPlayer?.currentItem?.preferredForwardBufferDuration = 1
        embeddedAudioPlayer?.currentItem?.preferredForwardBufferDuration = 1
    }

    /// Restore each separate audio player's forward buffer to its normal playing value.
    func restoreSeparateAudioBuffers() {
        // Restore to 30 s — matches the value set at audio player creation for HLS.
        // For non-HLS items the buffer was 0 (auto); 30 is safe and bounded for both.
        externalAudioPlayer?.currentItem?.preferredForwardBufferDuration = 30
        embeddedAudioPlayer?.currentItem?.preferredForwardBufferDuration = 30
    }

    @discardableResult
    func resumeSeparateAudio(at videoSeconds: Double) -> Bool {
        guard let audioPlayer = externalAudioPlayer ?? embeddedAudioPlayer else {
            return false
        }
        resumeWithAudioPlayer(audioPlayer, at: videoSeconds)
        return true
    }

    func syncSeparateAudio(shouldResume: Bool) {
        if shouldResume {
            guard !pausePlaybackForPresentedPicker() else { return }
        }

        if externalAudioPlayer != nil {
            syncExternalAudio(shouldResume: shouldResume)
        } else if embeddedAudioPlayer != nil {
            syncCompensatedEmbeddedAudioIfNeeded(force: true, shouldResume: shouldResume)
        }
    }

    func makeCompensatedEmbeddedAudioPlayer(for url: URL) -> AVPlayer {
        let asset: AVURLAsset
        if VidLinkService.isVidLinkProxyURL(url.absoluteString) {
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Referer": VidLinkService.vidLinkReferer]
            ])
        } else {
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        if url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.localizedCaseInsensitiveContains(".m3u8") {
            item.preferredForwardBufferDuration = 30
        }

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return player
    }

    func disableVideoTracks(on item: AVPlayerItem) {
        for track in item.tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = false
        }
    }

    func observeCompensatedEmbeddedAudio(_ audioPlayer: AVPlayer) {
        guard let item = audioPlayer.currentItem else { return }

        disableVideoTracks(on: item)
        let statusObserver = item.observe(\.status, options: [.initial, .new]) { [self, weak audioPlayer] observedItem, _ in
            DispatchQueue.main.async {
                guard let audioPlayer, self.embeddedAudioPlayer === audioPlayer else { return }
                self.disableVideoTracks(on: observedItem)
                if observedItem.status == .failed {
                    let errorMsg = observedItem.error?.localizedDescription ?? "unknown error"
                    StreamifyLogger.log("Audio: Compensated embedded audio failed: \(errorMsg)")
                    self.stopCompensatedEmbeddedAudio(unmuteMain: true)
                    if !self.pausePlaybackForPresentedPicker() {
                        self.viewModel.play()
                    }
                }
            }
        }
        embeddedAudioObservers = [statusObserver]

        DispatchQueue.main.async {
            guard self.embeddedAudioPlayer === audioPlayer, let item = audioPlayer.currentItem else { return }
            self.disableVideoTracks(on: item)
        }
    }

    func stopCompensatedEmbeddedAudio(unmuteMain: Bool = true) {
        embeddedAudioObservers.removeAll()
        embeddedAudioPlayer?.pause()
        embeddedAudioPlayer = nil

        if unmuteMain && externalAudioPlayer == nil && !isEmbeddedAudioDisabled {
            viewModel.isPlayerMuted = false
        }
    }

    func startCompensatedEmbeddedAudio(shouldResume: Bool) {
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        viewModel.isPlayerMuted = true

        guard !isEmbeddedAudioDisabled else { return }

        // Use the actual URL the engine loaded (e.g. a specific HLS variant playlist),
        // not currentVideoURL which for online HDR streams is the master manifest.
        // Loading a master manifest as the secondary audio player causes AVFoundation to fail
        // when video tracks are disabled and no audio-only rendition can be selected.
        // IMPORTANT: Do not revert to currentVideoURL — it breaks HDR stream audio entirely.
        let actualURL = (viewModel.asset as? AVURLAsset)?.url ?? currentVideoURL
        let audioPlayer = makeCompensatedEmbeddedAudioPlayer(for: actualURL)
        embeddedAudioPlayer = audioPlayer
        observeCompensatedEmbeddedAudio(audioPlayer)

        if shouldResume {
            syncAudioPlayerToVideo(audioPlayer, shouldResume: true)
        } else {
            audioPlayer.seek(to: Self.exactPlayerTime(for: resolvedAudioSyncTarget(nil)), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func syncCompensatedEmbeddedAudioIfNeeded(force: Bool = false, shouldResume: Bool? = nil) {
        guard let audioPlayer = embeddedAudioPlayer, externalAudioPlayer == nil else { return }

        let willPlay = shouldResume ?? (viewModel.playbackRate > 0)
        guard force || willPlay else { return }

        let videoSeconds = force ? resolvedAudioSyncTarget(nil) : viewModel.realPlaybackTime
        let targetAudioSeconds = max(videoSeconds, 0)
        let currentAudioSeconds = CMTimeGetSeconds(audioPlayer.currentTime())
        let audioIsValid = currentAudioSeconds.isFinite
        let diff = audioIsValid ? abs(currentAudioSeconds - targetAudioSeconds) : .infinity

        if force {
            syncAudioPlayerToVideo(audioPlayer, shouldResume: willPlay)
            return
        }

        guard diff > Self.embeddedAudioSyncThreshold else {
            return
        }

        audioPlayer.pause()
        audioPlayer.seek(to: Self.exactPlayerTime(for: targetAudioSeconds), toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
            DispatchQueue.main.async {
                guard let audioPlayer, self.embeddedAudioPlayer === audioPlayer else { return }
                if willPlay && !self.viewModel.isBuffering && !self.isPickerOrSwitchAlertPresented {
                    audioPlayer.play()
                }
            }
        }
    }


    // Re-apply audio for current episode after transition
    func reapplyAudioForCurrentEpisode(shouldStartPlayback: Bool = false) {
        // Stop separate audio players from the previous item.
        externalAudioPlayer?.pause()
        externalAudioPlayer = nil
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        audioBufferingObservers.removeAll()
        isAudioBuffering = false

        let tracks = availableAudioTracks

        if tracks.isEmpty {
            applyAudioTrack(nil, shouldResume: shouldStartPlayback)
            return
        }

        // Re-apply if was previously selected (prefer trackId match, fall back to language match)
        let matchedTrack: AudioTrack? = {
            if !selectedAudioTrackId.isEmpty {
                return tracks.first(where: { $0.trackId == selectedAudioTrackId })
            }
            if !selectedAudioLanguage.isEmpty {
                return tracks.first(where: { $0.language == selectedAudioLanguage && !$0.isEmbedded })
            }
            return nil
        }()
        if let track = matchedTrack, !track.isEmbedded {
            applyAudioTrack(track, shouldResume: shouldStartPlayback)
            return
        }

        if let fallback = fallbackExternalAudioTrack(in: tracks) {
            selectedAudioLanguage = fallback.language
            selectedAudioTrackId = fallback.trackId
            applyAudioTrack(fallback, shouldResume: shouldStartPlayback)
            return
        }

        if !selectedAudioLanguage.isEmpty || !selectedAudioTrackId.isEmpty {
            StreamifyLogger.log("Audio: Previously selected track not available for current episode — falling back to embedded")
            selectedAudioLanguage = ""
            selectedAudioTrackId = ""
        }

        applyAudioTrack(nil, shouldResume: shouldStartPlayback)
    }
    func reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: Bool) {
        reapplySubtitlesForCurrentEpisode {
            self.reapplyAudioForCurrentEpisode(shouldStartPlayback: shouldStartPlayback)
        }
    }

    func reapplySubtitlesForCurrentEpisode(completion: @escaping @MainActor () -> Void = {}) {
        let subs = availableSubtitles
        if subs.isEmpty {
            // No subtitles for this episode - clear selection state
            subtitleCues = []
            currentSubtitleText = ""
            completion()
            return
        }
        // If a subtitle track was previously selected and is available, re-apply it.
        if !selectedSubtitleTrackId.isEmpty,
           let track = subs.first(where: { $0.trackId == selectedSubtitleTrackId }) {
            applySubtitleTrack(track, completion: completion)
        } else if !selectedSubtitleLanguage.isEmpty,
                  let track = subs.first(where: { $0.language == selectedSubtitleLanguage }) {
            selectedSubtitleTrackId = track.trackId
            applySubtitleTrack(track, completion: completion)
        } else {
            completion()
        }
    }
}
