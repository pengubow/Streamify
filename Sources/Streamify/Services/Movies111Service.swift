import Foundation
import CommonCrypto

// MARK: - 111Movies Service
// Flow: fetchPageProps → encodeToken(pageProps.data) → fetchSources(/sr) → resolveFirstWorkingStream

enum Movies111Service {
    struct MovieResult {
        let hlsUrl: String
        let subtitles: [SubtitleTrack]
    }
    
    private static let baseURL = "https://111movies.net"
    private static let userAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0"
    private static let requestMethod = "GET"
    private static let apiContentType = "application/pdf"
    private static let xRequestedWith = "XMLHttpRequest"
    
    private static let aesKey = StreamifyHex.bytes(from: "75745e6c15fb316b25b34af455421c257c959ba6634cacfbaec0bae019c9a31c")
    private static let aesIV = StreamifyHex.bytes(from: "e26e7bf4549e9d99b169cf740a746e76")
    private static let xorKey: [UInt8] = [31, 53, 243, 172, 244, 229, 114, 181]
    
    private static let standardAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let scrambledAlphabet = Array("y5OnTckzKWGjIxS608up4F7BYVhimEZJ_NvldPfA9Ha-orQtsMwDUbqgCe3X1RL2")
    
    private static let apiPath = "APA91jIfiZxbFSzcMb2OmfKntpKPy-TQaw46YgiAUfMTO7qIqMPlsvMwYuyxK2MI2l1hlKXncY0YH8bjExtDSa5sg66tqDmP_csCi5B8-575ILXaYz2AeBtgZ7IknLrJwDKxI9OcHUaNXeJTSiugID-0polApBR10PQyX_-4GcuZwv9Sz4pLM9Y/w/1000074138859700/e200457c-4bce-5aa6-a15c-b6d8ab4b7d6c/aloom/7311467556049960822d8991a31d99836652ed0b13eb80175bf8cea462f89666"

    /// Fetch a playable stream for a movie by TMDB ID
    static func fetchMovieStream(tmdbId: Int) async -> MovieResult? {
        return await fetchStream(type: "movie", tmdbId: tmdbId)
    }
    
    /// Fetch a playable stream for a TV episode
    static func fetchEpisodeStream(tmdbId: Int, season: Int, episode: Int) async -> MovieResult? {
        return await fetchStream(type: "tv", tmdbId: tmdbId, season: season, episode: episode)
    }
    
    /// Resolve a TMDB ID to a playable URL + subtitles
    static func resolveStream(tmdbId: Int, type: ContentType, season: Int? = nil, episode: Int? = nil) async -> MovieResult? {
        if type == .series, let season = season, let episode = episode {
            return await fetchEpisodeStream(tmdbId: tmdbId, season: season, episode: episode)
        } else {
            return await fetchMovieStream(tmdbId: tmdbId)
        }
    }
    
    private static func fetchStream(type: String, tmdbId: Int, season: Int? = nil, episode: Int? = nil) async -> MovieResult? {
        let isTV = type == "tv" && season != nil && episode != nil
        
        // [1/3] Fetch page data
        StreamifyLogger.log("111Movies: [1/3] Fetching page data...")
        guard let pageData = await fetchPageData(tmdbId: tmdbId, isTV: isTV, season: season, episode: episode) else {
            StreamifyLogger.log("111Movies: No pageProps.data found")
            return nil
        }
        StreamifyLogger.log("111Movies: data: \(pageData.count) chars")
        
        // [2/3] Fetch sources
        StreamifyLogger.log("111Movies: [2/3] Fetching sources...")
        let token = encodeToken(data: pageData)
        guard let sources = await fetchSources(token: token) else {
            StreamifyLogger.log("111Movies: No sources returned")
            return nil
        }
        StreamifyLogger.log("111Movies: \(sources.count) source(s): \(sources.map { $0.name }.joined(separator: ", "))")
        
        // [3/3] Resolve stream
        StreamifyLogger.log("111Movies: [3/3] Resolving stream...")
        guard let (streamUrl, sourceName) = await resolveFirstWorkingStream(sources: sources) else {
            StreamifyLogger.log("111Movies: All sources failed")
            return nil
        }
        StreamifyLogger.log("111Movies: ✓ \(sourceName)")
        
        // Fetch Wyzie subtitles
        let subtitles = await fetchWyzieSubtitles(tmdbId: tmdbId, season: season, episode: episode)
        if !subtitles.isEmpty {
            StreamifyLogger.log("111Movies: Wyzie subtitles: \(subtitles.count)")
        }
        
        return MovieResult(hlsUrl: streamUrl, subtitles: subtitles)
    }
    
