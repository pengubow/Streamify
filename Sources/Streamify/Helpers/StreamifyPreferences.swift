import Foundation

enum StreamifyPreferences {
    static var selectableGenres: [Genre] {
        Genre.allCases
            .filter { $0 != .other }
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func languages(from rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func rawValue(forLanguages languages: Set<String>) -> String {
        languages.sorted().joined(separator: ",")
    }

    static func genres(from rawValue: String) -> Set<Genre> {
        Set(
            rawValue
                .split(separator: ",")
                .compactMap { Genre(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { $0 != .other }
        )
    }

    static func rawValue(forGenres genres: Set<Genre>) -> String {
        genres
            .filter { $0 != .other }
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: ",")
    }
}
