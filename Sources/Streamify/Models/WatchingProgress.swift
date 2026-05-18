import Foundation

// MARK: - Watching progress for continue watching feature
nonisolated struct WatchingProgress: Identifiable, Hashable, Sendable, Codable {
    var id: String { progressId }
    var contentId: String  // Not stored in JSON - derived from folder name
    var seasonIndex: Int?  // nil for movies
    var episodeIndex: Int?  // nil for movies
    var timestamp: Double
    var duration: Double  // Store duration for progress calculation
    var lastWatched: Date
    var isWatched: Bool  // True when content has been fully watched (hides from continue watching)
    
    // Computed ID for unique identification of episode progress
    var progressId: String {
        if let season = seasonIndex, let episode = episodeIndex {
            return "\(contentId)_s\(season)e\(episode)"
        }
        return contentId
    }
    
    init(contentId: String, seasonIndex: Int? = nil, episodeIndex: Int? = nil, timestamp: Double = 0, duration: Double = 0, lastWatched: Date = Date(), isWatched: Bool = false) {
        self.contentId = contentId
        self.seasonIndex = seasonIndex
        self.episodeIndex = episodeIndex
        self.timestamp = timestamp
        self.duration = duration
        self.lastWatched = lastWatched
        self.isWatched = isWatched
    }
    
    // MARK: - Codable (for legacy support)
    enum CodingKeys: String, CodingKey {
        case contentId = "ci"
        case seasonIndex = "si"
        case episodeIndex = "ei"
        case timestamp = "ts"
        case duration = "du"
        case lastWatched = "lw"
        case isWatched = "iw"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case contentId, seasonIndex, episodeIndex, timestamp, duration, lastWatched
    }
    
    // Encoder - skip contentId (derived from folder name)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Don't encode contentId - it's derived from the folder name
        try container.encodeIfPresent(seasonIndex, forKey: .seasonIndex)
        try container.encodeIfPresent(episodeIndex, forKey: .episodeIndex)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(duration, forKey: .duration)
        try container.encode(lastWatched, forKey: .lastWatched)
        if isWatched {
            try container.encode(isWatched, forKey: .isWatched)
        }
    }
    
    // Decoder - supports both new short keys and legacy keys
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        contentId = try c.decodeIfPresent(String.self, forKey: .contentId) ?? lc.decodeIfPresent(String.self, forKey: .contentId) ?? ""
        seasonIndex = try c.decodeIfPresent(Int.self, forKey: .seasonIndex) ?? lc.decodeIfPresent(Int.self, forKey: .seasonIndex)
        episodeIndex = try c.decodeIfPresent(Int.self, forKey: .episodeIndex) ?? lc.decodeIfPresent(Int.self, forKey: .episodeIndex)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp) ?? lc.decode(Double.self, forKey: .timestamp)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? lc.decode(Double.self, forKey: .duration)
        lastWatched = try c.decodeIfPresent(Date.self, forKey: .lastWatched) ?? lc.decode(Date.self, forKey: .lastWatched)
        isWatched = try c.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
    }
    
    // Progress as percentage (0-1)
    var progressPercent: Double {
        guard duration > 0 else { return 0 }
        return min(timestamp / duration, 1.0)
    }
    
    /// Whether playback has reached the end, using the metadata `end` marker.
    /// `endTimestamp` is an absolute timestamp (seconds from start) at which the content is considered finished.
    /// If no `end` marker is available, returns false — we can't determine if content reached the end.
    func hasReachedEnd(endTimestamp: Double?) -> Bool {
        guard let endMark = endTimestamp, endMark > 0 else { return false }
        return timestamp >= endMark
    }
    
}

// MARK: - Watching progress persistence
// Progress is stored in each content's folder as progress.json.zlib (zlib compressed)
enum WatchingProgressManager {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static var contentDirectoryURL: URL {
        documentsURL.appendingPathComponent("Content")
    }
    
    // File URLs for progress
    private static func progressZlibURL(for contentId: String) -> URL {
        let safeId = contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
        return contentDirectoryURL.appendingPathComponent(safeId).appendingPathComponent("progress.json.zlib")
    }
    
