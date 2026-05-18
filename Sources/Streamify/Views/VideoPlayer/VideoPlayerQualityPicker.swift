import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Switch to Online Play

    /// Cancels an in-progress `switchToOnlinePlay` task, clears the overlay, and resumes
    /// local playback so the user isn't left with a frozen screen.
    func cancelSwitchToOnlinePlay() {
        onlineSwitchSkipper?.skip()
        switchToOnlineTask?.cancel()
        switchToOnlineTask = nil
        onlineSwitchSkipper = nil
        onlineSwitchFetchingURL = nil
        isTransitioningToNext = false
        playWithSyncedAudio()
    }

    func switchToOnlinePlay() {
        saveProgress()
        activePlayingQualityName = nil
        activePlayingQualityId = nil
        let wasPlaying = viewModel.isPlaying || consumePickerResumeIntent()

        pausePlayback()
        isTransitioningToNext = true
        transitionMessage = "Setting up video player..."
        onlineSwitchFetchingURL = nil

        let skipper = URLCheckSkipper()
        onlineSwitchSkipper = skipper

        switchToOnlineTask?.cancel()
        switchToOnlineTask = Task {
            defer {
                Task { @MainActor in
                    switchToOnlineTask = nil
                    onlineSwitchSkipper = nil
                    onlineSwitchFetchingURL = nil
                }
            }

            let directUrls = onlineUrls.compactMap { URL(string: $0) }
            let tmdbId = resolveTmdbId()

            let onCheckingURL: @MainActor @Sendable (String) -> Void = { candidate in
                guard self.isTransitioningToNext else { return }
                let display = candidate.count > Self.maxDisplayUrlLength ? "..." + candidate.suffix(Self.displayUrlSuffixLength) : candidate
                self.onlineSwitchFetchingURL = String(display)
            }
            let onPreparingPlayback: @MainActor @Sendable () -> Void = {
                guard self.isTransitioningToNext else { return }
                self.onlineSwitchFetchingURL = nil
            }

            let resolved: PlaybackResolver.ResolvedPlayback?
            if let ep = currentEpisodeInfo {
                resolved = await PlaybackResolver.resolveEpisode(
                    directUrls: directUrls,
                    sourceNamesMap: onlineUrlSourceNames,
                    tmdbId: tmdbId,
                    season: ep.season,
                    episode: ep.episode,
                    vidLinkEnabled: vidLinkEnabled,
                    movies111Enabled: movies111Enabled,
                    torrentioEnabled: torrentioEnabled,
                    onCheckingURL: onCheckingURL,
                    onPreparingPlayback: onPreparingPlayback,
                    skipper: skipper
                )
            } else {
                resolved = await PlaybackResolver.resolveMovie(
                    directUrls: directUrls,
                    sourceNamesMap: onlineUrlSourceNames,
                    tmdbId: tmdbId,
                    vidLinkEnabled: vidLinkEnabled,
                    movies111Enabled: movies111Enabled,
                    torrentioEnabled: torrentioEnabled,
                    onCheckingURL: onCheckingURL,
                    onPreparingPlayback: onPreparingPlayback,
                    skipper: skipper
                )
            }

            guard !Task.isCancelled else { return }

            guard let result = resolved else {
                await MainActor.run {
                    isTransitioningToNext = false
                    if wasPlaying {
                        if !resumeSeparateAudio(at: viewModel.realPlaybackTime) {
                            playWithSyncedAudio()
                        }
                    }
                }
                return
            }

            await MainActor.run {
                if let merged = result.mergedSubtitles, !merged.isEmpty {
                    currentStreamingSubtitles = merged
                }
                isTransitioningToNext = false
                switchPlayerToUrl(result.url, preloadedQualities: result.preloadedQualities)
            }
        }
    }
    
    // Switch to downloaded (local) play
    func switchToDownloadedPlay() {
        saveProgress()
        // Determine which quality will actually be played (highest available)
        activePlayingQualityName = resolveActiveLocalQualityName()
        guard let url = resolveLocalVideoURL() else { return }
        switchPlayerToUrl(url)
    }
    
    /// Determines the name of the highest-quality downloaded video that will be played locally.
    func resolveActiveLocalQualityName() -> String? {
        let qualities: [DownloadedVideoQuality]?
        if let ep = currentEpisodeInfo {
            let metadata = ContentImportService.loadMetadata(from: content.folderPath)
            qualities = metadata?.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.downloadedVideoQualities
        } else {
            qualities = content.metadata.downloadedVideoQualities
        }
        guard let qs = qualities, !qs.isEmpty else {
            activePlayingQualityId = nil
            return currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality
        }
        // Return the playable quality that actually exists on disk. HLS wins over
        // its source MKV so the UI matches what ContentImportService will open.
        let folderPaths = buildFolderPaths()
        let sorted = sortedDownloadedQualitiesForPlayback(qs)
        for dq in sorted {
            for folder in folderPaths where !folder.isEmpty {
                let path = ContentImportService.contentDirectoryURL.appendingPathComponent(folder).appendingPathComponent(dq.localSource)
                if FileManager.default.fileExists(atPath: path.path) {
                    activePlayingQualityId = dq.qualityId
                    // Set HDR state from the downloaded quality's metadata
                    viewModel.isPlayingHDR = dq.isHDR
                    return dq.name
                }
            }
        }
        activePlayingQualityId = nil
        return currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality
    }

    func applyDownloadedQualityHDRForCurrentPlayback() {
        guard viewModel.isLocalFile || currentVideoURL.isFileURL || currentVideoURL.host == "localhost" else { return }
        let qualities = loadDownloadedVideoQualities()
        let currentLocalSource = currentLocalSourceRelativeToKnownFolders()
        let match: DownloadedVideoQuality?
        if let qid = activePlayingQualityId {
            match = qualities.first { $0.qualityId == qid }
        } else if let currentLocalSource,
                  let localMatch = qualities.first(where: { $0.localSource == currentLocalSource }) {
            match = localMatch
        } else if let qualityName = activePlayingQualityName ?? currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality {
            match = qualities.first { $0.name == qualityName }
        } else {
            match = nil
        }
        if let match {
            viewModel.isPlayingHDR = match.isHDR
            activePlayingQualityId = match.qualityId
            activePlayingQualityName = match.name
            viewModel.autoQualityLabel = match.name
            viewModel.autoQualityIsHDR = match.isHDR
            viewModel.autoQualitySourceName = match.sourceName
        }
    }

    func sortedDownloadedQualitiesForPlayback(_ qualities: [DownloadedVideoQuality]) -> [DownloadedVideoQuality] {
        qualities.sorted { lhs, rhs in
            let lhsIsHLS = lhs.localSource.localizedCaseInsensitiveContains(".m3u8")
            let rhsIsHLS = rhs.localSource.localizedCaseInsensitiveContains(".m3u8")
            if lhsIsHLS != rhsIsHLS {
                return lhsIsHLS
            }
            return lhs.bandwidth > rhs.bandwidth
        }
    }

    func downloadedHLSPlaybackSource(for quality: DownloadedVideoQuality, folder: String) -> String {
        guard quality.localSource.localizedCaseInsensitiveContains(".m3u8"), !quality.isHDR else {
            return quality.localSource
        }
        let masterURL = ContentImportService.contentDirectoryURL
            .appendingPathComponent(folder)
            .appendingPathComponent("master.m3u8")
        return FileManager.default.fileExists(atPath: masterURL.path) ? "master.m3u8" : quality.localSource
    }

    func currentLocalSourceRelativeToKnownFolders() -> String? {
        let localPath: String?
        if currentVideoURL.isFileURL {
            localPath = currentVideoURL.standardizedFileURL.path
        } else if let host = currentVideoURL.host,
                  host == "localhost" || host == "127.0.0.1" {
            let relativePath = String(currentVideoURL.path.drop(while: { $0 == "/" }))
            localPath = ContentImportService.contentDirectoryURL
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
        } else {
            localPath = nil
        }
        guard let localPath else { return nil }

        for folder in buildFolderPaths() where !folder.isEmpty {
            let basePath = ContentImportService.contentDirectoryURL
                .appendingPathComponent(folder)
                .standardizedFileURL
                .path
            if localPath.hasPrefix(basePath + "/") {
                return String(localPath.dropFirst(basePath.count + 1))
            }
        }
        return nil
    }

    func prepareAndSwitchMatroskaStream(_ url: URL, quality: HLSQuality? = nil) {
        if PlayerViewModel.shouldUseMPVDirectPlayback(for: url) {
            showQualitySheet = false
            if let quality {
                activePlayingQualityName = quality.name
                activePlayingQualityId = quality.id.uuidString
                viewModel.selectedQualityName = quality.name
                viewModel.selectedQualitySourceUrl = quality.sourceUrl
                viewModel.autoQualityLabel = quality.name
                viewModel.autoQualityIsHDR = quality.isHDR
                viewModel.autoQualitySourceName = quality.sourceName
                viewModel.isPlayingHDR = quality.isHDR
            }
            switchPlayerToUrl(url, preloadedQualities: viewModel.availableQualities)
            return
        }

        // MPV direct playback is unavailable for this file. When the user explicitly
        // selects a quality from the picker we do NOT fall back to online streaming —
        // only the initial play path (VideoPlayerSetup) should do that automatically.
        showQualitySheet = false
        StreamifyLogger.log("Quality: Matroska playback unavailable for \(url.absoluteString)")
    }
    
    // Switch the player to a new URL, preserving current position
    func switchPlayerToUrl(_ url: URL, pendingQuality: HLSQuality? = nil, preloadedQualities: [HLSQuality]? = nil) {
        clearPickerPauseState()
        // Use realPlaybackTime to get the true content position.
        // Fall back to viewModel.currentTime if the engine returns 0 (e.g., error state).
        // As a last resort, check saved progress to avoid resetting to the beginning.
        var realTime = viewModel.realPlaybackTime
        if realTime <= 0 {
            realTime = viewModel.currentTime
        }
        if realTime <= 0 {
            let seasonNumber = currentEpisodeInfo?.season
            let savedProgress = WatchingProgressManager.getProgress(for: content.id, seasonIndex: seasonNumber, episodeIndex: episodeNumber)
            realTime = savedProgress?.timestamp ?? 0
        }
        let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")
        // Preserve existing qualities if none were explicitly provided — this prevents
        // the quality list from being wiped when the user switches between sources
        // (e.g., tapping a VidLink quality from the picker).
        let qualitiesToPass = preloadedQualities ?? (viewModel.availableQualities.isEmpty ? nil : viewModel.availableQualities)
        
        StreamifyLogger.log("switchPlayerToUrl: captured realTime=\(realTime)s, switching to \(url.lastPathComponent) preloadedQualities=\(qualitiesToPass?.count ?? 0)")
        
        // Stop and clean up separate audio before switching
        externalAudioPlayer?.pause()
        externalAudioPlayer = nil
        cancelNativeMatroskaSubtitlePreparation()
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        audioBufferingObservers.removeAll()
        isAudioBuffering = false
        viewModel.isPlayerMuted = true
        
        viewModel.pause()
        stopProgressSaving()
        
        // Cancel the old ready-state subscriber BEFORE setup to prevent stale callbacks
        playerReadyCancellable?.cancel()
        playerReadyCancellable = nil
        
        currentVideoURL = url
        
        let intro = currentEpisodeInfo?.intro ?? content.metadata.intro
        let introDur = currentEpisodeInfo?.introDuration ?? content.metadata.introDuration
        let end = currentEpisodeInfo?.end ?? content.metadata.end
        viewModel.setup(url: url, intro: intro, introDuration: introDur, end: end, preloadedQualities: qualitiesToPass, sourceNames: onlineUrlSourceNames)
        viewModel.isPlayerMuted = !viewModel.isUsingMPVPlayback
        applyDownloadedQualityHDRForCurrentPlayback()
        
        // Restore displayed time immediately after setup (cleanup() resets to 0)
        // so the UI doesn't briefly flash 0:00 during the switch
        if realTime > 0 {
            viewModel.currentTime = realTime
        }

        // Update hasLocalFile state
        hasLocalFile = checkHasLocalFile()

        // Reset AFTER setup and BEFORE creating the new sink — setup's cleanup()
        // has already set isReadyToPlay=false, so the old sink can't fire anymore.
        hasProcessedReadyState = false
        
        // Seek to saved position when ready, then start playback.
        playerReadyCancellable = Publishers.CombineLatest(viewModel.$isReadyToPlay, viewModel.$duration)
            .filter { isReady, duration in
                isReady && (duration > 0 || viewModel.isUsingMPVPlayback)
            }
            .sink { [weak viewModel] _, readyDuration in
                guard let viewModel = viewModel else { return }
                guard !self.hasProcessedReadyState else { return }
                self.hasProcessedReadyState = true
                
                if realTime > 0 {
                    let durationForClamp = max(readyDuration, viewModel.duration)
                    let clampedTime = clampedResumeTime(realTime, duration: durationForClamp)
                    StreamifyLogger.log("switchPlayerToUrl: seeking to \(clampedTime)s (captured=\(realTime)s duration=\(durationForClamp)s)")
                    viewModel.seek(to: clampedTime) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                            if isHLS {
                                if let pq = pendingQuality {
                                    // Apply the user-selected quality instead of auto
                                    viewModel.setHLSQuality(pq)
                                } else {
                                    viewModel.setQuality(.auto)
                                }
                            }
                        }
                    }
                } else {
                    StreamifyLogger.log("switchPlayerToUrl: no saved position (realTime=\(realTime)), playing from start")
                    viewModel.seek(to: 0) {
                        Task { @MainActor in
                            self.markSeekedPlaybackNeedsVideoGate()
                            self.reapplyPlaybackPrerequisitesForCurrentEpisode(shouldStartPlayback: true)
                            if isHLS {
                                if let pq = pendingQuality {
                                    // Apply the user-selected quality instead of auto
                                    viewModel.setHLSQuality(pq)
                                } else {
                                    viewModel.setQuality(.auto)
                                }
                            }
                        }
                    }
                }
            }
        
        startProgressSaving()
    }

    // MARK: - Quality picker
    func streamQualitySourceRank(_ sourceName: String?) -> Int {
        StreamifySourceGrouping.rank(sourceName)
    }

    func downloadedQualitySourceRank(_ sourceName: String?) -> Int {
        streamQualitySourceRank(sourceName)
    }

    func sortedQualityNames<T>(for grouped: [String: [T]], bandwidth: (T) -> Double, isHDR: ((T) -> Bool)? = nil) -> [String] {
        grouped.keys.sorted { key1, key2 in
            let items1 = grouped[key1] ?? []
            let items2 = grouped[key2] ?? []
            if let isHDR {
                let hdr1 = items1.contains { isHDR($0) }
                let hdr2 = items2.contains { isHDR($0) }
                if hdr1 != hdr2 { return hdr1 }
            }
            let bw1 = items1.map(bandwidth).max() ?? 0
            let bw2 = items2.map(bandwidth).max() ?? 0
            if bw1 != bw2 { return bw1 > bw2 }
            return key1.localizedCaseInsensitiveCompare(key2) == .orderedAscending
        }
    }

    var qualityPicker: some View {
        StreamifyPickerShell(
            title: "Video Quality",
            trailingTitle: "Done",
            trailingAction: { showQualitySheet = false }
        ) {
                let _ = pickerRefreshId // force refresh on delete
	                let allDownloadedQualities = loadDownloadedVideoQualities()
	                    .sorted { q1, q2 in
	                        let r1 = downloadedQualitySourceRank(q1.sourceName)
	                        let r2 = downloadedQualitySourceRank(q2.sourceName)
	                        if r1 != r2 { return r1 < r2 }
	                        if q1.bandwidth != q2.bandwidth { return q1.bandwidth > q2.bandwidth }
	                        return (q1.sourceName ?? "") < (q2.sourceName ?? "")
	                    }
                
                // Show "Downloaded" section if any downloaded qualities exist (or legacy local file)
                if !allDownloadedQualities.isEmpty || (hasLocalFile && allDownloadedQualities.isEmpty) {
                    Text("Downloaded")
                        .streamifyPickerSectionTitle()

                        if allDownloadedQualities.isEmpty && hasLocalFile {
                            // Legacy/imported content without quality metadata — show generic row
                            HStack {
                                Button {
                                    if !viewModel.isLocalFile {
                                        showQualitySheet = false
                                        switchToDownloadedPlay()
                                    } else {
                                        showQualitySheet = false
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Downloaded")
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if viewModel.isLocalFile {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .streamifyPickerButtonLabel()
                                }
                                Button {
                                    deleteMainDownloadedQuality()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.borderless)
                                .padding(.leading, 16)
                            }
                            .streamifyPickerRow(selected: viewModel.isLocalFile)
                        }
                        StreamifyPickerBatchedForEach(allDownloadedQualities, id: \.qualityId) { dq in
                            HStack {
                                Button {
                                    switchToDownloadedQuality(dq)
                                    showQualitySheet = false
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.green)
                                                Text(dq.name)
                                                    .foregroundStyle(.primary)
                                                if let res = dq.resolution {
                                                    Text(res)
                                                        .font(.caption)
                                                        .foregroundStyle(.gray)
                                                }
                                                if let sn = dq.sourceName, !sn.isEmpty {
                                                    SourceBadge(sourceName: sn)
                                                }
                                            }
                                        }
                                        Spacer()
                                        if isPlayingDownloadedQuality(dq) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .streamifyPickerButtonLabel()
                                }
                                Button {
                                    deleteDownloadedQuality(dq)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.borderless)
                                .padding(.leading, 16)
                            }
                            .streamifyPickerRow(selected: isPlayingDownloadedQuality(dq))
                        }
                }
                
                // Stream section — hidden during local playback (matches audio/subtitle picker pattern)
                if !viewModel.isLocalFile {
                    Text("Stream")
                        .streamifyPickerSectionTitle()

                        if viewModel.isHLS {
                            Button {
                                viewModel.setQuality(.auto)
                                showQualitySheet = false
                            } label: {
                                HStack {
                                    HStack(spacing: 8) {
                                        Text("Auto")
                                            .font(.body.weight(.bold))
                                            .foregroundStyle(.primary)
                                        if viewModel.selectedQualityName == "Auto" && !viewModel.autoQualityLabel.isEmpty {
                                            Text("(\(viewModel.autoQualityLabel))")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        } else {
                                            Text("Adaptive quality")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                        if !viewModel.autoQualityLabel.isEmpty {
                                            SourceBadge(sourceName: viewModel.autoQualitySourceName)
                                        }
                                    }
                                    Spacer()
                                    if viewModel.selectedQualityName == "Auto" {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                    }
                                }
                                .streamifyPickerButtonLabel()
                            }
                            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                            .streamifyPickerRow(selected: viewModel.selectedQualityName == "Auto")
                        }
                        
                        if viewModel.availableQualities.isEmpty {
                            Text("No quality options found")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
	                            let sorted = viewModel.availableQualities.sorted { q1, q2 in
	                                if q1.isHDR != q2.isHDR { return q1.isHDR }
	                                let r1 = streamQualitySourceRank(q1.sourceName)
	                                let r2 = streamQualitySourceRank(q2.sourceName)
	                                if r1 != r2 { return r1 < r2 }
	                                if q1.bandwidth != q2.bandwidth { return q1.bandwidth > q2.bandwidth }
	                                return (q1.sourceName ?? "") < (q2.sourceName ?? "")
	                            }
                            let grouped = Dictionary(grouping: sorted, by: { $0.name })
                            let sortedKeys = sortedQualityNames(for: grouped, bandwidth: { $0.bandwidth }, isHDR: { $0.isHDR })

                            StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { qualityName in
                                let qualities = grouped[qualityName] ?? []
                                if qualities.count == 1 {
                                    // Single source — show directly
                                    qualityPickerRow(quality: qualities[0], allDownloadedQualities: allDownloadedQualities)
                                } else {
                                    // Multi-source — show expandable group
                                    let isExpanded = expandedQualityGroup == qualityName
                                    Button {
                                        StreamifyPickerMotion.toggle($expandedQualityGroup, value: qualityName)
                                    } label: {
                                        HStack {
                                            Text(qualityName)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            if let res = qualities.first?.resolution {
                                                Text(res)
                                                    .font(.caption)
                                                    .foregroundStyle(.gray)
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
                                    .streamifyPickerRow(selected: isExpanded || qualities.contains { quality in
                                        (quality.isDirectFileSource && currentVideoURL.absoluteString == quality.sourceUrl) ||
                                        (viewModel.selectedQualityName == quality.name && viewModel.selectedQualitySourceUrl == quality.sourceUrl)
                                    })

                                    StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                        StreamifyPickerBatchedForEach(qualities, id: \.id) { quality in
                                            qualityPickerRow(quality: quality, allDownloadedQualities: allDownloadedQualities, indented: true)
                                        }
                                    }
                                }
                            }
                        }
                } else {
                    // Local playback mode — show "Stream" section with "Switch to Online" option
                    Text("Stream")
                        .streamifyPickerSectionTitle()

                        Button {
                            showQualitySheet = false
                            showSwitchToOnlineAlert = true
                        } label: {
                            HStack {
	                                Image(systemName: "antenna.radiowaves.left.and.right")
	                                    .foregroundStyle(.white)
	                                Text("Switch to Online Streaming")
	                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .streamifyPickerButtonLabel()
                        }
                        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                        .streamifyPickerRow()
                }
        }
    }
    
    @ViewBuilder
    func qualityPickerRow(quality: HLSQuality, allDownloadedQualities: [DownloadedVideoQuality], indented: Bool = false) -> some View {
        let remoteSourceUrl = quality.sourceUrl ?? quality.variantUrl
        let isDownloaded = allDownloadedQualities.contains { dq in
            guard isDownloadedQualityOnDisk(dq) else { return false }
            if let remoteSourceUrl, downloadedQuality(dq, matchesSourceUrl: remoteSourceUrl, sourceName: quality.sourceName) {
                return true
            }
            return dq.sourceUrl == nil &&
                quality.sourceName != "Torrentio" &&
                dq.name == quality.name &&
                dq.sourceName == quality.sourceName
        }
        let isSelected = (quality.isDirectFileSource && currentVideoURL.absoluteString == quality.sourceUrl) ||
            (viewModel.selectedQualityName == quality.name && viewModel.selectedQualitySourceUrl == quality.sourceUrl)
        HStack(alignment: .top) {
            Button {
                if quality.isDirectFileSource {
                    if let sourceUrl = quality.sourceUrl, let url = URL(string: sourceUrl) {
                        if currentVideoURL.absoluteString != sourceUrl {
                            if MatroskaPlaybackSupport.isMatroskaURL(url) {
                                prepareAndSwitchMatroskaStream(url, quality: quality)
                            } else {
                                showQualitySheet = false
                                switchPlayerToUrl(url)
                            }
                        }
                    }
                } else if let sourceUrl = quality.sourceUrl,
                          let currentUrl = currentVideoURL.absoluteString as String?,
                          !currentUrl.contains(URL(string: sourceUrl)?.host ?? "NOMATCH") {
                    if let url = URL(string: sourceUrl) {
                        showQualitySheet = false
                        switchPlayerToUrl(url, pendingQuality: quality)
                    }
                } else {
                    viewModel.setHLSQuality(quality)
                    showQualitySheet = false
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
                    
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.white)
                    }
                }
                .streamifyPickerButtonLabel()
                .padding(.vertical, 4)
            }
            // Download/progress buttons (no delete - this is the Stream section)
            if let mainDL = findMatchingMainDownload(qualityName: quality.name, sourceName: quality.sourceName, sourceUrl: remoteSourceUrl) ?? (quality.name == "Auto" ? findMatchingMainDownload() : nil) {
                // Download in progress — show stage info + controls
                HStack(spacing: 4) {
                        if mainDL.status == .paused {
                            Text("Paused \(mainDL.progressPercent)%")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Button {
                                downloadManager.resumeDownload(mainDL)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                        } else if mainDL.status == .queued {
                            Image(systemName: "clock")
                                .foregroundStyle(.orange)
                            Text("Queued")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if mainDL.status == .downloading {
                            Text("\(mainDL.progressPercent)%")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Button {
                                downloadManager.pauseDownload(mainDL)
                            } label: {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.borderless)
                        }
                        Button {
                            downloadManager.cancelDownload(mainDL)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.leading, 16)
            } else if !isDownloaded, (quality.sourceUrl ?? quality.variantUrl) != nil {
                Button {
                    downloadQualityLocally(quality: quality)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 16)
            }
        }
        .streamifyPickerRow(selected: isSelected)
        .streamifyPickerExpandedItem(indented: indented)
    }

    // MARK: - Quality download management
    
    /// Check if a downloaded quality's files actually exist on disk
    func isDownloadedQualityOnDisk(_ dq: DownloadedVideoQuality) -> Bool {
        let folderPaths = buildFolderPaths()
        for folder in folderPaths where !folder.isEmpty {
            let fileURL = ContentImportService.contentDirectoryURL
                .appendingPathComponent(folder)
                .appendingPathComponent(dq.localSource)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return true
            }
        }
        return false
    }
    
    func loadDownloadedVideoQualities() -> [DownloadedVideoQuality] {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty, let metadata = ContentImportService.loadMetadata(from: folderPath) else { return [] }
        
        let qualities: [DownloadedVideoQuality]
        if let ep = currentEpisodeInfo {
            if let episode = metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                qualities = episode.downloadedVideoQualities ?? []
            } else {
                qualities = []
            }
        } else {
            qualities = metadata.downloadedVideoQualities ?? []
        }
        // Filter to only qualities whose files actually exist on disk
        return qualities.filter { isDownloadedQualityOnDisk($0) }
    }
    
    /// Returns the sourceName of the currently playing downloaded quality (if any)
    var currentDownloadedSourceName: String? {
        // Use qualityId for precise matching when available
        if let qid = activePlayingQualityId {
            let qualities = loadDownloadedVideoQualities()
            return qualities.first(where: { $0.qualityId == qid })?.sourceName
        }
        let qualityName = activePlayingQualityName ?? currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality
        guard let qn = qualityName, !qn.isEmpty else { return nil }
        let qualities = loadDownloadedVideoQualities()
        return qualities.first(where: { $0.name == qn })?.sourceName
    }
    
    /// Check if a specific downloaded quality is currently being played
    func isPlayingDownloadedQuality(_ dq: DownloadedVideoQuality) -> Bool {
        guard viewModel.isLocalFile else { return false }
        // Match by unique qualityId first (avoids matching multiple qualities with the same name)
        if let qid = activePlayingQualityId {
            return dq.qualityId == qid
        }
        // Fallback to name-based matching for legacy content without qualityId tracking
        let currentQuality = activePlayingQualityName ?? currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality
        return currentQuality == dq.name
    }
    
    func downloadQualityLocally(quality: HLSQuality) {
        // Use the sourceUrl (master m3u8) for the download queue, like ContentDetailView does.
        // DownloadManager.startDownload handles everything: HLS parsing, rate limiting, fallbacks,
        // metadata updates, and library management.
        guard let sourceUrl = quality.sourceUrl ?? quality.variantUrl else { return }
        
        // Ensure content is in library BEFORE queuing the download,
        // so metadata exists on disk and DownloadsView can resolve thumbnails
        if !isInLibrary {
            ensureInLibrary()
        }
        
        let contentId: String
        let allEpisodes: [EpisodeInfo]?
        if let ep = currentEpisodeInfo {
            contentId = "\(content.id)_ep\(ep.episode)"
            allEpisodes = content.metadata.episodes
        } else {
            contentId = content.id
            allEpisodes = nil
        }
        
        let needsProviderRefresh = VidLinkService.isVidLinkProxyURL(sourceUrl) || quality.sourceName == "Torrentio"
        let downloadTmdbId: Int? = needsProviderRefresh ? resolveTmdbId() : nil
        
        DownloadManager.shared.addQueuedDownload(
            contentId: contentId,
            videoUrl: sourceUrl,
            episodeIndex: currentEpisodeInfo?.episode,
            seasonIndex: currentEpisodeInfo?.season,
            episodeTitle: currentEpisodeInfo?.title,
            selectedBandwidth: quality.bandwidth,
            qualityName: quality.name,
            allEpisodes: allEpisodes,
            fallbackUrls: [],
            tmdbId: downloadTmdbId,
            sourceName: quality.sourceName,
            selectedResolution: quality.resolution,
            selectedVideoRange: quality.videoRange
        )
        
        // Start the queue immediately (like ContentDetailView's triggerProcessQueue)
        DownloadManager.shared.triggerProcessQueue()
    }
    
    func switchToDownloadedQuality(_ dq: DownloadedVideoQuality) {
        let folderPaths = buildFolderPaths()
        for folder in folderPaths where !folder.isEmpty {
            let fileURL = ContentImportService.contentDirectoryURL
                .appendingPathComponent(folder)
                .appendingPathComponent(dq.localSource)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if fileURL.isFileURL && MatroskaPlaybackSupport.isMatroskaURL(fileURL) {
                    activePlayingQualityName = dq.name
                    activePlayingQualityId = dq.qualityId
                    viewModel.isPlayingHDR = dq.isHDR
                    prepareAndSwitchMatroskaStream(fileURL)
                    return
                }
                // Local HLS m3u8 must be served via localhost HTTP server — AVPlayer
                // cannot play HLS from file:// URLs on iOS (CoreMediaError -12865).
                if dq.localSource.hasSuffix(".m3u8") {
                    let (isRunning, baseURL) = LocalServer.shared.getServerInfo()
                    var serverBase = baseURL
                    if !isRunning {
                        let _ = LocalServer.shared.ensureRunning()
                        serverBase = LocalServer.shared.getServerInfo().baseURL
                    }
                    let playbackSource = downloadedHLSPlaybackSource(for: dq, folder: folder)
                    let relativePath = "\(folder)/\(playbackSource)"
	                    if let serverURL = URL(string: "\(serverBase)/\(relativePath)") {
	                        activePlayingQualityName = dq.name
	                        activePlayingQualityId = dq.qualityId
	                        // Set HDR state from the downloaded quality's metadata
	                        viewModel.isPlayingHDR = dq.isHDR
	                        switchPlayerToUrl(serverURL)
	                        viewModel.isPlayingHDR = dq.isHDR
                        StreamifyLogger.log("Quality: Switched to downloaded \(dq.name) (HDR=\(dq.isHDR)) via localhost from \(serverURL.absoluteString)")
                        return
                    }
                }
                // Non-HLS files (mp4 etc) can play directly from file://
                activePlayingQualityName = dq.name
                activePlayingQualityId = dq.qualityId
                // Set HDR state from the downloaded quality's metadata
                switchPlayerToUrl(fileURL)
                viewModel.isPlayingHDR = dq.isHDR
                StreamifyLogger.log("Quality: Switched to downloaded \(dq.name) (HDR=\(dq.isHDR)) from \(fileURL.path)")
                return
            }
        }
        StreamifyLogger.log("Quality: Could not find downloaded quality \(dq.name)")
    }
    
    func deleteDownloadedQuality(_ dq: DownloadedVideoQuality) {
        let folderPaths = buildFolderPaths()
        
        // HLS localSource is usually "video_1080p_uuid/video.m3u8"; direct downloads are flat files.
        let dirName = (dq.localSource as NSString).deletingLastPathComponent
        
        for folder in folderPaths where !folder.isEmpty {
            let baseURL = ContentImportService.contentDirectoryURL.appendingPathComponent(folder)
            if !dirName.isEmpty && dirName != "." {
                let dirURL = baseURL.appendingPathComponent(dirName)
                if FileManager.default.fileExists(atPath: dirURL.path) {
                    do {
                        try FileManager.default.removeItem(at: dirURL)
                        StreamifyLogger.log("Quality: Deleted directory \(dirURL.lastPathComponent)")
                    } catch {
                        StreamifyLogger.log("Quality: Failed to delete \(dirURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } else {
                let fileURL = baseURL.appendingPathComponent(dq.localSource)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        removeMatroskaCompanion(for: fileURL)
                        try FileManager.default.removeItem(at: fileURL)
                        StreamifyLogger.log("Quality: Deleted file \(fileURL.lastPathComponent)")
                    } catch {
                        StreamifyLogger.log("Quality: Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        
        removeVideoQualityFromMetadata(qualityName: dq.name, localSource: dq.localSource)
        
        // If this quality was also the main localFile, clear that metadata too
        let folderPath = effectiveFolderPath
        if !folderPath.isEmpty, let metadata = ContentImportService.loadMetadata(from: folderPath) {
            let mainLocalFile: String?
            if let ep = currentEpisodeInfo {
                let episode = metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })
                mainLocalFile = episode?.localFile
            } else {
                mainLocalFile = [metadata.hlsUrl, metadata.file]
                    .compactMap { $0 }
                    .first { !$0.hasPrefix("http") }
            }
            if mainLocalFile == dq.localSource {
                clearLocalFileInMetadata(folderPath: folderPath)
                StreamifyLogger.log("Quality: Also cleared main localFile metadata for \(dq.name)")
            }
        }

        refreshLocalMasterAndCleanupIfEmpty()
        
        // If currently playing this quality, switch to online
        if viewModel.isLocalFile && isPlayingDownloadedQuality(dq) {
            switchToOnlinePlay()
        }
        
        // Force picker UI refresh and notify ContentDetailView
        hasLocalFile = checkHasLocalFile()
        pickerRefreshId += 1
        DownloadManager.shared.libraryRefreshNeeded = true
        
        StreamifyLogger.log("Quality: Deleted downloaded quality \(dq.name)")
    }
    
    /// Delete the main downloaded quality (the one from DownloadManager full content download)
    func deleteMainDownloadedQuality() {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty else { return }
        
        // Determine localFile from metadata
        let localFile: String?
        if let ep = currentEpisodeInfo {
            if let metadata = ContentImportService.loadMetadata(from: folderPath) {
                let episode = metadata.allEpisodes.first { $0.season == ep.season && $0.episode == ep.episode }
                localFile = episode?.localFile
            } else {
                localFile = nil
            }
        } else {
            let metadata = ContentImportService.loadMetadata(from: folderPath)
            localFile = [metadata?.hlsUrl, metadata?.file]
                .compactMap { $0 }
                .first { !$0.hasPrefix("http") }
        }
        
        // Delete video files from disk
        let contentDir = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
        if let localFile = localFile, !localFile.isEmpty, !localFile.hasPrefix("http") {
            // If localFile has a directory component (e.g., "video_1080p/video.m3u8"), delete the whole directory
            let dirName = (localFile as NSString).deletingLastPathComponent
            if !dirName.isEmpty && dirName != "." {
                let dirURL = contentDir.appendingPathComponent(dirName)
                if FileManager.default.fileExists(atPath: dirURL.path) {
                    try? FileManager.default.removeItem(at: dirURL)
                    StreamifyLogger.log("Quality: Deleted main download directory \(dirURL.lastPathComponent)")
                }
            } else {
                // Flat file (e.g., "video.m3u8" or "episode_1.mp4") — delete file and segments dir
                let fileURL = contentDir.appendingPathComponent(localFile)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    removeMatroskaCompanion(for: fileURL)
                    try? FileManager.default.removeItem(at: fileURL)
                    StreamifyLogger.log("Quality: Deleted main download file \(fileURL.lastPathComponent)")
                }
                // Also delete associated segments directory
                let segDirNames: [String]
                if let ep = currentEpisodeInfo {
                    let prefix = "ep\(ep.episode)_"
                    segDirNames = ["segments_ep\(ep.episode)", "\(prefix)segments", "segments"]
                } else {
                    segDirNames = ["segments"]
                }
                for segName in segDirNames {
                    let segDir = contentDir.appendingPathComponent(segName)
                    if FileManager.default.fileExists(atPath: segDir.path) {
                        try? FileManager.default.removeItem(at: segDir)
                        StreamifyLogger.log("Quality: Deleted segments directory \(segName)")
                    }
                }
            }
        }
        
        // Clear localFile and qualityName from metadata
        clearLocalFileInMetadata(folderPath: folderPath)
        refreshLocalMasterAndCleanupIfEmpty()
        
        // If currently playing from local, switch to online
        if viewModel.isLocalFile {
            switchToOnlinePlay()
        }
        
        hasLocalFile = false
        pickerRefreshId += 1
        DownloadManager.shared.libraryRefreshNeeded = true
        StreamifyLogger.log("Quality: Deleted main downloaded quality")
    }
    
    /// Clear localFile and downloadedQuality from metadata after deleting a main download
    func clearLocalFileInMetadata(folderPath: String) {
        guard var metadata = ContentImportService.loadMetadata(from: folderPath) else { return }
        func isLocalReference(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            return !value.hasPrefix("http")
        }

        if let ep = currentEpisodeInfo {
            func clearEpisode(_ episode: EpisodeInfo) -> EpisodeInfo {
                let remoteFile = episode.file?.hasPrefix("http") == true ? episode.file : nil
                let remoteHLS = episode.hlsUrl?.hasPrefix("http") == true ? episode.hlsUrl : nil
                return episode.copying(
                    file: .some(remoteFile),
                    hlsUrl: .some(remoteHLS),
                    localFile: .some(nil),
                    qualityName: .some(nil)
                )
            }

            if var episodes = metadata.episodes {
                if let idx = episodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                    if episodes[idx].localFile != nil ||
                        isLocalReference(episodes[idx].file) ||
                        isLocalReference(episodes[idx].hlsUrl) {
                        episodes[idx] = clearEpisode(episodes[idx])
                        metadata = metadata.copying(episodes: episodes)
                    }
                }
            }
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var sEpisodes = seasons[sIdx].episodes {
                        if let eIdx = sEpisodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                            if sEpisodes[eIdx].localFile != nil ||
                                isLocalReference(sEpisodes[eIdx].file) ||
                                isLocalReference(sEpisodes[eIdx].hlsUrl) {
                                sEpisodes[eIdx] = clearEpisode(sEpisodes[eIdx])
                                seasons[sIdx] = SeasonInfo(
                                    season: seasons[sIdx].season, title: seasons[sIdx].title,
                                    thumbnailUrl: seasons[sIdx].thumbnailUrl, episodes: sEpisodes
                                )
                            }
                        }
                    }
                }
                metadata = metadata.copying(seasons: seasons)
            }
        } else {
            let remoteFile = metadata.file?.hasPrefix("http") == true ? metadata.file : nil
            let remoteHLS = metadata.hlsUrl?.hasPrefix("http") == true ? metadata.hlsUrl : nil
            metadata = metadata.copying(
                file: .some(remoteFile),
                hlsUrl: .some(remoteHLS),
                downloadedQuality: .some(nil)
            )
        }
        
        ContentImportService.saveMetadata(metadata, to: folderPath)
        StreamifyLogger.log("Quality: Cleared localFile from metadata")
    }
    
    func removeVideoQualityFromMetadata(qualityName: String, localSource: String? = nil) {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty, var metadata = ContentImportService.loadMetadata(from: folderPath) else { return }
        
        var changed = false
        
        // Match by localSource when available (unique per download), fall back to qualityName
        let matchesQuality: (DownloadedVideoQuality) -> Bool = { dq in
            if let ls = localSource {
                return dq.localSource == ls
            }
            return dq.name == qualityName
        }
        
        if let ep = currentEpisodeInfo {
            if var episodes = metadata.episodes {
                if let idx = episodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                    let episode = episodes[idx]
                    if var qualities = episode.downloadedVideoQualities {
                        let before = qualities.count
                        qualities.removeAll(where: matchesQuality)
                        if qualities.count < before {
                            episodes[idx] = episode.copying(downloadedVideoQualities: .some(qualities.isEmpty ? nil : qualities))
                            changed = true
                        }
                    }
                }
                if changed {
                    metadata = metadata.copying(episodes: episodes)
                }
            }
            // Also update in seasons
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var sEpisodes = seasons[sIdx].episodes {
                        if let eIdx = sEpisodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                            let episode = sEpisodes[eIdx]
                            if var qualities = episode.downloadedVideoQualities {
                                let before = qualities.count
                                qualities.removeAll(where: matchesQuality)
                                if qualities.count < before {
                                    sEpisodes[eIdx] = episode.copying(downloadedVideoQualities: .some(qualities.isEmpty ? nil : qualities))
                                    seasons[sIdx] = SeasonInfo(
                                        season: seasons[sIdx].season, title: seasons[sIdx].title,
                                        thumbnailUrl: seasons[sIdx].thumbnailUrl, episodes: sEpisodes
                                    )
                                    changed = true
                                }
                            }
                        }
                    }
                }
                if changed {
                    metadata = metadata.copying(seasons: seasons)
                }
            }
        } else {
            // Movie-level
            if var qualities = metadata.downloadedVideoQualities {
                let before = qualities.count
                qualities.removeAll(where: matchesQuality)
                if qualities.count < before {
                    metadata = metadata.copying(downloadedVideoQualities: .some(qualities.isEmpty ? nil : qualities))
                    changed = true
                }
            }
        }
        
        if changed {
            ContentImportService.saveMetadata(metadata, to: folderPath)
            StreamifyLogger.log("Quality: Removed \(qualityName) from metadata")
        }
    }

    func removeMatroskaCompanion(for fileURL: URL) {
        MatroskaPlaybackSupport.removeGeneratedFiles(relatedTo: fileURL)
    }
}
