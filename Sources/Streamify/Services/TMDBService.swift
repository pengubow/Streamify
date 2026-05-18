import Foundation

// MARK: - TMDB API Service (v3)
// Provides popular movies, popular TV series, genres, and search using TMDB API v3.

enum TMDBService {
    
    // MARK: - API Configuration
    
    private static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p"
    
    /// Get the stored TMDB API key from UserDefaults
    static var apiKey: String {
        UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    /// Check if TMDB is configured (API key is set)
    static var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    // MARK: - Response Models
    
    struct TMDBMovieListResponse: Codable {
        let page: Int
        let results: [TMDBMovie]
        let totalPages: Int?
        let totalResults: Int?
        
        enum CodingKeys: String, CodingKey {
            case page, results
            case totalPages = "total_pages"
            case totalResults = "total_results"
        }
    }
    
    struct TMDBTVListResponse: Codable {
        let page: Int
        let results: [TMDBTVShow]
        let totalPages: Int?
        let totalResults: Int?
        
        enum CodingKeys: String, CodingKey {
            case page, results
            case totalPages = "total_pages"
            case totalResults = "total_results"
        }
    }
    
    struct TMDBMovie: Codable, Identifiable {
        let id: Int
        let title: String
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let releaseDate: String?
        let voteAverage: Double?
        
        enum CodingKeys: String, CodingKey {
            case id, title, overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case genreIds = "genre_ids"
            case releaseDate = "release_date"
            case voteAverage = "vote_average"
        }
        
    }
    
    struct TMDBTVShow: Codable, Identifiable {
        let id: Int
        let name: String
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let firstAirDate: String?
        let voteAverage: Double?
        
        enum CodingKeys: String, CodingKey {
            case id, name, overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case genreIds = "genre_ids"
            case firstAirDate = "first_air_date"
            case voteAverage = "vote_average"
        }
        
    }
    
    struct TMDBGenreListResponse: Codable {
        let genres: [TMDBGenre]
    }
    
    struct TMDBGenre: Codable, Identifiable {
        let id: Int
        let name: String
    }
    
    struct TMDBMultiSearchResponse: Codable {
        let page: Int
        let results: [TMDBSearchResult]
        let totalPages: Int?
        let totalResults: Int?
        
        enum CodingKeys: String, CodingKey {
            case page, results
            case totalPages = "total_pages"
            case totalResults = "total_results"
        }
    }
    
    struct TMDBSearchResult: Codable, Identifiable {
        let id: Int
        let mediaType: String?
        let title: String?     // For movies
        let name: String?      // For TV shows
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        
        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case mediaType = "media_type"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case genreIds = "genre_ids"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case voteAverage = "vote_average"
        }
        
        var displayTitle: String {
            title ?? name ?? "Unknown"
        }
        
        var isMovie: Bool {
            mediaType == "movie"
        }
        
    }
    
    // MARK: - TV Show Detail (for seasons/episodes)
    
    struct TMDBTVDetail: Codable {
        let id: Int
        let name: String
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genres: [TMDBGenre]?
        let numberOfSeasons: Int?
        let seasons: [TMDBSeason]?
        
        enum CodingKeys: String, CodingKey {
            case id, name, overview, genres, seasons
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case numberOfSeasons = "number_of_seasons"
        }
    }
    
    struct TMDBSeason: Codable, Identifiable {
        let id: Int
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
        let overview: String?
        let posterPath: String?
        
        enum CodingKeys: String, CodingKey {
            case id, name, overview
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
            case posterPath = "poster_path"
        }
    }
    
    struct TMDBSeasonDetail: Codable {
        let id: Int
        let seasonNumber: Int
        let episodes: [TMDBEpisode]?
        
        enum CodingKeys: String, CodingKey {
            case id, episodes
            case seasonNumber = "season_number"
        }
    }

    struct TMDBExternalIDs: Codable {
        let imdbId: String?

        enum CodingKeys: String, CodingKey {
            case imdbId = "imdb_id"
        }
    }
    
    struct TMDBEpisode: Codable, Identifiable {
        let id: Int
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let runtime: Int?
        
        enum CodingKeys: String, CodingKey {
            case id, name, overview, runtime
            case episodeNumber = "episode_number"
            case stillPath = "still_path"
        }
        
        var thumbnailURL: URL? {
            guard let path = stillPath else { return nil }
            return URL(string: "\(imageBaseURL)/w300\(path)")
        }
    }
    
    // MARK: - API Methods
    
