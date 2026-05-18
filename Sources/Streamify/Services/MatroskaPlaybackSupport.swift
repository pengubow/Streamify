import Foundation

enum MatroskaPlaybackSupport {
    private static let cacheFolderName = "StreamifyTranscodes"

    static func isMatroskaURL(_ url: URL) -> Bool {
        ["mkv", "webm"].contains(url.pathExtension.lowercased())
    }

    static func playbackURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL else { return fileURL }
        if let url = LocalServer.shared.urlForContentFile(fileURL) {
            return url
        }
        if let url = LocalServer.shared.urlForTransientFile(fileURL) {
            return url
        }
        return fileURL
    }

    static func localSource(for fileURL: URL, relativeTo directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    static func nativeSubtitleSidecarURL(for fileURL: URL, track: SubtitleTrack) -> URL? {
        guard fileURL.isFileURL else { return nil }
        let candidate = nativeSubtitleSidecarURLCandidate(for: fileURL, track: track)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func prepareNativeSubtitleSidecar(for fileURL: URL, track: SubtitleTrack, subtitleIndex: Int) async -> URL? {
        guard fileURL.isFileURL else { return nil }
        if let existing = nativeSubtitleSidecarURL(for: fileURL, track: track) {
            return existing
        }
        return await extractNativeSubtitleSidecar(for: fileURL, track: track, subtitleIndex: subtitleIndex)
    }

    static func removeGeneratedFiles(relatedTo url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let baseName = safeBaseName(for: url)

        if let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("subtitle_\(baseName)_") {
                try? fileManager.removeItem(at: entry)
            }
        }

        let subtitles = directory.appendingPathComponent("subtitles", isDirectory: true)
        if fileManager.fileExists(atPath: subtitles.path) {
            try? fileManager.removeItem(at: subtitles)
        }
    }

    static func cleanupTransientStreams() {
        try? FileManager.default.removeItem(at: transientRoot())
    }

    static func cleanupTransientCacheOnLaunch() {
        try? FileManager.default.removeItem(at: transientRoot())
    }

    private static func nativeSubtitleSidecarURLCandidate(for fileURL: URL, track: SubtitleTrack) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("subtitles", isDirectory: true)
            .appendingPathComponent("subtitle_\(safeBaseName(for: fileURL))_\(nativeTrackKey(for: track.trackId, defaultValue: "default"))")
            .appendingPathExtension("vtt")
    }

    private static func nativeTrackKey(for trackId: String, defaultValue: String) -> String {
        let rawId = trackId
            .replacingOccurrences(of: "mpv-subtitle-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = rawId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return value.isEmpty ? defaultValue : value
    }

    private static func extractNativeSubtitleSidecar(for fileURL: URL, track: SubtitleTrack, subtitleIndex: Int) async -> URL? {
        let outputURL = nativeSubtitleSidecarURLCandidate(for: fileURL, track: track)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        StreamifyLogger.log("MatroskaPlaybackSupport: Extracting native subtitle sidecar for \(fileURL.lastPathComponent) track=\(track.trackId)")
        let success = await MPVEncoder.extractSubtitle(
            from: fileURL,
            to: outputURL,
            subtitleIndex: subtitleIndex
        )
        guard success, FileManager.default.fileExists(atPath: outputURL.path) else {
            try? FileManager.default.removeItem(at: outputURL)
            StreamifyLogger.log("MatroskaPlaybackSupport: Native subtitle sidecar extraction failed for \(track.trackId)")
            return nil
        }
        return outputURL
    }

    private static func transientRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFolderName, isDirectory: true)
    }

    private static func safeBaseName(for url: URL) -> String {
        let decodedName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = decodedName.isEmpty ? UUID().uuidString : decodedName
        let withoutExtension = (name as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let cleaned = withoutExtension.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? UUID().uuidString : value
    }
}
