import SwiftUI

extension ContentDetailView {
    // MARK: - Helpers
    func downloadMissingThumbnail() {
        guard !currentContent.folderPath.isEmpty else { return }
        
        let remoteURL: URL?
        if let sourceContent = sourceContent {
            remoteURL = sourceContent.thumbnailUrl.flatMap { URL(string: $0) }
        } else if let thumbnail = currentContent.metadata.thumbnail, thumbnail.hasPrefix("http") {
            remoteURL = URL(string: thumbnail)
        } else {
            remoteURL = nil
        }
        
        guard let url = remoteURL else { return }
        
        Task {
            let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(currentContent.folderPath)
            if let localFilename = await ContentImportService.downloadImage(from: url, to: destDir, filename: "thumbnail") {
                var library = ContentImportService.loadLibrary()
                if let index = library.firstIndex(where: { $0.id == currentContent.id }) {
                    let updatedContent = library[index]
                    let updatedMetadata = updatedContent.metadata.copying(thumbnail: localFilename)
                    library[index] = SavedContent(
                        id: updatedContent.id,
                        metadata: updatedMetadata,
                        folderPath: updatedContent.folderPath,
                        dateAdded: updatedContent.dateAdded
                    )
                    ContentImportService.addToLibrary(library[index])
                    viewModel.refreshLibrary()
                }
            }
        }
    }
    
    func addSourceContentToLibrary(_ sourceContent: SourceContent) {
        isAddingToLibrary = true
        
        Task {
            await viewModel.addToLibrary(from: sourceContent)
            
            await MainActor.run {
                isAddingToLibrary = false
                if let error = viewModel.importError {
                    downloadError = error
                    showDownloadError = true
                    viewModel.clearImportError()
                }
            }
        }
    }

    // MARK: - Downloaded Track Helpers
    
    /// Get locally downloaded audio tracks for a movie (episode=nil) or episode
    func getLocalAudioTracks(for episode: EpisodeInfo?) -> [AudioTrack] {
        let current = currentContent
        let tracks: [AudioTrack]?
        if let ep = episode {
            tracks = current.metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks
        } else {
            tracks = current.metadata.audioTracks
        }
        return (tracks ?? []).filter { !$0.isEmbedded && !$0.source.isEmpty && !$0.source.hasPrefix("http") }
    }
    
    /// Get locally downloaded subtitle tracks for a movie (episode=nil) or episode
    func getLocalSubtitleTracks(for episode: EpisodeInfo?) -> [SubtitleTrack] {
        let current = currentContent
        let tracks: [SubtitleTrack]?
        if let ep = episode {
            tracks = current.metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles
        } else {
            tracks = current.metadata.subtitles
        }
        return (tracks ?? []).filter { !$0.source.isEmpty && !$0.source.hasPrefix("http") }
    }
    
    /// Get downloaded video qualities for a movie (episode=nil) or episode
    func getDownloadedQualities(for episode: EpisodeInfo?) -> [DownloadedVideoQuality] {
        let current = currentContent
        if let ep = episode {
            return current.metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.downloadedVideoQualities ?? []
        } else {
            return current.metadata.downloadedVideoQualities ?? []
        }
    }
    
    /// Load locally downloaded audio tracks directly from disk metadata (bypasses stale library cache)
    func getLocalAudioTracksFromDisk(for episode: EpisodeInfo?) -> [AudioTrack] {
        let safeId = content.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content.id
        let folderPath = content.folderPath.isEmpty ? safeId : content.folderPath
        guard let metadata = ContentImportService.loadMetadata(from: folderPath) else { return [] }
        let tracks: [AudioTrack]?
        if let ep = episode {
            tracks = metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks
        } else {
            tracks = metadata.audioTracks
        }
        return (tracks ?? []).filter { !$0.isEmbedded && !$0.source.isEmpty && !$0.source.hasPrefix("http") }
    }
    
