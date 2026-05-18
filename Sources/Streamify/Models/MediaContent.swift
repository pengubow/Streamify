import Foundation

// MARK: - Source content item (for sources.json)
nonisolated struct SourceContent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let type: ContentType
    let genres: [Genre]?
    let thumbnailUrl: String?
    let posterThumbnailUrl: String?
    let fileUrl: String?
    let hlsUrl: String?
    let intro: Double?
    let introDuration: Double?
    let end: Double?
    let seasons: [SeasonInfo]?
    let episodes: [EpisodeInfo]?
    let subtitles: [SubtitleTrack]?
    let audioTracks: [AudioTrack]?
    let embeddedAudioDisabled: Bool  // Global flag: disable embedded audio for this content
    let tmdbId: Int?  // TMDB movie/series ID for VidLink integration

    // For backward compatibility
    var genre: Genre? {
        genres?.first
    }
    
    // Get all episodes from seasons, or fall back to top-level episodes.
    // Ensures each episode's season property matches its parent SeasonInfo.
    var allEpisodes: [EpisodeInfo] {
        if let seasons = seasons {
            let seasonEpisodes = seasons.flatMap { season in
                (season.episodes ?? []).map { ep in
                    ep.season == season.season ? ep : ep.copying(season: season.season)
                }
            }
            if !seasonEpisodes.isEmpty {
                return seasonEpisodes
            }
        }
        return episodes ?? []
    }
    
    /// Convert to ContentMetadata (fallback when local metadata is missing)
    func toContentMetadata() -> ContentMetadata {
        ContentMetadata(
            id: id, title: title, description: description,
            type: type, genre: genres?.first, genres: genres,
            thumbnail: thumbnailUrl, posterThumbnail: posterThumbnailUrl,
            file: fileUrl, hlsUrl: hlsUrl,
            intro: intro, introDuration: introDuration, end: end,
            seasons: seasons, episodes: episodes,
            downloadedQuality: nil,
            subtitles: subtitles, audioTracks: audioTracks,
            embeddedAudioDisabled: embeddedAudioDisabled,
            tmdbId: tmdbId
        )
    }

    enum CodingKeys: String, CodingKey {
        case id = "i", title = "t", description = "d", type = "tp", genres = "g"
        case thumbnailUrl = "th"
        case posterThumbnailUrl = "pt"
        case fileUrl = "fu"
        case hlsUrl = "hu"
        case intro = "in"
        case introDuration = "ir"
        case end = "e", seasons = "ss", episodes = "ep", subtitles = "st"
        case audioTracks = "at"
        case embeddedAudioDisabled = "ea"
        case tmdbId = "tm"
    }
    
    // Legacy keys for backward compatibility with old JSON files
    private enum LegacyKeys: String, CodingKey {
        case id, title, description, type, genres
        case thumbnailUrl = "thumbnail_url"
        case posterThumbnailUrl = "poster_thumbnail_url"
        case fileUrl = "file_url"
        case hlsUrl = "hls_url"
        case intro
        case introDuration = "intro_duration"
        case end, seasons, episodes, subtitles
        case audioTracks = "audio_tracks"
        case embeddedAudioDisabled = "embedded_audio_disabled"
        case tmdbId = "tmdb_id"
    }
    
    // Initializer with default values
    init(
        id: String,
        title: String,
        description: String = "",
        type: ContentType,
        genres: [Genre]? = nil,
        thumbnailUrl: String? = nil,
        posterThumbnailUrl: String? = nil,
        fileUrl: String? = nil,
        hlsUrl: String? = nil,
        intro: Double? = nil,
        introDuration: Double? = nil,
        end: Double? = nil,
        seasons: [SeasonInfo]? = nil,
        episodes: [EpisodeInfo]? = nil,
        subtitles: [SubtitleTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        embeddedAudioDisabled: Bool = false,
        tmdbId: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.type = type
        self.genres = genres
        self.thumbnailUrl = thumbnailUrl
        self.posterThumbnailUrl = posterThumbnailUrl
        self.fileUrl = fileUrl
        self.hlsUrl = hlsUrl
        self.intro = intro
        self.introDuration = introDuration
        self.end = end
        self.seasons = seasons
        self.episodes = episodes
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.embeddedAudioDisabled = embeddedAudioDisabled
        self.tmdbId = tmdbId
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? lc.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? lc.decode(String.self, forKey: .description)
        type = try c.decodeIfPresent(ContentType.self, forKey: .type) ?? lc.decode(ContentType.self, forKey: .type)
        genres = try c.decodeIfPresent([Genre].self, forKey: .genres) ?? lc.decodeIfPresent([Genre].self, forKey: .genres)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl) ?? lc.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        posterThumbnailUrl = try c.decodeIfPresent(String.self, forKey: .posterThumbnailUrl) ?? lc.decodeIfPresent(String.self, forKey: .posterThumbnailUrl)
        fileUrl = try c.decodeIfPresent(String.self, forKey: .fileUrl) ?? lc.decodeIfPresent(String.self, forKey: .fileUrl)
        hlsUrl = try c.decodeIfPresent(String.self, forKey: .hlsUrl) ?? lc.decodeIfPresent(String.self, forKey: .hlsUrl)
        intro = try c.decodeIfPresent(Double.self, forKey: .intro) ?? lc.decodeIfPresent(Double.self, forKey: .intro)
        introDuration = try c.decodeIfPresent(Double.self, forKey: .introDuration) ?? lc.decodeIfPresent(Double.self, forKey: .introDuration)
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? lc.decodeIfPresent(Double.self, forKey: .end)
        seasons = try c.decodeIfPresent([SeasonInfo].self, forKey: .seasons) ?? lc.decodeIfPresent([SeasonInfo].self, forKey: .seasons)
        episodes = try c.decodeIfPresent([EpisodeInfo].self, forKey: .episodes) ?? lc.decodeIfPresent([EpisodeInfo].self, forKey: .episodes)
        subtitles = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles) ?? lc.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? lc.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)
        embeddedAudioDisabled = try c.decodeIfPresent(Bool.self, forKey: .embeddedAudioDisabled) ?? lc.decodeIfPresent(Bool.self, forKey: .embeddedAudioDisabled) ?? false
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId) ?? lc.decodeIfPresent(Int.self, forKey: .tmdbId)
    }
}

