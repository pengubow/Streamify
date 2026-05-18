import Foundation

// MARK: - Source reference in sources.json
// This is a lightweight reference that points to actual source files
struct SourceReference: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let isLocal: Bool
    let url: String?  // Remote URL for non-local sources (to re-fetch)
    
    enum CodingKeys: String, CodingKey {
        case id = "i"
        case isLocal = "l"
        case url = "u"
    }
    
    private enum LegacyKeys: String, CodingKey {
        case id, isLocal, url
    }
    
    init(id: String, isLocal: Bool, url: String?) {
        self.id = id
        self.isLocal = isLocal
        self.url = url
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? lc.decode(Bool.self, forKey: .isLocal)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? lc.decodeIfPresent(String.self, forKey: .url)
    }
}

nonisolated enum SourcesManager {
    
    // MARK: - File paths
    
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static var sourcesDirectoryURL: URL {
        documentsURL.appendingPathComponent("Sources")
    }
    
    /// Compressed sources index file
    private static var sourcesIndexZlibURL: URL {
        documentsURL.appendingPathComponent("sources.json.zlib")
    }
    
    /// Plain sources index file (legacy fallback)
    private static var sourcesIndexURL: URL {
        documentsURL.appendingPathComponent("sources.json")
    }
    
    /// Compressed source data file for a given source ID
    private static func sourceFileZlibURL(for id: String) -> URL {
        sourcesDirectoryURL.appendingPathComponent("\(id).json.zlib")
    }
    
    /// Plain source data file (legacy fallback)
    private static func sourceFileURL(for id: String) -> URL {
        sourcesDirectoryURL.appendingPathComponent("\(id).json")
    }
    
    // MARK: - Load source references
    
    static func loadSourceReferences() -> [SourceReference] {
        return (try? CompressedJSON.readWithFallback(
            [SourceReference].self,
            compressedURL: sourcesIndexZlibURL,
            plainURL: sourcesIndexURL
        )) ?? []
    }
    
    // MARK: - Save source references
    
    static func saveSourceReferences(_ references: [SourceReference]) {
        do {
            try CompressedJSON.write(references, to: sourcesIndexZlibURL)
        } catch {
            StreamifyLogger.log("Failed to save source references: \(error)")
        }
    }
    
    // MARK: - Load sources
    
    static func loadSources() -> [Source] {
        let refs = loadSourceReferences()
        var sources: [Source] = []
        
        try? FileManager.default.createDirectory(at: sourcesDirectoryURL, withIntermediateDirectories: true)
        
        for ref in refs {
            do {
                let source = try CompressedJSON.readWithFallback(
                    Source.self,
                    compressedURL: sourceFileZlibURL(for: ref.id),
                    plainURL: sourceFileURL(for: ref.id)
                )
                sources.append(source)
            } catch {
                StreamifyLogger.log("Failed to load source \(ref.id): \(error)")
            }
        }
        
        return sources
    }
    
    // MARK: - Save source
    
    static func saveSource(_ source: Source, isLocal: Bool = true, url: String? = nil) {
        try? FileManager.default.createDirectory(at: sourcesDirectoryURL, withIntermediateDirectories: true)
        
        // Save source data
        do {
            try CompressedJSON.write(source, to: sourceFileZlibURL(for: source.id))
        } catch {
            StreamifyLogger.log("Failed to save source \(source.id): \(error)")
        }
        
        // Update references
        var refs = (try? CompressedJSON.readWithFallback(
            [SourceReference].self,
            compressedURL: sourcesIndexZlibURL,
            plainURL: sourcesIndexURL
        )) ?? []
        
        // Preserve existing URL if not provided
        let existingUrl = refs.first(where: { $0.id == source.id })?.url
        refs.removeAll { $0.id == source.id }
        refs.append(SourceReference(id: source.id, isLocal: isLocal, url: url ?? existingUrl))
        saveSourceReferences(refs)
    }
    
    // MARK: - Add source from URL (remote JSON)
    
    static func addSource(from urlString: String) async throws -> Source {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidURL
        }
        
        try Task.checkCancellation()
        let (data, _) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        
        // Remote sources use old-format JSON (long keys), our decoder handles both
        let source = try JSONDecoder().decode(Source.self, from: data)
        
        saveSource(source, isLocal: false, url: urlString)
        
        return source
    }
    
    // MARK: - Add source from local file
    
    static func addLocalSource(from url: URL) throws -> Source {
        let data = try Data(contentsOf: url)
        // Local imports may use old-format JSON, our decoder handles both
        let source = try JSONDecoder().decode(Source.self, from: data)
        
        saveSource(source, isLocal: true)
        
        return source
    }
    
    // MARK: - Add source directly (from parsed Source object)
    
    static func addSource(_ source: Source, isLocal: Bool = true) {
        saveSource(source, isLocal: isLocal)
    }
    
    // MARK: - Remove source
    
    static func removeSource(_ source: Source) {
        // Remove source data file
        let zlibFile = sourceFileZlibURL(for: source.id)
        let plainFile = sourceFileURL(for: source.id)
        try? FileManager.default.removeItem(at: zlibFile)
        try? FileManager.default.removeItem(at: plainFile)
        
        // Remove from references
        var refs = (try? CompressedJSON.readWithFallback(
            [SourceReference].self,
            compressedURL: sourcesIndexZlibURL,
            plainURL: sourcesIndexURL
        )) ?? []
        refs.removeAll { $0.id == source.id }
        saveSourceReferences(refs)
    }
    
    // MARK: - Delete source (alias for removeSource)
    
    static func deleteSource(_ source: Source) {
        removeSource(source)
    }
    
    // MARK: - Update existing source
    
    static func updateSource(_ source: Source) {
        saveSource(source, isLocal: true)
    }
    
    // MARK: - Refresh all sources (re-fetches remote sources)
    
    static func refreshSources() async -> [Source] {
        let references = loadSourceReferences()
        
        for reference in references {
            guard !reference.isLocal, let urlString = reference.url, let url = URL(string: urlString) else {
                continue
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    StreamifyLogger.log("Failed to refresh source \(reference.id): HTTP \(httpResponse.statusCode)")
                    continue
                }
                
                guard !data.isEmpty else {
                    StreamifyLogger.log("Failed to refresh source \(reference.id): empty response")
                    continue
                }
                
                do {
                    let source = try JSONDecoder().decode(Source.self, from: data)
                    saveSource(source, isLocal: false, url: urlString)
                } catch {
                    StreamifyLogger.log("Failed to decode source \(reference.id): \(error.localizedDescription)")
                }
            } catch {
                StreamifyLogger.log("Failed to refresh source \(reference.id): \(error.localizedDescription)")
            }
        }
        
        return loadSources()
    }
    
    // MARK: - Get all content from sources
    
    static func allContent() -> [SourceContent] {
        let sources = loadSources()
        return sources.flatMap { $0.movies }
    }
    
    // MARK: - Get content by genre
    
    static func content(by genre: Genre) -> [SourceContent] {
        allContent().filter { $0.genre == genre }
    }
    
    // MARK: - Check if content is downloaded
    
    static func isDownloaded(_ content: SourceContent) -> Bool {
        let library = ContentImportService.loadLibrary()
        return library.contains { $0.id == content.id }
    }
    
    // MARK: - Create sample local source file
    
    static func createSampleSource() {
        let sampleSource = Source(
            id: "sample",
            name: "Sample Source",
            movies: [
                SourceContent(
                    id: "big-buck-bunny-src",
                    title: "Big Buck Bunny",
                    description: "A large and lovable bunny deals with three tiny bullies in this animated short.",
                    type: .movie,
                    genres: [.animation, .comedy],
                    thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png",
                    posterThumbnailUrl: "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/250px-Big_buck_bunny_poster_big.jpg",
                    fileUrl: nil,
                    hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
                    end: 30,
                    subtitles: [
                        SubtitleTrack(language: "English", source: "https://raw.githubusercontent.com/amazon-archives/web-app-starter-kit-for-fire-tv/refs/heads/master/out/mrss/assets/sample_video-en.vtt")
                    ]
                ),
                SourceContent(
                    id: "big-buck-bunny-series-src",
                    title: "Big Buck Bunny Series",
                    description: "The adventures of Big Buck Bunny in series format.",
                    type: .series,
                    genres: [.animation, .comedy],
                    thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png",
                    posterThumbnailUrl: "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/250px-Big_buck_bunny_poster_big.jpg",
                    fileUrl: nil,
                    hlsUrl: nil,
                    seasons: [
                        SeasonInfo(
                            season: 1,
                            title: "Season 1: The Beginning",
                            thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png",
                            episodes: [
                                EpisodeInfo(season: 1, episode: 1, title: "The Beginning", description: "Big Buck Bunny wakes up to a beautiful day in the forest.", thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png", hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", intro: 5, introDuration: 10, end: 30, subtitles: [SubtitleTrack(language: "English", source: "https://raw.githubusercontent.com/amazon-archives/web-app-starter-kit-for-fire-tv/refs/heads/master/out/mrss/assets/sample_video-en.vtt")]),
                                EpisodeInfo(season: 1, episode: 2, title: "The Bullies", description: "Three tiny rodents cause trouble for our gentle giant.", thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png", hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", intro: 8, introDuration: 12, end: 25),
                                EpisodeInfo(season: 1, episode: 3, title: "Revenge", description: "Big Buck Bunny gets his sweet revenge on the bullies.", thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png", hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", intro: 3, introDuration: 8, end: 20)
                            ]
                        ),
                        SeasonInfo(
                            season: 2,
                            title: "Season 2: New Horizons",
                            thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png",
                            episodes: [
                                EpisodeInfo(season: 2, episode: 1, title: "New Adventures", description: "Big Buck Bunny explores new territories.", thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png", hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", intro: 10, introDuration: 15, end: 30),
                                EpisodeInfo(season: 2, episode: 2, title: "Winter Coming", description: "The forest prepares for winter.", thumbnailUrl: "https://peach.blender.org/wp-content/uploads/bbb-splash.png", hlsUrl: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", intro: 6, introDuration: 10, end: 25)
                            ]
                        )
                    ],
                    episodes: nil
                )
            ]
        )
        
        saveSource(sampleSource, isLocal: true)
    }
}

// MARK: - Source errors

enum SourceError: LocalizedError {
    case invalidURL
    case invalidJSON
    case downloadFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL. Please enter a valid link."
        case .invalidJSON: return "Invalid JSON format in source file."
        case .downloadFailed: return "Failed to download source."
        }
    }
}