    /// Load locally downloaded subtitle tracks directly from disk metadata (bypasses stale library cache)
    func getLocalSubtitleTracksFromDisk(for episode: EpisodeInfo?) -> [SubtitleTrack] {
        let safeId = content.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content.id
        let folderPath = content.folderPath.isEmpty ? safeId : content.folderPath
        guard let metadata = ContentImportService.loadMetadata(from: folderPath) else { return [] }
        let tracks: [SubtitleTrack]?
        if let ep = episode {
            tracks = metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles
        } else {
            tracks = metadata.subtitles
        }
        return (tracks ?? []).filter { !$0.source.isEmpty && !$0.source.hasPrefix("http") }
    }
    
    /// Load downloaded video qualities directly from disk metadata (bypasses stale library cache)
    func getDownloadedQualitiesFromDisk(for episode: EpisodeInfo?) -> [DownloadedVideoQuality] {
        let safeId = content.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? content.id
        let folderPath = content.folderPath.isEmpty ? safeId : content.folderPath
        guard let metadata = ContentImportService.loadMetadata(from: folderPath) else { return [] }
        if let ep = episode {
            return metadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.downloadedVideoQualities ?? []
        } else {
            return metadata.downloadedVideoQualities ?? []
        }
    }

    // MARK: - Remove Download Picker Sheet
    
    var removeDownloadPickerSheet: some View {
        RemoveDownloadPickerView(
            episode: removePickerEpisode,
            hasVideo: removePickerEpisode.map { isEpisodeDownloaded($0) } ?? hasLocalVideoFile(),
            qualityName: removePickerEpisode?.qualityName ?? currentContent.metadata.downloadedQuality,
            downloadedQualities: getDownloadedQualities(for: removePickerEpisode),
            audioTracks: getLocalAudioTracks(for: removePickerEpisode),
            subtitleTracks: getLocalSubtitleTracks(for: removePickerEpisode),
            onRemove: { selection in
                applyGranularRemoval(selection: selection, episode: removePickerEpisode)
                showRemovePicker = false
            },
            onCancel: {
                showRemovePicker = false
            }
        )
    }
    