    private static func fetchPageData(tmdbId: Int, isTV: Bool, season: Int?, episode: Int?) async -> String? {
        let pagePath: String
        if isTV, let season = season, let episode = episode {
            pagePath = "/tv/\(tmdbId)/\(season)/\(episode)"
        } else {
            pagePath = "/movie/\(tmdbId)"
        }
        
        guard let url = URL(string: "\(baseURL)\(pagePath)") else { return nil }
        let request = makeBaseRequest(url: url)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
                StreamifyLogger.log("111Movies: Page fetch failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            
            guard let html = String(data: data, encoding: .utf8) else {
                StreamifyLogger.log("111Movies: Could not decode HTML as UTF-8")
                return nil
            }
            
            // Try extracting pageProps.data from __NEXT_DATA__
            if let pageProps = extractPagePropsFromHtml(html),
               let dataStr = pageProps["data"] as? String, !dataStr.isEmpty {
                return dataStr
            }
            
            guard let buildId = extractBuildId(from: html) else {
                StreamifyLogger.log("111Movies: buildId not found")
                return nil
            }
            
            let dataPath: String
            if isTV, let season = season, let episode = episode {
                dataPath = "/_next/data/\(buildId)/tv/\(tmdbId)/\(season)/\(episode).json"
            } else {
                dataPath = "/_next/data/\(buildId)/movie/\(tmdbId).json"
            }
            
            guard let dataUrl = URL(string: "\(baseURL)\(dataPath)") else { return nil }
            let dataReq = makeBaseRequest(url: dataUrl)
            
            let (jsonData, jsonResponse) = try await URLSession.shared.data(for: dataReq)
            guard let jsonHttp = jsonResponse as? HTTPURLResponse, jsonHttp.statusCode >= 200, jsonHttp.statusCode < 300 else {
                StreamifyLogger.log("111Movies: Data fetch failed")
                return nil
            }
            
            if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let pageProps = json["pageProps"] as? [String: Any],
               let dataStr = pageProps["data"] as? String, !dataStr.isEmpty {
                return dataStr
            }
            
            StreamifyLogger.log("111Movies: No pageProps.data in _next/data response")
            return nil
        } catch {
            StreamifyLogger.log("111Movies: Page fetch error: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Sources
    
    private struct SourceItem {
        let name: String
        let data: String
    }
    
    private static func fetchSources(token: String) async -> [SourceItem]? {
        guard let url = URL(string: "\(baseURL)/\(apiPath)/\(token)/sr") else { return nil }
        var request = makeBaseRequest(url: url)
        request.httpMethod = requestMethod
        applyAPIHeaders(to: &request)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
                StreamifyLogger.log("111Movies: Sources request failed (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return nil
            }
            
            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let text = String(data: data, encoding: .utf8) ?? ""
                StreamifyLogger.log("111Movies: Sources response is not a JSON array: \(String(text.prefix(200)))")
                return nil
            }
            
            let sources = jsonArray.compactMap { item -> SourceItem? in
                guard let name = item["name"] as? String,
                      let data = item["data"] as? String else { return nil }
                return SourceItem(name: name, data: data)
            }
            
            return sources.isEmpty ? nil : sources
        } catch {
            StreamifyLogger.log("111Movies: Sources request error: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func resolveFirstWorkingStream(sources: [SourceItem]) async -> (String, String)? {
        for source in sources {
            guard let url = URL(string: "\(baseURL)/\(apiPath)/\(source.data)") else { continue }
            var request = makeBaseRequest(url: url)
            request.httpMethod = requestMethod
            applyAPIHeaders(to: &request)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
                    StreamifyLogger.log("111Movies: ✗ \(source.name)")
                    continue
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let streamUrl = json["url"] as? String, !streamUrl.isEmpty {
                    return (streamUrl, source.name)
                }
            } catch {
                StreamifyLogger.log("111Movies: ✗ \(source.name)")
            }
        }
        
        return nil
    }
    
    // MARK: - Subtitle
    
    private static func fetchWyzieSubtitles(tmdbId: Int, season: Int?, episode: Int?) async -> [SubtitleTrack] {
        var components = URLComponents(string: "\(baseURL)/wyzie")
        var queryItems = [URLQueryItem(name: "id", value: "\(tmdbId)")]
        if let season = season, let episode = episode {
            queryItems.append(URLQueryItem(name: "season", value: "\(season)"))
            queryItems.append(URLQueryItem(name: "episode", value: "\(episode)"))
        }
        components?.queryItems = queryItems
        
        guard let url = components?.url else { return [] }
        var request = makeBaseRequest(url: url, includeOrigin: false)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else { return [] }
            
            guard let subsArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            
            return subsArray.compactMap { sub in
                guard let subUrl = sub["url"] as? String, !subUrl.isEmpty else { return nil }
                let display = sub["display"] as? String
                let language = sub["language"] as? String
                guard let label = display ?? language, !label.isEmpty else { return nil }
                let langId = (language ?? label).lowercased().replacingOccurrences(of: " ", with: "_")
                return SubtitleTrack(
                    language: language ?? label,
                    source: subUrl,
                    languageId: langId,
                    name: label,
                    trackId: TrackIdentity.stableTrackId(
                        type: "subtitle",
                        source: subUrl,
                        languageId: langId,
                        name: label,
                        sourceName: "111Movies"
                    ),
                    sourceName: "111Movies"
                )
            }
        } catch {
            return []
        }
    }
    
    // MARK: - HTML Parsing
    
    /// Extract __NEXT_DATA__ pageProps from HTML
    private static func extractPagePropsFromHtml(_ html: String) -> [String: Any]? {
        let pattern = "<script id=\"__NEXT_DATA__\"[^>]*>([\\s\\S]*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            StreamifyLogger.log("111Movies: No __NEXT_DATA__ script found in HTML")
            return nil
        }
        
        let jsonString = String(html[range])
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            StreamifyLogger.log("111Movies: Failed to parse __NEXT_DATA__ JSON")
            return nil
        }
        
