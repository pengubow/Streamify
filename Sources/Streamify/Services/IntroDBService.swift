import Foundation

enum IntroDBService {
    struct IntroTiming: Sendable, Equatable {
        let start: Double
        let end: Double

        var duration: Double { end - start }
    }

    struct EpisodeTiming: Sendable, Equatable {
        let intro: IntroTiming?
        let outroStart: Double?
    }

    private struct SegmentResponse: Decodable {
        let intro: Segment?
        let outro: Segment?
    }

    private struct Segment: Decodable {
        let startSec: Double?
        let endSec: Double?
        let startMs: Double?
        let endMs: Double?

        enum CodingKeys: String, CodingKey {
            case startSec = "start_sec"
            case endSec = "end_sec"
            case startMs = "start_ms"
            case endMs = "end_ms"
        }

        var start: Double? {
            let value: Double?
            if let startMs {
                value = startMs / 1_000
            } else {
                value = startSec
            }
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }

        var timing: IntroTiming? {
            guard let start else { return nil }
            let end: Double
            if let endMs {
                end = endMs / 1_000
            } else if let endSec {
                end = endSec
            } else {
                return nil
            }

            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return IntroTiming(start: start, end: end)
        }
    }

    private enum CacheEntry: Sendable {
        case found(EpisodeTiming)
        case missing
    }

    private actor Cache {
        private var imdbIds: [Int: String] = [:]
        private var intros: [String: CacheEntry] = [:]

        func imdbId(for tmdbId: Int) -> String? {
            imdbIds[tmdbId]
        }

        func store(imdbId: String, for tmdbId: Int) {
            imdbIds[tmdbId] = imdbId
        }

        func intro(for key: String) -> CacheEntry? {
            intros[key]
        }

        func store(_ entry: CacheEntry, for key: String) {
            intros[key] = entry
        }
    }

    private static let cache = Cache()

    static func fetchEpisodeTiming(tmdbId: Int, season: Int, episode: Int) async -> EpisodeTiming? {
        guard season >= 0, episode > 0 else { return nil }
        let key = "\(tmdbId):\(season):\(episode)"
        if let cached = await cache.intro(for: key) {
            switch cached {
            case .found(let timing): return timing
            case .missing: return nil
            }
        }

        let imdbId: String
        if let cached = await cache.imdbId(for: tmdbId) {
            imdbId = cached
        } else {
            guard let resolved = await TMDBService.fetchIMDBId(tmdbId: tmdbId, type: .series),
                  resolved.hasPrefix("tt") else {
                return nil
            }
            imdbId = resolved
            await cache.store(imdbId: resolved, for: tmdbId)
        }

        var components = URLComponents(string: "https://api.introdb.app/segments")
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Streamify/1.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 {
                await cache.store(.missing, for: key)
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                StreamifyLogger.log("IntroDB: HTTP \(http.statusCode) for \(imdbId) S\(season)E\(episode)")
                return nil
            }

            let segmentResponse = try JSONDecoder().decode(SegmentResponse.self, from: data)
            let timing = EpisodeTiming(
                intro: segmentResponse.intro?.timing,
                outroStart: segmentResponse.outro?.start
            )
            guard timing.intro != nil || timing.outroStart != nil else {
                await cache.store(.missing, for: key)
                return nil
            }
            await cache.store(.found(timing), for: key)
            let introLog = timing.intro.map {
                "intro=\($0.start)s+\($0.duration)s"
            } ?? "intro=none"
            let outroLog = timing.outroStart.map { "outro=\($0)s" } ?? "outro=none"
            StreamifyLogger.log("IntroDB: \(imdbId) S\(season)E\(episode) \(introLog) \(outroLog)")
            return timing
        } catch {
            guard !Task.isCancelled else { return nil }
            StreamifyLogger.log("IntroDB: Request failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func fetchIntro(tmdbId: Int, season: Int, episode: Int) async -> IntroTiming? {
        await fetchEpisodeTiming(tmdbId: tmdbId, season: season, episode: episode)?.intro
    }

    static func enriching(_ episode: EpisodeInfo, tmdbId: Int?) async -> EpisodeInfo {
        let needsIntro = episode.intro == nil || episode.introDuration == nil
        let needsOutro = episode.end == nil
        guard needsIntro || needsOutro,
              let tmdbId,
              let timing = await fetchEpisodeTiming(
                tmdbId: tmdbId,
                season: episode.season,
                episode: episode.episode
              ) else {
            return episode
        }

        let resolvedIntro = episode.intro ?? timing.intro?.start
        let resolvedIntroDuration = episode.introDuration ?? timing.intro?.duration
        let resolvedEnd = episode.end ?? timing.outroStart
        return episode.copying(
            intro: .some(resolvedIntro),
            introDuration: .some(resolvedIntroDuration),
            end: .some(resolvedEnd)
        )
    }
}