    /// Apply selective removal of downloaded items
    func applyGranularRemoval(selection: RemoveSelection, episode: EpisodeInfo?) {
        let current = currentContent
        let folderPath = current.folderPath
        guard !folderPath.isEmpty else { return }

        let audioTracksToRemove = getLocalAudioTracksFromDisk(for: episode)
            .filter { selection.audioTrackIds.contains($0.trackId) }
        let subtitleTracksToRemove = getLocalSubtitleTracksFromDisk(for: episode)
            .filter { selection.subtitleTrackIds.contains($0.trackId) }
        
        // Remove video files
        if selection.removeVideo {
            // Remove all video files
            if let ep = episode {
                removeEpisodeVideoOnly(ep)
            } else {
                removeMovieVideoOnly()
            }
        } else if !selection.removeQualityIds.isEmpty {
            // Remove only specific quality directories/files
            let qualities = getDownloadedQualities(for: episode)
            let qualitiesToRemove = qualities.filter { selection.removeQualityIds.contains($0.qualityId) }
            for dq in qualitiesToRemove {
                let baseDirForQuality: URL
                if let ep = episode {
                    baseDirForQuality = ContentImportService.contentDirectoryURL
                        .appendingPathComponent("\(folderPath)/\(DownloadManager.episodeSubfolder(season: ep.season, episode: ep.episode))")
                } else {
                    baseDirForQuality = ContentImportService.contentDirectoryURL
                        .appendingPathComponent(folderPath)
                }
                
                let dirName = (dq.localSource as NSString).deletingLastPathComponent
                if !dirName.isEmpty && dirName != "." {
                    // HLS quality in a subdirectory (e.g., "video_1080p_uuid/video.m3u8")
                    let dirURL = baseDirForQuality.appendingPathComponent(dirName)
                    if FileManager.default.fileExists(atPath: dirURL.path) {
                        try? FileManager.default.removeItem(at: dirURL)
                    }
                } else {
                    // Single file quality (e.g., "video.mp4")
                    let fileURL = baseDirForQuality.appendingPathComponent(dq.localSource)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        removeMatroskaCompanion(for: fileURL)
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
        }
        
        let baseDirURL = ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
        if let ep = episode {
            // Episode-specific folder
            let epFolderURL = ContentImportService.contentDirectoryURL
                .appendingPathComponent("\(folderPath)/\(DownloadManager.episodeSubfolder(season: ep.season, episode: ep.episode))")
            removeSelectedTracks(
                baseDirURL: epFolderURL,
                audioTracks: audioTracksToRemove,
                subtitleTracks: subtitleTracksToRemove
            )
            // Also try base folder
            removeSelectedTracks(
                baseDirURL: baseDirURL,
                audioTracks: audioTracksToRemove,
                subtitleTracks: subtitleTracksToRemove
            )
        } else {
            removeSelectedTracks(
                baseDirURL: baseDirURL,
                audioTracks: audioTracksToRemove,
                subtitleTracks: subtitleTracksToRemove
            )
        }
        
        // Update metadata
        updateMetadataAfterTrackRemoval(selection: selection, episode: episode)
        viewModel.refreshLibrary()
    }
    
    /// Delete audio/subtitle files from disk for selected items
    func removeSelectedTracks(
        baseDirURL: URL,
        audioTracks: [AudioTrack],
        subtitleTracks: [SubtitleTrack]
    ) {
        guard FileManager.default.fileExists(atPath: baseDirURL.path) else { return }
        var deletedPaths = Set<String>()

        for track in audioTracks {
            removeLocalTrackSource(track.source, baseDirURL: baseDirURL, deletedPaths: &deletedPaths)
        }
        for track in subtitleTracks {
            removeLocalTrackSource(track.source, baseDirURL: baseDirURL, deletedPaths: &deletedPaths)
        }
    }

    func removeLocalTrackSource(_ source: String, baseDirURL: URL, deletedPaths: inout Set<String>) {
        guard !source.isEmpty, !source.hasPrefix("http") else { return }
        let url = baseDirURL.appendingPathComponent(source)
        let parent = url.deletingLastPathComponent()
        let shouldRemoveParent = url.pathExtension.localizedCaseInsensitiveCompare("m3u8") == .orderedSame

        if shouldRemoveParent, parent.path != baseDirURL.path, FileManager.default.fileExists(atPath: parent.path) {
            removeLocalURL(parent, deletedPaths: &deletedPaths)
        } else if FileManager.default.fileExists(atPath: url.path) {
            removeLocalURL(url, deletedPaths: &deletedPaths)
        }
    }

    func removeLocalURL(_ url: URL, deletedPaths: inout Set<String>) {
        guard deletedPaths.insert(url.path).inserted else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    /// Update metadata after selective track removal
    func updateMetadataAfterTrackRemoval(selection: RemoveSelection, episode: EpisodeInfo?) {
        var library = ContentImportService.loadLibrary()
        guard let contentIndex = library.firstIndex(where: { $0.id == content.id }) else { return }
        let saved = library[contentIndex]
        
        if let ep = episode {
            // Update episode metadata
            var updatedEpisodes = saved.metadata.episodes ?? []
            if let epIndex = updatedEpisodes.firstIndex(where: { $0.episode == ep.episode && $0.season == ep.season }) {
                let currentEp = updatedEpisodes[epIndex]
	                
                var audioTracks = currentEp.audioTracks ?? []
                audioTracks.removeAll { track in selection.audioTrackIds.contains(track.trackId) }
	                
                var subtitles = currentEp.subtitles ?? []
                subtitles.removeAll { track in selection.subtitleTrackIds.contains(track.trackId) }
                
                // Handle video quality removal
                let remainingQualities: [DownloadedVideoQuality]? = {
                    if selection.removeVideo { return nil }
                    guard !selection.removeQualityIds.isEmpty else { return currentEp.downloadedVideoQualities }
                    let filtered = (currentEp.downloadedVideoQualities ?? []).filter { !selection.removeQualityIds.contains($0.qualityId) }
                    return filtered.isEmpty ? nil : filtered
                }()
                let hadQualities = !(currentEp.downloadedVideoQualities ?? []).isEmpty
                let shouldClearLocalFile = selection.removeVideo ||
                    (!selection.removeQualityIds.isEmpty && hadQualities && (remainingQualities?.isEmpty ?? true))
                
                updatedEpisodes[epIndex] = currentEp.copying(
                    file: shouldClearLocalFile ? .some(currentEp.file?.hasPrefix("http") == true ? currentEp.file : nil) : nil,
                    hlsUrl: shouldClearLocalFile ? .some(currentEp.hlsUrl?.hasPrefix("http") == true ? currentEp.hlsUrl : nil) : nil,
                    localFile: shouldClearLocalFile ? .some(nil) : nil,
                    qualityName: shouldClearLocalFile ? .some(nil) : nil,
                    subtitles: .some(subtitles.isEmpty ? nil : subtitles),
                    audioTracks: .some(audioTracks.isEmpty ? nil : audioTracks),
                    downloadedVideoQualities: remainingQualities
                )
            }
            
            // Also update seasons structure
            var updatedSeasons = saved.metadata.seasons
            if let seasons = updatedSeasons {
                for seasonIndex in seasons.indices {
                    var season = seasons[seasonIndex]
                    if var seasonEpisodes = season.episodes {
                        for epIdx in seasonEpisodes.indices {
                            if seasonEpisodes[epIdx].episode == ep.episode && season.season == ep.season {
	                                let currentEp = seasonEpisodes[epIdx]
	                                
	                                var audioTracks = currentEp.audioTracks ?? []
	                                audioTracks.removeAll { track in selection.audioTrackIds.contains(track.trackId) }
	                                
	                                var subtitles = currentEp.subtitles ?? []
	                                subtitles.removeAll { track in selection.subtitleTrackIds.contains(track.trackId) }
                                
                                let seasonRemainingQualities: [DownloadedVideoQuality]? = {
                                    if selection.removeVideo { return nil }
                                    guard !selection.removeQualityIds.isEmpty else { return currentEp.downloadedVideoQualities }
                                    let filtered = (currentEp.downloadedVideoQualities ?? []).filter { !selection.removeQualityIds.contains($0.qualityId) }
                                    return filtered.isEmpty ? nil : filtered
                                }()
                                let seasonHadQualities = !(currentEp.downloadedVideoQualities ?? []).isEmpty
                                let seasonShouldClearLocalFile = selection.removeVideo ||
                                    (!selection.removeQualityIds.isEmpty && seasonHadQualities && (seasonRemainingQualities?.isEmpty ?? true))
                                
                                seasonEpisodes[epIdx] = currentEp.copying(
                                    file: seasonShouldClearLocalFile ? .some(currentEp.file?.hasPrefix("http") == true ? currentEp.file : nil) : nil,
                                    hlsUrl: seasonShouldClearLocalFile ? .some(currentEp.hlsUrl?.hasPrefix("http") == true ? currentEp.hlsUrl : nil) : nil,
                                    localFile: seasonShouldClearLocalFile ? .some(nil) : nil,
                                    qualityName: seasonShouldClearLocalFile ? .some(nil) : nil,
                                    subtitles: .some(subtitles.isEmpty ? nil : subtitles),
                                    audioTracks: .some(audioTracks.isEmpty ? nil : audioTracks),
                                    downloadedVideoQualities: seasonRemainingQualities
                                )
                            }
                        }
                        season = SeasonInfo(season: season.season, title: season.title, thumbnailUrl: season.thumbnailUrl, episodes: seasonEpisodes)
                        updatedSeasons?[seasonIndex] = season
                    }
                }
            }
            
            let updatedMetadata = saved.metadata.copying(
                seasons: updatedSeasons,
                episodes: updatedEpisodes
            )
            library[contentIndex] = SavedContent(id: saved.id, metadata: updatedMetadata, folderPath: saved.folderPath, dateAdded: saved.dateAdded)
        } else {
	            // Movie: update content-level metadata
	            var audioTracks = saved.metadata.audioTracks ?? []
	            audioTracks.removeAll { track in selection.audioTrackIds.contains(track.trackId) }
	            
	            var subtitles = saved.metadata.subtitles ?? []
	            subtitles.removeAll { track in selection.subtitleTrackIds.contains(track.trackId) }
            
            // Handle video quality removal
            let movieRemainingQualities: [DownloadedVideoQuality]? = {
                if selection.removeVideo { return nil }
                guard !selection.removeQualityIds.isEmpty else { return saved.metadata.downloadedVideoQualities }
                let filtered = (saved.metadata.downloadedVideoQualities ?? []).filter { !selection.removeQualityIds.contains($0.qualityId) }
                return filtered.isEmpty ? nil : filtered
            }()
            let movieHadQualities = !(saved.metadata.downloadedVideoQualities ?? []).isEmpty
            let movieShouldClearLocalFile = selection.removeVideo ||
                (!selection.removeQualityIds.isEmpty && movieHadQualities && (movieRemainingQualities?.isEmpty ?? true))

            let hlsUrl = movieShouldClearLocalFile ? saved.metadata.remoteHlsUrl : saved.metadata.hlsUrl
            let file = movieShouldClearLocalFile ? saved.metadata.remoteFileUrl : saved.metadata.file

            let updatedMetadata = saved.metadata.copying(
                file: movieShouldClearLocalFile ? .some(file) : nil,
                hlsUrl: movieShouldClearLocalFile ? .some(hlsUrl) : nil,
                downloadedQuality: movieShouldClearLocalFile ? .some(nil) : nil,
                subtitles: .some(subtitles.isEmpty ? nil : subtitles),
                audioTracks: .some(audioTracks.isEmpty ? nil : audioTracks),
                downloadedVideoQualities: movieRemainingQualities
            )
            library[contentIndex] = SavedContent(id: saved.id, metadata: updatedMetadata, folderPath: saved.folderPath, dateAdded: saved.dateAdded)
        }
        
        ContentImportService.addToLibrary(library[contentIndex])
        DownloadManager.shared.refreshLocalMasterPlaylist(metadataFolder: saved.folderPath, episode: episode)
        DownloadManager.shared.cleanupLocalContentFolderIfEmpty(metadataFolder: saved.folderPath, episode: episode)
    }
    
    /// Remove only video files for an episode, preserving audio/subtitle files
    func removeEpisodeVideoOnly(_ episode: EpisodeInfo) {
        let latestContent = currentContent
        let basePath = latestContent.folderPath
        guard !basePath.isEmpty else { return }
        
        let episodeFolderPath = "\(basePath)/\(DownloadManager.episodeSubfolder(season: episode.season, episode: episode.episode))"
        let folderURL = ContentImportService.contentDirectoryURL.appendingPathComponent(episodeFolderPath)
        let mainFolderURL = ContentImportService.contentDirectoryURL.appendingPathComponent(basePath)
        
        let fm = FileManager.default
        
        // Delete video quality subdirectories (e.g. ep1_video_1080p/)
        for dir in [folderURL, mainFolderURL] {
            removeVideoQualityDirs(from: dir)
        }
        
        // Delete local video files, including original Matroska downloads and remuxed sidecars.
        let videoFiles = [
            "video.m3u8",
            "episode_\(episode.episode).m3u8",
            "episode_\(episode.episode).mp4",
            "episode_\(episode.episode).m4v",
            "episode_\(episode.episode).mkv",
            "episode_\(episode.episode).webm",
            "episode_\(episode.episode).streamify.m3u8"
        ]
        for dir in [folderURL, mainFolderURL] {
            for name in videoFiles {
                let fileURL = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: fileURL.path) {
                    MatroskaPlaybackSupport.removeGeneratedFiles(relatedTo: fileURL)
                    try? fm.removeItem(at: fileURL)
                }
            }
            // Delete segments directories
            let segDirs = ["segments", "segments_ep\(episode.episode)", "ep\(episode.episode)_segments"]
            for segName in segDirs {
                let segURL = dir.appendingPathComponent(segName)
                if fm.fileExists(atPath: segURL.path) {
                    try? fm.removeItem(at: segURL)
                }
            }
        }
        
        // If localFile was a quality-subfolder path, delete that too
        if let localFile = episode.localFile, !localFile.isEmpty, !localFile.hasPrefix("http") {
            let dirName = (localFile as NSString).deletingLastPathComponent
            if !dirName.isEmpty && dirName != "." {
                for dir in [folderURL, mainFolderURL] {
                    let dirURL = dir.appendingPathComponent(dirName)
                    if fm.fileExists(atPath: dirURL.path) {
                        try? fm.removeItem(at: dirURL)
                    }
                }
            }
        }
    }
    
    /// Remove only video files for a movie, preserving audio/subtitle files
    func removeMovieVideoOnly() {
        let latestContent = currentContent
        guard !latestContent.folderPath.isEmpty else { return }
        
        let folderURL = ContentImportService.contentDirectoryURL.appendingPathComponent(latestContent.folderPath)
        let fm = FileManager.default
        
        // Delete video quality subdirectories (e.g. video_1080p/)
        removeVideoQualityDirs(from: folderURL)
        
        // Delete local video files, including original Matroska downloads and remuxed sidecars.
        let videoExtensions = ["m3u8", "mp4", "m4v", "mkv", "webm"]
        if let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) {
            for item in contents {
                let itemLower = item.lowercased()
                if videoExtensions.contains(where: { itemLower.hasSuffix(".\($0)") }) {
                    let fileURL = folderURL.appendingPathComponent(item)
                    MatroskaPlaybackSupport.removeGeneratedFiles(relatedTo: fileURL)
                    try? fm.removeItem(at: fileURL)
                }
            }
        }
        
        // Delete segments directory
        let segURL = folderURL.appendingPathComponent("segments")
        if fm.fileExists(atPath: segURL.path) {
            try? fm.removeItem(at: segURL)
        }
        
        // If hlsUrl was a local quality-subfolder path, delete that
        if let hlsUrl = latestContent.metadata.hlsUrl, !hlsUrl.isEmpty, !hlsUrl.hasPrefix("http") {
            let dirName = (hlsUrl as NSString).deletingLastPathComponent
            if !dirName.isEmpty && dirName != "." {
                let dirURL = folderURL.appendingPathComponent(dirName)
                if fm.fileExists(atPath: dirURL.path) {
                    try? fm.removeItem(at: dirURL)
                }
            }
        }
    }
    
    /// Remove video quality subdirectories from a folder (items containing "video_" but not "audio_" or "subtitle_")
    func removeVideoQualityDirs(from folderURL: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) {
            for item in contents {
                if item.contains("video_") && !item.contains("audio_") && !item.contains("subtitle_") {
                    let itemURL = folderURL.appendingPathComponent(item)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
                        try? fm.removeItem(at: itemURL)
                    }
                }
            }
        }
    }

    func removeMatroskaCompanion(for fileURL: URL) {
        MatroskaPlaybackSupport.removeGeneratedFiles(relatedTo: fileURL)
    }
}