// MARK: - Source (individual source file in Sources/ folder)
nonisolated struct Source: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let movies: [SourceContent]
    
    enum CodingKeys: String, CodingKey {
        case id = "i", name = "n", movies = "m"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case id, name, movies
    }
    
    init(id: String, name: String, movies: [SourceContent]) {
        self.id = id
        self.name = name
        self.movies = movies
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? lc.decode(String.self, forKey: .name)
        movies = try c.decodeIfPresent([SourceContent].self, forKey: .movies) ?? lc.decode([SourceContent].self, forKey: .movies)
    }
}

// MARK: - Genre enum for content categorization
nonisolated enum Genre: String, Codable, CaseIterable, Identifiable, Sendable {
    case action = "Action"
    case comedy = "Comedy"
    case drama = "Drama"
    case sciFi = "Sci-Fi"
    case horror = "Horror"
    case thriller = "Thriller"
    case romance = "Romance"
    case animation = "Animation"
    case documentary = "Documentary"
    case other = "Other"

    var id: String { rawValue }
}

// MARK: - Video quality presets for HLS streaming
// Sets AVPlayerItem.preferredPeakBitRate to limit quality
nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "Auto"
    case low = "480p"
    case medium = "720p"
    case high = "1080p"
    case max = "Max"

    var id: String { rawValue }

    var peakBitRate: Double {
        switch self {
        case .auto: return 0
        case .low: return 1_500_000
        case .medium: return 4_000_000
        case .high: return 8_000_000
        case .max: return 0
        }
    }
}

