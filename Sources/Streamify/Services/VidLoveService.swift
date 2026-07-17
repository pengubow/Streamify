import CryptoKit
import Foundation

enum VidLoveService {
    struct VidLoveResult {
        let streamUrl: String
        let subtitles: [SubtitleTrack]
        let qualities: [HLSQuality]
    }

    private struct ContentRequest: Sendable {
        let type: ContentType
        let tmdbId: Int
        let season: Int?
        let episode: Int?
    }

    private struct Server: Sendable {
        let name: String
        let movieTemplate: String
        let tvTemplate: String
    }

    private struct SubtitleProvider: Sendable {
        let name: String
        let baseUrl: String
        let movieTemplate: String
        let tvTemplate: String
    }

    private struct RuntimeConfiguration: Sendable {
        let servers: [Server]
        let subtitleProvider: SubtitleProvider?
        let responseKeys: [String]
        let authPath: String
    }

    private struct StreamCandidate: Sendable {
        let server: String
        let name: String
        let height: Int?
        let resolution: String?
        let url: URL
        let headers: [String: String]
        var supportsByteRangeSeeking: Bool = false
    }

    private struct CandidateValidation: Sendable {
        let isAlive: Bool
        let supportsByteRangeSeeking: Bool
    }

    private struct HTTPResult: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private final class HeaderBox: NSObject {
        let headers: [String: String]

        init(_ headers: [String: String]) {
            self.headers = headers
        }
    }

    private actor RequestRateLimiter {
        private let minimumInterval: TimeInterval
        private var nextAllowedTime: TimeInterval = 0

        init(minimumInterval: TimeInterval) {
            self.minimumInterval = minimumInterval
        }

        func wait() async throws {
            try Task.checkCancellation()
            let now = Date.timeIntervalSinceReferenceDate
            let scheduledTime = max(now, nextAllowedTime)
            nextAllowedTime = scheduledTime + minimumInterval
            let delay = scheduledTime - now
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            try Task.checkCancellation()
        }
    }

    private enum ServiceError: LocalizedError {
        case invalidURL(String)
        case http(Int, String)
        case invalidResponse(String)
        case discovery(String)
        case decryption

        var errorDescription: String? {
            switch self {
            case .invalidURL(let value):
                return "Invalid URL: \(value)"
            case .http(let status, let url):
                return "HTTP \(status) for \(url)"
            case .invalidResponse(let message), .discovery(let message):
                return message
            case .decryption:
                return "No key discovered from the active player assets could decode the response"
            }
        }
    }

    private static let playerUrl = URL(string: "https://player.vidlove.cc/")!
    private static let userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/138 Safari/537.36"
    private static let requestHeaderCache = NSCache<NSString, HeaderBox>()
    private static let byteRangeSeekabilityCache = NSCache<NSString, NSNumber>()
    private static let requestRateLimiter = RequestRateLimiter(minimumInterval: 0.35)

    static func fetchMovieStream(tmdbId: Int) async -> VidLoveResult? {
        await fetchStream(ContentRequest(type: .movie, tmdbId: tmdbId, season: nil, episode: nil))
    }

    static func fetchEpisodeStream(tmdbId: Int, season: Int, episode: Int) async -> VidLoveResult? {
        await fetchStream(ContentRequest(type: .series, tmdbId: tmdbId, season: season, episode: episode))
    }

    static func resolveStream(
        tmdbId: Int,
        type: ContentType,
        season: Int? = nil,
        episode: Int? = nil
    ) async -> VidLoveResult? {
        if type == .series, let season, let episode {
            return await fetchEpisodeStream(tmdbId: tmdbId, season: season, episode: episode)
        }
        return await fetchMovieStream(tmdbId: tmdbId)
    }

    static func matchingQuality(
        in result: VidLoveResult,
        previousURL: String?,
        qualityName: String?,
        resolution: String?
    ) -> HLSQuality? {
        if let previousURL,
           let match = result.qualities.first(where: {
               $0.sourceUrl == previousURL || $0.variantUrl == previousURL
           }) {
            return match
        }
        if let qualityName,
           let match = result.qualities.first(where: {
               $0.name.caseInsensitiveCompare(qualityName) == .orderedSame
           }) {
            return match
        }
        if let resolution,
           let match = result.qualities.first(where: { $0.resolution == resolution }) {
            return match
        }
        return result.qualities.first
    }

