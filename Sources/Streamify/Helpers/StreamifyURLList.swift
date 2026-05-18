import Foundation

enum StreamifyURLList {
    static func combining(primary: URL?, fallbacks: [URL]) -> [URL] {
        var urls: [URL] = []
        if let primary {
            urls.append(primary)
        }
        for fallback in fallbacks where !urls.contains(fallback) {
            urls.append(fallback)
        }
        return urls
    }
}