// MARK: - Downloaded video quality (for multi-quality storage)
nonisolated struct DownloadedVideoQuality: Codable, Identifiable, Hashable, Sendable {
    let qualityId: String
    var id: String { qualityId }
    let name: String           // e.g., "1080p", "720p"
    let bandwidth: Double
    let resolution: String?
    let isHDR: Bool
    let localSource: String    // Relative path to video m3u8 (e.g., "video_1080p/video.m3u8")
    let sourceName: String?    // Source attribution (e.g., "VidLink", "MySource")
    let sourceUrl: String?     // Remote URL this quality was downloaded from, used to match picker rows

    enum CodingKeys: String, CodingKey {
        case qualityId = "qi"
        case name = "n"
        case bandwidth = "bw"
        case resolution = "r"
        case isHDR = "hd"
        case localSource = "ls"
        case sourceName = "sn"
        case sourceUrl = "su"
    }

    private enum LegacyKeys: String, CodingKey {
        case qualityId = "quality_id"
        case name
        case bandwidth
        case resolution
        case isHDR = "is_hdr"
        case localSource = "local_source"
        case sourceName = "source_name"
        case sourceUrl = "source_url"
    }

    init(qualityId: String = UUID().uuidString, name: String, bandwidth: Double, resolution: String? = nil, isHDR: Bool = false, localSource: String, sourceName: String? = nil, sourceUrl: String? = nil) {
        self.qualityId = qualityId
        self.name = name
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.isHDR = isHDR
        self.localSource = localSource
        self.sourceName = sourceName
        self.sourceUrl = sourceUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        let decodedName = try c.decodeIfPresent(String.self, forKey: .name) ?? lc.decode(String.self, forKey: .name)
        let decodedLocalSource = try c.decodeIfPresent(String.self, forKey: .localSource) ?? lc.decode(String.self, forKey: .localSource)
        let decodedSourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? lc.decodeIfPresent(String.self, forKey: .sourceName)
        let decodedSourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? lc.decodeIfPresent(String.self, forKey: .sourceUrl)
        let decodedIsHDR = try c.decodeIfPresent(Bool.self, forKey: .isHDR) ?? lc.decodeIfPresent(Bool.self, forKey: .isHDR) ?? false

        qualityId = try c.decodeIfPresent(String.self, forKey: .qualityId) ?? lc.decodeIfPresent(String.self, forKey: .qualityId) ?? UUID().uuidString
        name = decodedName
        bandwidth = try c.decodeIfPresent(Double.self, forKey: .bandwidth) ?? lc.decode(Double.self, forKey: .bandwidth)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? lc.decodeIfPresent(String.self, forKey: .resolution)
        isHDR = decodedIsHDR || Self.textSuggestsHDR([decodedName, decodedLocalSource, decodedSourceName, decodedSourceUrl])
        localSource = decodedLocalSource
        sourceName = decodedSourceName
        sourceUrl = decodedSourceUrl
    }

    private static func textSuggestsHDR(_ values: [String?]) -> Bool {
        let text = values.compactMap { $0 }.joined(separator: " ")
        let pattern = #"(?i)(^|[^A-Za-z0-9])(HDR10\+?|HDR|HLG|PQ|DV|DOVI|Dolby\s+Vision)([^A-Za-z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Content type
nonisolated enum ContentType: String, Codable, Sendable {
    case movie
    case series
}

// MARK: - Subtitle track
nonisolated struct SubtitleTrack: Codable, Identifiable, Hashable, Sendable {
    let trackId: String  // Stable UUID for this track instance
    var id: String { trackId }
    let language: String  // Display name (e.g., "English")
    let languageId: String  // Language identifier (e.g., "en", "en-forced")
    let source: String
    let name: String?  // Optional descriptive name (e.g., "English (SDH)", "Forced")
    let sourceName: String?  // Source attribution (e.g., "VidLink", "MySource")
    
    enum CodingKeys: String, CodingKey {
        case language = "l", source = "s", name = "n"
        case trackId = "ti"
        case languageId = "li"
        case sourceName = "sn"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case language, source, name
        case trackId = "track_id"
        case languageId = "language_id"
        case sourceName = "source_name"
    }
    
    init(language: String, source: String, languageId: String? = nil, name: String? = nil, trackId: String? = nil, sourceName: String? = nil) {
        self.trackId = trackId ?? UUID().uuidString
        self.language = language
        self.source = source
        self.languageId = languageId ?? language.lowercased().replacingOccurrences(of: " ", with: "_")
        self.name = name
        self.sourceName = sourceName
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        let lang = try c.decodeIfPresent(String.self, forKey: .language) ?? lc.decode(String.self, forKey: .language)
        language = lang
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? lc.decode(String.self, forKey: .source)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? lc.decodeIfPresent(String.self, forKey: .name)
        trackId = try c.decodeIfPresent(String.self, forKey: .trackId) ?? lc.decodeIfPresent(String.self, forKey: .trackId) ?? UUID().uuidString
        languageId = try c.decodeIfPresent(String.self, forKey: .languageId)
            ?? lc.decodeIfPresent(String.self, forKey: .languageId)
            ?? lang.lowercased().replacingOccurrences(of: " ", with: "_")
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? lc.decodeIfPresent(String.self, forKey: .sourceName)
    }
    
    /// Display name: uses `name` if available, otherwise `language`
    var displayName: String {
        name ?? language
    }
}

// MARK: - Audio track (dubbing)
nonisolated struct AudioTrack: Codable, Identifiable, Hashable, Sendable {
    let trackId: String  // Stable UUID for this track instance
    var id: String { trackId }
    let language: String  // Display name (e.g., "English")
    let languageId: String  // Language identifier (e.g., "en", "en-atmos")
    let source: String  // URL to audio file/HLS m3u8, or empty for embedded
    let isSpatial: Bool  // Whether this track has spatial audio (e.g., Dolby Atmos / EAC-3)
    let isDisabled: Bool  // Whether embedded audio should be disabled (video has no sound)
    let name: String?  // Optional descriptive name (e.g., "English (Atmos)", "Japanese (Stereo)")
    let bandwidth: Double?  // Audio bandwidth in bits/sec (from HLS parsing)
    let sourceName: String?  // Source attribution (e.g., "VidLink", "MySource")
    let originalTrackId: String?  // Source track id this local/prepared track was derived from
    
    enum CodingKeys: String, CodingKey {
        case language = "l", source = "s", name = "n", bandwidth = "bw"
        case trackId = "ti"
        case languageId = "li"
        case isSpatial = "sp"
        case isDisabled = "ds"
        case sourceName = "sn"
        case originalTrackId = "ot"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case language, source, name, bandwidth
        case trackId = "track_id"
        case languageId = "language_id"
        case isSpatial = "is_spatial"
        case isDisabled = "is_disabled"
        case sourceName = "source_name"
        case originalTrackId = "original_track_id"
    }

    init(language: String, source: String = "", isSpatial: Bool = false, isDisabled: Bool = false, languageId: String? = nil, name: String? = nil, bandwidth: Double? = nil, trackId: String? = nil, sourceName: String? = nil, originalTrackId: String? = nil) {
        self.trackId = trackId ?? UUID().uuidString
        self.language = language
        self.source = source
        self.isSpatial = isSpatial
        self.isDisabled = isDisabled
        self.languageId = languageId ?? language.lowercased().replacingOccurrences(of: " ", with: "_")
        self.name = name
        self.bandwidth = bandwidth
        self.sourceName = sourceName
        self.originalTrackId = originalTrackId
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        let lang = try c.decodeIfPresent(String.self, forKey: .language) ?? lc.decode(String.self, forKey: .language)
        language = lang
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? lc.decode(String.self, forKey: .source)
        isSpatial = try c.decodeIfPresent(Bool.self, forKey: .isSpatial) ?? lc.decodeIfPresent(Bool.self, forKey: .isSpatial) ?? false
        isDisabled = try c.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? lc.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? lc.decodeIfPresent(String.self, forKey: .name)
        bandwidth = try c.decodeIfPresent(Double.self, forKey: .bandwidth) ?? lc.decodeIfPresent(Double.self, forKey: .bandwidth)
        trackId = try c.decodeIfPresent(String.self, forKey: .trackId) ?? lc.decodeIfPresent(String.self, forKey: .trackId) ?? UUID().uuidString
        languageId = try c.decodeIfPresent(String.self, forKey: .languageId)
            ?? lc.decodeIfPresent(String.self, forKey: .languageId)
            ?? lang.lowercased().replacingOccurrences(of: " ", with: "_")
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? lc.decodeIfPresent(String.self, forKey: .sourceName)
        originalTrackId = try c.decodeIfPresent(String.self, forKey: .originalTrackId) ?? lc.decodeIfPresent(String.self, forKey: .originalTrackId)
    }
    
    var isEmbedded: Bool {
        source.isEmpty
    }
    
    /// Display name: uses `name` if available, otherwise `language`
    var displayName: String {
        name ?? language
    }
    
}

nonisolated enum TrackIdentity {
    static func stableTrackId(
        type: String,
        source: String,
        languageId: String? = nil,
        name: String? = nil,
        sourceName: String? = nil,
        extra: String? = nil
    ) -> String {
        let parts = [type, sourceName, languageId, name, source, extra]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let seed = parts.joined(separator: "|")
        return "\(safePrefix(type))-\(fnv1a64(seed))"
    }

    static func shortDisplayId(_ trackId: String) -> String {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("mpv-audio-") {
            return String(trimmed.dropFirst("mpv-audio-".count))
        }
        if trimmed.hasPrefix("mpv-subtitle-") {
            return String(trimmed.dropFirst("mpv-subtitle-".count))
        }
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.suffix(8))
    }

    private static func safePrefix(_ value: String) -> String {
        let prefix = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return prefix.isEmpty ? "track" : prefix
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Season metadata
nonisolated struct SeasonInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { "season_\(season)" }
    let season: Int
    let title: String?
    let thumbnailUrl: String?
    let episodes: [EpisodeInfo]?

    var displayTitle: String {
        Self.preferredTitle(title, nil, season: season) ?? "Season \(season)"
    }
    
    enum CodingKeys: String, CodingKey {
        case season = "s", title = "t"
        case thumbnailUrl = "th"
        case episodes = "ep"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case season, title
        case thumbnailUrl = "thumbnail_url"
        case episodes
    }
    
    init(season: Int, title: String? = nil, thumbnailUrl: String? = nil, episodes: [EpisodeInfo]? = nil) {
        self.season = season
        self.title = title
        self.thumbnailUrl = thumbnailUrl
        self.episodes = episodes
    }

    static func preferredTitle(_ primary: String?, _ secondary: String?, season: Int) -> String? {
        if let title = meaningfulTitle(primary, season: season) {
            return title
        }
        if let title = meaningfulTitle(secondary, season: season) {
            return title
        }
        return cleanedTitle(primary) ?? cleanedTitle(secondary)
    }

    private static func meaningfulTitle(_ title: String?, season: Int) -> String? {
        guard let title = cleanedTitle(title) else { return nil }
        return title.localizedCaseInsensitiveCompare("Season \(season)") == .orderedSame ? nil : title
    }

    private static func cleanedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        season = try c.decodeIfPresent(Int.self, forKey: .season) ?? lc.decode(Int.self, forKey: .season)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? lc.decodeIfPresent(String.self, forKey: .title)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl) ?? lc.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        episodes = try c.decodeIfPresent([EpisodeInfo].self, forKey: .episodes) ?? lc.decodeIfPresent([EpisodeInfo].self, forKey: .episodes)
    }
}

