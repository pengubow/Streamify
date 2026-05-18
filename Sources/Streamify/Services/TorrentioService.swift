import Foundation

// MARK: - Torrentio Service
// Fetches direct streams from Torrentio's Stremio add-on endpoint.
// Torrentio requests intentionally bypass URL caches so newly added releases
// can appear without waiting for the system cache to expire.

enum TorrentioService {
    enum DebridProvider: String, CaseIterable, Identifiable, Sendable {
        case none
        case realdebrid
        case premiumize
        case alldebrid
        case debridlink
        case easydebrid
        case offcloud
        case torbox
        case putio

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "None"
            case .realdebrid: return "RealDebrid"
            case .premiumize: return "Premiumize"
            case .alldebrid: return "AllDebrid"
            case .debridlink: return "DebridLink"
            case .easydebrid: return "EasyDebrid"
            case .offcloud: return "Offcloud"
            case .torbox: return "TorBox"
            case .putio: return "Put.io"
            }
        }
    }

    struct StreamOption: Sendable {
        let url: String
        let name: String
        let bandwidth: Double
        let resolution: String?
        let videoRange: String?
        let detail: String?
        let sourceName: String?
    }

    struct TorrentioResult: Sendable {
        let streamUrl: String?
        let subtitles: [SubtitleTrack]
        let streamName: String?
        let options: [StreamOption]
    }

    struct StreamIdentity: Equatable, Sendable {
        let infoHash: String?
        let fileIndex: Int?
        let fileName: String?
    }

    private struct StreamResponse: Codable {
        let streams: [Stream]
    }

    private struct Stream: Codable {
        let name: String?
        let title: String?
        let description: String?
        let url: String?
        let infoHash: String?
        let fileIdx: Int?
        let behaviorHints: BehaviorHints?
        let subtitles: [StreamSubtitle]?
    }

    private struct BehaviorHints: Codable {
        let filename: String?
    }

    private struct StreamSubtitle: Codable {
        let id: String?
        let url: String?
        let lang: String?
        let language: String?
    }

    private struct Candidate {
        let url: String
        let name: String?
        let subtitles: [SubtitleTrack]
        let option: StreamOption
    }

    private static let baseURL = "https://torrentio.strem.fun"

    private static var selectedDebridProvider: DebridProvider {
        let value = UserDefaults.standard.string(forKey: "torrentioDebridProvider") ?? DebridProvider.realdebrid.rawValue
        return DebridProvider(rawValue: value) ?? .realdebrid
    }

    private static var activeDebridApiKey: String {
        switch selectedDebridProvider {
        case .none:
            return ""
        case .putio:
            let clientId = UserDefaults.standard.string(forKey: "torrentioPutioClientId")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = UserDefaults.standard.string(forKey: "torrentioPutioToken")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clientId.isEmpty, !token.isEmpty else { return "" }
            return "\(clientId)@\(token)"
        default:
            return UserDefaults.standard.string(forKey: apiKeyStorageKey(for: selectedDebridProvider))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static func apiKeyStorageKey(for provider: DebridProvider) -> String {
        switch provider {
        case .none: return ""
        case .realdebrid: return "torrentioRealDebridApiKey"
        case .premiumize: return "torrentioPremiumizeApiKey"
        case .alldebrid: return "torrentioAllDebridApiKey"
        case .debridlink: return "torrentioDebridLinkApiKey"
        case .easydebrid: return "torrentioEasyDebridApiKey"
        case .offcloud: return "torrentioOffcloudApiKey"
        case .torbox: return "torrentioTorBoxApiKey"
        case .putio: return "torrentioPutioToken"
        }
    }

    static var isDebridConfigured: Bool {
        !activeDebridApiKey.isEmpty
    }

    static var isRealDebridConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: "torrentioRealDebridApiKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    static func isFailedAccessURL(_ urlString: String) -> Bool {
        urlString.localizedCaseInsensitiveContains("torrentio.strem.fun/videos/failed_access") ||
            urlString.localizedCaseInsensitiveContains("/failed_access")
    }

    static func streamIdentity(from urlString: String) -> StreamIdentity? {
        guard let url = URL(string: urlString) else { return nil }
        let components = url.pathComponents
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { $0 != "/" }
        let infoHash = components.first { component in
            component.count == 40 && component.allSatisfy { $0.isHexDigit }
        }?.lowercased()
        let fileIndex = components.compactMap(Int.init).last
        let fileName = extractFileName(from: urlString)
        guard infoHash != nil || fileIndex != nil || fileName != nil else { return nil }
        return StreamIdentity(infoHash: infoHash, fileIndex: fileIndex, fileName: fileName)
    }

    static func matchingOption(
        in options: [StreamOption],
        previousURL: String,
        qualityName: String?,
        resolution: String?
    ) -> StreamOption? {
        if let exact = options.first(where: { $0.url == previousURL }) {
            return exact
        }

        let previousIdentity = streamIdentity(from: previousURL)
        if let previousIdentity,
           let identityMatch = options.first(where: { option in
               guard let current = streamIdentity(from: option.url) else { return false }
               if let oldHash = previousIdentity.infoHash,
                  let newHash = current.infoHash,
                  oldHash == newHash {
                   if let oldIndex = previousIdentity.fileIndex,
                      let newIndex = current.fileIndex {
                       return oldIndex == newIndex
                   }
                   return previousIdentity.fileName == nil || previousIdentity.fileName == current.fileName
               }
               return previousIdentity.fileName != nil && previousIdentity.fileName == current.fileName
           }) {
            return identityMatch
        }

        let qualityMatches = options.filter { option in
            guard qualityName == nil || option.name == qualityName else { return false }
            guard resolution == nil || option.resolution == resolution else { return false }
            return true
        }
        return qualityMatches.count == 1 ? qualityMatches[0] : nil
    }

    static func fetchMovieStream(tmdbId: Int) async -> TorrentioResult? {
        guard let imdbId = await resolveIMDBId(tmdbId: tmdbId, type: .movie) else {
            return nil
        }
        return await fetchStream(type: "movie", stremioId: imdbId)
    }

    static func fetchEpisodeStream(tmdbId: Int, season: Int, episode: Int) async -> TorrentioResult? {
        guard let imdbId = await resolveIMDBId(tmdbId: tmdbId, type: .series) else {
            return nil
        }
        return await fetchStream(type: "series", stremioId: "\(imdbId):\(season):\(episode)")
    }

    private static func resolveIMDBId(tmdbId: Int, type: ContentType) async -> String? {
        guard let imdbId = await TMDBService.fetchIMDBId(tmdbId: tmdbId, type: type),
              imdbId.hasPrefix("tt") else {
            StreamifyLogger.log("Torrentio: IMDb ID unavailable for TMDB \(tmdbId). Configure TMDB API key to use Torrentio.")
            return nil
        }
        return imdbId
    }

    private static func fetchStream(type: String, stremioId: String) async -> TorrentioResult? {
        guard let url = streamURL(type: type, stremioId: stremioId) else {
            StreamifyLogger.log("Torrentio: Could not build stream URL for \(type)/\(stremioId)")
            return nil
        }

        if !isDebridConfigured {
            StreamifyLogger.log("Torrentio: Debrid key not configured; only direct URL results can be used.")
        }

        do {
            StreamifyLogger.log("Torrentio: Fetching \(type)/\(stremioId)")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Streamify/1.0", forHTTPHeaderField: "User-Agent")

            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                StreamifyLogger.log("Torrentio: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let decoded = try JSONDecoder().decode(StreamResponse.self, from: data)
            let allOptions = decoded.streams.compactMap(makeOption)
            let candidates = decoded.streams.compactMap(makePlaybackCandidate)

            guard let selected = candidates.first else {
                let torrentOnlyCount = decoded.streams.filter { $0.infoHash != nil }.count
                StreamifyLogger.log("Torrentio: No playable direct streams found (\(decoded.streams.count) total, \(allOptions.count) parsed option(s), \(torrentOnlyCount) torrent-backed).")
                return allOptions.isEmpty ? nil : TorrentioResult(
                    streamUrl: nil,
                    subtitles: [],
                    streamName: nil,
                    options: allOptions
                )
            }

            StreamifyLogger.log("Torrentio: Selected \(selected.name ?? "direct stream")")
            return TorrentioResult(
                streamUrl: selected.url,
                subtitles: selected.subtitles,
                streamName: selected.name,
                options: allOptions
            )
        } catch {
            StreamifyLogger.log("Torrentio: Error fetching streams: \(error.localizedDescription)")
            return nil
        }
    }

    private static func streamURL(type: String, stremioId: String) -> URL? {
        let config = configurationPath()
        let encodedId = encodePathComponent("\(stremioId).json")
        let path: String
        if config.isEmpty {
            path = "stream/\(type)/\(encodedId)"
        } else {
            path = "\(config)/stream/\(type)/\(encodedId)"
        }
        return URL(string: "\(baseURL)/\(path)")
    }

    private static func configurationPath() -> String {
        var parts: [String] = []

        let provider = selectedDebridProvider
        let key = activeDebridApiKey
        if provider != .none && !key.isEmpty {
            parts.append("\(provider.rawValue)=\(key)")
        }

        return encodeConfiguration(parts.joined(separator: "|"))
    }

    private static func makePlaybackCandidate(from stream: Stream) -> Candidate? {
        guard let streamUrl = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: streamUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !isFailedAccessURL(streamUrl),
              !isDebridDownloadOnly(stream) else {
            return nil
        }

        return makeCandidate(from: stream, url: streamUrl)
    }

    private static func makeOption(from stream: Stream) -> StreamOption? {
        guard let streamUrl = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: streamUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return makeCandidate(from: stream, url: streamUrl)?.option
    }

    private static func makeCandidate(from stream: Stream, url streamUrl: String) -> Candidate? {
        let name = displayName(for: stream)
        let parsed = parseQuality(from: name, streamUrl: streamUrl, fileNameOverride: stream.behaviorHints?.filename, stream: stream)

        return Candidate(
            url: streamUrl,
            name: name,
            subtitles: parseSubtitles(stream.subtitles),
            option: StreamOption(
                url: streamUrl,
                name: parsed.name,
                bandwidth: parsed.bandwidth,
                resolution: parsed.resolution,
                videoRange: parsed.videoRange,
                detail: parsed.detail,
                sourceName: parsed.sourceName
            )
        )
    }

    private static func isDebridDownloadOnly(_ stream: Stream) -> Bool {
        let text = [stream.name, stream.title, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("rd download") ||
            text.contains("download to debrid") ||
            text.contains("download only")
    }

    private static func displayName(for stream: Stream) -> String? {
        let details = [stream.name, stream.title, stream.description]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        guard !details.isEmpty else { return nil }
        return details.joined(separator: " - ")
    }

    private struct ParsedQualityLabel {
        let name: String
        let resolution: String?
        let sortBandwidth: Double
    }

    private static func parseQuality(from name: String?, streamUrl: String, fileNameOverride: String?, stream: Stream) -> (name: String, bandwidth: Double, resolution: String?, videoRange: String?, detail: String?, sourceName: String?) {
        let text = name ?? "Torrentio Stream"
        let releaseLine = extractReleaseLine(from: text)
        let fileName = fileNameOverride ?? extractFileName(from: streamUrl)
        let parsed = [fileName, releaseLine, text]
            .compactMap { $0 }
            .compactMap(parseQualityLabel(from:))
            .first ?? ParsedQualityLabel(name: "Torrentio", resolution: nil, sortBandwidth: 1)

        let isHDR = containsHDRToken([fileName, releaseLine, text].compactMap { $0 }.joined(separator: " "))
        let sizeDetail = extractSizeDetail(from: text)
        let provider = extractProvider(from: text)
        let availability = availabilityDetail(for: stream, urlString: streamUrl)
        let details = [availability, sizeDetail, provider, fileName ?? releaseLine]
            .compactMap { $0 }
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }

        return (
            name: parsed.name,
            bandwidth: extractSizeBandwidth(from: text) ?? parsed.sortBandwidth,
            resolution: parsed.resolution,
            videoRange: isHDR ? "HDR" : nil,
            detail: details.isEmpty ? nil : details.joined(separator: " - "),
            sourceName: "Torrentio"
        )
    }

    private static func availabilityDetail(for stream: Stream, urlString: String) -> String? {
        if isFailedAccessURL(urlString) || isDebridDownloadOnly(stream) {
            return "Needs debrid caching"
        }
        return nil
    }

    private static func parseQualityLabel(from text: String) -> ParsedQualityLabel? {
        let tokens = Set(qualityTokens(from: text))
        if tokens.contains("4320p") || tokens.contains("8k") {
            return ParsedQualityLabel(name: "4320p", resolution: "7680x4320", sortBandwidth: 40_000_000)
        }
        if tokens.contains("2160p") || tokens.contains("4k") || tokens.contains("uhd") {
            return ParsedQualityLabel(name: "2160p", resolution: "3840x2160", sortBandwidth: 25_000_000)
        }
        if tokens.contains("1080p") {
            return ParsedQualityLabel(name: "1080p", resolution: "1920x1080", sortBandwidth: 8_000_000)
        }
        if tokens.contains("720p") {
            return ParsedQualityLabel(name: "720p", resolution: "1280x720", sortBandwidth: 4_000_000)
        }
        if tokens.contains("480p") {
            return ParsedQualityLabel(name: "480p", resolution: "854x480", sortBandwidth: 1_500_000)
        }
        return nil
    }

    private static func qualityTokens(from text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractSizeDetail(from text: String) -> String? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(GB|MB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func extractSizeBandwidth(from text: String) -> Double? {
        guard let size = extractSizeDetail(from: text) else { return nil }
        let parts = size.split(separator: " ")
        guard let first = parts.first, let value = Double(String(first)) else { return nil }
        if size.uppercased().contains("GB") {
            return value * 1_000_000_000
        }
        if size.uppercased().contains("MB") {
            return value * 1_000_000
        }
        return nil
    }

    private static func extractProvider(from text: String) -> String? {
        guard let gearRange = text.range(of: "\u{2699}\u{FE0F}") else { return nil }
        let afterGear = text[gearRange.upperBound...]
        return afterGear.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsHDRToken(_ text: String) -> Bool {
        let pattern = #"(?i)(^|[^A-Za-z0-9])(HDR10\+?|HDR|HLG|PQ|DV|DOVI|Dolby\s+Vision)([^A-Za-z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func extractReleaseLine(from text: String) -> String? {
        let knownQualities = ["4320p", "2160p", "1080p", "720p", "480p"]
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                guard !line.isEmpty, !line.hasPrefix("[") else { return false }
                let lower = line.lowercased()
                return knownQualities.contains { lower.contains($0) }
            }
    }

    private static func extractFileName(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseSubtitles(_ subtitles: [StreamSubtitle]?) -> [SubtitleTrack] {
        (subtitles ?? []).compactMap { subtitle in
            guard let source = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty else {
                return nil
            }
            let language = subtitle.language ?? subtitle.lang ?? subtitle.id ?? "Unknown"
            let languageId = (subtitle.lang ?? subtitle.id ?? language)
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
            return SubtitleTrack(
                language: language,
                source: source,
                languageId: languageId,
                name: language,
                trackId: TrackIdentity.stableTrackId(
                    type: "subtitle",
                    source: source,
                    languageId: languageId,
                    name: language,
                    sourceName: "Torrentio"
                ),
                sourceName: "Torrentio"
            )
        }
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/|")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodeConfiguration(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