    /// Fetch popular movies
    static func fetchPopularMovies(page: Int = 1) async -> [TMDBMovie] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/movie/popular?api_key=\(apiKey)&language=en-US&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBMovieListResponse.self, from: data)
            return response.results
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode popular movies: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch popular TV shows
    static func fetchPopularTVShows(page: Int = 1) async -> [TMDBTVShow] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/tv/popular?api_key=\(apiKey)&language=en-US&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBTVListResponse.self, from: data)
            return response.results
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode popular TV shows: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch weekly trending movies and TV shows.
    static func fetchTrendingWeek(page: Int = 1) async -> [TMDBSearchResult] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/trending/all/week?api_key=\(apiKey)&language=en-US&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBMultiSearchResponse.self, from: data)
            return response.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode weekly trending results: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch movie genres
    static func fetchMovieGenres() async -> [TMDBGenre] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/genre/movie/list?api_key=\(apiKey)&language=en-US"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBGenreListResponse.self, from: data)
            return response.genres
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode movie genres: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch TV genres
    static func fetchTVGenres() async -> [TMDBGenre] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/genre/tv/list?api_key=\(apiKey)&language=en-US"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBGenreListResponse.self, from: data)
            return response.genres
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode TV genres: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch movies by genre
    static func fetchMoviesByGenre(genreId: Int, page: Int = 1) async -> [TMDBMovie] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/discover/movie?api_key=\(apiKey)&language=en-US&sort_by=popularity.desc&with_genres=\(genreId)&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBMovieListResponse.self, from: data)
            return response.results
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode movies by genre: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch TV shows by genre
    static func fetchTVShowsByGenre(genreId: Int, page: Int = 1) async -> [TMDBTVShow] {
        guard isConfigured else { return [] }
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=en-US&sort_by=popularity.desc&with_genres=\(genreId)&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBTVListResponse.self, from: data)
            return response.results
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode TV by genre: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Multi-search (movies + TV shows)
    static func search(query: String, page: Int = 1) async -> [TMDBSearchResult] {
        guard isConfigured else { return [] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/search/multi?api_key=\(apiKey)&language=en-US&query=\(encoded)&page=\(page)"
        guard let data = await fetchData(from: urlString) else { return [] }
        do {
            let response = try JSONDecoder().decode(TMDBMultiSearchResponse.self, from: data)
            // Only return movies and TV shows (filter out people, etc.)
            return response.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode search results: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch TV show detail (includes seasons list)
    static func fetchTVShowDetail(tmdbId: Int) async -> TMDBTVDetail? {
        guard isConfigured else { return nil }
        let urlString = "\(baseURL)/tv/\(tmdbId)?api_key=\(apiKey)&language=en-US"
        guard let data = await fetchData(from: urlString) else { return nil }
        do {
            return try JSONDecoder().decode(TMDBTVDetail.self, from: data)
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode TV detail: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetch season detail (includes episodes)
    static func fetchSeasonDetail(tmdbId: Int, seasonNumber: Int) async -> TMDBSeasonDetail? {
        guard isConfigured else { return nil }
        let urlString = "\(baseURL)/tv/\(tmdbId)/season/\(seasonNumber)?api_key=\(apiKey)&language=en-US"
        guard let data = await fetchData(from: urlString) else { return nil }
        do {
            return try JSONDecoder().decode(TMDBSeasonDetail.self, from: data)
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode season detail: \(error.localizedDescription)")
            return nil
        }
    }

    static func normalizedSeasonTitle(for season: TMDBSeason, showTitle: String, allSeasons: [TMDBSeason]) -> String? {
        guard let rawTitle = season.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
            return nil
        }

        let genericTitle = "Season \(season.seasonNumber)"
        guard season.seasonNumber == 1,
              rawTitle.localizedCaseInsensitiveCompare(genericTitle) == .orderedSame else {
            return rawTitle
        }

        let hasShowNamedFollowup = allSeasons.contains { other in
            guard other.seasonNumber > 1,
                  let otherTitle = other.name?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return otherTitle.localizedCaseInsensitiveCompare("Season \(other.seasonNumber)") != .orderedSame &&
                otherTitle.localizedCaseInsensitiveContains(showTitle)
        }

        return hasShowNamedFollowup ? showTitle : rawTitle
    }

    /// Fetch IMDb ID for a TMDB movie/series, used by Stremio-compatible stream providers.
    static func fetchIMDBId(tmdbId: Int, type: ContentType) async -> String? {
        guard isConfigured else { return nil }
        let path = type == .series ? "tv" : "movie"
        let urlString = "\(baseURL)/\(path)/\(tmdbId)/external_ids?api_key=\(apiKey)"
        guard let data = await fetchData(from: urlString) else { return nil }
        do {
            let response = try JSONDecoder().decode(TMDBExternalIDs.self, from: data)
            let imdbId = response.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let imdbId, !imdbId.isEmpty else { return nil }
            return imdbId
        } catch {
            StreamifyLogger.log("TMDB: Failed to decode external IDs: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Conversion to App Models

    /// Shared builder: converts raw TMDB fields into a `SourceContent`.
    private static func makeSourceContent(
        id: String,
        title: String,
        description: String,
        type: ContentType,
        genreIds: [Int]?,
        allGenres: [TMDBGenre],
        backdropPath: String?,
        posterPath: String?,
        tmdbId: Int
    ) -> SourceContent {
        let genres = mapGenres(ids: genreIds, allGenres: allGenres)
        return SourceContent(
            id: id,
            title: title,
            description: description,
            type: type,
            genres: genres.isEmpty ? nil : genres,
            thumbnailUrl: backdropPath.map { "\(imageBaseURL)/w780\($0)" },
            posterThumbnailUrl: posterPath.map { "\(imageBaseURL)/w342\($0)" },
            fileUrl: nil,
            hlsUrl: nil,
            intro: nil,
            introDuration: nil,
            end: nil,
            seasons: nil,
            episodes: nil,
            subtitles: nil,
            audioTracks: nil,
            embeddedAudioDisabled: false,
            tmdbId: tmdbId
        )
    }

    /// Convert a TMDB movie to SourceContent for use in the app
    static func toSourceContent(_ movie: TMDBMovie, movieGenres: [TMDBGenre] = []) -> SourceContent {
        makeSourceContent(
            id: "tmdb_movie_\(movie.id)",
            title: movie.title,
            description: movie.overview ?? "",
            type: .movie,
            genreIds: movie.genreIds,
            allGenres: movieGenres,
            backdropPath: movie.backdropPath,
            posterPath: movie.posterPath,
            tmdbId: movie.id
        )
    }
    
    /// Convert a TMDB TV show to SourceContent for use in the app
    static func toSourceContent(_ show: TMDBTVShow, tvGenres: [TMDBGenre] = []) -> SourceContent {
        makeSourceContent(
            id: "tmdb_tv_\(show.id)",
            title: show.name,
            description: show.overview ?? "",
            type: .series,
            genreIds: show.genreIds,
            allGenres: tvGenres,
            backdropPath: show.backdropPath,
            posterPath: show.posterPath,
            tmdbId: show.id
        )
    }
    
    /// Convert a TMDB search result to SourceContent
    static func toSourceContent(_ result: TMDBSearchResult, movieGenres: [TMDBGenre] = [], tvGenres: [TMDBGenre] = []) -> SourceContent {
        let isMovie = result.isMovie
        return makeSourceContent(
            id: "\(isMovie ? "tmdb_movie_" : "tmdb_tv_")\(result.id)",
            title: result.displayTitle,
            description: result.overview ?? "",
            type: isMovie ? .movie : .series,
            genreIds: result.genreIds,
            allGenres: isMovie ? movieGenres : tvGenres,
            backdropPath: result.backdropPath,
            posterPath: result.posterPath,
            tmdbId: result.id
        )
    }
    
    // MARK: - Helpers
    
    /// Map TMDB genre IDs to app Genre enum values
    private static func mapGenres(ids: [Int]?, allGenres: [TMDBGenre]) -> [Genre] {
        guard let ids = ids else { return [] }
        let genreMap: [String: Genre] = [
            "Action": .action, "Action & Adventure": .action,
            "Comedy": .comedy,
            "Drama": .drama,
            "Science Fiction": .sciFi, "Sci-Fi & Fantasy": .sciFi,
            "Horror": .horror,
            "Thriller": .thriller,
            "Romance": .romance,
            "Animation": .animation,
            "Documentary": .documentary,
        ]
        var result: [Genre] = []
        for id in ids {
            if let tmdbGenre = allGenres.first(where: { $0.id == id }),
               let genre = genreMap[tmdbGenre.name] {
                if !result.contains(genre) {
                    result.append(genre)
                }
            }
        }
        return result
    }
    
    /// Fetch raw data from a URL
    private static func fetchData(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                // Log the path and status code without the api_key query parameter.
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                StreamifyLogger.log("TMDB: HTTP \(statusCode) for \(url.path)")
                return nil
            }
            return data
        } catch {
            StreamifyLogger.log("TMDB: Network error: \(error.localizedDescription)")
            return nil
        }
    }
}