// MARK: - Episode metadata
nonisolated struct EpisodeInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(season)x\(episode)" }
    let season: Int
    let episode: Int
    let title: String
    let description: String
    let thumbnailUrl: String?
    let file: String?
    let hlsUrl: String?
    let localFile: String?
    let intro: Double?
    let introDuration: Double?
    let end: Double?
    let qualityName: String?
    let subtitles: [SubtitleTrack]?
    let audioTracks: [AudioTrack]?
    let downloadedVideoQualities: [DownloadedVideoQuality]?

    enum CodingKeys: String, CodingKey {
        case season = "s", episode = "e", title = "t", description = "d"
        case thumbnailUrl = "th"
        case file = "f"
        case hlsUrl = "hu"
        case localFile = "lf"
        case intro = "in"
        case introDuration = "ir"
        case end = "en"
        case qualityName = "qn"
        case subtitles = "st"
        case audioTracks = "at"
        case downloadedVideoQualities = "vq"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case season, episode, title, description
        case thumbnailUrl = "thumbnail_url"
        case file
        case hlsUrl = "hls_url"
        case localFile = "local_file"
        case intro
        case introDuration = "intro_duration"
        case end
        case qualityName = "quality_name"
        case subtitles
        case audioTracks = "audio_tracks"
        case downloadedVideoQualities = "downloaded_video_qualities"
    }
    
    // Initializer for creating episodes programmatically
    init(
        season: Int,
        episode: Int,
        title: String,
        description: String = "",
        thumbnailUrl: String? = nil,
        file: String? = nil,
        hlsUrl: String? = nil,
        localFile: String? = nil,
        intro: Double? = nil,
        introDuration: Double? = nil,
        end: Double? = nil,
        qualityName: String? = nil,
        subtitles: [SubtitleTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        downloadedVideoQualities: [DownloadedVideoQuality]? = nil
    ) {
        self.season = season
        self.episode = episode
        self.title = title
        self.description = description
        self.thumbnailUrl = thumbnailUrl
        self.file = file
        self.hlsUrl = hlsUrl
        self.localFile = localFile
        self.intro = intro
        self.introDuration = introDuration
        self.end = end
        self.qualityName = qualityName
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.downloadedVideoQualities = downloadedVideoQualities
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        season = try c.decodeIfPresent(Int.self, forKey: .season) ?? lc.decode(Int.self, forKey: .season)
        episode = try c.decodeIfPresent(Int.self, forKey: .episode) ?? lc.decode(Int.self, forKey: .episode)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? lc.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? lc.decodeIfPresent(String.self, forKey: .description) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl) ?? lc.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? lc.decodeIfPresent(String.self, forKey: .file)
        hlsUrl = try c.decodeIfPresent(String.self, forKey: .hlsUrl) ?? lc.decodeIfPresent(String.self, forKey: .hlsUrl)
        localFile = try c.decodeIfPresent(String.self, forKey: .localFile) ?? lc.decodeIfPresent(String.self, forKey: .localFile)
        intro = try c.decodeIfPresent(Double.self, forKey: .intro) ?? lc.decodeIfPresent(Double.self, forKey: .intro)
        introDuration = try c.decodeIfPresent(Double.self, forKey: .introDuration) ?? lc.decodeIfPresent(Double.self, forKey: .introDuration)
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? lc.decodeIfPresent(Double.self, forKey: .end)
        qualityName = try c.decodeIfPresent(String.self, forKey: .qualityName) ?? lc.decodeIfPresent(String.self, forKey: .qualityName)
        subtitles = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles) ?? lc.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? lc.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)
        downloadedVideoQualities = try c.decodeIfPresent([DownloadedVideoQuality].self, forKey: .downloadedVideoQualities) ?? lc.decodeIfPresent([DownloadedVideoQuality].self, forKey: .downloadedVideoQualities)
    }
    
    /// Create a copy with selected fields overridden.
    /// Pass `.some(nil)` to explicitly clear an optional field.
    func copying(
        season: Int? = nil,
        title: String? = nil,
        description: String? = nil,
        thumbnailUrl: String?? = nil,
        file: String?? = nil,
        hlsUrl: String?? = nil,
        localFile: String?? = nil,
        intro: Double?? = nil,
        introDuration: Double?? = nil,
        end: Double?? = nil,
        qualityName: String?? = nil,
        subtitles: [SubtitleTrack]?? = nil,
        audioTracks: [AudioTrack]?? = nil,
        downloadedVideoQualities: [DownloadedVideoQuality]?? = nil
    ) -> EpisodeInfo {
        EpisodeInfo(
            season: season ?? self.season,
            episode: self.episode,
            title: title ?? self.title,
            description: description ?? self.description,
            thumbnailUrl: thumbnailUrl ?? self.thumbnailUrl,
            file: file ?? self.file,
            hlsUrl: hlsUrl ?? self.hlsUrl,
            localFile: localFile ?? self.localFile,
            intro: intro ?? self.intro,
            introDuration: introDuration ?? self.introDuration,
            end: end ?? self.end,
            qualityName: qualityName ?? self.qualityName,
            subtitles: subtitles ?? self.subtitles,
            audioTracks: audioTracks ?? self.audioTracks,
            downloadedVideoQualities: downloadedVideoQualities ?? self.downloadedVideoQualities
        )
    }

}