        StreamifyLogger.log("111Movies: Extracted pageProps with \(pageProps.count) keys")
        return pageProps
    }
    
    /// Extract buildId from HTML
    private static func extractBuildId(from html: String) -> String? {
        let pattern = "buildId['\"\\_]?\\s*:\\s*['\"]([^'\"]+)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }
    
    // MARK: - Token Encryption
    // AES-256-CBC(data) → hex → XOR(cycling key) → UTF-8 → base64 → URL-safe → char substitution
    
    static func encodeToken(data: String) -> String {
        // Step 1: AES-256-CBC encrypt
        let inputData = Data(data.utf8)
        let bufferSize = inputData.count + kCCBlockSizeAES128
        var encryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0
        
        let status = inputData.withUnsafeBytes { inputPtr in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                aesKey, aesKey.count,
                aesIV,
                inputPtr.baseAddress, inputData.count,
                &encryptedBytes, bufferSize,
                &numBytesEncrypted
            )
        }
        
        guard status == kCCSuccess else {
            StreamifyLogger.log("111Movies: AES encryption failed with status \(status)")
            return ""
        }
        
        // Step 2: Convert to hex string
        let hex = encryptedBytes[0..<numBytesEncrypted].map { String(format: "%02x", $0) }.joined()
        
        // Step 3: XOR with cycling key
        let xored = hex.enumerated().map { (i, char) -> Character in
            let charCode = char.asciiValue ?? 0
            let xorByte = xorKey[i % xorKey.count]
            return Character(UnicodeScalar(UInt32(charCode ^ xorByte))!)
        }
        let xoredString = String(xored)
        
        // Step 4: Base64 URL-safe encode
        let base64 = Data(xoredString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        // Step 5: Character substitution (standard → scrambled alphabet)
        let result = base64.map { char -> Character in
            if let index = standardAlphabet.firstIndex(of: char) {
                return scrambledAlphabet[index]
            }
            return char
        }
        
        return String(result)
    }
    
    // MARK: - Helpers
    
    private static func applyAPIHeaders(to request: inout URLRequest) {
        request.setValue(apiContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(xRequestedWith, forHTTPHeaderField: "X-Requested-With")
        if requestMethod != "GET" && requestMethod != "HEAD" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
    }
    
    /// Create a base URLRequest with default headers
    private static func makeBaseRequest(url: URL, includeOrigin: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(baseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        if includeOrigin {
            request.setValue(baseURL, forHTTPHeaderField: "Origin")
        }
        return request
    }
}
