import Foundation

/// Centralizes playback source resolution — collects URLs, fetches Torrentio/VidLink/111Movies
/// in parallel, validates, pre-parses HLS audio + qualities, and merges subtitles.
struct PlaybackResolver {
    
    /// Resolved playback source ready for PlayerContext / EpisodeChangeRequest
    struct ResolvedPlayback {
        let url: URL
        let sourceName: String?
        let vidLinkUrl: URL?
        let movies111Url: URL?
        let torrentioUrl: URL?
        let preloadedAudioTracks: [AudioTrack]?
        let preloadedQualities: [HLSQuality]?
        let mergedSubtitles: [SubtitleTrack]?
    }
    
    // MARK: - URL Collection
    
    /// Collect all remote URLs for a movie from metadata + sources
    @MainActor static func collectMovieUrls(
        content: SavedContent,
        sourceContent: SourceContent?,
        viewModel: LibraryViewModel
    ) -> [URL] {
        var allUrls: [URL] = []
        appendRemoteURL(content.metadata.hlsUrl, to: &allUrls)
        if let url = ContentImportService.remoteHlsURL(for: content) {
            if !allUrls.contains(url) { allUrls.append(url) }
        }
        appendRemoteURL(content.metadata.file, to: &allUrls)
        if let sc = sourceContent {
            appendRemoteURL(sc.hlsUrl, to: &allUrls)
            appendRemoteURL(sc.fileUrl, to: &allUrls)
        }
        for urlStr in viewModel.allHlsUrls(for: content.id) {
            appendRemoteURL(urlStr, to: &allUrls)
        }
        return allUrls
    }
    
    /// Collect all remote URLs for an episode from metadata + sources
    @MainActor static func collectEpisodeUrls(
        content: SavedContent,
        episode: EpisodeInfo,
        sourceContent: SourceContent?,
        viewModel: LibraryViewModel
    ) -> [URL] {
        var allUrls: [URL] = []
        appendRemoteURL(episode.hlsUrl, to: &allUrls)
        appendRemoteURL(content.metadata.hlsUrl, to: &allUrls)
        if let url = ContentImportService.remoteHlsURL(for: content) {
            if !allUrls.contains(url) { allUrls.append(url) }
        }
        if let sc = sourceContent {
            appendRemoteURL(sc.hlsUrl, to: &allUrls)
            appendRemoteURL(sc.fileUrl, to: &allUrls)
        }
        for urlStr in viewModel.allEpisodeHlsUrls(for: content.id, season: episode.season, episode: episode.episode) {
            appendRemoteURL(urlStr, to: &allUrls)
        }
        return allUrls
    }

    private static func appendRemoteURL(_ urlString: String?, to urls: inout [URL]) {
        guard let urlString,
              urlString.hasPrefix("http"),
              let url = URL(string: urlString),
              !urls.contains(url) else { return }
        urls.append(url)
    }
    
    // MARK: - TMDB ID Resolution
    
    /// Resolve TMDB ID from content metadata or loaded sources
    static func resolveTmdbId(for content: SavedContent, sourceContent: SourceContent? = nil) -> Int? {
        if let tmdbId = content.metadata.tmdbId {
            return tmdbId
        }
        if let tmdbId = sourceContent?.tmdbId {
            return tmdbId
        }
        if let tmdbId = parseTMDBId(from: content.id) {
            return tmdbId
        }
        if let sourceContent, let tmdbId = parseTMDBId(from: sourceContent.id) {
            return tmdbId
        }
        let sources = SourcesManager.loadSources()
        for source in sources {
            for item in source.movies where item.id == content.id {
                if let tmdbId = item.tmdbId {
                    return tmdbId
                }
            }
        }
        return nil
    }

    private static func parseTMDBId(from id: String) -> Int? {
        let prefixes = ["tmdb_tv_", "tmdb_movie_", "tmdb_"]
        for prefix in prefixes where id.hasPrefix(prefix) {
            return Int(id.dropFirst(prefix.count))
        }
        return nil
    }
    
    // MARK: - Resolve Movie Playback
    
