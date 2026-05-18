import Foundation
import Combine

// MARK: - URL Check Skipper
/// Allows the UI to skip the currently-in-progress URL reachability check
/// so the resolver moves on to the next candidate immediately.
/// `@unchecked Sendable` is used because `CheckedContinuation` is not itself `Sendable`,
/// preventing a plain `Sendable` conformance. All mutable state is protected by `NSLock`,
/// making concurrent access safe.
final class URLCheckSkipper: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var isCancelled = false
    }

    private let lock = NSLock()
    private var waiter: Waiter?
    private var pendingSkip = false

    /// `true` after the user has pressed Skip at least once.
    /// Callers use this to distinguish a user-initiated skip from a genuine
    /// all-sources-failed failure, so they can dismiss silently instead of
    /// showing an error alert.
    private(set) var wasSkipped = false

    /// Called from the UI when the user presses "Skip".
    func skip() {
        lock.lock()
        wasSkipped = true
        let activeWaiter = waiter
        waiter = nil
        let cont = activeWaiter?.continuation
        activeWaiter?.continuation = nil
        if activeWaiter == nil { pendingSkip = true }
        lock.unlock()
        cont?.resume()
    }

    /// Called inside URLValidator to race the HTTP check against a skip signal.
    func waitForSkip() async {
        let currentWaiter = Waiter()
        await withTaskCancellationHandler {
            await self.waitForSkipSignal(currentWaiter)
        } onCancel: {
            self.cancelWait(currentWaiter)
        }
    }

    private func waitForSkipSignal(_ currentWaiter: Waiter) async {
        await withCheckedContinuation { cont in
            let shouldResume: Bool
            lock.lock()
            if pendingSkip {
                pendingSkip = false
                shouldResume = true
            } else if currentWaiter.isCancelled || Task.isCancelled {
                shouldResume = true
            } else {
                currentWaiter.continuation = cont
                waiter = currentWaiter
                shouldResume = false
            }
            lock.unlock()

            if shouldResume {
                cont.resume()
            }
        }
    }

    private func cancelWait(_ currentWaiter: Waiter) {
        lock.lock()
        currentWaiter.isCancelled = true
        let cont: CheckedContinuation<Void, Never>?
        if waiter === currentWaiter {
            waiter = nil
            cont = currentWaiter.continuation
            currentWaiter.continuation = nil
        } else {
            cont = nil
        }
        lock.unlock()
        cont?.resume()
    }
}

// MARK: - URL Validation for Multi-Source Playback
enum URLValidator {
    private static let reachabilityAttempts = 4
    private static let reachabilityRetryDelayNanoseconds: UInt64 = 1_000_000_000

