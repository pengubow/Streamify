import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Subtitle picker
    var subtitlePicker: some View {
        StreamifyPickerShell(
            title: "Subtitles",
            trailingTitle: "Done",
            trailingAction: { showSubtitleSheet = false }
        ) {
                // Off option
                Button {
                    selectedSubtitleLanguage = ""
                    selectedSubtitleTrackId = ""
                    applySubtitleTrack(nil)
                    showSubtitleSheet = false
                } label: {
                    HStack {
                        Text("Off")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedSubtitleLanguage.isEmpty && selectedSubtitleTrackId.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                        }
                    }
                    .streamifyPickerButtonLabel()
                }
                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                .streamifyPickerRow(selected: selectedSubtitleLanguage.isEmpty && selectedSubtitleTrackId.isEmpty)

                let _ = pickerRefreshId // force refresh on delete
                let subs = availableSubtitles
                let downloadedSubs = subs.filter { isSubtitleLocallyAvailable($0) }
                
                // Downloaded subtitle section
                if !downloadedSubs.isEmpty {
                    Text("Downloaded")
                        .streamifyPickerSectionTitle()

                        let grouped = Dictionary(grouping: downloadedSubs, by: { $0.displayName })
                        let sortedKeys = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                        StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { displayName in
                            let groupTracks = grouped[displayName] ?? []
                            if groupTracks.count == 1 {
                                subtitlePickerRow(track: groupTracks[0], showButtons: true)
                            } else {
                                let isExpanded = expandedSubtitleGroup == "dl_\(displayName)"
                                Button {
                                    StreamifyPickerMotion.toggle($expandedSubtitleGroup, value: "dl_\(displayName)")
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
                                .streamifyPickerRow(selected: isExpanded || groupTracks.contains { isSubtitleTrackSelected($0) })

                                StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                    StreamifyPickerBatchedForEach(groupTracks, id: \.trackId) { track in
                                        subtitlePickerRow(track: track, showButtons: true)
                                            .streamifyPickerExpandedItem(indented: true)
                                    }
                                }
                            }
                        }
                }
                
                // Stream subtitle section — show tracks that have remote sources,
                // plus already-downloaded tracks (they appear without download button,
                // matching the quality picker's behavior).
                // For MPV/Matroska playback, this section carries embedded MKV tracks.
                if (!viewModel.isLocalFile || viewModel.isUsingMPVPlayback) && !subs.isEmpty {
                    let streamSubs = subs.filter { track in
                        if viewModel.isUsingMPVPlayback && viewModel.isLocalFile {
                            return viewModel.isMPVSubtitleTrack(track)
                        }
                        return viewModel.isMPVSubtitleTrack(track) ||
                            track.source.hasPrefix("http") ||
                            resolveRemoteSubtitleURL(for: track) != nil ||
                            isSubtitleLocallyAvailable(track)
                    }
                    if !streamSubs.isEmpty {
                        Text(viewModel.isUsingMPVPlayback && viewModel.isLocalFile ? "MKV" : "Stream")
                            .streamifyPickerSectionTitle()

                            let grouped = Dictionary(grouping: streamSubs, by: { $0.displayName })
                            let sortedKeys = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                            StreamifyPickerBatchedForEach(sortedKeys, id: \.self) { displayName in
                                let groupTracks = grouped[displayName] ?? []
                                if groupTracks.count == 1 {
                                    subtitlePickerRow(track: groupTracks[0], showButtons: true, isDownloadedSection: false)
                            } else {
                                let isExpanded = expandedSubtitleGroup == "st_\(displayName)"
                                Button {
                                    StreamifyPickerMotion.toggle($expandedSubtitleGroup, value: "st_\(displayName)")
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
                                    .streamifyPickerRow(selected: isExpanded || groupTracks.contains { isSubtitleTrackSelected($0) })

                                    StreamifyPickerExpandableGroup(isExpanded: isExpanded) {
                                        StreamifyPickerBatchedForEach(groupTracks, id: \.trackId) { track in
                                            subtitlePickerRow(track: track, showButtons: true, isDownloadedSection: false)
                                                .streamifyPickerExpandedItem(indented: true)
                                        }
                                    }
                                }
                            }
                    }
                }
        }
    }

    // Subtitle variant picker for duplicate languageIds
    var subtitleVariantPicker: some View {
        StreamifyPickerShell(
            title: "Choose Version",
            trailingTitle: "Done",
            trailingAction: { showSubtitleVariantSheet = false }
        ) {
            StreamifyPickerBatchedForEach(subtitleVariantTracks, id: \.trackId) { track in
                subtitlePickerRow(track: track)
            }
        }
    }
    
    @ViewBuilder
    func subtitlePickerRow(track: SubtitleTrack, showButtons: Bool = false, isDownloadedSection: Bool = true) -> some View {
        let isLocal = isSubtitleLocallyAvailable(track)
        HStack {
            Button {
                selectedSubtitleLanguage = track.language
                selectedSubtitleTrackId = track.trackId
                applySubtitleTrack(track)
                // Dismiss variant sheet first (if open), then parent
                if showSubtitleVariantSheet {
                    showSubtitleVariantSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showSubtitleSheet = false
                    }
                } else {
                    showSubtitleSheet = false
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayName)
                            .foregroundStyle(.primary)
                        Text(subtitleTrackDebugText(track))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.gray)
                    }
                    if let sn = track.sourceName {
                        SourceBadge(sourceName: sn)
                    }
                    Spacer()
                    if isSubtitleTrackSelected(track) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.white)
                    }
                }
                .streamifyPickerButtonLabel()
            }
            if showButtons {
                let hasRemoteSource = resolveRemoteSubtitleURL(for: track) != nil
                // Delete button for locally downloaded subtitles — only in Downloaded section
                if isLocal && isDownloadedSection {
                    Button {
                        deleteLocalSubtitle(for: track)
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
                    } else if let externalDL = findMatchingTrackDownload(trackType: "subtitle", language: track.language) {
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
                            downloadTrackLocally(subtitle: track)
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
        .streamifyPickerRow(selected: isSubtitleTrackSelected(track))
    }

    func isSubtitleTrackSelected(_ track: SubtitleTrack) -> Bool {
        if !selectedSubtitleTrackId.isEmpty {
            if track.trackId == selectedSubtitleTrackId {
                return true
            }
            if availableSubtitles.contains(where: { $0.trackId == selectedSubtitleTrackId }) {
                return false
            }
        }
        return !selectedSubtitleLanguage.isEmpty && selectedSubtitleLanguage == track.language
    }

    func subtitleTrackDebugText(_ track: SubtitleTrack) -> String {
        "id \(TrackIdentity.shortDisplayId(track.trackId)) · lang \(track.languageId)"
    }

    // MARK: - Apply subtitle track
    func applySubtitleTrack(_ track: SubtitleTrack?, completion: @escaping @MainActor () -> Void = {}) {
        cancelNativeMatroskaSubtitlePreparation()
        subtitleCues = []
        currentSubtitleText = ""
        
        guard let track = track else {
            if viewModel.isUsingMPVPlayback {
                viewModel.selectMPVSubtitleTrack(nil)
            }
            StreamifyLogger.log("Subtitle: Turned off")
            completion()
            return
        }

        if viewModel.isUsingMPVPlayback {
            viewModel.selectMPVSubtitleTrack(nil)
            if viewModel.isMPVSubtitleTrack(track) {
                if startNativeMatroskaSubtitleIfNeeded(track, completion: completion) {
                    return
                }
                viewModel.selectMPVSubtitleTrack(track)
                StreamifyLogger.log("Subtitle: Switched MPV subtitle to \(track.displayName)")
                completion()
                return
            }
            if let url = resolveSubtitleURL(for: track) {
                StreamifyLogger.log("Subtitle: Loading external subtitle in Swift overlay from \(url)")
                loadVTTSubtitles(from: url, completion: completion)
                return
            }
            StreamifyLogger.log("Subtitle: No subtitle source found for \(track.language) on MPV playback")
            showSubtitleErrorAlert = true
            completion()
            return
        }

        if let url = resolveSubtitleURL(for: track) {
            if url.isFileURL {
                // Local file - check if it actually exists
                if FileManager.default.fileExists(atPath: url.path) {
                    StreamifyLogger.log("Subtitle: Loading VTT from local file \(url)")
                    loadVTTSubtitles(from: url, completion: completion)
                } else {
                    // Local file not found - try to re-download
                    StreamifyLogger.log("Subtitle: Local file not found at \(url.path), attempting re-download")
                    tryRedownloadSubtitle(track, completion: completion)
                }
            } else {
                StreamifyLogger.log("Subtitle: Loading VTT from \(url)")
                loadVTTSubtitles(from: url, completion: completion)
            }
        } else {
            // No URL resolved - try to find a remote source and download
            StreamifyLogger.log("Subtitle: No subtitle source found for \(track.language), attempting fallback download")
            tryRedownloadSubtitle(track, completion: completion)
        }
    }

    @discardableResult
    func startNativeMatroskaSubtitleIfNeeded(_ track: SubtitleTrack, completion: @escaping @MainActor () -> Void = {}) -> Bool {
        guard viewModel.isUsingMPVPlayback,
              currentVideoURL.isFileURL,
              MatroskaPlaybackSupport.isMatroskaURL(currentVideoURL),
              viewModel.isMPVSubtitleTrack(track) else { return false }

        if nativeMatroskaSubtitleTask != nil && nativeMatroskaSubtitleTrackId == track.trackId {
            return true
        }

        let subtitleIndex = mpvSubtitleIndex(for: track)
        nativeMatroskaSubtitleTask?.cancel()
        nativeMatroskaSubtitleTrackId = track.trackId
        isSubtitlePreparing = true
        viewModel.selectMPVSubtitleTrack(nil)

        let fileURL = currentVideoURL
        nativeMatroskaSubtitleTask = Task {
            let sidecarURL = await MatroskaPlaybackSupport.prepareNativeSubtitleSidecar(
                for: fileURL,
                track: track,
                subtitleIndex: subtitleIndex
            )

            await MainActor.run {
                guard nativeMatroskaSubtitleTrackId == track.trackId else { return }
                nativeMatroskaSubtitleTask = nil
                nativeMatroskaSubtitleTrackId = nil
                isSubtitlePreparing = false

                guard let sidecarURL else {
                    StreamifyLogger.log("Subtitle: MKV extraction failed for \(track.displayName); using live mpv text overlay")
                    viewModel.selectMPVSubtitleTrack(track)
                    completion()
                    return
                }

                loadVTTSubtitles(from: sidecarURL, completion: completion)
                StreamifyLogger.log("Subtitle: Using Swift overlay for MKV subtitle \(track.displayName)")
            }
        }

        return true
    }

    func cancelNativeMatroskaSubtitlePreparation() {
        nativeMatroskaSubtitleTask?.cancel()
        nativeMatroskaSubtitleTask = nil
        nativeMatroskaSubtitleTrackId = nil
        isSubtitlePreparing = false
    }

    func mpvSubtitleIndex(for track: SubtitleTrack) -> Int {
        if let indexValue = URLComponents(string: track.source)?
            .queryItems?
            .first(where: { $0.name == "index" })?
            .value,
           let index = Int(indexValue) {
            return index
        }
        return viewModel.mpvSubtitleTracks.firstIndex { $0.trackId == track.trackId } ?? 0
    }

    // Try to re-download a subtitle track from remote sources
    func tryRedownloadSubtitle(_ track: SubtitleTrack, completion: @escaping @MainActor () -> Void = {}) {
        // Find remote URL for this subtitle
        var remoteURL: URL?
        
        // Check if the track source itself is a remote URL
        if track.source.hasPrefix("http"), let url = URL(string: track.source) {
            remoteURL = url
        }
        
        // Fallback: look up from sources
        if remoteURL == nil {
            let allSources = SourcesManager.allContent()
            if let sourceContent = allSources.first(where: { $0.id == content.id }) {
                // Check episode-specific subtitles first
                if let ep = currentEpisodeInfo,
                   let epSubs = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles,
                   let sourceTrack = epSubs.first(where: { $0.language == track.language }),
                   sourceTrack.source.hasPrefix("http"),
                   let url = URL(string: sourceTrack.source) {
                    remoteURL = url
                }
                // Then content-level subtitles
                if remoteURL == nil,
                   let sourceTrack = sourceContent.subtitles?.first(where: { $0.language == track.language }),
                   sourceTrack.source.hasPrefix("http"),
                   let url = URL(string: sourceTrack.source) {
                    remoteURL = url
                }
            }
        }
        
        guard let downloadURL = remoteURL else {
            StreamifyLogger.log("Subtitle: No remote source available for \(track.language)")
            removeSubtitleFromMetadata(language: track.language)
            showSubtitleErrorAlert = true
            completion()
            return
        }
        
        // Update metadata to store the remote URL (replacing broken local reference)
        let metadataFolder = effectiveFolderPath
        updateTrackInMetadata(metadataFolder: metadataFolder, subtitleLanguage: track.language, localSource: downloadURL.absoluteString, sourceName: track.sourceName)
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: downloadURL)
                if let vttContent = String(data: data, encoding: .utf8) {
                    let cues = await Task.detached(priority: .userInitiated) {
                        parseVTT(vttContent)
                    }.value
                    await MainActor.run {
                        self.subtitleCues = cues
                        StreamifyLogger.log("Subtitle: Re-downloaded and loaded \(cues.count) cues for \(track.language)")
                        completion()
                    }
                } else {
                    await MainActor.run {
                        StreamifyLogger.log("Subtitle: Re-download returned invalid data for \(track.language)")
                        removeSubtitleFromMetadata(language: track.language)
                        showSubtitleErrorAlert = true
                        completion()
                    }
                }
            } catch {
                await MainActor.run {
                    StreamifyLogger.log("Subtitle: Re-download failed for \(track.language): \(error.localizedDescription)")
                    removeSubtitleFromMetadata(language: track.language)
                    showSubtitleErrorAlert = true
                    completion()
                }
            }
        }
    }
    
    // Remove a downloaded subtitle track from metadata — only removes local tracks, keeps online/stream tracks
    func removeSubtitleFromMetadata(language: String) {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty else { return }
        guard var metadata = ContentImportService.loadMetadata(from: folderPath) else { return }
        
        // Only remove locally-downloaded tracks (non-HTTP source) — keep online/stream tracks intact
        let isLocalTrack: (SubtitleTrack) -> Bool = { track in
            track.language.lowercased() == language.lowercased() && !track.source.isEmpty && !track.source.hasPrefix("http")
        }
        
        var changed = false
        
        if let ep = currentEpisodeInfo {
            // Remove from episode-specific subtitles within episodes array
            if var episodes = metadata.episodes {
                if let idx = episodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode }) {
                    let episode = episodes[idx]
                    if var subs = episode.subtitles {
                        let before = subs.count
                        subs.removeAll(where: isLocalTrack)
                        if subs.count < before {
                            episodes[idx] = episode.copying(subtitles: .some(subs.isEmpty ? nil : subs))
                            changed = true
                        }
                    }
                }
                if changed {
                    metadata = metadata.copying(episodes: episodes)
                }
            }
            // Also remove from within seasons
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var sEpisodes = seasons[sIdx].episodes {
                        if seasons[sIdx].season == ep.season, let eIdx = sEpisodes.firstIndex(where: { $0.episode == ep.episode }) {
                            let episode = sEpisodes[eIdx]
                            if var subs = episode.subtitles {
                                let before = subs.count
                                subs.removeAll(where: isLocalTrack)
                                if subs.count < before {
                                    sEpisodes[eIdx] = episode.copying(subtitles: .some(subs.isEmpty ? nil : subs))
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
            // Movie: remove from content-level subtitles
            if var subs = metadata.subtitles {
                let before = subs.count
                subs.removeAll(where: isLocalTrack)
                if subs.count < before {
                    metadata = metadata.copying(subtitles: .some(subs.isEmpty ? nil : subs))
                    changed = true
                }
            }
        }
        
        if changed {
            ContentImportService.saveMetadata(metadata, to: folderPath)
            refreshLocalMasterAndCleanupIfEmpty()
            StreamifyLogger.log("Subtitle: Removed local \(language) subtitle from metadata")
        }
    }
    
    func loadVTTSubtitles(from url: URL, completion: @escaping @MainActor () -> Void = {}) {
        isSubtitlePreparing = true
        Task {
            do {
                let content: String
                if url.isFileURL {
                    content = try await Task.detached(priority: .userInitiated) {
                        try String(contentsOf: url, encoding: .utf8)
                    }.value
                } else {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let loadedContent = String(data: data, encoding: .utf8) else {
                        await MainActor.run {
                            self.isSubtitlePreparing = false
                            StreamifyLogger.log("Subtitle: Failed to decode VTT from \(url.absoluteString)")
                            completion()
                        }
                        return
                    }
                    content = loadedContent
                }

                let cues = await Task.detached(priority: .userInitiated) {
                    parseVTT(content)
                }.value

                await MainActor.run {
                    self.isSubtitlePreparing = false
                    self.subtitleCues = cues
                    let source = url.isFileURL ? "local file" : "remote URL"
                    StreamifyLogger.log("Subtitle: Loaded \(cues.count) cues from \(source)")
                    completion()
                }
            } catch {
                await MainActor.run {
                    self.isSubtitlePreparing = false
                    StreamifyLogger.log("Subtitle: Failed to load VTT: \(error.localizedDescription)")
                    completion()
                }
            }
        }
    }
}