// MARK: - Content metadata (stored in metadata.json in content folder)
nonisolated struct ContentMetadata: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let type: ContentType
    let genre: Genre?
    let genres: [Genre]?
    let thumbnail: String?
    let posterThumbnail: String?
    let file: String?
    let hlsUrl: String?
    let intro: Double?
    let introDuration: Double?
    let end: Double?
    let seasons: [SeasonInfo]?
    let episodes: [EpisodeInfo]?
    let downloadedQuality: String?
    let subtitles: [SubtitleTrack]?
    let audioTracks: [AudioTrack]?
    let embeddedAudioDisabled: Bool  // Global flag: disable embedded audio for this content
    let downloadedVideoQualities: [DownloadedVideoQuality]?
    let tmdbId: Int?  // TMDB movie/series ID for VidLink integration

    var displayGenre: Genre? {
        genre ?? genres?.first
    }
    
    func seasonInfo(for seasonNum: Int) -> SeasonInfo? {
        seasons?.first { $0.season == seasonNum }
    }
    
    var allEpisodes: [EpisodeInfo] {
        if let seasons = seasons {
            let seasonEpisodes = seasons.flatMap { season in
                (season.episodes ?? []).map { ep in
                    ep.season == season.season ? ep : ep.copying(season: season.season)
                }
            }
            if !seasonEpisodes.isEmpty {
                return seasonEpisodes
            }
        }
        return episodes ?? []
    }
    
    func withUpdatedThumbnails(thumbnail: String? = nil, posterThumbnail: String? = nil) -> ContentMetadata {
        copying(thumbnail: thumbnail, posterThumbnail: posterThumbnail)
    }
    
    /// Create a copy with selected fields overridden.
    /// Pass `.some(nil)` to explicitly clear an optional field.
    func copying(
        title: String? = nil,
        description: String? = nil,
        genre: Genre?? = nil,
        genres: [Genre]?? = nil,
        thumbnail: String?? = nil,
        posterThumbnail: String?? = nil,
        file: String?? = nil,
        hlsUrl: String?? = nil,
        intro: Double?? = nil,
        introDuration: Double?? = nil,
        end: Double?? = nil,
        seasons: [SeasonInfo]?? = nil,
        episodes: [EpisodeInfo]?? = nil,
        downloadedQuality: String?? = nil,
        subtitles: [SubtitleTrack]?? = nil,
        audioTracks: [AudioTrack]?? = nil,
        embeddedAudioDisabled: Bool? = nil,
        downloadedVideoQualities: [DownloadedVideoQuality]?? = nil,
        tmdbId: Int?? = nil
    ) -> ContentMetadata {
        ContentMetadata(
            id: self.id,
            title: title ?? self.title,
            description: description ?? self.description,
            type: self.type,
            genre: genre ?? self.genre,
            genres: genres ?? self.genres,
            thumbnail: thumbnail ?? self.thumbnail,
            posterThumbnail: posterThumbnail ?? self.posterThumbnail,
            file: file ?? self.file,
            hlsUrl: hlsUrl ?? self.hlsUrl,
            intro: intro ?? self.intro,
            introDuration: introDuration ?? self.introDuration,
            end: end ?? self.end,
            seasons: seasons ?? self.seasons,
            episodes: episodes ?? self.episodes,
            downloadedQuality: downloadedQuality ?? self.downloadedQuality,
            subtitles: subtitles ?? self.subtitles,
            audioTracks: audioTracks ?? self.audioTracks,
            embeddedAudioDisabled: embeddedAudioDisabled ?? self.embeddedAudioDisabled,
            downloadedVideoQualities: downloadedVideoQualities ?? self.downloadedVideoQualities,
            tmdbId: tmdbId ?? self.tmdbId
        )
    }
    
    var remoteHlsUrl: String? {
        guard let hlsUrl = hlsUrl, hlsUrl.hasPrefix("http") else { return nil }
        return hlsUrl
    }
    
    var remoteFileUrl: String? {
        guard let file = file, file.hasPrefix("http") else { return nil }
        return file
    }

    enum CodingKeys: String, CodingKey {
        case id = "i", title = "t", description = "d", type = "tp"
        case genre = "ge", genres = "g", thumbnail = "th", file = "f"
        case posterThumbnail = "pt"
        case hlsUrl = "hu"
        case intro = "in"
        case introDuration = "ir"
        case end = "e", seasons = "ss", episodes = "ep"
        case downloadedQuality = "dq"
        case subtitles = "st"
        case audioTracks = "at"
        case embeddedAudioDisabled = "ea"
        case downloadedVideoQualities = "vq"
        case tmdbId = "tm"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case id, title, description, type, genre, genres, thumbnail, file
        case posterThumbnail = "poster_thumbnail"
        case hlsUrl = "hls_url"
        case intro
        case introDuration = "intro_duration"
        case end, seasons, episodes
        case downloadedQuality = "downloaded_quality"
        case subtitles
        case audioTracks = "audio_tracks"
        case embeddedAudioDisabled = "embedded_audio_disabled"
        case downloadedVideoQualities = "downloaded_video_qualities"
        case tmdbId = "tmdb_id"
    }
    
    init(
        id: String,
        title: String,
        description: String = "",
        type: ContentType,
        genre: Genre? = nil,
        genres: [Genre]? = nil,
        thumbnail: String? = nil,
        posterThumbnail: String? = nil,
        file: String? = nil,
        hlsUrl: String? = nil,
        intro: Double? = nil,
        introDuration: Double? = nil,
        end: Double? = nil,
        seasons: [SeasonInfo]? = nil,
        episodes: [EpisodeInfo]? = nil,
        downloadedQuality: String? = nil,
        subtitles: [SubtitleTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        embeddedAudioDisabled: Bool = false,
        downloadedVideoQualities: [DownloadedVideoQuality]? = nil,
        tmdbId: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.type = type
        self.genre = genre
        self.genres = genres
        self.thumbnail = thumbnail
        self.posterThumbnail = posterThumbnail
        self.file = file
        self.hlsUrl = hlsUrl
        self.intro = intro
        self.introDuration = introDuration
        self.end = end
        self.seasons = seasons
        self.episodes = episodes
        self.downloadedQuality = downloadedQuality
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.embeddedAudioDisabled = embeddedAudioDisabled
        self.downloadedVideoQualities = downloadedVideoQualities
        self.tmdbId = tmdbId
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? lc.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? lc.decodeIfPresent(String.self, forKey: .description) ?? ""
        type = try c.decodeIfPresent(ContentType.self, forKey: .type) ?? lc.decode(ContentType.self, forKey: .type)
        genre = try c.decodeIfPresent(Genre.self, forKey: .genre) ?? lc.decodeIfPresent(Genre.self, forKey: .genre)
        genres = try c.decodeIfPresent([Genre].self, forKey: .genres) ?? lc.decodeIfPresent([Genre].self, forKey: .genres)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail) ?? lc.decodeIfPresent(String.self, forKey: .thumbnail)
        posterThumbnail = try c.decodeIfPresent(String.self, forKey: .posterThumbnail) ?? lc.decodeIfPresent(String.self, forKey: .posterThumbnail)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? lc.decodeIfPresent(String.self, forKey: .file)
        hlsUrl = try c.decodeIfPresent(String.self, forKey: .hlsUrl) ?? lc.decodeIfPresent(String.self, forKey: .hlsUrl)
        intro = try c.decodeIfPresent(Double.self, forKey: .intro) ?? lc.decodeIfPresent(Double.self, forKey: .intro)
        introDuration = try c.decodeIfPresent(Double.self, forKey: .introDuration) ?? lc.decodeIfPresent(Double.self, forKey: .introDuration)
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? lc.decodeIfPresent(Double.self, forKey: .end)
        seasons = try c.decodeIfPresent([SeasonInfo].self, forKey: .seasons) ?? lc.decodeIfPresent([SeasonInfo].self, forKey: .seasons)
        episodes = try c.decodeIfPresent([EpisodeInfo].self, forKey: .episodes) ?? lc.decodeIfPresent([EpisodeInfo].self, forKey: .episodes)
        downloadedQuality = try c.decodeIfPresent(String.self, forKey: .downloadedQuality) ?? lc.decodeIfPresent(String.self, forKey: .downloadedQuality)
        subtitles = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles) ?? lc.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? lc.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)
        embeddedAudioDisabled = try c.decodeIfPresent(Bool.self, forKey: .embeddedAudioDisabled) ?? lc.decodeIfPresent(Bool.self, forKey: .embeddedAudioDisabled) ?? false
        downloadedVideoQualities = try c.decodeIfPresent([DownloadedVideoQuality].self, forKey: .downloadedVideoQualities) ?? lc.decodeIfPresent([DownloadedVideoQuality].self, forKey: .downloadedVideoQualities)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId) ?? lc.decodeIfPresent(Int.self, forKey: .tmdbId)
    }

}
nonisolated struct LibraryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let folderPath: String
    let dateAdded: Date
    
    enum CodingKeys: String, CodingKey {
        case id = "i"
        case folderPath = "fp"
        case dateAdded = "da"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case id, folderPath, dateAdded
    }
    
    init(id: String, folderPath: String, dateAdded: Date) {
        self.id = id
        self.folderPath = folderPath
        self.dateAdded = dateAdded
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? lc.decode(String.self, forKey: .folderPath)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? lc.decode(Date.self, forKey: .dateAdded)
    }
}