    /// Try to validate a remote URL by making a HEAD request.
    /// Returns true if the server responds with a success status (2xx/3xx).
    static func isReachable(_ url: URL) async -> Bool {
        // Local file URLs are always considered reachable
        guard url.scheme == "http" || url.scheme == "https" else { return true }

        // Only Streamify's own local server gets the cheap pass. Other localhost
        // URLs may be user source servers and need a real probe.
        if isStreamifyLocalServerURL(url) { return true }

        for attempt in 1...reachabilityAttempts {
            guard !Task.isCancelled else { return false }

            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    return (200...399).contains(httpResponse.statusCode)
                }
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                StreamifyLogger.log("URLValidator: HEAD attempt \(attempt)/\(reachabilityAttempts) failed for \(url.absoluteString): \(error.localizedDescription)")
                guard attempt < reachabilityAttempts else { return false }
                try? await Task.sleep(nanoseconds: reachabilityRetryDelayNanoseconds)
            }
        }

        return false
    }

    private static func isStreamifyLocalServerURL(_ url: URL) -> Bool {
        guard url.host == "localhost" || url.host == "127.0.0.1" else { return false }
        let serverInfo = LocalServer.shared.getServerInfo()
        guard serverInfo.isRunning,
              let serverURL = URL(string: serverInfo.baseURL),
              let serverPort = serverURL.port else {
            return false
        }
        return url.port == serverPort
    }
    
    /// Try multiple URLs in order, returning the first one that responds successfully.
    /// - Parameters:
    ///   - onCheckingURL: Called on the main actor each time a new URL starts being checked.
    ///   - skipper: Optional skipper; pressing Skip races against the current HEAD request
    ///              and moves on to the next URL immediately.
    static func firstWorkingUrl(
        from urls: [URL],
        onCheckingURL: (@MainActor (String) -> Void)? = nil,
        skipper: URLCheckSkipper? = nil
    ) async -> URL? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            if let cb = onCheckingURL {
                await MainActor.run { cb(url.absoluteString) }
            }
            let reachable: Bool
            if let skipper {
                reachable = await withTaskGroup(of: Bool.self) { group -> Bool in
                    group.addTask { await isReachable(url) }
                    group.addTask { await skipper.waitForSkip(); return false }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } else {
                reachable = await isReachable(url)
            }
            if reachable { return url }
            StreamifyLogger.log("Request to play failed for URL: \(url.absoluteString)")
        }
        return nil
    }
}

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var library: [SavedContent] = []
    @Published var sources: [Source] = []
    @Published var mergedContent: [SourceContent] = []
    @Published var isImporting: Bool = false
    @Published var importError: String?
    @Published var isRefreshingSources: Bool = false
    
    private var downloadManager = DownloadManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// Caches for TMDB poster/backdrop URLs keyed by tmdbId
    var tmdbPosterCache: [Int: String] = [:]
    var tmdbBackdropCache: [Int: String] = [:]

    /// Persists the featured content ID across LibraryView re-renders
    /// (resets only on app restart, which is the intended behaviour).
    var featuredContentId: String?

    init() {
        downloadManager.$libraryRefreshNeeded
            .sink { [weak self] needsRefresh in
                if needsRefresh {
                    self?.loadLibrary()
                    self?.downloadManager.libraryRefreshNeeded = false
                }
            }
            .store(in: &cancellables)
    }
    
    func loadLibrary() {
        library = ContentImportService.validateAndCleanLibrary()
        updateLibraryFromSources()
        // Download any missing thumbnails concurrently in the background
        let items = library
        Task {
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        await ContentImportService.downloadMissingThumbnails(for: item)
                    }
                }
            }
            // Reload to pick up locally downloaded thumbnails
            await MainActor.run {
                library = ContentImportService.loadLibrary()
            }
        }
    }

    func refreshLibrary() {
        library = ContentImportService.loadLibrary()
    }
    
    func loadSources() {
        sources = SourcesManager.loadSources()
        mergedContent = Self.mergeSourceContent(from: sources)
        updateLibraryFromSources()
    }
    
    func clearImportError() {
        importError = nil
    }

    func deleteContent(_ content: SavedContent) {
        // Cancel and remove any downloads associated with this content
        let downloadManager = DownloadManager.shared
        
        // For movies: remove download with matching contentId
        // For series: remove downloads with matching seriesId (including episode downloads like "seriesId_ep1")
        let downloadsToRemove = downloadManager.downloads.filter { download in
            if download.contentId == content.id {
                return true
            }
            // Check for episode downloads (format: seriesId_epN)
            if download.contentId.hasPrefix("\(content.id)_ep") {
                return true
            }
            return false
        }
        
        // Cancel and remove each download
        for download in downloadsToRemove {
            downloadManager.cancelDownload(download)
        }
        
        ContentImportService.deleteContent(content)
        library.removeAll { $0.id == content.id }
    }
    
    func addToLibrary(from sourceContent: SourceContent) async {
        await addToLibraryWithDownload(from: sourceContent, downloadVideo: false)
    }

    func addToLibraryWithDownload(from sourceContent: SourceContent, downloadVideo: Bool) async {
        isImporting = true
        importError = nil

        do {
            let safeId = sourceContent.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceContent.id
            let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(safeId)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            var localThumbnail: String? = nil
            if let thumbnailUrl = sourceContent.thumbnailUrl, let url = URL(string: thumbnailUrl) {
                localThumbnail = await ContentImportService.downloadImage(from: url, to: destDir, filename: "thumbnail")
            }

            var localPosterThumbnail: String? = nil
            if let posterThumbnailUrl = sourceContent.posterThumbnailUrl, let url = URL(string: posterThumbnailUrl) {
                localPosterThumbnail = await ContentImportService.downloadImage(from: url, to: destDir, filename: "poster_thumbnail")
            }

            var updatedEpisodes: [EpisodeInfo] = []
            var updatedSeasons: [SeasonInfo] = []

            if let seasons = sourceContent.seasons {
                for season in seasons {
                    var updatedSeasonEpisodes: [EpisodeInfo] = []
                    if let seasonEpisodes = season.episodes {
                        for episode in seasonEpisodes {
                            var localEpThumbnail: String? = nil
                            if let epThumbnailUrl = episode.thumbnailUrl, let url = URL(string: epThumbnailUrl) {
                                localEpThumbnail = await ContentImportService.downloadImage(from: url, to: destDir, filename: "s\(season.season)_ep\(episode.episode)_thumbnail")
                            }
                            
                            let thumbnailUrl = localEpThumbnail ?? episode.thumbnailUrl
                            let updatedEpisode = episode.copying(
                                season: season.season,
                                thumbnailUrl: .some(thumbnailUrl),
                                localFile: .some(nil),
                                qualityName: .some(nil)
                            )
                            updatedSeasonEpisodes.append(updatedEpisode)
                            updatedEpisodes.append(updatedEpisode)
                        }
                    }
                    
                    // Download season thumbnail locally
                    var localSeasonThumbnail: String? = nil
                    if let seasonThumbUrl = season.thumbnailUrl, let url = URL(string: seasonThumbUrl) {
                        localSeasonThumbnail = await ContentImportService.downloadImage(from: url, to: destDir, filename: "thumbnail_s\(season.season)")
                    }
                    
                    updatedSeasons.append(SeasonInfo(
                        season: season.season,
                        title: season.title,
                        thumbnailUrl: localSeasonThumbnail ?? season.thumbnailUrl,
                        episodes: updatedSeasonEpisodes
                    ))
                }
            } else if let episodes = sourceContent.episodes {
                for episode in episodes {
                    var localEpThumbnail: String? = nil
                    if let epThumbnailUrl = episode.thumbnailUrl, let url = URL(string: epThumbnailUrl) {
                        localEpThumbnail = await ContentImportService.downloadImage(from: url, to: destDir, filename: "ep\(episode.episode)_thumbnail")
                    }
                    
                    let thumbnailUrl = localEpThumbnail ?? episode.thumbnailUrl
                    updatedEpisodes.append(episode.copying(
                        thumbnailUrl: .some(thumbnailUrl),
                        localFile: .some(nil),
                        qualityName: .some(nil)
                    ))
                }
            }
            
            let videoUrl = sourceContent.hlsUrl ?? sourceContent.fileUrl
            var savedContent: SavedContent

            if downloadVideo, let urlString = videoUrl {
                savedContent = try await ContentImportService.importContent(
                    from: urlString,
                    withId: sourceContent.id,
                    title: sourceContent.title,
                    description: sourceContent.description,
                    type: sourceContent.type,
                    genre: sourceContent.genre,
                    thumbnailUrl: localThumbnail ?? sourceContent.thumbnailUrl,
                    downloadHLS: true,
                    episodes: updatedEpisodes.isEmpty ? nil : updatedEpisodes,
                    genres: sourceContent.genres,
                    seasons: updatedSeasons.isEmpty ? nil : updatedSeasons
                )
                // Update metadata with source fallback URLs and tmdbId
                let updatedMetadata = savedContent.metadata.copying(tmdbId: sourceContent.tmdbId)
                savedContent = SavedContent(
                    id: savedContent.id,
                    metadata: updatedMetadata,
                    folderPath: savedContent.folderPath,
                    dateAdded: savedContent.dateAdded
                )
                ContentImportService.addToLibrary(savedContent)
            } else {
                let metadata = ContentMetadata(
                    id: sourceContent.id,
                    title: sourceContent.title,
                    description: sourceContent.description,
                    type: sourceContent.type,
                    genre: sourceContent.genre,
                    genres: sourceContent.genres,
                    thumbnail: localThumbnail ?? sourceContent.thumbnailUrl,
                    posterThumbnail: localPosterThumbnail ?? sourceContent.posterThumbnailUrl,
                    file: sourceContent.fileUrl,
                    hlsUrl: sourceContent.hlsUrl,
                    intro: sourceContent.intro,
                    introDuration: sourceContent.introDuration,
                    end: sourceContent.end,
                    seasons: updatedSeasons.isEmpty ? nil : updatedSeasons,
                    episodes: updatedEpisodes.isEmpty ? nil : updatedEpisodes,
                    subtitles: sourceContent.subtitles,
                    audioTracks: sourceContent.audioTracks,
                    embeddedAudioDisabled: sourceContent.embeddedAudioDisabled,
                    tmdbId: sourceContent.tmdbId
                )
                
                savedContent = SavedContent(
                    id: sourceContent.id,
                    metadata: metadata,
                    folderPath: safeId,
                    dateAdded: Date()
                )

                ContentImportService.addToLibrary(savedContent)
            }
            
            await MainActor.run {
                library.removeAll { $0.id == savedContent.id }
                library.insert(savedContent, at: 0)
                isImporting = false
            }
        } catch {
            await MainActor.run {
                importError = error.localizedDescription
                isImporting = false
            }
        }
    }

    func isDownloaded(_ content: SourceContent) -> Bool {
        library.contains { $0.id == content.id }
    }

    func refreshSources() async {
        isRefreshingSources = true
        defer { isRefreshingSources = false }
        sources = await SourcesManager.refreshSources()
        mergedContent = Self.mergeSourceContent(from: sources)
        updateLibraryFromSources()
    }

    func addSampleSource() {
        SourcesManager.createSampleSource()
        loadSources()
    }
    
    // MARK: - Get all HLS URLs for a content ID from all sources
    // Returns all unique HLS URLs for a given content ID across all loaded sources
    func allHlsUrls(for contentId: String) -> [String] {
        var urls: [String] = []
        for source in sources {
            for item in source.movies where item.id == contentId {
                if let hlsUrl = item.hlsUrl, !urls.contains(hlsUrl) {
                    urls.append(hlsUrl)
                }
                if let fileUrl = item.fileUrl, !urls.contains(fileUrl) {
                    urls.append(fileUrl)
                }
            }
        }
        return urls
    }
    
    /// Returns a mapping of HLS URL → source name for a content ID
    func hlsUrlSourceNames(for contentId: String) -> [String: String] {
        var mapping: [String: String] = [:]
        for source in sources {
            for item in source.movies where item.id == contentId {
                if let hlsUrl = item.hlsUrl {
                    mapping[hlsUrl] = source.name
                }
                if let fileUrl = item.fileUrl {
                    mapping[fileUrl] = source.name
                }
            }
        }
        return mapping
    }
    
    // Get all HLS URLs for a specific episode from all sources
    func allEpisodeHlsUrls(for contentId: String, season: Int, episode: Int) -> [String] {
        var urls: [String] = []
        for source in sources {
            for item in source.movies where item.id == contentId {
                for ep in item.allEpisodes where ep.season == season && ep.episode == episode {
                    if let hlsUrl = ep.hlsUrl, !urls.contains(hlsUrl) {
                        urls.append(hlsUrl)
                    }
                    if let fileUrl = ep.file, !urls.contains(fileUrl) {
                        urls.append(fileUrl)
                    }
                }
                // Also include content-level HLS URL as fallback
                if let hlsUrl = item.hlsUrl, !urls.contains(hlsUrl) {
                    urls.append(hlsUrl)
                }
                if let fileUrl = item.fileUrl, !urls.contains(fileUrl) {
                    urls.append(fileUrl)
                }
            }
        }
        return urls
    }
    
    /// Returns a mapping of episode HLS URL → source name
    func episodeHlsUrlSourceNames(for contentId: String, season: Int, episode: Int) -> [String: String] {
        var mapping: [String: String] = [:]
        for source in sources {
            for item in source.movies where item.id == contentId {
                for ep in item.allEpisodes where ep.season == season && ep.episode == episode {
                    if let hlsUrl = ep.hlsUrl {
                        mapping[hlsUrl] = source.name
                    }
                    if let fileUrl = ep.file {
                        mapping[fileUrl] = source.name
                    }
                }
                if let hlsUrl = item.hlsUrl {
                    mapping[hlsUrl] = source.name
                }
                if let fileUrl = item.fileUrl {
                    mapping[fileUrl] = source.name
                }
            }
        }
        return mapping
    }
    
    // Get all thumbnail URLs for a content ID from all sources
    func allThumbnailUrls(for contentId: String) -> [String] {
        var urls: [String] = []
        for source in sources {
            for item in source.movies where item.id == contentId {
                if let url = item.thumbnailUrl, !urls.contains(url) {
                    urls.append(url)
                }
            }
        }
        // TMDB fallback: if content has a tmdbId, add TMDB backdrop as fallback
        if let tmdbUrl = tmdbThumbnailFallback(for: contentId), !urls.contains(tmdbUrl) {
            urls.append(tmdbUrl)
        }
        return urls
    }
    
    // Get all poster thumbnail URLs for a content ID from all sources
    func allPosterThumbnailUrls(for contentId: String) -> [String] {
        var urls: [String] = []
        for source in sources {
            for item in source.movies where item.id == contentId {
                if let url = item.posterThumbnailUrl, !urls.contains(url) {
                    urls.append(url)
                }
            }
        }
        // TMDB fallback: if content has a tmdbId, add TMDB poster as fallback
        if let tmdbUrl = tmdbPosterFallback(for: contentId), !urls.contains(tmdbUrl) {
            urls.append(tmdbUrl)
        }
        return urls
    }
    
    // MARK: - TMDB Fallback URLs
    
    /// Resolve a TMDB poster fallback URL for a content ID by looking up its tmdbId
    private func tmdbPosterFallback(for contentId: String) -> String? {
        guard TMDBService.isConfigured else { return nil }
        if let item = mergedContent.first(where: { $0.id == contentId }), let tmdbId = item.tmdbId {
            if let cached = tmdbPosterCache[tmdbId] { return cached }
        }
        if let item = library.first(where: { $0.id == contentId }), let tmdbId = item.metadata.tmdbId {
            if let cached = tmdbPosterCache[tmdbId] { return cached }
        }
        return nil
    }
    
    /// Resolve a TMDB backdrop/thumbnail fallback URL for a content ID
    private func tmdbThumbnailFallback(for contentId: String) -> String? {
        guard TMDBService.isConfigured else { return nil }
        if let item = mergedContent.first(where: { $0.id == contentId }), let tmdbId = item.tmdbId {
            if let cached = tmdbBackdropCache[tmdbId] { return cached }
        }
        if let item = library.first(where: { $0.id == contentId }), let tmdbId = item.metadata.tmdbId {
            if let cached = tmdbBackdropCache[tmdbId] { return cached }
        }
        return nil
    }
    
    // MARK: - TMDB Enrichment
    
    /// Enrich merged content and library with TMDB data (posters, episodes).
    /// Fetches TMDB metadata for content that has a tmdbId and fills in missing posters and episodes.
    func enrichWithTMDB() {
        guard TMDBService.isConfigured else { return }
        
        // Collect all content with tmdbIds (from sources and library)
        var tmdbItems: [(id: String, tmdbId: Int, type: ContentType)] = []
        var seen: Set<Int> = []
        
        for item in mergedContent {
            if let tmdbId = item.tmdbId, !seen.contains(tmdbId) {
                tmdbItems.append((id: item.id, tmdbId: tmdbId, type: item.type))
                seen.insert(tmdbId)
            }
        }
        for item in library {
            if let tmdbId = item.metadata.tmdbId, !seen.contains(tmdbId) {
                tmdbItems.append((id: item.id, tmdbId: tmdbId, type: item.metadata.type))
                seen.insert(tmdbId)
            }
        }
        
        guard !tmdbItems.isEmpty else { return }
        
        Task {
            // Fetch TMDB metadata for enrichment (poster/backdrop fallbacks + episodes)
            for item in tmdbItems {
                if item.type == .series {
                    // Fetch TV show detail for poster + seasons/episodes
                    if let detail = await TMDBService.fetchTVShowDetail(tmdbId: item.tmdbId) {
                        await MainActor.run {
                            // Cache poster/backdrop
                            if let posterPath = detail.posterPath {
                                tmdbPosterCache[item.tmdbId] = "\(TMDBService.imageBaseURL)/w342\(posterPath)"
                            }
                            if let backdropPath = detail.backdropPath {
                                tmdbBackdropCache[item.tmdbId] = "\(TMDBService.imageBaseURL)/w780\(backdropPath)"
                            }
                        }
                        
                        // Fetch episodes for each season and build enrichment data
                        if let seasons = detail.seasons?.filter({ $0.seasonNumber > 0 }) {
                            var enrichedSeasons: [SeasonInfo] = []
                            for season in seasons {
                                if let seasonDetail = await TMDBService.fetchSeasonDetail(tmdbId: item.tmdbId, seasonNumber: season.seasonNumber) {
                                    let episodes: [EpisodeInfo] = (seasonDetail.episodes ?? []).map { ep in
                                        EpisodeInfo(
                                            season: season.seasonNumber,
                                            episode: ep.episodeNumber,
                                            title: ep.name ?? "",
                                            description: ep.overview ?? "",
                                            thumbnailUrl: ep.thumbnailURL?.absoluteString
                                        )
                                    }
                                    enrichedSeasons.append(SeasonInfo(
                                        season: season.seasonNumber,
                                        title: TMDBService.normalizedSeasonTitle(
                                            for: season,
                                            showTitle: detail.name,
                                            allSeasons: seasons
                                        ),
                                        thumbnailUrl: season.posterPath.map { "\(TMDBService.imageBaseURL)/w342\($0)" },
                                        episodes: episodes
                                    ))
                                }
                            }
                            
                            if !enrichedSeasons.isEmpty {
                                await MainActor.run {
                                    enrichMergedContentSeasons(contentId: item.id, tmdbSeasons: enrichedSeasons)
                                    enrichLibrarySeasons(contentId: item.id, tmdbSeasons: enrichedSeasons)
                                }
                            }
                        }
                    }
                } else {
                    // Movie: just fetch poster/backdrop
                    if let data = await fetchTMDBData(urlString: "https://api.themoviedb.org/3/movie/\(item.tmdbId)?api_key=\(TMDBService.apiKey)&language=en-US") {
                        struct MovieInfo: Codable {
                            let posterPath: String?
                            let backdropPath: String?
                            enum CodingKeys: String, CodingKey {
                                case posterPath = "poster_path"
                                case backdropPath = "backdrop_path"
                            }
                        }
                        if let info = try? JSONDecoder().decode(MovieInfo.self, from: data) {
                            await MainActor.run {
                                if let posterPath = info.posterPath {
                                    tmdbPosterCache[item.tmdbId] = "\(TMDBService.imageBaseURL)/w342\(posterPath)"
                                }
                                if let backdropPath = info.backdropPath {
                                    tmdbBackdropCache[item.tmdbId] = "\(TMDBService.imageBaseURL)/w780\(backdropPath)"
                                }
                            }
                        }
                    }
                }
            }
            
            // After enrichment, update poster fallbacks for merged content that lacks images
            await MainActor.run {
                enrichMergedContentPosters()
                objectWillChange.send()
            }
        }
    }
    
    /// Enrich merged content posters with TMDB fallback URLs for items missing posters
    private func enrichMergedContentPosters() {
        var updated = false
        for i in mergedContent.indices {
            let item = mergedContent[i]
            guard let tmdbId = item.tmdbId else { continue }
            
            var newPoster = item.posterThumbnailUrl
            var newThumb = item.thumbnailUrl
            
            if newPoster == nil, let cached = tmdbPosterCache[tmdbId] {
                newPoster = cached
            }
            if newThumb == nil, let cached = tmdbBackdropCache[tmdbId] {
                newThumb = cached
            }
            
            if newPoster != item.posterThumbnailUrl || newThumb != item.thumbnailUrl {
                mergedContent[i] = SourceContent(
                    id: item.id,
                    title: item.title,
                    description: item.description,
                    type: item.type,
                    genres: item.genres,
                    thumbnailUrl: newThumb ?? item.thumbnailUrl,
                    posterThumbnailUrl: newPoster ?? item.posterThumbnailUrl,
                    fileUrl: item.fileUrl,
                    hlsUrl: item.hlsUrl,
                    intro: item.intro,
                    introDuration: item.introDuration,
                    end: item.end,
                    seasons: item.seasons,
                    episodes: item.episodes,
                    subtitles: item.subtitles,
                    audioTracks: item.audioTracks,
                    embeddedAudioDisabled: item.embeddedAudioDisabled,
                    tmdbId: item.tmdbId
                )
                updated = true
            }
        }
        if updated {
            updateLibraryFromSources()
        }
    }
    
    /// Merge TMDB seasons/episodes into merged content for a specific content ID
    private func enrichMergedContentSeasons(contentId: String, tmdbSeasons: [SeasonInfo]) {
        guard let idx = mergedContent.firstIndex(where: { $0.id == contentId }) else { return }
        let item = mergedContent[idx]
        let existingSeasons = item.seasons
        let merged = Self.mergeSeasons(existingSeasons, tmdbSeasons)
        
        mergedContent[idx] = SourceContent(
            id: item.id,
            title: item.title,
            description: item.description,
            type: item.type,
            genres: item.genres,
            thumbnailUrl: item.thumbnailUrl,
            posterThumbnailUrl: item.posterThumbnailUrl,
            fileUrl: item.fileUrl,
            hlsUrl: item.hlsUrl,
            intro: item.intro,
            introDuration: item.introDuration,
            end: item.end,
            seasons: merged,
            episodes: item.episodes,
            subtitles: item.subtitles,
            audioTracks: item.audioTracks,
            embeddedAudioDisabled: item.embeddedAudioDisabled,
            tmdbId: item.tmdbId
        )
    }
    
    /// Merge TMDB seasons/episodes into library metadata for a specific content ID
    private func enrichLibrarySeasons(contentId: String, tmdbSeasons: [SeasonInfo]) {
        guard let idx = library.firstIndex(where: { $0.id == contentId }) else { return }
        let item = library[idx]
        let mergedSeasons = Self.mergeLibrarySeasons(item.metadata.seasons, withSource: tmdbSeasons)
        let mergedEpisodes = Self.mergeLibraryEpisodes(item.metadata.episodes, withSource: tmdbSeasons.flatMap { $0.episodes ?? [] })
        
        let updated = item.metadata.copying(
            seasons: .some(mergedSeasons),
            episodes: .some(mergedEpisodes)
        )
        
        if updated != item.metadata {
            library[idx] = SavedContent(
                id: item.id,
                metadata: updated,
                folderPath: item.folderPath,
                dateAdded: item.dateAdded
            )
            ContentImportService.saveMetadata(updated, to: item.folderPath)
        }
    }
    
    /// Simple data fetch helper for TMDB enrichment
    private func fetchTMDBData(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
    
    // MARK: - Update library metadata from sources
    // Fully updates library metadata from current sources - replaces source-dependent
    // fields (seasons, episodes, URLs, thumbnails) with what's currently in merged sources.
    // This properly removes data when a source is deleted.
    private func updateLibraryFromSources() {
        guard !library.isEmpty, !mergedContent.isEmpty else { return }
        
        // Build lookup dictionary for O(1) access
        var sourceById: [String: SourceContent] = [:]
        for content in mergedContent {
            sourceById[content.id] = content
        }
        
        var updatedLibrary: [SavedContent] = []
        var didUpdate = false
        
        for item in library {
            guard let sourceContent = sourceById[item.id],
                  sourceContent.type == item.metadata.type else {
                updatedLibrary.append(item)
                continue
            }
            
            let updated = Self.updateMetadata(item.metadata, from: sourceContent, folderPath: item.folderPath)
            if updated != item.metadata {
                let updatedItem = SavedContent(
                    id: item.id,
                    metadata: updated,
                    folderPath: item.folderPath,
                    dateAdded: item.dateAdded
                )
                ContentImportService.saveMetadata(updated, to: item.folderPath)
                updatedLibrary.append(updatedItem)
                didUpdate = true
            } else {
                updatedLibrary.append(item)
            }
        }
        
        if didUpdate {
            library = updatedLibrary
        }
    }
    
    // Update ContentMetadata with source data - syncs metadata from sources.
    // Preserves local files (downloaded thumbnails, videos) while updating remote URLs
    // and adding newly available metadata from sources.
    // folderPath is used to verify that local thumbnail files actually exist on disk.
    static func updateMetadata(_ metadata: ContentMetadata, from source: SourceContent, folderPath: String = "") -> ContentMetadata {
        let mergedEpisodes = mergeLibraryEpisodes(metadata.episodes, withSource: source.episodes)
        let mergedSeasons = mergeLibrarySeasons(metadata.seasons, withSource: source.seasons)
        let mergedSubtitles = mergeSubtitleTracks(metadata.subtitles, withSource: source.subtitles)
        let mergedAudioTracks = mergeAudioTracks(metadata.audioTracks, withSource: source.audioTracks)
        
        // For thumbnails, verify local file actually exists before preserving it
        let destDir = folderPath.isEmpty ? nil : ContentImportService.contentDirectoryURL.appendingPathComponent(folderPath)
        
        return ContentMetadata(
            id: metadata.id,
            title: source.title.isEmpty ? metadata.title : source.title,
            description: source.description.isEmpty ? metadata.description : source.description,
            type: metadata.type,
            genre: source.genre ?? metadata.genre,
            genres: source.genres ?? metadata.genres,
            thumbnail: mergeField(local: metadata.thumbnail, source: source.thumbnailUrl, destDir: destDir),
            posterThumbnail: mergeField(local: metadata.posterThumbnail, source: source.posterThumbnailUrl, destDir: destDir),
            file: mergeField(local: metadata.file, source: source.fileUrl),
            hlsUrl: mergeField(local: metadata.hlsUrl, source: source.hlsUrl),
            intro: source.intro ?? metadata.intro,
            introDuration: source.introDuration ?? metadata.introDuration,
            end: source.end ?? metadata.end,
            seasons: mergedSeasons,
            episodes: mergedEpisodes,
            downloadedQuality: metadata.downloadedQuality,
            subtitles: mergedSubtitles,
            audioTracks: mergedAudioTracks,
            embeddedAudioDisabled: metadata.embeddedAudioDisabled || source.embeddedAudioDisabled,
            downloadedVideoQualities: metadata.downloadedVideoQualities
        )
    }
    
    // Merge a string field: preserve local references (downloaded files/paths),
    // update remote URLs from source. Local filenames (non-http) are always preserved.
    // If destDir is provided, verifies local file exists on disk before preserving.
    private static func mergeField(local: String?, source: String?, destDir: URL? = nil) -> String? {
        if let local = local, !local.isEmpty, !local.hasPrefix("http") {
            // If we can verify the local file exists, do so
            if let destDir = destDir {
                if FileManager.default.fileExists(atPath: destDir.appendingPathComponent(local).path) {
                    return local  // Local file exists — preserve
                }
                // Local file missing — fall through to source
            } else {
                return local  // No destDir to check — preserve (for file/hlsUrl fields)
            }
        }
        return source ?? local  // Source wins for remote URLs, fill nil from source
    }
    
    // Merge subtitle tracks: keep all local tracks, add new from source by languageId
    private static func mergeSubtitleTracks(_ local: [SubtitleTrack]?, withSource source: [SubtitleTrack]?) -> [SubtitleTrack]? {
        guard let source = source else { return local }
        guard let local = local else { return source }
        var merged = local
        let localIds = Set(local.map { $0.languageId })
        for track in source where !localIds.contains(track.languageId) {
            merged.append(track)
        }
        return merged.isEmpty ? nil : merged
    }
    
    // Merge audio tracks: keep all local tracks, add new from source by languageId
    private static func mergeAudioTracks(_ local: [AudioTrack]?, withSource source: [AudioTrack]?) -> [AudioTrack]? {
        guard let source = source else { return local }
        guard let local = local else { return source }
        var merged = local
        let localIds = Set(local.map { $0.languageId })
        for track in source where !localIds.contains(track.languageId) {
            merged.append(track)
        }
        return merged.isEmpty ? nil : merged
    }
    
    // Merge library episodes with source episodes, preserving local download info
    // while syncing newly added/updated metadata from sources
    private static func mergeLibraryEpisodes(_ library: [EpisodeInfo]?, withSource source: [EpisodeInfo]?) -> [EpisodeInfo]? {
        guard let source = source else { return library }
        guard let library = library else { return source }
        
        // Build lookup for library episodes by season+episode
        var libraryByKey: [String: EpisodeInfo] = [:]
        for ep in library {
            libraryByKey["\(ep.season)x\(ep.episode)"] = ep
        }
        
        var merged: [EpisodeInfo] = []
        var seenKeys: Set<String> = []
        
        for srcEp in source {
            let key = "\(srcEp.season)x\(srcEp.episode)"
            seenKeys.insert(key)
            if let libEp = libraryByKey[key] {
                // Merge: preserve local download info, sync metadata from source
                merged.append(EpisodeInfo(
                    season: libEp.season,
                    episode: libEp.episode,
                    title: srcEp.title.isEmpty ? libEp.title : srcEp.title,
                    description: srcEp.description.isEmpty ? libEp.description : srcEp.description,
                    thumbnailUrl: mergeField(local: libEp.thumbnailUrl, source: srcEp.thumbnailUrl),
                    file: mergeField(local: libEp.file, source: srcEp.file),
                    hlsUrl: mergeField(local: libEp.hlsUrl, source: srcEp.hlsUrl),
                    localFile: libEp.localFile,
                    intro: srcEp.intro ?? libEp.intro,
                    introDuration: srcEp.introDuration ?? libEp.introDuration,
                    end: srcEp.end ?? libEp.end,
                    qualityName: libEp.qualityName,
                    subtitles: mergeSubtitleTracks(libEp.subtitles, withSource: srcEp.subtitles),
                    audioTracks: mergeAudioTracks(libEp.audioTracks, withSource: srcEp.audioTracks),
                    downloadedVideoQualities: libEp.downloadedVideoQualities
                ))
            } else {
                merged.append(srcEp)
            }
        }
        
        // Add any library episodes not in source (e.g., manually added)
        for ep in library {
            let key = "\(ep.season)x\(ep.episode)"
            if !seenKeys.contains(key) {
                merged.append(ep)
            }
        }
        
        return merged.isEmpty ? nil : merged
    }
    
    // Merge library seasons with source seasons, preserving local download info in episodes
    // while syncing newly added/updated metadata from sources
    private static func mergeLibrarySeasons(_ library: [SeasonInfo]?, withSource source: [SeasonInfo]?) -> [SeasonInfo]? {
        guard let source = source else { return library }
        guard let library = library else { return source }
        
        var libraryBySeason: [Int: SeasonInfo] = [:]
        for season in library {
            libraryBySeason[season.season] = season
        }
        
        var merged: [SeasonInfo] = []
        var seenSeasons: Set<Int> = []
        
        for srcSeason in source {
            seenSeasons.insert(srcSeason.season)
            if let libSeason = libraryBySeason[srcSeason.season] {
                let mergedEpisodes = mergeLibraryEpisodes(libSeason.episodes, withSource: srcSeason.episodes)
                merged.append(SeasonInfo(
                    season: srcSeason.season,
                    title: SeasonInfo.preferredTitle(srcSeason.title, libSeason.title, season: srcSeason.season),
                    thumbnailUrl: mergeField(local: libSeason.thumbnailUrl, source: srcSeason.thumbnailUrl),
                    episodes: mergedEpisodes
                ))
            } else {
                merged.append(srcSeason)
            }
        }
        
        // Add any library seasons not in source
        for season in library {
            if !seenSeasons.contains(season.season) {
                merged.append(season)
            }
        }
        
        return merged.isEmpty ? nil : merged
    }
    
    // MARK: - Merge content from multiple sources
    // When multiple sources have content with the same ID and type, combine their
    // seasons, episodes, and thumbnails into a single merged SourceContent
    static func mergeSourceContent(from sources: [Source]) -> [SourceContent] {
        var contentById: [String: SourceContent] = [:]
        var orderedIds: [String] = []
        
        for source in sources {
            for item in source.movies {
                if let existing = contentById[item.id] {
                    // Only merge if types match
                    guard existing.type == item.type else { continue }
                    contentById[item.id] = mergeTwo(existing, item)
                } else {
                    contentById[item.id] = item
                    orderedIds.append(item.id)
                }
            }
        }
        
        return orderedIds.compactMap { contentById[$0] }
    }
    
    // Merge two SourceContent items with the same ID
    private static func mergeTwo(_ a: SourceContent, _ b: SourceContent) -> SourceContent {
        // Merge seasons: combine seasons from both, for overlapping season numbers merge episodes
        let mergedSeasons = mergeSeasons(a.seasons, b.seasons)
        
        // Merge top-level episodes (for content without seasons)
        let mergedEpisodes = mergeEpisodes(a.episodes, b.episodes)
        
        return SourceContent(
            id: a.id,
            title: a.title,
            description: a.description.isEmpty ? b.description : a.description,
            type: a.type,
            genres: a.genres ?? b.genres,
            thumbnailUrl: a.thumbnailUrl ?? b.thumbnailUrl,
            posterThumbnailUrl: a.posterThumbnailUrl ?? b.posterThumbnailUrl,
            fileUrl: a.fileUrl ?? b.fileUrl,
            hlsUrl: a.hlsUrl ?? b.hlsUrl,
            intro: a.intro ?? b.intro,
            introDuration: a.introDuration ?? b.introDuration,
            end: a.end ?? b.end,
            seasons: mergedSeasons,
            episodes: mergedEpisodes,
            subtitles: a.subtitles ?? b.subtitles,
            audioTracks: a.audioTracks ?? b.audioTracks,
            embeddedAudioDisabled: a.embeddedAudioDisabled || b.embeddedAudioDisabled
        )
    }
    
    // Merge seasons arrays: combine seasons from both, merging episodes for same season number
    private static func mergeSeasons(_ a: [SeasonInfo]?, _ b: [SeasonInfo]?) -> [SeasonInfo]? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        
        var seasonsByNumber: [Int: SeasonInfo] = [:]
        
        for season in a {
            seasonsByNumber[season.season] = season
        }
        
        for season in b {
            if let existing = seasonsByNumber[season.season] {
                // Merge episodes within the same season
                let merged = SeasonInfo(
                    season: season.season,
                    title: SeasonInfo.preferredTitle(existing.title, season.title, season: season.season),
                    thumbnailUrl: existing.thumbnailUrl ?? season.thumbnailUrl,
                    episodes: mergeEpisodes(existing.episodes, season.episodes)
                )
                seasonsByNumber[season.season] = merged
            } else {
                seasonsByNumber[season.season] = season
            }
        }
        
        let result = seasonsByNumber.values.sorted { $0.season < $1.season }
        return result.isEmpty ? nil : result
    }
    
    // Merge episode arrays: combine episodes, preferring first source for same season+episode
    private static func mergeEpisodes(_ a: [EpisodeInfo]?, _ b: [EpisodeInfo]?) -> [EpisodeInfo]? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        
        var episodesByKey: [String: EpisodeInfo] = [:]
        
        for ep in a {
            let key = "\(ep.season)x\(ep.episode)"
            episodesByKey[key] = ep
        }
        
        for ep in b {
            let key = "\(ep.season)x\(ep.episode)"
            if episodesByKey[key] == nil {
                episodesByKey[key] = ep
            } else {
                // Merge: fill in missing fields from second source
                guard let existing = episodesByKey[key] else { continue }
                episodesByKey[key] = EpisodeInfo(
                    season: existing.season,
                    episode: existing.episode,
                    title: existing.title.isEmpty ? ep.title : existing.title,
                    description: existing.description.isEmpty ? ep.description : existing.description,
                    thumbnailUrl: existing.thumbnailUrl ?? ep.thumbnailUrl,
                    file: existing.file ?? ep.file,
                    hlsUrl: existing.hlsUrl ?? ep.hlsUrl,
                    intro: existing.intro ?? ep.intro,
                    introDuration: existing.introDuration ?? ep.introDuration,
                    end: existing.end ?? ep.end,
                    subtitles: existing.subtitles ?? ep.subtitles,
                    audioTracks: existing.audioTracks ?? ep.audioTracks,
                    downloadedVideoQualities: existing.downloadedVideoQualities
                )
            }
        }
        
        // Sort by season then episode
        let sorted = episodesByKey.values
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        return sorted.isEmpty ? nil : sorted
    }
}