    private static func progressURL(for contentId: String) -> URL {
        let safeId = contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
        return contentDirectoryURL.appendingPathComponent(safeId).appendingPathComponent("progress.json")
    }
    
    // Save progress for a specific content
    private static func saveProgressForContent(contentId: String, progress: [WatchingProgress]) {
        let folder = contentDirectoryURL.appendingPathComponent(
            contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zlibURL = progressZlibURL(for: contentId)
        do {
            try CompressedJSON.write(progress, to: zlibURL)
        } catch {
            StreamifyLogger.log("Failed to save progress for \(contentId): \(error)")
        }
    }
    
    // Get progress for a specific content (movie or episode)
    static func getProgress(for contentId: String, seasonIndex: Int? = nil, episodeIndex: Int? = nil) -> WatchingProgress? {
        let allProgress = loadProgressForContent(contentId: contentId)
        return allProgress.first { progress in
            if let epIdx = episodeIndex, let seasonIdx = seasonIndex {
                return progress.seasonIndex == seasonIdx && progress.episodeIndex == epIdx
            } else {
                return progress.episodeIndex == nil
            }
        }
    }
    
    // Load progress for a specific content
    static func loadProgressForContent(contentId: String) -> [WatchingProgress] {
        do {
            var progress = try CompressedJSON.readWithFallback(
                [WatchingProgress].self,
                compressedURL: progressZlibURL(for: contentId),
                plainURL: progressURL(for: contentId)
            )
            // Set contentId (not stored in JSON)
            for i in progress.indices {
                progress[i].contentId = contentId
            }
            return progress
        } catch {
            return []
        }
    }
    
    // Update or add progress
    static func updateProgress(_ newProgress: WatchingProgress) {
        var allProgress = loadProgressForContent(contentId: newProgress.contentId)
        allProgress.removeAll { existing in
            existing.seasonIndex == newProgress.seasonIndex && existing.episodeIndex == newProgress.episodeIndex
        }
        allProgress.append(newProgress)
        saveProgressForContent(contentId: newProgress.contentId, progress: allProgress)
    }
    
    // Get all progress for a content (for library display)
    static func getAllProgress(for contentId: String) -> [WatchingProgress] {
        loadProgressForContent(contentId: contentId)
    }
    
    // Get the "current" progress (most recently watched episode or movie)
    static func getCurrentProgress(for contentId: String) -> WatchingProgress? {
        let allProgress = loadProgressForContent(contentId: contentId)
        return allProgress.max(by: { $0.lastWatched < $1.lastWatched })
    }
    
    // Reload progress for a specific content
    static func reloadProgress(for contentId: String) -> [WatchingProgress] {
        return loadProgressForContent(contentId: contentId)
    }
    
    // Load all progress (for Continue Watching section)
    static func load() -> [WatchingProgress] {
        var allProgress: [WatchingProgress] = []
        guard FileManager.default.fileExists(atPath: contentDirectoryURL.path) else { return [] }
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: contentDirectoryURL.path) else { return [] }
        for folder in folders {
            let contentId = folder.removingPercentEncoding ?? folder
            let progress = loadProgressForContent(contentId: contentId)
            allProgress.append(contentsOf: progress)
        }
        return allProgress
    }
    