    static func resolveMovie(
        directUrls: [URL],
        sourceNamesMap: [String: String],
        tmdbId: Int?,
        vidLinkEnabled: Bool,
        movies111Enabled: Bool,
        torrentioEnabled: Bool = false,
        includeTorrentioDirectOptions: Bool = true,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil,
        skipper: URLCheckSkipper? = nil
    ) async -> ResolvedPlayback? {
        return await resolve(
            directUrls: directUrls,
            sourceNamesMap: sourceNamesMap,
            tmdbId: tmdbId,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            includeTorrentioDirectOptions: includeTorrentioDirectOptions,
            fetchVidLink: { id in await VidLinkService.fetchMovieStream(tmdbId: id) },
            fetch111Movies: { id in await Movies111Service.fetchMovieStream(tmdbId: id) },
            fetchTorrentio: { id in await TorrentioService.fetchMovieStream(tmdbId: id) },
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        )
    }
    
    // MARK: - Resolve Episode Playback
    
    static func resolveEpisode(
        directUrls: [URL],
        sourceNamesMap: [String: String],
        tmdbId: Int?,
        season: Int,
        episode: Int,
        vidLinkEnabled: Bool,
        movies111Enabled: Bool,
        torrentioEnabled: Bool = false,
        includeTorrentioDirectOptions: Bool = true,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil,
        skipper: URLCheckSkipper? = nil
    ) async -> ResolvedPlayback? {
        return await resolve(
            directUrls: directUrls,
            sourceNamesMap: sourceNamesMap,
            tmdbId: tmdbId,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            includeTorrentioDirectOptions: includeTorrentioDirectOptions,
            fetchVidLink: { id in await VidLinkService.fetchEpisodeStream(tmdbId: id, season: season, episode: episode) },
            fetch111Movies: { id in await Movies111Service.fetchEpisodeStream(tmdbId: id, season: season, episode: episode) },
            fetchTorrentio: { id in await TorrentioService.fetchEpisodeStream(tmdbId: id, season: season, episode: episode) },
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        )
    }
    
    // MARK: - Shared Resolution Logic
    
