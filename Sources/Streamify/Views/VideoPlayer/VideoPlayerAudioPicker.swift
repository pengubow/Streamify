import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Audio picker
    var currentMPVEmbeddedAudioTrack: AudioTrack? {
        guard viewModel.isUsingMPVPlayback else { return nil }
        if let selectedId = viewModel.selectedMPVAudioTrackId,
           let selected = viewModel.mpvAudioTracks.first(where: { $0.trackId == selectedId }) {
            return selected
        }
        return viewModel.mpvAudioTracks.first
    }

    var embeddedAudioDisplayTitle: String {
        guard let track = currentMPVEmbeddedAudioTrack else { return "Embedded" }
        return track.language
    }

    var embeddedAudioDisplayDetail: String {
        guard let track = currentMPVEmbeddedAudioTrack else { return "(Default)" }
        if let name = track.name, name.localizedCaseInsensitiveCompare(track.language) != .orderedSame {
            return "(\(name))"
        }
        return "(Embedded)"
    }

    var audioPicker: some View {
        StreamifyPickerShell(
            title: "Audio",
            trailingTitle: "Done",
            trailingAction: { showAudioSheet = false }
        ) {
                let _ = pickerRefreshId // force refresh on delete
                let tracks = availableAudioTracks
                let embeddedDisabled = isEmbeddedAudioDisabled
                let visibleTracks = tracks.filter { !$0.isEmbedded }
                let downloadedTracks = visibleTracks.filter {
                    !viewModel.isMPVAudioTrack($0) && isAudioLocallyAvailable($0)
                }
                let isLocalMatroskaPlayback = viewModel.isUsingMPVPlayback &&
                    viewModel.isLocalFile &&
                    MatroskaPlaybackSupport.isMatroskaURL(currentVideoURL)
                // Once the HLS manifest has been parsed, hide Embedded when every
                // advertised audio rendition points to a separate playlist.
                let hlsUsesExternalAudioOnly = viewModel.isHLS &&
                    !hlsAudioTracks.isEmpty &&
                    !hlsAudioTracks.contains { $0.isEmbedded }
                let shouldShowEmbeddedOption = !viewModel.isUsingMPVPlayback &&
                    !embeddedDisabled &&
                    !isLocalMatroskaPlayback &&
                    !hlsUsesExternalAudioOnly

                // Add Embedded option if embedded audio isn't disabled
                if shouldShowEmbeddedOption {
                    Button {
                        selectedAudioLanguage = ""
                        selectedAudioTrackId = ""
                        applyAudioTrack(nil)
                        showAudioSheet = false
                    } label: {
                        HStack {
                            HStack(spacing: 4) {
                                Text(embeddedAudioDisplayTitle)
                                    .foregroundStyle(.primary)
                                Text(embeddedAudioDisplayDetail)
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                if embeddedAudioIsSpatial || (currentMPVEmbeddedAudioTrack?.isSpatial == true) {
                                    SpatialAudioBadge(isSpatial: true)
                                }
                            }
                            Spacer()
                            if shouldShowEmbeddedCheckmark(nonEmbeddedTracks: visibleTracks) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                            }
                        }
                        .streamifyPickerButtonLabel()
                    }
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .streamifyPickerRow(selected: shouldShowEmbeddedCheckmark(nonEmbeddedTracks: visibleTracks))
                }

                // Downloaded audio section
                if !downloadedTracks.isEmpty {
                    Text("Downloaded")
                        .streamifyPickerSectionTitle()

                        let grouped = Dictionary(grouping: downloadedTracks, by: { $0.displayName })
                        let sortedKeys = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                        StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { displayName in
                            let groupTracks = grouped[displayName] ?? []
                            if groupTracks.count == 1 {
                                audioPickerRow(track: groupTracks[0], showButtons: true)
                            } else {
                                let isExpanded = expandedAudioGroup == "dl_\(displayName)"
                                Button {
                                    StreamifyPickerMotion.toggle($expandedAudioGroup, value: "dl_\(displayName)")
                                } label: {
                                    HStack {
                                        Text(displayName)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .streamifyPickerButtonLabel()
                                }
                                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                                .streamifyPickerRow(selected: isExpanded || groupTracks.contains { isAudioTrackSelected($0) })

                                StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                    StreamifyPickerBatchedForEach(groupTracks, id: \.trackId) { track in
                                        audioPickerRow(track: track, showButtons: true)
                                            .streamifyPickerExpandedItem(indented: true)
                                    }
                                }
                            }
                        }
                }
                
                // Stream audio section — show tracks that have remote sources,
                // plus already-downloaded tracks (they appear without download button,
                // matching the quality picker's behavior).
                // For MPV/Matroska playback, this section carries embedded MKV tracks.
                if (!viewModel.isLocalFile || viewModel.isUsingMPVPlayback) && !visibleTracks.isEmpty {
                    let streamTracks = visibleTracks.filter { track in
                        if viewModel.isUsingMPVPlayback && viewModel.isLocalFile {
                            return viewModel.isMPVAudioTrack(track)
                        }
                        if viewModel.isUsingMPVPlayback,
                           viewModel.isMPVAudioTrack(track) {
                            return true
                        }
                        return track.source.hasPrefix("http") ||
                            resolveRemoteAudioURL(for: track) != nil ||
                            isAudioLocallyAvailable(track)
                    }
                    if !streamTracks.isEmpty {
                        Text(viewModel.isUsingMPVPlayback && viewModel.isLocalFile ? "MKV" : "Stream")
                            .streamifyPickerSectionTitle()

                            let grouped = Dictionary(grouping: streamTracks, by: { $0.displayName })
                            let sortedKeys = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                            StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { displayName in
                                let groupTracks = grouped[displayName] ?? []
                                if groupTracks.count == 1 {
                                    audioPickerRow(track: groupTracks[0], showButtons: true, isDownloadedSection: false)
                                } else {
                                    let isExpanded = expandedAudioGroup == "st_\(displayName)"
                                    Button {
                                        StreamifyPickerMotion.toggle($expandedAudioGroup, value: "st_\(displayName)")
                                    } label: {
                                        HStack {
                                            Text(displayName)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .streamifyPickerButtonLabel()
                                    }
                                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                                    .streamifyPickerRow(selected: isExpanded || groupTracks.contains { isAudioTrackSelected($0) })

                                    StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                        StreamifyPickerBatchedForEach(groupTracks, id: \.trackId) { track in
                                            audioPickerRow(track: track, showButtons: true, isDownloadedSection: false)
                                                .streamifyPickerExpandedItem(indented: true)
                                        }
                                    }
                                }
                            }
                    }
                }
        }
    }

    // Audio variant picker for duplicate languageIds
    var audioVariantPicker: some View {
        StreamifyPickerShell(
            title: "Choose Version",
            trailingTitle: "Done",
            trailingAction: { showAudioVariantSheet = false }
        ) {
            StreamifyPickerBatchedForEach(audioVariantTracks, id: \.trackId) { track in
                audioPickerRow(track: track)
            }
        }
    }
    
    // Whether the embedded audio option should show a checkmark.
    // True when nothing is explicitly selected, or when the stored selection
    // doesn't match any available non-embedded track.
    func shouldShowEmbeddedCheckmark(nonEmbeddedTracks: [AudioTrack]) -> Bool {
        if selectedAudioLanguage.isEmpty && selectedAudioTrackId.isEmpty {
            return true
        }
        // If the stored trackId matches a current track, embedded is not active
        if !selectedAudioTrackId.isEmpty && nonEmbeddedTracks.contains(where: { $0.trackId == selectedAudioTrackId }) {
            return false
        }
        // If the stored language matches a current non-embedded track, embedded is not active
        if !selectedAudioLanguage.isEmpty && nonEmbeddedTracks.contains(where: { $0.language == selectedAudioLanguage }) {
            return false
        }
        return true
    }
    
    // Check if an audio track is currently selected
    func isAudioTrackSelected(_ track: AudioTrack) -> Bool {
        // Prefer trackId match if available AND the trackId actually exists in current tracks
        if !selectedAudioTrackId.isEmpty {
            if track.trackId == selectedAudioTrackId {
                return true
            }
            // If no track matches the stored trackId, fall through to language match
            let anyTrackMatchesId = availableAudioTracks.contains(where: { $0.trackId == selectedAudioTrackId })
            if anyTrackMatchesId {
                return false
            }
        }
        if viewModel.isMPVAudioTrack(track),
           selectedAudioTrackId.isEmpty,
           selectedAudioLanguage.isEmpty,
           viewModel.selectedMPVAudioTrackId == track.trackId {
            return true
        }
        if track.isEmbedded {
            let nonEmbedded = availableAudioTracks.filter { !$0.isEmbedded }
            return shouldShowEmbeddedCheckmark(nonEmbeddedTracks: nonEmbedded)
        }
        return !selectedAudioLanguage.isEmpty && selectedAudioLanguage == track.language
    }
    
    @ViewBuilder
    func audioPickerRow(track: AudioTrack, showButtons: Bool = false, isDownloadedSection: Bool = true) -> some View {
        let isLocal = isAudioLocallyAvailable(track)
        HStack {
            Button {
                selectedAudioLanguage = track.isEmbedded ? "" : track.language
                selectedAudioTrackId = track.isEmbedded ? "" : track.trackId
                if track.isEmbedded {
                    applyAudioTrack(nil)
                } else {
                    applyAudioTrack(track)
                }
                // Dismiss variant sheet first (if open), then parent
                if showAudioVariantSheet {
                    showAudioVariantSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showAudioSheet = false
                    }
                } else {
                    showAudioSheet = false
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(track.displayName)
                                .foregroundStyle(.primary)
                            if track.isEmbedded {
                                Text("(Embedded)")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                            if track.isSpatial || (track.isEmbedded && embeddedAudioIsSpatial) {
                                SpatialAudioBadge(isSpatial: true)
                            }
                            if let sn = track.sourceName {
                                SourceBadge(sourceName: sn)
                            }
                        }
                        Text(audioTrackDebugText(track))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    if isAudioTrackSelected(track) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.white)
                    }
                }
                .streamifyPickerButtonLabel()
            }
            if showButtons && !track.isEmbedded {
                let hasRemoteSource = resolveRemoteAudioURL(for: track) != nil
                // Delete button for locally downloaded audio — only in Downloaded section
                if isLocal && isDownloadedSection {
                    Button {
                        deleteLocalAudio(for: track)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 16)
                }
                // Download/progress button — show when a remote source is available
                if hasRemoteSource {
                    if downloadingTrackLanguage == track.language {
                        // Player-initiated download in progress — show progress + controls
                        HStack(spacing: 4) {
                            Text("\(Int(downloadingTrackProgress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Button {
                                pausePickerDownload()
                            } label: {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.borderless)
                            Button {
                                cancelPickerDownload()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.gray)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.leading, 16)
                    } else if let externalDL = findMatchingTrackDownload(trackType: "audio", language: track.language) {
                        // External download in progress (e.g. from downloads tab or re-entered player)
                        HStack(spacing: 4) {
                            ProgressView(value: externalDL.progress)
                                .progressViewStyle(.circular)
                            Text("\(Int(externalDL.progress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Button {
                                if let task = externalDL.downloadTask {
                                    task.cancel()
                                }
                                DownloadManager.shared.cancelTrackDownload(id: externalDL.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.gray)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.leading, 16)
                    } else if !isLocal {
                        Button {
                            downloadTrackLocally(audio: track)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.borderless)
                        .padding(.leading, 16)
                    }
                }
            }
        }
        .streamifyPickerRow(selected: isAudioTrackSelected(track))
    }

    func audioTrackDebugText(_ track: AudioTrack) -> String {
        "id \(TrackIdentity.shortDisplayId(track.trackId)) · lang \(track.languageId)"
    }

    // MARK: - Apply audio track
    func applyAudioTrack(_ track: AudioTrack?, shouldResume: Bool? = nil) {
        let wantsResumePlayback = shouldResume ?? (
            viewModel.isPlaying ||
            viewModel.playbackRate > 0 ||
            pausedPlaybackForPicker ||
            shouldResumeAfterPicker
        )
        let shouldResumePlayback = wantsResumePlayback

        if wantsResumePlayback {
            viewModel.pause()
            if isPickerOrSwitchAlertPresented {
                pausedPlaybackForPicker = true
                shouldResumeAfterPicker = true
            }
        }

        // Stop and remove any external audio player
        externalAudioPlayer?.pause()
        externalAudioPlayer = nil
        separateAudioSyncOffsetSeconds = 0
        stopCompensatedEmbeddedAudio(unmuteMain: false)
        audioBufferingObservers.removeAll()
        isAudioBuffering = false

        if viewModel.isUsingMPVPlayback {
            if let track, viewModel.isMPVAudioTrack(track) {
                viewModel.isPlayerMuted = false
                viewModel.selectMPVAudioTrack(track)
                StreamifyLogger.log("Audio: Switched MPV audio to \(track.displayName)")
            } else if let track,
                      let url = resolveAudioURL(for: track) {
                viewModel.isPlayerMuted = true
                viewModel.disableMPVAudioOutput()
                loadExternalAudio(from: url, track: track, shouldResume: shouldResumePlayback)
                StreamifyLogger.log("Audio: Switched MKV playback to external audio \(track.displayName)")
                return
            } else {
                viewModel.isPlayerMuted = false
                viewModel.selectMPVAudioTrack(nil)
                StreamifyLogger.log("Audio: Switched MPV audio to default")
            }
            if shouldResumePlayback && !isPickerOrSwitchAlertPresented {
                viewModel.play()
            }
            return
        }

        guard let track = track, !track.isEmbedded else {
            // Switching to embedded audio
            if isEmbeddedAudioDisabled {
                viewModel.isPlayerMuted = true
                StreamifyLogger.log("Audio: Switched to embedded (default) audio — disabled")
                if shouldResumePlayback {
                    playWithSyncedAudio()
                }
                return
            }

            startCompensatedEmbeddedAudio(shouldResume: shouldResumePlayback)
            StreamifyLogger.log("Audio: Switched to compensated embedded audio")
            return
        }
        
        // Switching to external audio — mute embedded audio
        viewModel.isPlayerMuted = true
        
        // Resolve audio URL
        if let url = resolveAudioURL(for: track) {
            loadExternalAudio(from: url, track: track, shouldResume: shouldResumePlayback)
        } else {
            StreamifyLogger.log("Audio: No source found for \(track.language), attempting fallback")
            tryRedownloadAudio(track, shouldResume: shouldResumePlayback)
        }
    }

    func handleMPVAudioTracksChanged(_ tracks: [AudioTrack]) {
        embeddedAudioIsSpatial = tracks.contains { $0.isSpatial }
    }

    // Resolve audio file URL - check local then remote
    func resolveAudioURL(for track: AudioTrack) -> URL? {
        let sourceStr = track.source
        let folderPaths = buildFolderPaths()

        // Check if it's a local file reference
        if let url = localContentFileURL(from: sourceStr, folderPaths: folderPaths) {
            return url
        }
        
        // Check if a locally downloaded version exists (by naming convention)
        let names = possibleLocalFileNames(language: track.language, source: sourceStr, trackType: "audio", defaultExtension: "mp3")
        if let url = findLocalFile(possibleNames: names, in: folderPaths) {
            return url
        }
        
        // Try as remote URL
        if sourceStr.hasPrefix("http"), let url = URL(string: sourceStr) {
            return url
        }
        
        // Fallback: look up from ALL sources for the same content
        let allSources = SourcesManager.allContent()
        let matchingSources = allSources.filter { $0.id == content.id }
        for sourceContent in matchingSources {
            // Episode-specific
            if let ep = currentEpisodeInfo,
               let srcTrack = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks?.first(where: { $0.language == track.language }),
               srcTrack.source.hasPrefix("http"),
               let url = URL(string: srcTrack.source) {
                return url
            }
            // Content-level
            if let srcTrack = sourceContent.audioTracks?.first(where: { $0.language == track.language }),
               srcTrack.source.hasPrefix("http"),
               let url = URL(string: srcTrack.source) {
                return url
            }
        }
        
        // Final fallback: try resolving a remote URL (from HLS-parsed tracks, metadata, etc.)
        if let remoteURL = resolveRemoteAudioURL(for: track) {
            return remoteURL
        }
        
        return nil
    }
    
    // Load external audio and sync with video
    func loadExternalAudio(from url: URL, track: AudioTrack, shouldResume: Bool? = nil) {
        StreamifyLogger.log("Audio: Loading external audio from \(url)")
        let isMPVAudioTrack = viewModel.isMPVAudioTrack(track)
        separateAudioSyncOffsetSeconds = 0
        if isMPVAudioTrack {
            viewModel.disableMPVAudioOutput()
        }

        let originalIsHLS = url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.localizedCaseInsensitiveContains(".m3u8")
        let playbackURL: URL
        if url.isFileURL, originalIsHLS,
           let serverURL = MatroskaPlaybackSupport.playbackURL(for: url) {
            playbackURL = serverURL
            StreamifyLogger.log("Audio: Serving local HLS audio through \(serverURL)")
        } else {
            playbackURL = url
        }
        let isLocalServer = playbackURL.host == "localhost" || playbackURL.host == "127.0.0.1"
        let isHLS = playbackURL.pathExtension.lowercased() == "m3u8"
            || playbackURL.absoluteString.localizedCaseInsensitiveContains(".m3u8")
        let wantsResumePlayback = shouldResume ?? (viewModel.isPlaying || viewModel.playbackRate > 0)
        let shouldResumePlayback = wantsResumePlayback
        if wantsResumePlayback && isPickerOrSwitchAlertPresented {
            pausedPlaybackForPicker = true
            shouldResumeAfterPicker = true
        }
        
        if playbackURL.isFileURL || isLocalServer {
            // Local file or local HLS served via HTTP server
            let audioPlayer = AVPlayer(url: playbackURL)
            // Cap the forward buffer for localhost HLS audio for the same reason as the
            // video player — byte-range prefetching will otherwise buffer unboundedly.
            if isLocalServer && isHLS {
                audioPlayer.currentItem?.preferredForwardBufferDuration = 30
            }
            externalAudioPlayer = audioPlayer
            let wasPlaying = shouldResumePlayback
            viewModel.isPlayerMuted = true  // Mute video's embedded audio
            
            // Observe for playback failures — if local audio fails, fall back to remote
            if let item = audioPlayer.currentItem {
                let statusObserver = item.observe(\.status, options: [.new]) { [self] observedItem, _ in
                    if observedItem.status == .failed {
                        DispatchQueue.main.async {
                            if isMPVAudioTrack {
                                StreamifyLogger.log("Audio: Native MKV audio failed to play for \(track.displayName), falling back to MPV")
                                self.externalAudioPlayer?.pause()
                                self.externalAudioPlayer = nil
                                self.audioBufferingObservers.removeAll()
                                self.isAudioBuffering = false
                                self.viewModel.isPlayerMuted = false
                                self.viewModel.selectMPVAudioTrack(track)
                                if wasPlaying {
                                    self.viewModel.play()
                                }
                                return
                            }
                            StreamifyLogger.log("Audio: Local audio failed to play for \(track.language), falling back to remote")
                            self.externalAudioPlayer?.pause()
                            self.externalAudioPlayer = nil
                            self.audioBufferingObservers.removeAll()
                            self.tryRedownloadAudio(track, shouldResume: nil)
                        }
                    }
                }
                audioBufferingObservers.append(statusObserver)
            }
            
            syncAudioPlayerToVideo(audioPlayer, shouldResume: wasPlaying)
            StreamifyLogger.log("Audio: Loaded local audio for \(track.language), wasPlaying=\(wasPlaying)")
        } else {
            // Remote URL - load asynchronously with buffering detection
            Task {
                do {
                    // Verify URL is reachable with HEAD request (for non-HLS; HLS just attempts playback)
                    if !isHLS {
                        var headRequest = URLRequest(url: playbackURL)
                        headRequest.httpMethod = "HEAD"
                        headRequest.timeoutInterval = 10
                        let (_, response) = try await URLSession.shared.data(for: headRequest)
                        guard let httpResponse = response as? HTTPURLResponse,
                              (200...399).contains(httpResponse.statusCode) else {
                            await MainActor.run {
                                StreamifyLogger.log("Audio: Remote audio returned non-200 for \(track.language)")
                                showAudioErrorAlert = true
                            }
                            return
                        }
                    }
                    
                    await MainActor.run {
                        let audioPlayer = AVPlayer(url: playbackURL)
                        // Enable concurrent downloads for HLS audio
                        if isHLS {
                            audioPlayer.currentItem?.preferredForwardBufferDuration = 30
                        }
                        self.externalAudioPlayer = audioPlayer
                        self.viewModel.isPlayerMuted = true
                        
                        let wasPlaying = shouldResumePlayback
                        self.isAudioBuffering = true
                        
                        // Observe audio buffering state
                        self.observeAudioBuffering(audioPlayer)
                        
                        self.syncAudioPlayerToVideo(audioPlayer, shouldResume: wasPlaying)
                        StreamifyLogger.log("Audio: Loaded remote audio for \(track.language), pausing video until audio is ready")
                    }
                } catch {
                    await MainActor.run {
                        StreamifyLogger.log("Audio: Failed to load remote audio for \(track.language): \(error.localizedDescription)")
                        showAudioErrorAlert = true
                    }
                }
            }
        }
    }
    
    // Observe external audio player buffering to pause video when audio is not ready
    func observeAudioBuffering(_ audioPlayer: AVPlayer) {
        guard let item = audioPlayer.currentItem else { return }
        // Use periodic observation for buffer state
        let bufferObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [self] item, change in
            DispatchQueue.main.async {
                if item.isPlaybackBufferEmpty {
                    self.isAudioBuffering = true
                }
            }
        }
        let keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [self] item, change in
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp {
                    self.isAudioBuffering = false
                }
            }
        }
        audioBufferingObservers = [bufferObserver, keepUpObserver]
    }
    
    func nextAudioSyncGeneration() -> Int {
        audioSyncGeneration += 1
        activeAudioSyncGeneration = audioSyncGeneration
        isSyncingSeparateAudio = true
        return audioSyncGeneration
    }

    func finishAudioSync(_ generation: Int) {
        guard activeAudioSyncGeneration == generation else { return }
        activeAudioSyncGeneration = nil
        isSyncingSeparateAudio = false
        separateAudioPausedForVideoBuffering = false
    }

    func cancelPendingAudioSync() {
        audioSyncGeneration += 1
        activeAudioSyncGeneration = nil
        isSyncingSeparateAudio = false
        separateAudioPausedForVideoBuffering = false
        cancelSkipAudioSyncTasks()
        cancelPiPSeekAudioSyncTask()
        cancelVideoBufferingPauseTask()
    }

    func isCurrentAudioSync(_ generation: Int, audioPlayer: AVPlayer) -> Bool {
        generation == audioSyncGeneration && ownsSeparateAudioPlayer(audioPlayer)
    }

    func cancelVideoBufferingPauseTask() {
        videoBufferingPauseTask?.cancel()
        videoBufferingPauseTask = nil
    }

    func scheduleSeparateAudioPauseIfVideoClockStalls() {
        cancelVideoBufferingPauseTask()
        let baselineSeconds = viewModel.realPlaybackTime
        let work = DispatchWorkItem {
            guard hasSeparateAudioPlayer,
                  viewModel.isBuffering,
                  !isSyncingSeparateAudio else { return }

            let currentSeconds = viewModel.realPlaybackTime
            let videoClockAdvanced = baselineSeconds.isFinite &&
                currentSeconds.isFinite &&
                currentSeconds > baselineSeconds + 0.03
            guard !videoClockAdvanced else { return }

            separateAudioPausedForVideoBuffering = viewModel.isPlaying || viewModel.playbackRate > 0
            pauseSeparateAudio(cancelSync: false)
            StreamifyLogger.log("Audio: Paused separate audio because video clock stalled during buffering")
        }
        videoBufferingPauseTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func waitForAudioReady(audioPlayer: AVPlayer, generation: Int, completion: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else {
                self.isAudioBuffering = false
                return
            }
            guard let item = audioPlayer.currentItem else {
                self.isAudioBuffering = false
                Task { @MainActor in completion() }
                return
            }

            func canStart(_ item: AVPlayerItem, attempts: Int) -> Bool {
                if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                    return true
                }
                if item.status == .readyToPlay,
                   let urlAsset = item.asset as? AVURLAsset {
                    let url = urlAsset.url
                    if url.isFileURL || url.host == "localhost" || url.host == "127.0.0.1" {
                        return true
                    }
                }
                return attempts >= 100
            }

            if canStart(item, attempts: 0) {
                self.isAudioBuffering = false
                Task { @MainActor in
                    guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }
                    completion()
                }
                return
            }

            var attempts = 0

            func checkReady() {
                attempts += 1
                guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer),
                      let currentItem = audioPlayer.currentItem else {
                    self.isAudioBuffering = false
                    return
                }

                if canStart(currentItem, attempts: attempts) {
                    self.isAudioBuffering = false
                    Task { @MainActor in
                        guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }
                        completion()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        checkReady()
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                checkReady()
            }
        }
    }

    func syncAudioPlayerToVideo(_ audioPlayer: AVPlayer, at videoSeconds: Double? = nil, shouldResume: Bool) {
        if shouldResume {
            guard !pausePlaybackForPresentedPicker() else {
                audioPlayer.pause()
                return
            }
        }

        let generation = nextAudioSyncGeneration()
        let targetSeconds = resolvedAudioSyncTarget(videoSeconds)
        let targetTime = Self.exactPlayerTime(for: targetSeconds)
        let needsSeekGate = consumeSeekedPlaybackVideoGate()
        let shouldGateAudioStart = shouldResume &&
            !viewModel.isUsingMPVPlayback &&
            (needsSeekGate || separateAudioRequiresVideoClockGate(audioPlayer))

        if !shouldResume {
            viewModel.pause()
        } else if shouldGateAudioStart {
            separateAudioPausedForVideoBuffering = false
        }
        audioPlayer.pause()

        audioPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
            Task { @MainActor in
                guard let audioPlayer,
                      self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }

                @MainActor
                func finishSync() {
                    guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }

                    if shouldResume {
                        guard !self.pausePlaybackForPresentedPicker() else {
                            audioPlayer.pause()
                            self.finishAudioSync(generation)
                            return
                        }
                        StreamifyLogger.log("Audio: Synced separate audio at \(String(format: "%.2f", targetSeconds))s, resuming")
                        if shouldGateAudioStart {
                            self.startAudioAfterVideoClockAdvances(audioPlayer, generation: generation, baselineSeconds: targetSeconds)
                        } else {
                            self.viewModel.play {
                                Task { @MainActor in
                                    guard self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }
                                    defer { self.finishAudioSync(generation) }
                                    guard (self.viewModel.playbackRate > 0 || self.viewModel.isPlaying),
                                          !self.viewModel.isBuffering,
                                          !self.isPickerOrSwitchAlertPresented else { return }
                                    audioPlayer.play()
                                    StreamifyLogger.log("Audio: Started separate audio with video at \(String(format: "%.2f", targetSeconds))s")
                                }
                            }
                        }
                    } else {
                        StreamifyLogger.log("Audio: Synced separate audio at \(String(format: "%.2f", targetSeconds))s, staying paused")
                        self.viewModel.pause()
                        audioPlayer.pause()
                        self.finishAudioSync(generation)
                    }
                }

                guard shouldResume else {
                    self.isAudioBuffering = false
                    finishSync()
                    return
                }

                self.waitForAudioReady(audioPlayer: audioPlayer, generation: generation) {
                    finishSync()
                }
            }
        }
    }

    func markSeekedPlaybackNeedsVideoGate() {
        gateAudioStartForNextResume = true
    }

    func consumeSeekedPlaybackVideoGate() -> Bool {
        let shouldGate = gateAudioStartForNextResume
        gateAudioStartForNextResume = false
        return shouldGate
    }

    func startAudioAfterVideoClockAdvances(_ audioPlayer: AVPlayer, generation: Int, baselineSeconds: Double) {
        guard !pausePlaybackForPresentedPicker() else {
            audioPlayer.pause()
            finishAudioSync(generation)
            return
        }

        viewModel.play()

        Task { @MainActor in
            while !Task.isCancelled, isCurrentAudioSync(generation, audioPlayer: audioPlayer) {
                if isPickerOrSwitchAlertPresented {
                    pausePlaybackForPresentedPicker()
                    audioPlayer.pause()
                    finishAudioSync(generation)
                    return
                }

                let videoSeconds = viewModel.realPlaybackTime
                let videoIsPlaying = viewModel.playbackRate > 0 || viewModel.isPlaying
                let videoAdvanced = videoSeconds.isFinite && videoSeconds > baselineSeconds + 0.03

                if videoIsPlaying && videoAdvanced && !viewModel.isBuffering {
                    let audioStartSeconds = max(videoSeconds.isFinite ? videoSeconds : baselineSeconds, 0)
                    audioPlayer.seek(to: Self.exactPlayerTime(for: audioStartSeconds), toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
                        Task { @MainActor in
                            guard let audioPlayer,
                                  self.isCurrentAudioSync(generation, audioPlayer: audioPlayer) else { return }
                            defer { self.finishAudioSync(generation) }
                            guard (self.viewModel.playbackRate > 0 || self.viewModel.isPlaying),
                                  !self.viewModel.isBuffering,
                                  !self.isPickerOrSwitchAlertPresented else { return }
                            audioPlayer.play()
                            StreamifyLogger.log("Audio: Started separate audio after video clock advanced to \(String(format: "%.2f", audioStartSeconds))s")
                        }
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func resolvedAudioSyncTarget(_ explicitSeconds: Double?) -> Double {
        if let explicitSeconds {
            return max(explicitSeconds, 0)
        }

        let realSeconds = viewModel.realPlaybackTime
        let displayedSeconds = viewModel.currentTime

        if displayedSeconds.isFinite,
           abs(displayedSeconds - realSeconds) > 0.75 {
            return max(displayedSeconds, 0)
        }

        return max(realSeconds + separateAudioSyncOffsetSeconds, 0)
    }

    func separateAudioRequiresVideoClockGate(_ audioPlayer: AVPlayer) -> Bool {
        guard let url = (audioPlayer.currentItem?.asset as? AVURLAsset)?.url else { return false }
        return url.pathExtension.lowercased() == "m3u8" ||
            url.absoluteString.localizedCaseInsensitiveContains(".m3u8")
    }
    
    // Try to re-download an audio track
    func tryRedownloadAudio(_ track: AudioTrack, shouldResume: Bool? = nil) {
        // If the local file actually exists on disk, the failure is transient
        // (e.g. local HTTP server not yet ready after returning from background).
        // In that case do NOT remove from metadata — just retry resolving.
        if isAudioLocallyAvailable(track) {
            StreamifyLogger.log("Audio: Track \(track.language) local file exists — server may be starting, retrying in 1s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let url = self.resolveAudioURL(for: track) {
                    self.loadExternalAudio(from: url, track: track, shouldResume: shouldResume)
                } else {
                    StreamifyLogger.log("Audio: Retry failed for \(track.language) — local server still unavailable, not removing metadata")
                    self.showAudioErrorAlert = true
                }
            }
            return
        }
        
        var remoteURL: URL?
        
        if track.source.hasPrefix("http"), let url = URL(string: track.source) {
            remoteURL = url
        }
        
        if remoteURL == nil {
            // Search ALL sources for the same content and language
            let allSources = SourcesManager.allContent()
            let matchingSources = allSources.filter { $0.id == content.id }
            for sourceContent in matchingSources {
                if let ep = currentEpisodeInfo,
                   let srcTrack = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks?.first(where: { $0.language == track.language }),
                   srcTrack.source.hasPrefix("http"),
                   let url = URL(string: srcTrack.source) {
                    remoteURL = url
                    break
                }
                if let srcTrack = sourceContent.audioTracks?.first(where: { $0.language == track.language }),
                   srcTrack.source.hasPrefix("http"),
                   let url = URL(string: srcTrack.source) {
                    remoteURL = url
                    break
                }
            }
        }
        
        guard let downloadURL = remoteURL else {
            StreamifyLogger.log("Audio: No remote source available for \(track.language)")
            if isLocalAudioReference(track) {
                StreamifyLogger.log("Audio: Keeping local metadata for \(track.displayName); source could not be resolved this time")
            }
            showAudioErrorAlert = true
            return
        }
        
        // Notify user that fallback remote source is being used
        audioFallbackMessage = "Local audio for \(track.displayName) could not be found. Using remote source as fallback."
        
        // Update metadata to store the remote URL (replacing broken local reference)
        let metadataFolder = effectiveFolderPath
        updateTrackInMetadata(metadataFolder: metadataFolder, audioLanguage: track.language, localSource: downloadURL.absoluteString, sourceName: track.sourceName)
        
        loadExternalAudio(from: downloadURL, track: track, shouldResume: shouldResume)
    }

    func isLocalAudioReference(_ track: AudioTrack) -> Bool {
        let source = track.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if track.originalTrackId?.hasPrefix("mpv-audio-") == true { return true }
        if track.sourceName == "MKV" { return true }
        if source.localizedCaseInsensitiveContains(".m3u8") { return true }
        if source.isEmpty { return false }
        if let url = URL(string: source),
           let host = url.host,
           host == "localhost" || host == "127.0.0.1" {
            return true
        }
        return !source.hasPrefix("http")
    }
    
    // Remove a broken audio track from metadata
    func removeAudioFromMetadata(language: String) {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty else { return }
        guard var metadata = ContentImportService.loadMetadata(from: folderPath) else { return }
        
        // Only remove locally-downloaded tracks (non-HTTP source) — keep online/stream tracks intact
        let isLocalTrack: (AudioTrack) -> Bool = { track in
            track.language.lowercased() == language.lowercased() && !track.source.isEmpty && !track.source.hasPrefix("http")
        }
        
        var changed = false
        
        if let ep = currentEpisodeInfo {
            if var episodes = metadata.episodes {
                if let idx = episodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                    let episode = episodes[idx]
                    if var tracks = episode.audioTracks {
                        let before = tracks.count
                        tracks.removeAll(where: isLocalTrack)
                        if tracks.count < before {
                            episodes[idx] = episode.copying(audioTracks: .some(tracks.isEmpty ? nil : tracks))
                            changed = true
                        }
                    }
                }
                if changed {
                    metadata = metadata.copying(episodes: episodes)
                }
            }
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var sEpisodes = seasons[sIdx].episodes {
                        if seasons[sIdx].season == ep.season, let eIdx = sEpisodes.firstIndex(where: { $0.episode == ep.episode }) {
                            let episode = sEpisodes[eIdx]
                            if var tracks = episode.audioTracks {
                                let before = tracks.count
                                tracks.removeAll(where: isLocalTrack)
                                if tracks.count < before {
                                    sEpisodes[eIdx] = episode.copying(audioTracks: .some(tracks.isEmpty ? nil : tracks))
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
            if var tracks = metadata.audioTracks {
                let before = tracks.count
                tracks.removeAll(where: isLocalTrack)
                if tracks.count < before {
                    metadata = metadata.copying(audioTracks: .some(tracks.isEmpty ? nil : tracks))
                    changed = true
                }
            }
        }
        
        if changed {
            ContentImportService.saveMetadata(metadata, to: folderPath)
            refreshLocalMasterAndCleanupIfEmpty()
            StreamifyLogger.log("Audio: Removed local \(language) audio track from metadata")
        }
    }
    
    /// Delete downloaded audio files for a given language from disk and update metadata.
    func deleteLocalAudio(for track: AudioTrack) {
        let language = track.language
        let folderPaths = buildFolderPaths()
        let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
        let lang = language.lowercased().replacingOccurrences(of: " ", with: "_")
        
        // Collect all possible local file paths and HLS directories to delete
        var pathsToDelete: [URL] = []
        
        // Single audio files (e.g., audio_russian.mp3, ep1_audio_russian.m4a, etc.)
        let extensions = ["mp3", "m4a", "aac", "ogg", "opus"]
        for ext in extensions {
            let names: [String]
            if !prefix.isEmpty {
                names = ["\(prefix)audio_\(lang).\(ext)", "audio_\(lang).\(ext)"]
            } else {
                names = ["audio_\(lang).\(ext)"]
            }
            for folder in folderPaths where !folder.isEmpty {
                for name in names {
                    let url = ContentImportService.contentDirectoryURL
                        .appendingPathComponent(folder)
                        .appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        pathsToDelete.append(url)
                    }
                }
            }
        }
        
        // Local file referenced in track source (non-http)
        let sourceStr = track.source
        if !sourceStr.hasPrefix("http") && !sourceStr.isEmpty {
            for folder in folderPaths where !folder.isEmpty {
                let folderURL = ContentImportService.contentDirectoryURL
                    .appendingPathComponent(folder)
                let url = folderURL
                    .appendingPathComponent(sourceStr)
                if FileManager.default.fileExists(atPath: url.path) {
                    pathsToDelete.append(url)
                }
                let parent = url.deletingLastPathComponent()
                if parent.path != folderURL.path,
                   FileManager.default.fileExists(atPath: parent.path) {
                    pathsToDelete.append(parent)
                }
            }
        }
        
        // HLS audio directories (e.g., audio_russian/ or ep1_audio_russian/)
        let dirNames = prefix.isEmpty ? ["audio_\(lang)"] : ["\(prefix)audio_\(lang)", "audio_\(lang)"]
        for folder in folderPaths where !folder.isEmpty {
            for dirName in dirNames {
                let dirURL = ContentImportService.contentDirectoryURL
                    .appendingPathComponent(folder)
                    .appendingPathComponent(dirName)
                if FileManager.default.fileExists(atPath: dirURL.path) {
                    pathsToDelete.append(dirURL)
                }
            }
        }
        
        // Delete files
        for url in pathsToDelete {
            do {
                try FileManager.default.removeItem(at: url)
                StreamifyLogger.log("Audio: Deleted \(url.lastPathComponent)")
            } catch {
                StreamifyLogger.log("Audio: Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        // Remove from metadata
        removeAudioFromMetadata(language: language)
        refreshLocalMasterAndCleanupIfEmpty()
        
        // Force picker UI refresh
        pickerRefreshId += 1
        
        // If currently playing this audio, switch back to embedded
        if selectedAudioLanguage == language {
            selectedAudioLanguage = ""
            selectedAudioTrackId = ""
            applyAudioTrack(nil)
        }
        
        StreamifyLogger.log("Audio: Deleted local audio for \(language)")
    }
    
    func deleteLocalSubtitle(for track: SubtitleTrack) {
        let language = track.language
        let folderPaths = buildFolderPaths()
        let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
        let lang = language.lowercased().replacingOccurrences(of: " ", with: "_")
        
        var pathsToDelete: [URL] = []
        
        let extensions = ["vtt", "srt", "ass", "ssa", "sub", "txt"]
        for ext in extensions {
            let names: [String]
            if !prefix.isEmpty {
                names = ["\(prefix)subtitle_\(lang).\(ext)", "subtitle_\(lang).\(ext)"]
            } else {
                names = ["subtitle_\(lang).\(ext)"]
            }
            for folder in folderPaths where !folder.isEmpty {
                for name in names {
                    let url = ContentImportService.contentDirectoryURL
                        .appendingPathComponent(folder)
                        .appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        pathsToDelete.append(url)
                    }
                }
            }
        }
        
        // Local file referenced in track source (non-http)
        let sourceStr = track.source
        if !sourceStr.hasPrefix("http") && !sourceStr.isEmpty {
            for folder in folderPaths where !folder.isEmpty {
                let folderURL = ContentImportService.contentDirectoryURL
                    .appendingPathComponent(folder)
                let url = folderURL
                    .appendingPathComponent(sourceStr)
                if FileManager.default.fileExists(atPath: url.path) {
                    pathsToDelete.append(url)
                }
                let parent = url.deletingLastPathComponent()
                if parent.path != folderURL.path,
                   FileManager.default.fileExists(atPath: parent.path) {
                    pathsToDelete.append(parent)
                }
            }
        }
        
        for url in pathsToDelete {
            do {
                try FileManager.default.removeItem(at: url)
                StreamifyLogger.log("Subtitle: Deleted \(url.lastPathComponent)")
            } catch {
                StreamifyLogger.log("Subtitle: Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        removeSubtitleFromMetadata(language: language)
        refreshLocalMasterAndCleanupIfEmpty()
        
        // Force picker UI refresh
        pickerRefreshId += 1
        
        if selectedSubtitleLanguage == language {
            selectedSubtitleLanguage = ""
            applySubtitleTrack(nil)
        }
        
        StreamifyLogger.log("Subtitle: Deleted local subtitle for \(language)")
    }
}