// MARK: - Saved content (runtime type combining library entry + metadata from file)
nonisolated struct SavedContent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let metadata: ContentMetadata
    let folderPath: String
    let dateAdded: Date
    
    init(id: String, metadata: ContentMetadata, folderPath: String, dateAdded: Date) {
        self.id = id
        self.metadata = metadata
        self.folderPath = folderPath
        self.dateAdded = dateAdded
    }
    
    init(entry: LibraryEntry, metadata: ContentMetadata) {
        self.id = entry.id
        self.metadata = metadata
        self.folderPath = entry.folderPath
        self.dateAdded = entry.dateAdded
    }
    
    var libraryEntry: LibraryEntry {
        LibraryEntry(id: id, folderPath: folderPath, dateAdded: dateAdded)
    }

}

// MARK: - Context for launching the video player
struct PlayerContext: Identifiable, Equatable {
    let id = UUID()
    let content: SavedContent
    let videoURL: URL
    let episodeInfo: EpisodeInfo?
    let episodeIndex: Int?
    let totalEpisodes: Int
    /// Pre-parsed HLS audio tracks (parsed before opening the player)
    let preloadedAudioTracks: [AudioTrack]?
    /// Subtitles from streaming sources (VidLink, 111Movies) to merge into the player's subtitle list
    let streamingSubtitles: [SubtitleTrack]?
    /// Pre-parsed HLS qualities (parsed before opening the player)
    let preloadedQualities: [HLSQuality]?
    init(content: SavedContent, videoURL: URL, episodeInfo: EpisodeInfo?, episodeIndex: Int?, totalEpisodes: Int, preloadedAudioTracks: [AudioTrack]? = nil, streamingSubtitles: [SubtitleTrack]? = nil, preloadedQualities: [HLSQuality]? = nil) {
        self.content = content
        self.videoURL = videoURL
        self.episodeInfo = episodeInfo
        self.episodeIndex = episodeIndex
        self.totalEpisodes = totalEpisodes
        self.preloadedAudioTracks = preloadedAudioTracks
        self.streamingSubtitles = streamingSubtitles
        self.preloadedQualities = preloadedQualities
    }

    var hasNext: Bool {
        guard let idx = episodeIndex else { return false }
        return idx < totalEpisodes - 1
    }
    
    static func == (lhs: PlayerContext, rhs: PlayerContext) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Import errors
nonisolated enum ImportError: LocalizedError, Sendable {
    case invalidURL
    case missingMetadata
    case downloadFailed
    case rateLimitPauseAndResume
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL. Please enter a valid link."
        case .missingMetadata: return "Missing metadata."
        case .downloadFailed: return "Failed to download content."
        case .rateLimitPauseAndResume: return "Rate limited — pausing and resuming."
        case .accessDenied: return "Source access denied."
        }
    }
}