    private static func resolve(
        directUrls: [URL],
        sourceNamesMap: [String: String],
        tmdbId: Int?,
        vidLinkEnabled: Bool,
        movies111Enabled: Bool,
        torrentioEnabled: Bool,
        includeTorrentioDirectOptions: Bool,
        fetchVidLink: @escaping @Sendable (Int) async -> VidLinkService.VidLinkResult?,
        fetch111Movies: @escaping @Sendable (Int) async -> Movies111Service.MovieResult?,
        fetchTorrentio: @escaping @Sendable (Int) async -> TorrentioService.TorrentioResult?,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil,
        skipper: URLCheckSkipper? = nil
    ) async -> ResolvedPlayback? {
        let workingUrl: URL?
        if directUrls.isEmpty {
            workingUrl = nil
        } else {
            workingUrl = await URLValidator.firstWorkingUrl(from: directUrls,
                                                            onCheckingURL: onCheckingURL,
                                                            skipper: skipper)
        }
        
        var movies111: Movies111Service.MovieResult?
        var movies111Url: URL?
        var vidLink: VidLinkService.VidLinkResult?
        var vidLinkUrl: URL?
        var torrentio: TorrentioService.TorrentioResult?
        var torrentioUrl: URL?

        if let tmdbId, torrentioEnabled {
            torrentio = await resolveServiceCandidate(
                label: "Torrentio",
                onCheckingURL: onCheckingURL,
                skipper: skipper
            ) {
                await fetchTorrentio(tmdbId)
            }
            torrentioUrl = torrentio?.streamUrl.flatMap { URL(string: $0) }
        } else {
            StreamifyLogger.log("PlaybackResolver: Torrentio skipped — tmdbId=\(tmdbId.map(String.init) ?? "nil") enabled=\(torrentioEnabled)")
        }
        
        if let tmdbId, movies111Enabled {
            movies111 = await resolveServiceCandidate(
                label: "111Movies",
                onCheckingURL: onCheckingURL,
                skipper: skipper
            ) {
                await fetch111Movies(tmdbId)
            }
            movies111Url = movies111.flatMap { URL(string: $0.hlsUrl) }
        } else {
            StreamifyLogger.log("PlaybackResolver: 111Movies skipped — tmdbId=\(tmdbId.map(String.init) ?? "nil") enabled=\(movies111Enabled)")
        }

        if let tmdbId, vidLinkEnabled {
            vidLink = await resolveServiceCandidate(
                label: "VidLink",
                onCheckingURL: onCheckingURL,
                skipper: skipper
            ) {
                await fetchVidLink(tmdbId)
            }
            vidLinkUrl = vidLink.flatMap { URL(string: $0.hlsUrl) }
        } else {
            StreamifyLogger.log("PlaybackResolver: VidLink skipped — tmdbId=\(tmdbId.map(String.init) ?? "nil") enabled=\(vidLinkEnabled)")
        }
        
        StreamifyLogger.log("PlaybackResolver: directUrl=\(workingUrl?.absoluteString ?? "nil") torrentioUrl=\(torrentioUrl?.absoluteString ?? "nil") torrentioSubs=\(torrentio?.subtitles.count ?? 0) vidLinkUrl=\(vidLinkUrl?.absoluteString ?? "nil") vidLinkSubs=\(vidLink?.subtitles.count ?? 0) 111MoviesUrl=\(movies111Url?.absoluteString ?? "nil")")
        
        // Determine final URL — prefer normal streaming sources before Torrentio.
        // Torrentio direct file options stay visible in the picker/download flow, but
        // should not become the automatic playback source while HLS sources exist.
        let finalUrl: URL?
        let finalSourceName: String?
        if let workingUrl = workingUrl {
            finalUrl = workingUrl
            finalSourceName = nil
        } else if let movies111Url = movies111Url {
            finalUrl = movies111Url
            finalSourceName = "111Movies"
        } else if let vidLinkUrl = vidLinkUrl {
            finalUrl = vidLinkUrl
            finalSourceName = "VidLink"
        } else if let torrentioUrl = torrentioUrl {
            finalUrl = torrentioUrl
            finalSourceName = "Torrentio"
        } else {
            return nil
        }
        
        guard let resolvedUrl = finalUrl else { return nil }
        
        // Determine source name for the resolved URL
        let resolvedSourceName: String? = finalSourceName ?? sourceNamesMap[resolvedUrl.absoluteString]
        
        // Notify caller that URL resolution is done and quality parsing is about to begin.
        // This lets the UI hide the Skip button, which cannot be used during quality parsing.
        if let onPreparingPlayback {
            await MainActor.run { onPreparingPlayback() }
        }

        // Pre-parse HLS audio renditions and qualities before opening the player
        var preloadedAudio: [AudioTrack]? = nil
        var preloadedQualities: [HLSQuality]? = nil
        let isHLS = resolvedUrl.pathExtension == "m3u8" || resolvedUrl.absoluteString.contains(".m3u8")
        if isHLS && !resolvedUrl.isFileURL {
            // Parse audio from the primary/resolved URL
            let audioData = await PlayerViewModel.parseHLSAudioRenditions(from: resolvedUrl)
            let parsed = audioData.renditions.map { $0.toAudioTrack(hlsBaseUrl: resolvedUrl.absoluteString, sourceName: resolvedSourceName) }
            if !parsed.isEmpty {
                preloadedAudio = parsed
            }
        }

        // Build list of ALL stream options for the picker. This includes HLS
        // variants from every URL provider and direct Torrentio file streams.
        var allQualityUrls: [String] = directUrls.map { $0.absoluteString }.filter { HLSQuality.looksLikeHLS($0) }
        if let vlUrl = vidLinkUrl, !allQualityUrls.contains(vlUrl.absoluteString) {
            allQualityUrls.append(vlUrl.absoluteString)
        }
        if let m111Url = movies111Url, !allQualityUrls.contains(m111Url.absoluteString) {
            allQualityUrls.append(m111Url.absoluteString)
        }
        if let tUrl = torrentioUrl,
           (tUrl.pathExtension == "m3u8" || tUrl.absoluteString.contains(".m3u8")),
           !allQualityUrls.contains(tUrl.absoluteString) {
            allQualityUrls.append(tUrl.absoluteString)
        }
        if isHLS && !allQualityUrls.contains(resolvedUrl.absoluteString) {
            allQualityUrls.insert(resolvedUrl.absoluteString, at: 0)
        }

        var fullSourceNames = sourceNamesMap
        if let vlUrl = vidLinkUrl {
            fullSourceNames[vlUrl.absoluteString] = "VidLink"
        }
        if let m111Url = movies111Url {
            fullSourceNames[m111Url.absoluteString] = "111Movies"
        }
        if let tUrl = torrentioUrl {
            fullSourceNames[tUrl.absoluteString] = "Torrentio"
        }

        var allQualities: [HLSQuality] = []
        if !allQualityUrls.isEmpty {
            allQualities = await PlayerViewModel.parseAllSourceQualities(
                from: allQualityUrls, sourceNames: fullSourceNames)
        }
        allQualities.append(contentsOf: directFileQualities(from: directUrls, sourceNames: fullSourceNames))
        if includeTorrentioDirectOptions {
            allQualities.append(contentsOf: torrentioDirectQualities(from: torrentio?.options ?? []))
        }
        allQualities = deduplicatedQualities(allQualities)
        allQualities = sortedQualities(allQualities)
        if !allQualities.isEmpty {
            preloadedQualities = allQualities
        }
        
        // Merge subtitles from all streaming sources
        let mergedSubtitles: [SubtitleTrack]? = {
            var subs: [SubtitleTrack] = []
            func appendUnique(_ tracks: [SubtitleTrack]) {
                for track in tracks {
                    let sourceKey = track.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !subs.contains(where: {
                        $0.trackId == track.trackId ||
                            (!sourceKey.isEmpty && $0.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sourceKey)
                    }) else { continue }
                    subs.append(track)
                }
            }
            appendUnique(vidLink?.subtitles ?? [])
            appendUnique(movies111?.subtitles ?? [])
            appendUnique(torrentio?.subtitles ?? [])
            return subs.isEmpty ? nil : subs
        }()
        
        return ResolvedPlayback(
            url: resolvedUrl,
            sourceName: resolvedSourceName,
            vidLinkUrl: vidLinkUrl,
            movies111Url: movies111Url,
            torrentioUrl: torrentioUrl,
            preloadedAudioTracks: preloadedAudio,
            preloadedQualities: preloadedQualities,
            mergedSubtitles: mergedSubtitles
        )
    }

