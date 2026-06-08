import Foundation

nonisolated enum ContentImportService {

    // MARK: - File paths

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var contentDirectoryURL: URL {
        documentsURL.appendingPathComponent("Content")
    }

    private static func shouldUseDirectMatroskaPlayback(_ url: URL) -> Bool {
        MPVDirectPlayerEngine.isAvailable && MatroskaPlaybackSupport.isMatroskaURL(url)
    }

    static var libraryFileURL: URL {
        documentsURL.appendingPathComponent("library.json")
    }

    // MARK: - Import content from a source with a specific ID
    static func importContent(from urlString: String, withId contentId: String, title: String, description: String, type: ContentType, genre: Genre?, thumbnailUrl: String?, downloadHLS: Bool = false, episodes: [EpisodeInfo]? = nil, genres: [Genre]? = nil, seasons: [SeasonInfo]? = nil) async throws -> SavedContent {
        guard let url = URL(string: urlString) else {
            throw ImportError.invalidURL
        }
        
        let safeId = contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
        let destDir = contentDirectoryURL.appendingPathComponent(safeId)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        if downloadHLS {
            let localM3U8Path = try await downloadHLSStream(from: url, to: destDir, baseURL: url)
            
            let metadata = ContentMetadata(
                id: contentId,
                title: title,
                description: description,
                type: type,
                genre: genre,
                genres: genres,
                thumbnail: thumbnailUrl,
                file: nil,
                hlsUrl: localM3U8Path,
                seasons: seasons,
                episodes: episodes
            )
            
            let savedContent = SavedContent(id: contentId, metadata: metadata, folderPath: safeId, dateAdded: Date())
            addToLibrary(savedContent)
            
            return savedContent
        } else {
            let metadata = ContentMetadata(
                id: contentId,
                title: title,
                description: description,
                type: type,
                genre: genre,
                genres: genres,
                thumbnail: thumbnailUrl,
                file: nil,
                hlsUrl: urlString,
                seasons: seasons,
                episodes: episodes
            )
            
            let savedContent = SavedContent(id: contentId, metadata: metadata, folderPath: safeId, dateAdded: Date())
            addToLibrary(savedContent)
            
            return savedContent
        }
    }
    

    // MARK: - Download HLS stream for offline playback
    // Parses the master m3u8, finds highest quality, downloads all fragments
    private static func downloadHLSStream(from masterURL: URL, to destDir: URL, baseURL: URL) async throws -> String {
        // Fetch master playlist
        try Task.checkCancellation()
        let (masterData, _) = try await URLSession.shared.data(from: masterURL)
        try Task.checkCancellation()
        
        guard let masterContent = String(data: masterData, encoding: .utf8) else {
            throw ImportError.downloadFailed
        }
        
        // Sort by bandwidth (highest first) and pick the best quality
        let variants = HLSManifestParser.parseStreamVariants(from: masterContent)
            .filter { $0.bandwidth > 0 }
            .sorted { $0.bandwidth > $1.bandwidth }
        
        let variantURL: URL
        let variantContent: String
        if let bestVariant = variants.first {
            // Resolve the variant playlist URL
            if bestVariant.uri.hasPrefix("http") {
                guard let url = URL(string: bestVariant.uri) else {
                    throw ImportError.downloadFailed
                }
                variantURL = url
            } else {
                variantURL = baseURL.deletingLastPathComponent().appendingPathComponent(bestVariant.uri)
            }
            
            // Fetch variant playlist
            try Task.checkCancellation()
            let (variantData, _) = try await URLSession.shared.data(from: variantURL)
            try Task.checkCancellation()
            
            guard let fetchedVariantContent = String(data: variantData, encoding: .utf8) else {
                throw ImportError.downloadFailed
            }
            variantContent = fetchedVariantContent
        } else if masterContent.contains("#EXTINF:") {
            // Some sources provide a media playlist directly instead of a
            // master playlist. The input URL is already the selected variant.
            variantURL = masterURL
            variantContent = masterContent
        } else {
            throw ImportError.downloadFailed
        }
        
        // Parse variant playlist for segments
        let mediaPlaylist = HLSManifestParser.parseMediaPlaylist(from: variantContent)
        let segments = mediaPlaylist.segments.map(\.uri)
        let segmentDurations = mediaPlaylist.segments.map(\.duration)
        
        // Download all segments
        let segmentsDir = destDir.appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        
        for (index, segmentURL) in segments.enumerated() {
            let segmentURLResolved: URL
            if segmentURL.hasPrefix("http") {
                guard let url = URL(string: segmentURL) else { continue }
                segmentURLResolved = url
            } else {
                segmentURLResolved = variantURL.deletingLastPathComponent().appendingPathComponent(segmentURL)
            }
            
            do {
                try Task.checkCancellation()
                let (data, _) = try await URLSession.shared.data(from: segmentURLResolved)
                try Task.checkCancellation()
                
                let segmentFileName = String(format: "segment_%05d.ts", index)
                let segmentPath = segmentsDir.appendingPathComponent(segmentFileName)
                try data.write(to: segmentPath)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                StreamifyLogger.log("Failed to download segment \(index): \(error)")
            }
        }
        
        // Create local m3u8 playlist with relative paths
        var localPlaylist = "#EXTM3U\n"
        localPlaylist += "#EXT-X-VERSION:3\n"
        localPlaylist += "#EXT-X-TARGETDURATION:10\n"
        localPlaylist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        
        for (index, duration) in segmentDurations.enumerated() {
            localPlaylist += String(format: "#EXTINF:%.1f,\n", duration)
            localPlaylist += "segments/segment_\(String(format: "%05d", index)).ts\n"
        }
        
        localPlaylist += "#EXT-X-ENDLIST\n"
        
        let localM3U8Path = destDir.appendingPathComponent("video.m3u8")
        try localPlaylist.write(to: localM3U8Path, atomically: true, encoding: .utf8)
        
        return "video.m3u8"
    }
    
    // MARK: - Download image from remote URL with custom filename
    static func downloadImage(from url: URL, to destDir: URL, filename: String) async -> String? {
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)
            
            let (tempURL, _) = try await session.download(from: url)
            let rawExt = url.pathExtension.lowercased()
            let ext = ["jpg", "jpeg", "png", "webp"].contains(rawExt) ? rawExt : "jpg"
            let imageName = "\(filename).\(ext)"
            let imageURL = destDir.appendingPathComponent(imageName)
            // Remove existing file to avoid moveItem failure
            try? FileManager.default.removeItem(at: imageURL)
            try FileManager.default.moveItem(at: tempURL, to: imageURL)
            return imageName
        } catch {
            return nil
        }
    }

    // MARK: - Library persistence (Compressed JSON)

    /// Compressed library file
    private static var libraryZlibURL: URL {
        documentsURL.appendingPathComponent("library.json.zlib")
    }

    static func loadLibraryEntries() -> [LibraryEntry] {
        do {
            return try CompressedJSON.readWithFallback(
                [LibraryEntry].self,
                compressedURL: libraryZlibURL,
                plainURL: libraryFileURL
            )
        } catch {
            return []
        }
    }

    static func saveLibraryEntries(_ entries: [LibraryEntry]) {
        do {
            try CompressedJSON.write(entries, to: libraryZlibURL)
        } catch {
            StreamifyLogger.log("Failed to save library entries: \(error)")
        }
    }
    
    static func loadMetadata(from folderPath: String) -> ContentMetadata? {
        guard !folderPath.isEmpty else { return nil }
        let folder = contentDirectoryURL.appendingPathComponent(folderPath)
        let zlibURL = folder.appendingPathComponent("metadata.json.zlib")
        let plainURL = folder.appendingPathComponent("metadata.json")
        if let metadata = try? CompressedJSON.readWithFallback(ContentMetadata.self, compressedURL: zlibURL, plainURL: plainURL) {
            return metadata
        }
        // Local metadata not found — fall back to sources
        let allSources = SourcesManager.allContent()
        if let src = allSources.first(where: { $0.id == folderPath || $0.id == folderPath.removingPercentEncoding }) {
            StreamifyLogger.log("ContentImportService: Local metadata 404 for '\(folderPath)', using source fallback")
            return src.toContentMetadata()
        }
        StreamifyLogger.log("ContentImportService: 404 — metadata not found for '\(folderPath)' (local and sources)")
        return nil
    }
    
    static func saveMetadata(_ metadata: ContentMetadata, to folderPath: String) {
        guard !folderPath.isEmpty else { return }
        let folder = contentDirectoryURL.appendingPathComponent(folderPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zlibURL = folder.appendingPathComponent("metadata.json.zlib")
        do {
            try CompressedJSON.write(metadata, to: zlibURL)
        } catch {
            StreamifyLogger.log("Failed to save metadata for \(folderPath): \(error)")
        }
    }

    static func loadLibrary() -> [SavedContent] {
        let entries = loadLibraryEntries()
        return entries.compactMap { entry in
            guard let metadata = loadMetadata(from: entry.folderPath) else { return nil }
            return SavedContent(entry: entry, metadata: metadata)
        }
        .sorted { $0.dateAdded > $1.dateAdded }
    }

    static func saveLibrary(_ library: [SavedContent]) {
        let sortedLibrary = library.sorted { $0.dateAdded > $1.dateAdded }
        let entries = sortedLibrary.map { $0.libraryEntry }
        saveLibraryEntries(entries)
        for content in sortedLibrary {
            saveMetadata(content.metadata, to: content.folderPath)
        }
    }
    
    static func addToLibrary(_ content: SavedContent) {
        var entries = loadLibraryEntries()
        entries.removeAll { $0.id == content.id }
        entries.insert(content.libraryEntry, at: 0)
        saveLibraryEntries(entries)
        saveMetadata(content.metadata, to: content.folderPath)
    }

    static func deleteContent(_ content: SavedContent) {
        if !content.folderPath.isEmpty {
            let folderPath = contentDirectoryURL.appendingPathComponent(content.folderPath)
            if FileManager.default.fileExists(atPath: folderPath.path) {
                try? FileManager.default.removeItem(at: folderPath)
            }
        }
        var entries = loadLibraryEntries()
        entries.removeAll { $0.id == content.id }
        saveLibraryEntries(entries)
    }

    // MARK: - Resolve the playback URL for a content item or episode
    static func videoURL(for content: SavedContent, episode: EpisodeInfo? = nil) -> URL? {
        let folderPath = contentDirectoryURL.appendingPathComponent(content.folderPath)
        var (isServerRunning, serverBaseURL) = LocalServer.shared.getServerInfo()
        
        if let episode = episode {
            // Prefer highest quality from downloadedVideoQualities (if any exist on disk)
            if let qualities = episode.downloadedVideoQualities, !qualities.isEmpty {
                let episodeFolder = "\(content.folderPath)/\(DownloadManager.episodeSubfolder(season: episode.season, episode: episode.episode))"
                let episodeDir = contentDirectoryURL.appendingPathComponent(episodeFolder)
                let sorted = sortedQualitiesForPlayback(qualities)
                for dq in sorted {
                    let localPath = episodeDir.appendingPathComponent(dq.localSource)
                    if FileManager.default.fileExists(atPath: localPath.path) {
                        if shouldUseDirectMatroskaPlayback(localPath) {
                            return localPath
                        }
                        if dq.localSource.hasSuffix(".m3u8") {
                            if !isServerRunning {
                                isServerRunning = LocalServer.shared.ensureRunning()
                                serverBaseURL = LocalServer.shared.getServerInfo().baseURL
                            }
                            if isServerRunning {
                                let playbackSource = localHLSPlaybackSource(for: dq, in: episodeDir)
                                return URL(string: "\(serverBaseURL)/\(episodeFolder)/\(playbackSource)")
                            }
                        }
                        return localPath
                    }
                }
            }
            
            // Check for localFile (downloaded episodes)
            if let localFile = episode.localFile, !content.folderPath.isEmpty {
                let episodeFolder = "\(content.folderPath)/\(DownloadManager.episodeSubfolder(season: episode.season, episode: episode.episode))"
                let episodeSpecificPath = contentDirectoryURL.appendingPathComponent(episodeFolder)
                let localFilePath = episodeSpecificPath.appendingPathComponent(localFile)

                if FileManager.default.fileExists(atPath: localFilePath.path) {
                    if shouldUseDirectMatroskaPlayback(localFilePath) {
                        return localFilePath
                    }
                    if localFile.hasSuffix(".m3u8") {
                        if !isServerRunning {
                            isServerRunning = LocalServer.shared.ensureRunning()
                            let info = LocalServer.shared.getServerInfo()
                            serverBaseURL = info.baseURL
                        }
                        if isServerRunning {
                            let playbackSource = localHLSPlaybackSource(
                                for: localFile,
                                in: episodeSpecificPath,
                                isHDR: textSuggestsHDR(episode.qualityName)
                            )
                            return URL(string: "\(serverBaseURL)/\(episodeFolder)/\(playbackSource)")
                        }
                    }
                    return localFilePath
                }
                
                let localFileInMain = folderPath.appendingPathComponent(localFile)
                if FileManager.default.fileExists(atPath: localFileInMain.path) {
                    if shouldUseDirectMatroskaPlayback(localFileInMain) {
                        return localFileInMain
                    }
                    if localFile.hasSuffix(".m3u8") {
                        if !isServerRunning {
                            isServerRunning = LocalServer.shared.ensureRunning()
                            let info = LocalServer.shared.getServerInfo()
                            serverBaseURL = info.baseURL
                        }
                        if isServerRunning {
                            let playbackSource = localHLSPlaybackSource(
                                for: localFile,
                                in: folderPath,
                                isHDR: textSuggestsHDR(episode.qualityName)
                            )
                            return URL(string: "\(serverBaseURL)/\(content.folderPath)/\(playbackSource)")
                        }
                    }
                    return localFileInMain
                }
            }
            
            // Fall back to remote URLs
            if let hlsUrl = episode.hlsUrl, hlsUrl.hasPrefix("http") {
                return URL(string: hlsUrl)
            }
            if let hlsUrl = content.metadata.hlsUrl, hlsUrl.hasPrefix("http") {
                return URL(string: hlsUrl)
            }
            if let file = episode.file, file.hasPrefix("http") {
                return URL(string: file)
            }
            if let file = content.metadata.file, file.hasPrefix("http") {
                return URL(string: file)
            }
            // Fall back to HLS URL from sources
            if let sourceHlsURL = remoteHlsURL(for: content) {
                return sourceHlsURL
            }
            return nil
        }
        
        // Movie content - prefer highest quality from downloadedVideoQualities
        if let qualities = content.metadata.downloadedVideoQualities, !qualities.isEmpty, !content.folderPath.isEmpty {
            let sorted = sortedQualitiesForPlayback(qualities)
            for dq in sorted {
                let localPath = folderPath.appendingPathComponent(dq.localSource)
                if FileManager.default.fileExists(atPath: localPath.path) {
                    if shouldUseDirectMatroskaPlayback(localPath) {
                        return localPath
                    }
                    if dq.localSource.hasSuffix(".m3u8") {
                        if !isServerRunning {
                            isServerRunning = LocalServer.shared.ensureRunning()
                            serverBaseURL = LocalServer.shared.getServerInfo().baseURL
                        }
                        if isServerRunning {
                            let playbackSource = localHLSPlaybackSource(for: dq, in: folderPath)
                            return URL(string: "\(serverBaseURL)/\(content.folderPath)/\(playbackSource)")
                        }
                    }
                    return localPath
                }
            }
        }
        
        // Movie content - check local files first
        let videoM3U8 = folderPath.appendingPathComponent("video.m3u8")
        if FileManager.default.fileExists(atPath: videoM3U8.path) {
            if !isServerRunning {
                isServerRunning = LocalServer.shared.ensureRunning()
                let info = LocalServer.shared.getServerInfo()
                serverBaseURL = info.baseURL
            }
            if isServerRunning {
                let playbackSource = localHLSPlaybackSource(
                    for: "video.m3u8",
                    in: folderPath,
                    isHDR: textSuggestsHDR(content.metadata.downloadedQuality)
                )
                return URL(string: "\(serverBaseURL)/\(content.folderPath)/\(playbackSource)")
            }
        }
        
        // Check for local HLS using metadata's hlsUrl field (only if it's a local path)
        if let hlsUrl = content.metadata.hlsUrl, !hlsUrl.hasPrefix("http"), !content.folderPath.isEmpty {
            let localHLS = folderPath.appendingPathComponent(hlsUrl)
            if FileManager.default.fileExists(atPath: localHLS.path) {
                if hlsUrl.hasSuffix(".m3u8") {
                    if !isServerRunning {
                        isServerRunning = LocalServer.shared.ensureRunning()
                        let info = LocalServer.shared.getServerInfo()
                        serverBaseURL = info.baseURL
                    }
                    if isServerRunning {
                        let playbackSource = localHLSPlaybackSource(
                            for: hlsUrl,
                            in: folderPath,
                            isHDR: textSuggestsHDR(content.metadata.downloadedQuality)
                        )
                        return URL(string: "\(serverBaseURL)/\(content.folderPath)/\(playbackSource)")
                    }
                }
                return localHLS
            }
        }
        
        // Check for local file using metadata's file field (only if it's a local path)
        if let file = content.metadata.file, !file.hasPrefix("http"), !content.folderPath.isEmpty {
            let localFile = folderPath.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: localFile.path) {
                if shouldUseDirectMatroskaPlayback(localFile) {
                    return localFile
                }
                return localFile
            }
        }
        
        // Check for any direct local video file in the folder.
        if !content.folderPath.isEmpty {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath.path) {
                for file in files {
                    let localFile = folderPath.appendingPathComponent(file)
                    let lowercased = file.lowercased()
                    guard lowercased.hasSuffix(".mp4") ||
                            lowercased.hasSuffix(".mov") ||
                            lowercased.hasSuffix(".m4v") ||
                            lowercased.hasSuffix(".mkv") ||
                            lowercased.hasSuffix(".webm") else {
                        continue
                    }
                    if shouldUseDirectMatroskaPlayback(localFile) {
                        return localFile
                    }
                    return localFile
                }
            }
        }
        
        // Fall back to remote URL
        if let hlsUrl = content.metadata.hlsUrl, hlsUrl.hasPrefix("http") {
            return URL(string: hlsUrl)
        }
        if let file = content.metadata.file, file.hasPrefix("http") {
            return URL(string: file)
        }
        // Fall back to HLS URL from sources
        if let sourceHlsURL = remoteHlsURL(for: content) {
            return sourceHlsURL
        }
        
        return nil
    }

    // MARK: - Resolve thumbnail URL (supports both remote URLs and local filenames)
    static func thumbnailURL(for content: SavedContent) -> URL? {
        guard let thumbnail = content.metadata.thumbnail else { return nil }
        
        // If it's a remote URL, return it directly
        if thumbnail.hasPrefix("http") { return URL(string: thumbnail) }
        
        // If it's a local filename, check if file exists
        if !content.folderPath.isEmpty {
            let localURL = contentDirectoryURL
                .appendingPathComponent(content.folderPath)
                .appendingPathComponent(thumbnail)
            
            // Check if local file exists
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }
        
        // Return nil - caller should fall back to remote URL if available
        return nil
    }
    
    // MARK: - Get thumbnail URL with remote fallback
    // Returns local if exists, otherwise tries to get remote from sources
    static func thumbnailURLWithFallback(for content: SavedContent) -> URL? {
        // First try local
        if let localURL = thumbnailURL(for: content) {
            return localURL
        }
        
        // Try to get remote URL from sources
        if let remoteURL = getRemoteThumbnailURL(for: content) {
            return remoteURL
        }
        
        // If thumbnail is already a remote URL, use it
        if let thumbnail = content.metadata.thumbnail, thumbnail.hasPrefix("http") {
            return URL(string: thumbnail)
        }
        
        return nil
    }

    // MARK: - Get thumbnail URL from source content
    static func thumbnailURL(from sourceContent: SourceContent) -> URL? {
        if let thumbnailUrl = sourceContent.thumbnailUrl,
           let url = URL(string: thumbnailUrl) {
            return url
        }
        if let posterUrl = sourceContent.posterThumbnailUrl,
           let url = URL(string: posterUrl) {
            return url
        }
        return nil
    }

    // MARK: - Get remote thumbnail URL from sources
    private static func getRemoteThumbnailURL(for content: SavedContent) -> URL? {
        let sources = SourcesManager.loadSources()
        
        for source in sources {
            for sourceContent in source.movies {
                if sourceContent.id == content.id {
                    if let thumbnailUrl = sourceContent.thumbnailUrl {
                        return URL(string: thumbnailUrl)
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Get remote HLS URL from sources
    static func remoteHlsURL(for content: SavedContent) -> URL? {
        let sources = SourcesManager.loadSources()
        
        for source in sources {
            for sourceContent in source.movies {
                if sourceContent.id == content.id {
                    if let hlsUrl = sourceContent.hlsUrl,
                       let url = URL(string: hlsUrl) {
                        return url
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Get poster thumbnail URL for cards (uses posterThumbnail, falls back to thumbnail)
    static func posterThumbnailURL(for content: SavedContent) -> URL? {
        // First try local posterThumbnail file
        if let posterThumbnail = content.metadata.posterThumbnail {
            if posterThumbnail.hasPrefix("http") {
                return URL(string: posterThumbnail)
            }
            
            // Try local file
            if !content.folderPath.isEmpty {
                let localURL = contentDirectoryURL
                    .appendingPathComponent(content.folderPath)
                    .appendingPathComponent(posterThumbnail)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return localURL
                }
            }
        }
        
        // Try to get poster thumbnail from sources
        if let remotePosterURL = getRemotePosterThumbnailURL(for: content) {
            return remotePosterURL
        }
        
        // Fall back to regular thumbnail
        return thumbnailURLWithFallback(for: content)
    }
    
    // MARK: - Get remote poster thumbnail URL from sources
    private static func getRemotePosterThumbnailURL(for content: SavedContent) -> URL? {
        let sources = SourcesManager.loadSources()
        
        for source in sources {
            for sourceContent in source.movies {
                if sourceContent.id == content.id {
                    if let posterThumbnailUrl = sourceContent.posterThumbnailUrl,
                       let url = URL(string: posterThumbnailUrl) {
                        return url
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Get poster thumbnail URL from source content
    static func posterThumbnailURL(from sourceContent: SourceContent) -> URL? {
        if let posterUrl = sourceContent.posterThumbnailUrl,
           let url = URL(string: posterUrl) {
            return url
        }
        // Fall back to regular thumbnail
        if let thumbnailUrl = sourceContent.thumbnailUrl,
           let url = URL(string: thumbnailUrl) {
            return url
        }
        return nil
    }
    
    // MARK: - Get season-specific thumbnail URL
    // Checks for local file `thumbnail_s{N}.ext`, then remote from season metadata/sources
    // Falls back to the content-level thumbnail
    static func seasonThumbnailURL(for content: SavedContent, season: Int) -> URL? {
        // 1. Check local season-specific file
        if !content.folderPath.isEmpty {
            let destDir = contentDirectoryURL.appendingPathComponent(content.folderPath)
            // Look for thumbnail_s{N}.* files
            if let files = try? FileManager.default.contentsOfDirectory(atPath: destDir.path) {
                for file in files where file.hasPrefix("thumbnail_s\(season).") {
                    let localURL = destDir.appendingPathComponent(file)
                    return localURL
                }
            }
        }
        
        // 2. Check season thumbnailUrl from metadata
        if let seasonInfo = content.metadata.seasonInfo(for: season),
           let thumbUrl = seasonInfo.thumbnailUrl {
            if thumbUrl.hasPrefix("http"), let url = URL(string: thumbUrl) {
                return url
            }
            // Local filename reference
            if !content.folderPath.isEmpty {
                let localURL = contentDirectoryURL
                    .appendingPathComponent(content.folderPath)
                    .appendingPathComponent(thumbUrl)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return localURL
                }
            }
        }
        
        // 3. Check sources for season thumbnail
        let sources = SourcesManager.loadSources()
        for source in sources {
            for sourceContent in source.movies where sourceContent.id == content.id {
                if let srcSeason = sourceContent.seasons?.first(where: { $0.season == season }),
                   let thumbUrl = srcSeason.thumbnailUrl,
                   thumbUrl.hasPrefix("http"),
                   let url = URL(string: thumbUrl) {
                    return url
                }
            }
        }
        
        // 4. Fall back to content-level thumbnail
        return thumbnailURLWithFallback(for: content)
    }
    
    // Returns the URL to download from if a thumbnail needs downloading locally
    private static func thumbnailDownloadURL(current: String?, remoteURL: URL?, in destDir: URL) -> URL? {
        if let current = current {
            if current.hasPrefix("http") { return URL(string: current) }
            if !FileManager.default.fileExists(atPath: destDir.appendingPathComponent(current).path) {
                return remoteURL
            }
            return nil
        }
        return remoteURL
    }
    
    /// Find an existing file on disk matching a filename prefix (e.g. "poster_thumbnail")
    /// Returns the filename (not full path) if found, nil otherwise.
    private static func findExistingFile(prefix: String, in directory: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for file in files where file.hasPrefix(prefix + ".") {
            return file
        }
        return nil
    }

    // MARK: - Download missing thumbnails locally for a library item
    // When thumbnails fall back to remote URLs, download them to the content folder
    // and update metadata so they're available locally next time
    static func downloadMissingThumbnails(for content: SavedContent) async {
        guard !content.folderPath.isEmpty else { return }
        let destDir = contentDirectoryURL.appendingPathComponent(content.folderPath)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Re-read metadata from disk to avoid race with updateLibraryFromSources
        guard var metadata = loadMetadata(from: content.folderPath) else { return }
        var metadataUpdated = false
        
        // Load sources once for remote URL lookups
        let sources = SourcesManager.loadSources()
        var sourceContent: SourceContent?
        for source in sources {
            if let match = source.movies.first(where: { $0.id == content.id }) {
                sourceContent = match
                break
            }
        }
        
        // Check if poster_thumbnail already exists on disk but metadata has a stale/remote value
        if let existing = findExistingFile(prefix: "poster_thumbnail", in: destDir) {
            if metadata.posterThumbnail != existing {
                metadata = metadata.withUpdatedThumbnails(posterThumbnail: existing)
                metadataUpdated = true
            }
        } else {
            let remotePosterUrl = getRemotePosterThumbnailURL(for: content)
            if let url = thumbnailDownloadURL(current: metadata.posterThumbnail, remoteURL: remotePosterUrl, in: destDir) {
                if let downloaded = await downloadImage(from: url, to: destDir, filename: "poster_thumbnail") {
                    metadata = metadata.withUpdatedThumbnails(posterThumbnail: downloaded)
                    metadataUpdated = true
                }
            }
        }
        
        // Check if thumbnail already exists on disk but metadata has a stale/remote value
        // Use "thumbnail." prefix (with dot) to avoid matching "thumbnail_s1.jpg" (season thumbnails)
        let existingThumb = findExistingFile(prefix: "thumbnail", in: destDir)
        if let existing = existingThumb, !existing.hasPrefix("thumbnail_s") {
            // Found a local thumbnail file (e.g. thumbnail.jpg)
            if metadata.thumbnail != existing {
                metadata = metadata.withUpdatedThumbnails(thumbnail: existing)
                metadataUpdated = true
            }
        } else {
            let remoteThumbnailUrl = getRemoteThumbnailURL(for: content)
            if let url = thumbnailDownloadURL(current: metadata.thumbnail, remoteURL: remoteThumbnailUrl, in: destDir) {
                if let downloaded = await downloadImage(from: url, to: destDir, filename: "thumbnail") {
                    metadata = metadata.withUpdatedThumbnails(thumbnail: downloaded)
                    metadataUpdated = true
                }
            }
        }
        
        // Download missing season thumbnails and episode thumbnails within seasons
        if let seasons = metadata.seasons {
            var updatedSeasons: [SeasonInfo] = []
            var seasonsChanged = false
            
            for season in seasons {
                var seasonUpdated = false
                
                // Season thumbnail
                var remoteSeasonThumbUrl: URL? = nil
                if let srcSeason = sourceContent?.seasons?.first(where: { $0.season == season.season }),
                   let thumbUrl = srcSeason.thumbnailUrl,
                   thumbUrl.hasPrefix("http"),
                   let url = URL(string: thumbUrl) {
                    remoteSeasonThumbUrl = url
                }
                
                var updatedSeasonThumb = season.thumbnailUrl
                if let url = thumbnailDownloadURL(current: season.thumbnailUrl, remoteURL: remoteSeasonThumbUrl, in: destDir) {
                    if let downloaded = await downloadImage(from: url, to: destDir, filename: "thumbnail_s\(season.season)") {
                        updatedSeasonThumb = downloaded
                        seasonUpdated = true
                    }
                }
                
                // Episode thumbnails within this season
                var updatedEpisodes: [EpisodeInfo]? = season.episodes
                if let episodes = season.episodes {
                    var epList: [EpisodeInfo] = []
                    var episodesChanged = false
                    
                    for ep in episodes {
                        // Get remote episode thumbnail from source
                        var remoteEpThumbUrl: URL? = nil
                        if let srcSeason = sourceContent?.seasons?.first(where: { $0.season == season.season }),
                           let srcEp = srcSeason.episodes?.first(where: { $0.episode == ep.episode }),
                           let thumbUrl = srcEp.thumbnailUrl,
                           thumbUrl.hasPrefix("http"),
                           let url = URL(string: thumbUrl) {
                            remoteEpThumbUrl = url
                        }
                        
                        if let url = thumbnailDownloadURL(current: ep.thumbnailUrl, remoteURL: remoteEpThumbUrl, in: destDir) {
                            if let downloaded = await downloadImage(from: url, to: destDir, filename: "s\(season.season)_ep\(ep.episode)_thumbnail") {
                                epList.append(EpisodeInfo(
                                    season: season.season, episode: ep.episode,
                                    title: ep.title, description: ep.description,
                                    thumbnailUrl: downloaded,
                                    file: ep.file, hlsUrl: ep.hlsUrl,
                                    localFile: ep.localFile,
                                    intro: ep.intro, introDuration: ep.introDuration, end: ep.end,
                                    qualityName: ep.qualityName,
                                    subtitles: ep.subtitles, audioTracks: ep.audioTracks,
                                    downloadedVideoQualities: ep.downloadedVideoQualities
                                ))
                                episodesChanged = true
                                continue
                            }
                        }
                        epList.append(ep)
                    }
                    
                    if episodesChanged {
                        updatedEpisodes = epList
                        seasonUpdated = true
                    }
                }
                
                if seasonUpdated {
                    updatedSeasons.append(SeasonInfo(
                        season: season.season,
                        title: season.title,
                        thumbnailUrl: updatedSeasonThumb,
                        episodes: updatedEpisodes
                    ))
                    seasonsChanged = true
                } else {
                    updatedSeasons.append(season)
                }
            }
            
            if seasonsChanged {
                metadata = ContentMetadata(
                    id: metadata.id, title: metadata.title, description: metadata.description,
                    type: metadata.type, genre: metadata.genre, genres: metadata.genres,
                    thumbnail: metadata.thumbnail, posterThumbnail: metadata.posterThumbnail,
                    file: metadata.file, hlsUrl: metadata.hlsUrl,
                    intro: metadata.intro, introDuration: metadata.introDuration, end: metadata.end,
                    seasons: updatedSeasons, episodes: metadata.episodes,
                    downloadedQuality: metadata.downloadedQuality,
                    subtitles: metadata.subtitles,
                    audioTracks: metadata.audioTracks,
                    embeddedAudioDisabled: metadata.embeddedAudioDisabled,
                    downloadedVideoQualities: metadata.downloadedVideoQualities
                )
                metadataUpdated = true
            }
        }
        
        // Download missing episode thumbnails for top-level episodes (no seasons)
        if let episodes = metadata.episodes, metadata.seasons == nil {
            var updatedEpisodes: [EpisodeInfo] = []
            var episodesChanged = false
            
            for ep in episodes {
                var remoteEpThumbUrl: URL? = nil
                if let srcEp = sourceContent?.episodes?.first(where: { $0.season == ep.season && $0.episode == ep.episode }),
                   let thumbUrl = srcEp.thumbnailUrl,
                   thumbUrl.hasPrefix("http"),
                   let url = URL(string: thumbUrl) {
                    remoteEpThumbUrl = url
                }
                
                if let url = thumbnailDownloadURL(current: ep.thumbnailUrl, remoteURL: remoteEpThumbUrl, in: destDir) {
                    if let downloaded = await downloadImage(from: url, to: destDir, filename: "ep\(ep.episode)_thumbnail") {
                        updatedEpisodes.append(EpisodeInfo(
                            season: ep.season, episode: ep.episode,
                            title: ep.title, description: ep.description,
                            thumbnailUrl: downloaded,
                            file: ep.file, hlsUrl: ep.hlsUrl,
                            localFile: ep.localFile,
                            intro: ep.intro, introDuration: ep.introDuration, end: ep.end,
                            qualityName: ep.qualityName,
                            subtitles: ep.subtitles, audioTracks: ep.audioTracks,
                            downloadedVideoQualities: ep.downloadedVideoQualities
                        ))
                        episodesChanged = true
                        continue
                    }
                }
                updatedEpisodes.append(ep)
            }
            
            if episodesChanged {
                metadata = ContentMetadata(
                    id: metadata.id, title: metadata.title, description: metadata.description,
                    type: metadata.type, genre: metadata.genre, genres: metadata.genres,
                    thumbnail: metadata.thumbnail, posterThumbnail: metadata.posterThumbnail,
                    file: metadata.file, hlsUrl: metadata.hlsUrl,
                    intro: metadata.intro, introDuration: metadata.introDuration, end: metadata.end,
                    seasons: metadata.seasons, episodes: updatedEpisodes,
                    downloadedQuality: metadata.downloadedQuality,
                    subtitles: metadata.subtitles,
                    audioTracks: metadata.audioTracks,
                    embeddedAudioDisabled: metadata.embeddedAudioDisabled,
                    downloadedVideoQualities: metadata.downloadedVideoQualities
                )
                metadataUpdated = true
            }
        }
        
        if metadataUpdated {
            saveMetadata(metadata, to: content.folderPath)
        }
    }
    
    // MARK: - Validate and clean library (remove entries with missing content)
    static func validateAndCleanLibrary() -> [SavedContent] {
        let entries = loadLibraryEntries()
        var cleanedEntries: [LibraryEntry] = []
        var result: [SavedContent] = []
        
        for entry in entries {
            if !entry.folderPath.isEmpty {
                let folderPath = contentDirectoryURL.appendingPathComponent(entry.folderPath)
                if !FileManager.default.fileExists(atPath: folderPath.path) {
                    continue
                }
            }
            
            if let metadata = loadMetadata(from: entry.folderPath) {
                cleanedEntries.append(entry)
                result.append(SavedContent(entry: entry, metadata: metadata))
            }
        }
        
        if cleanedEntries.count != entries.count {
            saveLibraryEntries(cleanedEntries.sorted { $0.dateAdded > $1.dateAdded })
        }
        
        return result.sorted { $0.dateAdded > $1.dateAdded }
    }
    
    private static func sortedQualitiesForPlayback(_ qualities: [DownloadedVideoQuality]) -> [DownloadedVideoQuality] {
        qualities.sorted { lhs, rhs in
            let lhsIsHLS = lhs.localSource.localizedCaseInsensitiveContains(".m3u8")
            let rhsIsHLS = rhs.localSource.localizedCaseInsensitiveContains(".m3u8")
            if lhsIsHLS != rhsIsHLS {
                return lhsIsHLS
            }
            return lhs.bandwidth > rhs.bandwidth
        }
    }

    private static func localHLSPlaybackSource(for quality: DownloadedVideoQuality, in directory: URL) -> String {
        localHLSPlaybackSource(for: quality.localSource, in: directory, isHDR: quality.isHDR)
    }

    private static func localHLSPlaybackSource(for localSource: String, in directory: URL, isHDR: Bool) -> String {
        guard localSource.localizedCaseInsensitiveContains(".m3u8"), !isHDR else { return localSource }
        let masterURL = directory.appendingPathComponent("master.m3u8")
        return FileManager.default.fileExists(atPath: masterURL.path) ? "master.m3u8" : localSource
    }

    private static func textSuggestsHDR(_ text: String?) -> Bool {
        guard let text else { return false }
        let lower = text.lowercased()
        if lower.contains("dolby vision") || lower.contains("hdr10+") || lower.contains("hdr10plus") {
            return true
        }
        let tokens = Set(
            lower
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        return !tokens.isDisjoint(with: ["hdr", "hdr10", "hlg", "pq", "dovi", "dv", "bt2020"])
    }

    // MARK: - Resolve episode thumbnail URL
    static func episodeThumbnailURL(for content: SavedContent, episode: EpisodeInfo) -> URL? {
        // Check for local episode thumbnail first
        if !content.folderPath.isEmpty {
            // Check in episode-specific folder (new structure)
            let episodeFolder = "\(content.folderPath)/\(DownloadManager.episodeSubfolder(season: episode.season, episode: episode.episode))"
            let episodeFolderPath = contentDirectoryURL.appendingPathComponent(episodeFolder)
            
            // Check for thumbnail files with common extensions
            let extensions = ["jpg", "jpeg", "png", "webp"]
            for ext in extensions {
                // Check for "thumbnail.ext" (standard name)
                let thumbnailName = "thumbnail.\(ext)"
                let thumbnailURL = episodeFolderPath.appendingPathComponent(thumbnailName)
                if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                    return thumbnailURL
                }
                
                // Check for "episode_thumbnail.ext" (episode-specific name)
                let episodeThumbnailName = "episode_thumbnail.\(ext)"
                let episodeThumbnailURL = episodeFolderPath.appendingPathComponent(episodeThumbnailName)
                if FileManager.default.fileExists(atPath: episodeThumbnailURL.path) {
                    return episodeThumbnailURL
                }
            }
            
            // Check in main content folder with naming pattern
            if let thumbUrl = episode.thumbnailUrl {
                // If thumbnailUrl looks like a local filename
                if !thumbUrl.hasPrefix("http") {
                    let localURL = contentDirectoryURL
                        .appendingPathComponent(content.folderPath)
                        .appendingPathComponent(thumbUrl)
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        return localURL
                    }
                }
            }
            
            // Check for auto-generated names like s1_ep1_thumbnail.jpg
            let autoNames = [
                "s\(episode.season)_ep\(episode.episode)_thumbnail.jpg",
                "s\(episode.season)_ep\(episode.episode)_thumbnail.jpeg",
                "s\(episode.season)_ep\(episode.episode)_thumbnail.png",
                "ep\(episode.episode)_thumbnail.jpg",
                "ep\(episode.episode)_thumbnail.jpeg",
                "ep\(episode.episode)_thumbnail.png"
            ]
            for name in autoNames {
                let localURL = contentDirectoryURL
                    .appendingPathComponent(content.folderPath)
                    .appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return localURL
                }
            }
        }
        
        return nil
    }

}