    static func requestHeaders(for url: URL) -> [String: String] {
        if let exact = requestHeaderCache.object(forKey: url.absoluteString as NSString) {
            return exact.headers
        }

        if let embedded = embeddedHeaders(in: url) {
            var headers = embedded
            headers["Origin"] = playerUrlOrigin
            headers["Referer"] = playerUrl.absoluteString
            register(headers: headers, for: url)
            return headers
        }

        if let originKey = originCacheKey(for: url),
           let origin = requestHeaderCache.object(forKey: originKey) {
            return origin.headers
        }
        return [:]
    }

    static func supportsByteRangeSeeking(for url: URL) -> Bool? {
        byteRangeSeekabilityCache.object(forKey: url.absoluteString as NSString)?.boolValue
    }

    static func makeRequest(for url: URL, timeoutInterval: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        for (name, value) in requestHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    static func assetOptions(for url: URL) -> [String: Any]? {
        let headers = requestHeaders(for: url)
        guard !headers.isEmpty else { return nil }
        return ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    private static func fetchStream(_ content: ContentRequest) async -> VidLoveResult? {
        do {
            let configuration = try await discoverRuntime(for: content)
            async let source = firstWorkingSource(for: content, configuration: configuration)
            async let subtitles = fetchSubtitles(for: content, provider: configuration.subtitleProvider)
            let (candidates, tracks) = await (source, subtitles)

            guard !candidates.isEmpty else {
                StreamifyLogger.log("VidLoveService: No live media URL was returned by any discovered source")
                return nil
            }

            let qualities = candidates.map { candidate in
                register(headers: candidate.headers, for: candidate.url)
                byteRangeSeekabilityCache.setObject(
                    NSNumber(value: candidate.supportsByteRangeSeeking),
                    forKey: candidate.url.absoluteString as NSString
                )
                return HLSQuality(
                    name: candidate.name,
                    bandwidth: 0,
                    resolution: candidate.resolution,
                    videoRange: nil,
                    frameRate: nil,
                    sourceUrl: candidate.url.absoluteString,
                    variantUrl: nil,
                    sourceName: "VidLove",
                    displayDetail: candidate.server
                )
            }

            StreamifyLogger.log(
                "VidLoveService: Resolved \(qualities.count) quality option(s), "
                    + "\(candidates.filter(\.supportsByteRangeSeeking).count) range-seekable, "
                    + "and \(tracks.count) subtitle(s)"
            )
            return VidLoveResult(
                streamUrl: candidates[0].url.absoluteString,
                subtitles: tracks,
                qualities: qualities
            )
        } catch {
            StreamifyLogger.log("VidLoveService: \(error.localizedDescription)")
            return nil
        }
    }

    private static func discoverRuntime(for content: ContentRequest) async throws -> RuntimeConfiguration {
        let route: String
        if content.type == .series, let season = content.season, let episode = content.episode {
            route = "embed/tv/\(content.tmdbId)/\(season)/\(episode)"
        } else {
            route = "embed/movie/\(content.tmdbId)"
        }
        guard let embedUrl = URL(string: route, relativeTo: playerUrl)?.absoluteURL else {
            throw ServiceError.invalidURL(route)
        }

        let html = try await fetchText(
            embedUrl,
            headers: standardHeaders(accept: "text/html,*/*")
        )
        let scriptTags = captures(
            pattern: #"<script\b[^>]*>"#,
            in: html,
            options: [.caseInsensitive]
        ).compactMap(\.first)
        let moduleScripts = scriptTags.filter {
            firstCapture(pattern: #"type=["']module["']"#, in: $0, options: [.caseInsensitive]) != nil
        }
        let scriptTag = moduleScripts.first {
            firstCapture(pattern: #"index-[^"']+\.js"#, in: $0, options: [.caseInsensitive]) != nil
        } ?? moduleScripts.first
        guard let scriptTag,
              let scriptRef = firstCapture(pattern: #"src=["']([^"']+)["']"#, in: scriptTag),
              let bundleUrl = URL(string: scriptRef, relativeTo: embedUrl)?.absoluteURL else {
            throw ServiceError.discovery("VidLove player script was not found")
        }

        let bundle = try await fetchText(bundleUrl, headers: standardHeaders())
        var variables: [String: String] = [:]
        for match in captures(
            pattern: #"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*["'](https?://[^"']+)["']"#,
            in: bundle
        ) where match.count >= 2 {
            variables[match[0]] = match[1]
        }

        var servers: [Server] = []
        for match in captures(
            pattern: #"\{name:"([^"]+)",api:([A-Za-z_$][\w$]*)\+"([^"]+)",tvApi:\2\+"([^"]+)""#,
            in: bundle
        ) where match.count >= 4 {
            guard let base = variables[match[1]] else { continue }
            servers.append(Server(
                name: match[0],
                movieTemplate: base + match[2],
                tvTemplate: base + match[3]
            ))
        }
        guard !servers.isEmpty else {
            throw ServiceError.discovery("VidLove source list was not found in the current player bundle")
        }

        let subtitleProvider: SubtitleProvider? = {
            guard let match = captures(
                pattern: #"\{name:"([^"]+)",baseUrl:"([^"]+)",movieEndpoint:"([^"]+)",tvEndpoint:"([^"]+)""#,
                in: bundle
            ).first, match.count >= 4 else {
                return nil
            }
            return SubtitleProvider(
                name: match[0],
                baseUrl: match[1],
                movieTemplate: match[2],
                tvTemplate: match[3]
            )
        }()

        var responseKeys: [String] = []
        func addKey(_ value: String?) {
            guard let value, value.count >= 4, !responseKeys.contains(value) else { return }
            responseKeys.append(value)
        }
        for match in captures(
            pattern: #"decryptResponseGcm\(\s*[^,]+,\s*((?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'))"#,
            in: bundle
        ) {
            addKey(match.first.flatMap(javascriptLiteral))
        }

        if let constantsRef = captures(
            pattern: #"(?:href|src)=["']([^"']*sec-constants[^"']*\.js)["']"#,
            in: html,
            options: [.caseInsensitive]
        ).first?.first,
           let constantsUrl = URL(string: constantsRef, relativeTo: embedUrl)?.absoluteURL,
           let constants = try? await fetchText(constantsUrl, headers: standardHeaders()) {
            for match in captures(
                pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
                in: constants
            ) {
                addKey(match.first.flatMap(javascriptLiteral))
            }
        }
        guard !responseKeys.isEmpty else {
            throw ServiceError.discovery("VidLove response key was not discoverable from current assets")
        }

        guard let authPath = firstCapture(
            pattern: #"/(auth/[a-z0-9_/-]+)"#,
            in: bundle,
            options: [.caseInsensitive]
        ) else {
            throw ServiceError.discovery("VidLove token route was not found")
        }

        return RuntimeConfiguration(
            servers: servers,
            subtitleProvider: subtitleProvider,
            responseKeys: responseKeys,
            authPath: "/" + authPath
        )
    }

    private static func firstWorkingSource(
        for content: ContentRequest,
        configuration: RuntimeConfiguration
    ) async -> [StreamCandidate] {
        for server in configuration.servers {
            let template = content.type == .series ? server.tvTemplate : server.movieTemplate
            let endpointString = fill(template: template, content: content)
            guard let endpoint = URL(string: endpointString),
                  let origin = originURL(for: endpoint) else {
                continue
            }

            do {
                var response: HTTPResult?
                for attempt in 0..<2 {
                    let token = try await fetchToken(origin: origin, authPath: configuration.authPath)
                    var request = URLRequest(url: endpoint)
                    request.timeoutInterval = 30
                    apply(headers: standardHeaders(accept: "application/json,*/*"), to: &request)
                    request.setValue(token, forHTTPHeaderField: "x-request-token")
                    request.setValue("aes-gcm", forHTTPHeaderField: "x-response-encryption")
                    response = try await send(request)
                    if ![401, 403].contains(response?.response.statusCode ?? 0) || attempt == 1 {
                        break
                    }
                }

                guard let response else { continue }
                let wire = try jsonObject(from: response.data)
                let payload = try decrypt(wire: wire, keys: configuration.responseKeys)
                let candidates = streamCandidates(from: payload, endpoint: endpoint, server: server.name)
                let live = await verified(candidates)
                if !live.isEmpty {
                    return live
                }
            } catch {
                StreamifyLogger.log("VidLoveService: \(server.name) failed: \(error.localizedDescription)")
            }
        }
        return []
    }

    private static func fetchToken(origin: URL, authPath: String) async throws -> String {
        guard let url = URL(string: authPath, relativeTo: origin)?.absoluteURL else {
            throw ServiceError.invalidURL(authPath)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        apply(headers: standardHeaders(accept: "application/json,*/*"), to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["clientData": [:]])

        let result = try await send(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw ServiceError.http(result.response.statusCode, url.absoluteString)
        }
        let object = try jsonObject(from: result.data)
        let data = object["data"] as? [String: Any]
        guard let token = (data?["token"] ?? object["token"]) as? String, !token.isEmpty else {
            throw ServiceError.invalidResponse("VidLove fresh-token request did not return a token")
        }
        return token
    }

    private static func decrypt(wire: [String: Any], keys: [String]) throws -> [String: Any] {
        guard let payload = wire["payload"] as? String else { return wire }
        guard let encrypted = base64URLData(payload), encrypted.count > 44 else {
            throw ServiceError.decryption
        }

        let salt = encrypted.prefix(16)
        let nonceData = encrypted.subdata(in: 16..<28)
        let ciphertext = encrypted.subdata(in: 28..<(encrypted.count - 16))
        let tag = encrypted.suffix(16)

        for password in keys {
            do {
                var keyMaterial = Data(password.utf8)
                keyMaterial.append(salt)
                let digest = SHA256.hash(data: keyMaterial)
                let key = SymmetricKey(data: Data(digest))
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                let plaintext = try AES.GCM.open(box, using: key)
                var merged = wire
                for (name, value) in try jsonObject(from: plaintext) {
                    merged[name] = value
                }
                return merged
            } catch {
                continue
            }
        }
        throw ServiceError.decryption
    }

    private static func streamCandidates(
        from payload: [String: Any],
        endpoint: URL,
        server: String
    ) -> [StreamCandidate] {
        var items: [Any] = []
        if let sources = payload["sources"] as? [Any] {
            items.append(contentsOf: sources)
        } else if let streams = payload["streams"] as? [Any] {
            items.append(contentsOf: streams)
        }
        for key in ["url", "stream", "m3u8", "playlist"] {
            if let value = payload[key] as? String {
                items.insert(["url": value, "quality": "Auto"], at: 0)
            }
        }

        let payloadHeaders = stringDictionary(payload["headers"])
        var seen: Set<String> = []
        var candidates: [StreamCandidate] = []
        for item in items {
            let dictionary = item as? [String: Any]
            let rawUrl = (item as? String)
                ?? dictionary?["url"] as? String
                ?? dictionary?["file"] as? String
                ?? dictionary?["streamUrl"] as? String
            guard let rawUrl,
                  let url = URL(string: rawUrl, relativeTo: endpoint)?.absoluteURL,
                  seen.insert(url.absoluteString).inserted else {
                continue
            }

            let rawQuality = stringValue(dictionary?["quality"])
            let rawResolution = stringValue(dictionary?["resolution"])
            var resolution: String?
            var resolutionHeight: Int?
            if let rawResolution,
               let dimensions = captures(
                   pattern: #"(\d{2,5})\s*[xX]\s*(\d{2,5})"#,
                   in: rawResolution
               ).first,
               dimensions.count >= 2 {
                resolution = "\(dimensions[0])x\(dimensions[1])"
                resolutionHeight = Int(dimensions[1])
            }
            let height = rawQuality.flatMap(firstInteger) ?? resolutionHeight
            var headers = payloadHeaders
            headers.merge(stringDictionary(dictionary?["headers"])) { _, new in new }
            if let embedded = embeddedHeaders(in: url) {
                headers.merge(embedded) { _, new in new }
                headers["Origin"] = playerUrlOrigin
                headers["Referer"] = playerUrl.absoluteString
            }

            candidates.append(StreamCandidate(
                server: server,
                name: height.map { "\($0)p" } ?? rawQuality ?? "Auto",
                height: height,
                resolution: resolution,
                url: url,
                headers: headers
            ))
        }

        return candidates.sorted {
            if ($0.height ?? 0) != ($1.height ?? 0) {
                return ($0.height ?? 0) > ($1.height ?? 0)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func verified(_ candidates: [StreamCandidate]) async -> [StreamCandidate] {
        await withTaskGroup(of: (Int, CandidateValidation).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await validate(candidate))
                }
            }
            var validations: [Int: CandidateValidation] = [:]
            for await (index, validation) in group {
                validations[index] = validation
            }
            return candidates.enumerated().compactMap { index, candidate in
                guard let validation = validations[index], validation.isAlive else { return nil }
                var candidate = candidate
                candidate.supportsByteRangeSeeking = validation.supportsByteRangeSeeking
                return candidate
            }.sorted {
                if $0.supportsByteRangeSeeking != $1.supportsByteRangeSeeking {
                    return $0.supportsByteRangeSeeking
                }
                if ($0.height ?? 0) != ($1.height ?? 0) {
                    return ($0.height ?? 0) > ($1.height ?? 0)
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func validate(_ candidate: StreamCandidate) async -> CandidateValidation {
        do {
            var request = URLRequest(url: candidate.url)
            request.timeoutInterval = 12
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            apply(headers: candidate.headers, to: &request)
            request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")

            try await requestRateLimiter.wait()
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return CandidateValidation(isAlive: false, supportsByteRangeSeeking: false)
            }
            let supportsByteRangeSeeking = http.statusCode == 206

            var sample = Data()
            sample.reserveCapacity(2_048)
            for try await byte in bytes {
                sample.append(byte)
                if sample.count >= 2_048 { break }
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let finalUrl = http.url ?? candidate.url
            let expectsHLS = contentType.contains("mpegurl")
                || HLSQuality.looksLikeHLS(finalUrl.absoluteString)
                || HLSQuality.looksLikeHLS(candidate.url.absoluteString)
            if expectsHLS {
                return CandidateValidation(
                    isAlive: String(data: sample, encoding: .utf8)?.contains("#EXTM3U") == true,
                    supportsByteRangeSeeking: false
                )
            }
            if contentType.contains("text/html") || contentType.contains("application/json") {
                return CandidateValidation(isAlive: false, supportsByteRangeSeeking: false)
            }
            let isAlive = http.statusCode == 206
                || contentType.hasPrefix("video/")
                || contentType.hasPrefix("audio/")
                || contentType.contains("application/octet-stream")
                || contentType.contains("application/mp4")
                || sample.range(of: Data("ftyp".utf8)) != nil
                || !sample.isEmpty
            return CandidateValidation(
                isAlive: isAlive,
                supportsByteRangeSeeking: supportsByteRangeSeeking
            )
        } catch {
            return CandidateValidation(isAlive: false, supportsByteRangeSeeking: false)
        }
    }

    private static func fetchSubtitles(
        for content: ContentRequest,
        provider: SubtitleProvider?
    ) async -> [SubtitleTrack] {
        guard let provider else { return [] }
        let template = content.type == .series ? provider.tvTemplate : provider.movieTemplate
        let endpointPath = fill(template: template, content: content)
        guard let base = URL(string: provider.baseUrl),
              let endpoint = URL(string: endpointPath, relativeTo: base)?.absoluteURL else {
            return []
        }

        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 30
            apply(headers: standardHeaders(), to: &request)
            let result = try await send(request)
            guard (200..<300).contains(result.response.statusCode) else { return [] }
            let raw = try JSONSerialization.jsonObject(with: result.data)
            let list = (raw as? [Any]) ?? ((raw as? [String: Any])?["subtitles"] as? [Any]) ?? []
            return list.compactMap { item in
                guard let item = item as? [String: Any] else { return nil }
                let rawUrl = item["file"] as? String
                    ?? item["url"] as? String
                    ?? item["src"] as? String
                guard let rawUrl,
                      let url = URL(string: rawUrl, relativeTo: endpoint)?.absoluteURL else {
                    return nil
                }
                let label = stringValue(item["label"])
                    ?? stringValue(item["display"])
                    ?? stringValue(item["language"])
                    ?? "Unknown"
                let language = stringValue(item["language"])
                    ?? stringValue(item["lang"])
                    ?? label
                let languageId = language.lowercased().replacingOccurrences(of: " ", with: "_")
                return SubtitleTrack(
                    language: language,
                    source: url.absoluteString,
                    languageId: languageId,
                    name: label,
                    trackId: TrackIdentity.stableTrackId(
                        type: "subtitle",
                        source: url.absoluteString,
                        languageId: languageId,
                        name: label,
                        sourceName: "VidLove",
                        extra: stringValue(item["source"]) ?? provider.name
                    ),
                    sourceName: "VidLove"
                )
            }
        } catch {
            StreamifyLogger.log("VidLoveService: Subtitle request failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func standardHeaders(accept: String = "*/*") -> [String: String] {
        [
            "Accept": accept,
            "Origin": playerUrlOrigin,
            "Referer": playerUrl.absoluteString,
            "User-Agent": userAgent
        ]
    }

    private static var playerUrlOrigin: String {
        "\(playerUrl.scheme ?? "https")://\(playerUrl.host ?? "player.vidlove.cc")"
    }

    private static func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        apply(headers: headers, to: &request)
        let result = try await send(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw ServiceError.http(result.response.statusCode, url.absoluteString)
        }
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw ServiceError.invalidResponse("Non-text response from \(url.absoluteString)")
        }
        return text
    }

    private static func send(_ request: URLRequest) async throws -> HTTPResult {
        try await requestRateLimiter.wait()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse("Non-HTTP response from \(request.url?.absoluteString ?? "unknown URL")")
        }
        return HTTPResult(data: data, response: http)
    }

    private static func apply(headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func fill(template: String, content: ContentRequest) -> String {
        var result = template
        let values: [(String, String?)] = [
            ("type", content.type == .series ? "tv" : "movie"),
            ("id", String(content.tmdbId)),
            ("tmdbId", String(content.tmdbId)),
            ("season", content.season.map(String.init)),
            ("episode", content.episode.map(String.init))
        ]
        for (name, value) in values {
            guard let value else { continue }
            result = result
                .replacingOccurrences(of: "${\(name)}", with: value)
                .replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidResponse("VidLove returned a non-object JSON response")
        }
        return object
    }

    private static func javascriptLiteral(_ value: String) -> String? {
        guard value.count >= 2 else { return nil }
        if value.hasPrefix("\"") {
            guard let data = "[\(value)]".data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return nil
            }
            return values.first
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func captures(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            let captureRange = match.numberOfRanges > 1 ? 1..<match.numberOfRanges : 0..<1
            return captureRange.compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
                    return nil
                }
                return String(text[swiftRange])
            }
        }
    }

    private static func firstCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        captures(pattern: pattern, in: text, options: options).first?.first
    }

    private static func base64URLData(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let value = value as? [String: Any] else { return [:] }
        return value.reduce(into: [:]) { result, item in
            if let string = stringValue(item.value), !string.isEmpty {
                result[item.key] = string
            }
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func firstInteger(in value: String) -> Int? {
        guard let match = value.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(value[match])
    }

    private static func embeddedHeaders(in url: URL) -> [String: String]? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "headers" })?
            .value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let headers = stringDictionary(object)
        return headers.isEmpty ? nil : headers
    }

    private static func register(headers: [String: String], for url: URL) {
        guard !headers.isEmpty else { return }
        let box = HeaderBox(headers)
        requestHeaderCache.setObject(box, forKey: url.absoluteString as NSString)
        if let originKey = originCacheKey(for: url) {
            requestHeaderCache.setObject(box, forKey: originKey)
        }
    }

    private static func originCacheKey(for url: URL) -> NSString? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "origin:\(scheme)://\(host)\(port)" as NSString
    }

    private static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

}