    private static func torrentioDirectQualities(from options: [TorrentioService.StreamOption]) -> [HLSQuality] {
        options.compactMap { option in
            guard !HLSQuality.looksLikeHLS(option.url) else { return nil }
            guard let quality = HLSQuality.directFileQuality(
                urlString: option.url,
                sourceName: option.sourceName,
                name: option.name,
                displayDetail: option.detail
            ) else { return nil }
            return HLSQuality(
                name: quality.name,
                bandwidth: option.bandwidth,
                resolution: option.resolution,
                videoRange: option.videoRange,
                frameRate: nil,
                sourceUrl: quality.sourceUrl,
                variantUrl: quality.variantUrl,
                sourceName: option.sourceName,
                displayDetail: quality.displayDetail
            )
        }
    }

    private static func directFileQualities(from urls: [URL], sourceNames: [String: String]) -> [HLSQuality] {
        urls.compactMap { url in
            let urlString = url.absoluteString
            guard !HLSQuality.looksLikeHLS(urlString) else { return nil }
            return HLSQuality.directFileQuality(urlString: urlString, sourceName: sourceNames[urlString])
        }
    }

    private static func deduplicatedQualities(_ qualities: [HLSQuality]) -> [HLSQuality] {
        var seen: Set<String> = []
        var result: [HLSQuality] = []
        for quality in qualities {
            let key = "\(quality.sourceUrl ?? "")|\(quality.variantUrl ?? "")|\(quality.name)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(quality)
        }
        return result
    }

    // Source priority: own sources (10) → 111Movies (20) → VidLink (30) → Torrentio (40)
    private static func sourcePriority(_ sourceName: String?) -> Int {
        switch sourceName {
        case "111Movies": return 20
        case "VidLink": return 30
        case "Torrentio": return 40
        default: return 10
        }
    }

    private static func sortedQualities(_ qualities: [HLSQuality]) -> [HLSQuality] {
        qualities.sorted { q1, q2 in
            let p1 = sourcePriority(q1.sourceName)
            let p2 = sourcePriority(q2.sourceName)
            if p1 != p2 { return p1 < p2 }
            if q1.isHDR != q2.isHDR { return q1.isHDR }
            if q1.bandwidth != q2.bandwidth { return q1.bandwidth > q2.bandwidth }
            return (q1.sourceName ?? "") < (q2.sourceName ?? "")
        }
    }

    private static func resolveServiceCandidate<Result: Sendable>(
        label: String,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)?,
        skipper: URLCheckSkipper?,
        fetch: @escaping @Sendable () async -> Result?
    ) async -> Result? {
        if let onCheckingURL {
            await MainActor.run {
                onCheckingURL(label)
            }
        }

        guard let skipper else {
            return await fetch()
        }

        return await withTaskGroup(of: Result?.self) { group in
            group.addTask {
                await fetch()
            }
            group.addTask {
                await skipper.waitForSkip()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
