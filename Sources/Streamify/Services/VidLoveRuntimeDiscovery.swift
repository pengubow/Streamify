import Foundation

enum VidLoveRuntimeDiscovery {
    struct Server: Sendable {
        let name: String
        let movieTemplate: String
        let tvTemplate: String
    }

    static func configurationScripts(in bundle: String, relativeTo bundleURL: URL) -> [URL] {
        // Vite may move the source list into a lazy chunk with an opaque filename.
        // Follow module references instead of depending on the old serverConfigs name.
        let dynamicImports = captures(
            #"\bimport\s*\(\s*["']([^"']+\.js(?:\?[^"']*)?)["']\s*\)"#,
            in: bundle
        ).compactMap(\.first)
        let namedChunks = captures(
            #"["']([^"']*serverConfigs-[^"']+\.js)["']"#,
            in: bundle
        ).compactMap(\.first)
        let staticImports = captures(
            #"\bfrom\s*["']([^"']+\.js(?:\?[^"']*)?)["']"#,
            in: bundle
        ).compactMap(\.first)

        var seen: Set<URL> = [bundleURL]
        return (dynamicImports + namedChunks + staticImports).compactMap { reference in
            let base = reference.hasPrefix("assets/")
                ? URL(string: "/", relativeTo: bundleURL)!.absoluteURL
                : bundleURL
            guard let url = URL(string: reference, relativeTo: base)?.absoluteURL,
                  url.scheme == bundleURL.scheme,
                  url.host == bundleURL.host,
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func servers(in bundle: String) -> [Server] {
        if let base = captures(
            #"["'](https?://[^"']+)["']\.replace\(/\\/\+\$"#,
            in: bundle
        ).first?.first {
            let keyedServers = captures(
                #"\{\s*name:\s*["']([^"']+)["'],\s*key:\s*["']([^"']+)["']"#,
                in: bundle
            )
            if !keyedServers.isEmpty {
                return keyedServers.compactMap { match in
                    guard match.count == 2 else { return nil }
                    let key = match[1]
                    return Server(
                        name: match[0],
                        movieTemplate: "\(base)/movie?id=${id}&mode=json&sources=\(key)",
                        tvTemplate: "\(base)/tv?id=${id}&season=${season}&episode=${episode}&mode=json&sources=\(key)"
                    )
                }
            }
        }

        // Older bundles spell out API templates using a shared base variable.
        var variables: [String: String] = [:]
        for match in captures(
            #"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*["'](https?://[^"']+)["']"#,
            in: bundle
        ) where match.count == 2 {
            variables[match[0]] = match[1]
        }
        return captures(
            #"\{name:"([^"]+)",api:([A-Za-z_$][\w$]*)\+"([^"]+)",tvApi:\2\+"([^"]+)""#,
            in: bundle
        ).compactMap { match in
            guard match.count == 4, let base = variables[match[1]] else { return nil }
            return Server(name: match[0], movieTemplate: base + match[2], tvTemplate: base + match[3])
        }
    }

    static func nativePlaybackURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let source = components.queryItems?.first(where: { $0.name == "sources" })?.value,
              source == "moviebox" || source == "moviebox2" else { return url }
        // Match the current player's HEVC-capable MovieBox request. The native
        // engines decode HEVC directly and do not need the web service worker.
        var items = components.queryItems ?? []
        for name in ["hevc", "vh"] where !items.contains(where: { $0.name == name }) {
            items.append(URLQueryItem(name: name, value: "1"))
        }
        components.queryItems = items
        return components.url ?? url
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }
}