    // Clear all watching progress
    static func clear() {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: contentDirectoryURL.path) else { return }
        for folder in folders {
            let zlibURL = contentDirectoryURL.appendingPathComponent(folder).appendingPathComponent("progress.json.zlib")
            let plainURL = contentDirectoryURL.appendingPathComponent(folder).appendingPathComponent("progress.json")
            try? FileManager.default.removeItem(at: zlibURL)
            try? FileManager.default.removeItem(at: plainURL)
        }
    }
    
    /// Mark a content's progress as fully watched (hides from continue watching).
    /// For movies: marks the movie progress as isWatched.
    /// For episodes: marks the specific episode progress as isWatched.
    static func markAsWatched(contentId: String, seasonIndex: Int? = nil, episodeIndex: Int? = nil) {
        var allProgress = loadProgressForContent(contentId: contentId)
        if let idx = allProgress.firstIndex(where: {
            $0.seasonIndex == seasonIndex && $0.episodeIndex == episodeIndex
        }) {
            allProgress[idx].isWatched = true
            saveProgressForContent(contentId: contentId, progress: allProgress)
        }
    }
    
    /// Clear the isWatched flag — called when user starts playing content again
    /// (e.g., rewatching a completed movie or starting a new episode).
    static func clearIsWatched(contentId: String) {
        var allProgress = loadProgressForContent(contentId: contentId)
        var changed = false
        for i in allProgress.indices {
            if allProgress[i].isWatched {
                allProgress[i].isWatched = false
                changed = true
            }
        }
        if changed {
            saveProgressForContent(contentId: contentId, progress: allProgress)
        }
    }
    
    /// Check if the entire content is marked as watched.
    /// Returns true if the most recent progress entry has isWatched=true.
    static func isContentWatched(contentId: String) -> Bool {
        let allProgress = loadProgressForContent(contentId: contentId)
        guard !allProgress.isEmpty else { return false }
        if let latest = allProgress.max(by: { $0.lastWatched < $1.lastWatched }) {
            return latest.isWatched
        }
        return false
    }
    
    /// Handle end-of-playback logic:
    /// - Movies: if reached end, mark as watched (removes from continue watching)
    /// - TV episodes: if reached end, check for next episode. If found, create progress for it.
    ///   If no next episode, mark content as watched.
    /// `endTimestamp` is from metadata `end` field — absolute timestamp (seconds from start) at which content ends.
    /// If nil, no end-of-playback processing occurs.
    /// Returns the next episode info (seasonIndex, episodeIndex) if one was found, nil otherwise.
    @discardableResult
    static func handlePlaybackEnd(
        contentId: String,
        progress: WatchingProgress,
        allEpisodes: [EpisodeInfo],
        contentType: ContentType,
        endTimestamp: Double?
    ) -> (seasonIndex: Int, episodeIndex: Int)? {
        guard progress.hasReachedEnd(endTimestamp: endTimestamp) else { return nil }
        
        if contentType == .movie {
            // Movie reached end — mark as watched
            markAsWatched(contentId: contentId)
            StreamifyLogger.log("WatchingProgress: Movie '\(contentId)' reached end, marked as watched")
            return nil
        }
        
        // TV show episode reached end — find next episode
        guard let currentSeason = progress.seasonIndex, let currentEpisode = progress.episodeIndex else {
            // Episode info missing, treat like a movie
            markAsWatched(contentId: contentId)
            return nil
        }
        
        // Mark current episode as watched
        markAsWatched(contentId: contentId, seasonIndex: currentSeason, episodeIndex: currentEpisode)
        
        // Find next episode: first try next in same season, then first of next season
        let sorted = allEpisodes.sorted { a, b in
            if a.season != b.season { return a.season < b.season }
            return a.episode < b.episode
        }
        
        var foundCurrent = false
        for ep in sorted {
            if ep.season == currentSeason && ep.episode == currentEpisode {
                foundCurrent = true
                continue
            }
            if foundCurrent {
                // Found next episode — create a progress entry at timestamp 0
                let nextProgress = WatchingProgress(
                    contentId: contentId,
                    seasonIndex: ep.season,
                    episodeIndex: ep.episode,
                    timestamp: 0,
                    duration: 0,
                    lastWatched: Date()
                )
                updateProgress(nextProgress)
                StreamifyLogger.log("WatchingProgress: Episode S\(currentSeason)E\(currentEpisode) ended, advanced to S\(ep.season)E\(ep.episode)")
                return (seasonIndex: ep.season, episodeIndex: ep.episode)
            }
        }
        
        // No next episode found — mark content as fully watched
        var latestProgress = progress
        latestProgress.isWatched = true
        updateProgress(latestProgress)
        StreamifyLogger.log("WatchingProgress: Last episode S\(currentSeason)E\(currentEpisode) ended, content marked as watched")
        return nil
    }
}
