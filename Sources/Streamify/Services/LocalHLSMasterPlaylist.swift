import CoreGraphics
import Foundation

enum LocalHLSMasterPlaylist {
    struct TranscodedAudioRendition {
        let uri: String?
        let languageId: String
        let displayName: String
        let codec: String
        let channels: Int
        let isDefault: Bool
    }

    struct TranscodedSubtitleRendition {
        let uri: String
        let languageId: String
        let displayName: String
        let isDefault: Bool
    }

    struct TranscodedVariant {
        let uri: String
        let videoCodec: String
        let audioCodec: String
        let audioChannels: Int
        let resolution: CGSize
        let frameRate: Double
        let bandwidth: Int
        let isHDR: Bool
    }

    private struct StreamEntry {
        var infoLine: String
        var uri: String
    }

    private struct MediaSummary {
        var lines: [String]
        var audioCodecs: [String]
        var maxAudioBandwidth: Double
        var hasAudio: Bool {
            lines.contains { LocalHLSMasterPlaylist.attributeValue("TYPE", inLine: $0) == "AUDIO" }
        }
        var hasSubtitles: Bool {
            lines.contains { LocalHLSMasterPlaylist.attributeValue("TYPE", inLine: $0) == "SUBTITLES" }
        }
    }

    static func refresh(metadataFolder: String, episode: EpisodeInfo? = nil) {
        let destDir = masterDirectory(
            metadataFolder: metadataFolder,
            season: episode?.season,
            episode: episode?.episode
        )
        let masterPath = destDir.appendingPathComponent("master.m3u8")
        let existingMaster = (try? String(contentsOf: masterPath, encoding: .utf8)) ?? ""
        guard existingMaster.isEmpty || existingMaster.contains("#EXTM3U") else { return }

        let mediaSummary = mediaSummaryFromMetadata(
            metadataFolder: metadataFolder,
            season: episode?.season,
            episode: episode?.episode,
            destDir: destDir
        )
        let streamEntries = streamEntriesFromMetadata(
            metadataFolder: metadataFolder,
            season: episode?.season,
            episode: episode?.episode,
            destDir: destDir,
            existingMaster: existingMaster,
            mediaSummary: mediaSummary
        )

        guard !streamEntries.isEmpty else {
            try? FileManager.default.removeItem(at: masterPath)
            StreamifyLogger.log("Removed local master m3u8 with no local entries: \(masterPath.path)")
            return
        }

        writeMasterPlaylist(
            to: masterPath,
            version: max(hlsVersion(from: existingMaster), 7),
            mediaSummary: mediaSummary,
            streamEntries: streamEntries,
            destDir: destDir
        )
    }

    static func removeRootMaster(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("master.m3u8"))
    }

    static func writeTranscodedMaster(
        to masterPath: URL,
        variant: TranscodedVariant,
        audioRenditions: [TranscodedAudioRendition],
        subtitleRenditions: [TranscodedSubtitleRendition]
    ) {
        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:7", ""]

        for rendition in audioRenditions {
            let channels = rendition.channels > 0 ? ",CHANNELS=\"\(rendition.channels)\"" : ""
            let codecTag = hlsAudioCodecTag(codec: rendition.codec, channels: rendition.channels)
            let codecAttr = codecTag.isEmpty ? "" : ",CODECS=\"\(hlsEscaped(codecTag))\""
            var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",LANGUAGE=\"\(hlsEscaped(rendition.languageId))\",NAME=\"\(hlsEscaped(rendition.displayName))\",DEFAULT=\(rendition.isDefault ? "YES" : "NO"),AUTOSELECT=YES\(channels)\(codecAttr)"
            if let uri = rendition.uri, !uri.isEmpty {
                line += ",URI=\"\(hlsEscaped(uri))\""
            }
            lines.append(line)
        }
        if !audioRenditions.isEmpty { lines.append("") }

        for rendition in subtitleRenditions {
            lines.append(
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subtitles\",LANGUAGE=\"\(hlsEscaped(rendition.languageId))\",NAME=\"\(hlsEscaped(rendition.displayName))\",DEFAULT=\(rendition.isDefault ? "YES" : "NO"),AUTOSELECT=YES,FORCED=NO,URI=\"\(hlsEscaped(rendition.uri))\""
            )
        }
        if !subtitleRenditions.isEmpty { lines.append("") }

        let videoCodecTag = hlsVideoCodecTag(codec: variant.videoCodec)
        let audioCodecTag = hlsAudioCodecTag(codec: variant.audioCodec, channels: variant.audioChannels)
        let codecs = [videoCodecTag, audioCodecTag].filter { !$0.isEmpty }.joined(separator: ",")
        let streamName = streamName(resolution: variant.resolution, isHDR: variant.isHDR)

        var attributes: [String] = []
        if !streamName.isEmpty {
            attributes.append(#"NAME="\#(hlsEscaped(streamName))""#)
        }
        attributes.append("BANDWIDTH=\(variant.bandwidth > 0 ? variant.bandwidth : 8_000_000)")
        if variant.resolution.width > 0, variant.resolution.height > 0 {
            attributes.append("RESOLUTION=\(Int(variant.resolution.width))x\(Int(variant.resolution.height))")
        }
        if variant.frameRate > 0 {
            attributes.append(String(format: "FRAME-RATE=%.3f", variant.frameRate))
        }
        if !codecs.isEmpty {
            attributes.append(#"CODECS="\#(hlsEscaped(codecs))""#)
        }
        if variant.isHDR {
            attributes.append("VIDEO-RANGE=PQ")
        }
        if !audioRenditions.isEmpty {
            attributes.append(#"AUDIO="audio""#)
        }
        if !subtitleRenditions.isEmpty {
            attributes.append(#"SUBTITLES="subtitles""#)
        }

        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(variant.uri)

        let content = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: masterPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: masterPath, atomically: true, encoding: .utf8)
    }

    static func writeAfterVideoDownload(
        sourceMaster: String,
        selectedVariantURI: String,
        selectedLocalVariantURI: String,
        selectedBandwidth: Double,
        selectedResolution: String?,
        selectedVideoRange: String?,
        destDir: URL,
        metadataFolder: String,
        season: Int?,
        episode: Int?,
        qualityName: String?
    ) {
        let masterPath = destDir.appendingPathComponent("master.m3u8")
        let existingMaster = try? String(contentsOf: masterPath, encoding: .utf8)
        let mediaSummary = mediaSummaryFromMetadata(
            metadataFolder: metadataFolder,
            season: season,
            episode: episode,
            destDir: destDir
        )

        let sourceInfoLine = streamInfoLine(
            in: sourceMaster,
            matchingVariantURI: selectedVariantURI,
            bandwidth: selectedBandwidth
        ) ?? fallbackStreamInfoLine(
            name: qualityName,
            bandwidth: selectedBandwidth,
            resolution: selectedResolution,
            videoRange: selectedVideoRange
        )

        let selectedEntry = StreamEntry(
            infoLine: sourceInfoLine,
            uri: selectedLocalVariantURI
        )

        var streamEntries = streamEntriesFromMetadata(
            metadataFolder: metadataFolder,
            season: season,
            episode: episode,
            destDir: destDir,
            existingMaster: existingMaster,
            mediaSummary: mediaSummary
        )
        streamEntries = sortStreamEntries(
            upsertStreamEntry(selectedEntry, into: streamEntries),
            destDir: destDir,
            mediaSummary: mediaSummary
        )

        let existingVersion = existingMaster.map { hlsVersion(from: $0) } ?? 0
        let version = max(max(hlsVersion(from: sourceMaster), existingVersion), 7)
        writeMasterPlaylist(
            to: masterPath,
            version: version,
            mediaSummary: mediaSummary,
            streamEntries: streamEntries,
            destDir: destDir
        )
        StreamifyLogger.log("Saved local master m3u8 to: \(masterPath.path)")
    }

    private static func writeMasterPlaylist(
        to masterPath: URL,
        version: Int,
        mediaSummary: MediaSummary,
        streamEntries: [StreamEntry],
        destDir: URL
    ) {
        var content = "#EXTM3U\n"
        content += "#EXT-X-VERSION:\(max(version, 6))\n\n"

        if !mediaSummary.lines.isEmpty {
            content += mediaSummary.lines.joined(separator: "\n")
            content += "\n\n"
        }

        for entry in streamEntries {
            let infoLine = normalizeStreamInfoLine(
                entry.infoLine,
                uri: entry.uri,
                mediaSummary: mediaSummary,
                destDir: destDir
            )
            content += "\(infoLine)\n"
            content += "\(entry.uri)\n"
        }

        try? FileManager.default.createDirectory(at: masterPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: masterPath, atomically: true, encoding: .utf8)
    }

    private static func mediaSummaryFromMetadata(
        metadataFolder: String,
        season: Int?,
        episode: Int?,
        destDir: URL
    ) -> MediaSummary {
        guard let metadata = ContentImportService.loadMetadata(from: metadataFolder) else {
            return MediaSummary(lines: [], audioCodecs: [], maxAudioBandwidth: 0)
        }

        let audioTracks: [AudioTrack]
        let subtitleTracks: [SubtitleTrack]
        if let ep = findEpisode(in: metadata, season: season, episode: episode) {
            audioTracks = ep.audioTracks ?? []
            subtitleTracks = ep.subtitles ?? []
        } else {
            audioTracks = metadata.audioTracks ?? []
            subtitleTracks = metadata.subtitles ?? []
        }

        let localAudio = audioTracks
            .filter { $0.isEmbedded || $0.source.isEmpty || isLocalRelativeMediaSource($0.source) }
        let localSubtitles = subtitleTracks
            .filter { isLocalRelativeMediaSource($0.source) }

        var lines: [String] = []
        var audioCodecs: [String] = []
        var maxAudioBandwidth = 0.0

        for (index, track) in localAudio.enumerated() {
            let summary = audioTrackSummary(for: track, destDir: destDir)
            if let codec = summary.codec, !audioCodecs.contains(codec) {
                audioCodecs.append(codec)
            }
            maxAudioBandwidth = max(maxAudioBandwidth, summary.bandwidth ?? 0)
            lines.append(audioMediaLine(for: track, isDefault: index == 0, summary: summary))
        }
        for track in localSubtitles {
            lines.append(subtitleMediaLine(for: track))
        }

        return MediaSummary(lines: lines, audioCodecs: audioCodecs, maxAudioBandwidth: maxAudioBandwidth)
    }

    private static func streamEntriesFromMetadata(
        metadataFolder: String,
        season: Int?,
        episode: Int?,
        destDir: URL,
        existingMaster: String?,
        mediaSummary: MediaSummary
    ) -> [StreamEntry] {
        guard let metadata = ContentImportService.loadMetadata(from: metadataFolder) else { return [] }
        let existingEntries = existingMaster.map { streamEntries(from: $0) } ?? []
        var existingByURI: [String: String] = [:]
        for entry in existingEntries {
            existingByURI[entry.uri] = entry.infoLine
        }

        let episodeMetadata = findEpisode(in: metadata, season: season, episode: episode)
        let qualities = episodeMetadata?.downloadedVideoQualities ?? metadata.downloadedVideoQualities ?? []
        let qualitiesByURI = Dictionary(
            qualities.compactMap { quality -> (String, DownloadedVideoQuality)? in
                guard let uri = localHLSURI(quality.localSource) else { return nil }
                return (uri, quality)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.bandwidth >= rhs.bandwidth ? lhs : rhs
            }
        )

        var entries: [StreamEntry] = []
        var seenURIs = Set<String>()

        func appendEntry(uri: String, infoLine: String) {
            guard seenURIs.insert(uri).inserted else { return }
            let localPath = destDir.appendingPathComponent(uri)
            guard FileManager.default.fileExists(atPath: localPath.path),
                  uri.hasSuffix(".m3u8") else { return }
            entries.append(StreamEntry(infoLine: infoLine, uri: uri))
        }

        let mainHLSCandidates: [(String?, String?)] = {
            if let episodeMetadata {
                return [
                    (episodeMetadata.localFile, episodeMetadata.qualityName),
                    (episodeMetadata.hlsUrl, episodeMetadata.qualityName)
                ]
            }
            return [
                (metadata.hlsUrl, metadata.downloadedQuality),
                (metadata.file, metadata.downloadedQuality)
            ]
        }()

        for (candidate, qualityName) in mainHLSCandidates {
            guard let uri = localHLSURI(candidate) else { continue }
            let infoLine: String
            if let quality = qualitiesByURI[uri] {
                infoLine = streamInfoLine(
                    for: quality,
                    existingInfoLine: existingByURI[uri],
                    destDir: destDir
                )
            } else {
                infoLine = existingByURI[uri]
                    ?? fallbackStreamInfoLine(name: qualityName, bandwidth: 0, resolution: nil, videoRange: nil)
            }
            appendEntry(uri: uri, infoLine: infoLine)
        }

        for quality in qualities {
            guard localHLSURI(quality.localSource) != nil else { continue }
            let infoLine = streamInfoLine(
                for: quality,
                existingInfoLine: existingByURI[quality.localSource],
                destDir: destDir
            )
            appendEntry(uri: quality.localSource, infoLine: infoLine)
        }

        return sortStreamEntries(entries, destDir: destDir, mediaSummary: mediaSummary)
    }

    private static func streamInfoLine(for quality: DownloadedVideoQuality, existingInfoLine: String?, destDir: URL) -> String {
        let fallback = fallbackStreamInfoLine(
            name: quality.name,
            bandwidth: quality.bandwidth,
            resolution: quality.resolution,
            videoRange: quality.isHDR ? "PQ" : nil
        )

        var infoLine = existingInfoLine
            ?? streamInfoLineFromSiblingMaster(forLocalSource: quality.localSource, destDir: destDir)
            ?? fallback

        if quality.isHDR {
            if attributeValue("VIDEO-RANGE", inLine: infoLine) == nil {
                infoLine = setBareAttribute("VIDEO-RANGE", value: "PQ", in: infoLine)
            }
        } else {
            infoLine = removeAttribute("VIDEO-RANGE", from: infoLine)
        }
        if attributeValue("NAME", inLine: infoLine) == nil, !quality.name.isEmpty {
            infoLine = setQuotedAttribute("NAME", value: quality.name, in: infoLine)
        }
        if attributeValue("RESOLUTION", inLine: infoLine) == nil,
           let resolution = quality.resolution,
           !resolution.isEmpty {
            infoLine = setBareAttribute("RESOLUTION", value: resolution, in: infoLine)
        }
        if (Double(attributeValue("BANDWIDTH", inLine: infoLine) ?? "") ?? 0) <= 0,
           quality.bandwidth > 0 {
            infoLine = setBareAttribute("BANDWIDTH", value: "\(Int(quality.bandwidth))", in: infoLine)
        }

        return infoLine
    }

    private static func streamInfoLineFromSiblingMaster(forLocalSource localSource: String, destDir: URL) -> String? {
        let localURL = destDir.appendingPathComponent(localSource)
        let candidateMaster = localURL.deletingLastPathComponent().appendingPathComponent("master.m3u8")
        guard FileManager.default.fileExists(atPath: candidateMaster.path),
              let master = try? String(contentsOf: candidateMaster, encoding: .utf8) else {
            return nil
        }
        let localName = localURL.lastPathComponent
        return HLSManifestParser.parseStreamVariants(from: master)
            .first { $0.uri == localName || $0.uri == localSource }?
            .streamInfoLine
    }

    private static func audioTrackSummary(for track: AudioTrack, destDir: URL) -> (codec: String?, channels: String?, bandwidth: Double?) {
        if track.source.isEmpty {
            return (codecTag(for: track), channelCountTag(for: track), track.bandwidth)
        }

        let playlistURL = destDir.appendingPathComponent(track.source)
        let bandwidth = estimatedBandwidth(forPlaylistAt: playlistURL)
        return (
            codecTag(for: track),
            channelCountTag(for: track),
            bandwidth > 0 ? bandwidth : track.bandwidth
        )
    }

    private static func audioMediaLine(
        for track: AudioTrack,
        isDefault: Bool,
        summary: (codec: String?, channels: String?, bandwidth: Double?)
    ) -> String {
        var attributes = [
            #"TYPE=AUDIO"#,
            #"GROUP-ID="audio""#,
            #"LANGUAGE="\#(hlsEscaped(track.languageId))""#,
            #"NAME="\#(hlsEscaped(track.displayName))""#,
            "DEFAULT=\(isDefault ? "YES" : "NO")",
            #"AUTOSELECT=YES"#
        ]
        if !track.source.isEmpty {
            attributes.append(#"URI="\#(hlsEscaped(track.source))""#)
        }
        if let channels = summary.channels {
            attributes.append(#"CHANNELS="\#(channels)""#)
        }
        if let codec = summary.codec {
            attributes.append(#"CODECS="\#(hlsEscaped(codec))""#)
        }
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    private static func subtitleMediaLine(for track: SubtitleTrack) -> String {
        let isForced = track.displayName.localizedCaseInsensitiveContains("forced")
        let attributes = [
            #"TYPE=SUBTITLES"#,
            #"GROUP-ID="subtitles""#,
            #"LANGUAGE="\#(hlsEscaped(track.languageId))""#,
            #"NAME="\#(hlsEscaped(track.displayName))""#,
            #"DEFAULT=NO"#,
            #"AUTOSELECT=YES"#,
            "FORCED=\(isForced ? "YES" : "NO")",
            #"URI="\#(hlsEscaped(track.source))""#
        ]
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    private static func normalizeStreamInfoLine(
        _ line: String,
        uri: String,
        mediaSummary: MediaSummary,
        destDir: URL
    ) -> String {
        var normalized = line
        if mediaSummary.hasAudio {
            normalized = setQuotedAttribute("AUDIO", value: "audio", in: normalized)
        }
        if mediaSummary.hasSubtitles {
            normalized = setQuotedAttribute("SUBTITLES", value: "subtitles", in: normalized)
        }

        let playlistBandwidth = estimatedBandwidth(forPlaylistAt: destDir.appendingPathComponent(uri))
        let baseBandwidth = playlistBandwidth > 0
            ? playlistBandwidth
            : Double(attributeValue("BANDWIDTH", inLine: normalized) ?? "") ?? 0
        let isAudioOnlyEntry = mediaSummary.lines.contains {
            attributeValue("TYPE", inLine: $0) == "AUDIO" && attributeValue("URI", inLine: $0) == uri
        }
        let totalBandwidth = baseBandwidth + (isAudioOnlyEntry ? 0 : mediaSummary.maxAudioBandwidth)
        if totalBandwidth > 0 {
            normalized = setBareAttribute("BANDWIDTH", value: "\(Int(ceil(totalBandwidth)))", in: normalized)
        }

        let mergedCodecs = mergedCodecs(
            existing: attributeValue("CODECS", inLine: normalized),
            adding: mediaSummary.audioCodecs
        )
        if !mergedCodecs.isEmpty {
            normalized = setQuotedAttribute("CODECS", value: mergedCodecs.joined(separator: ","), in: normalized)
        }

        return normalized
    }

    private static func estimatedBandwidth(forPlaylistAt playlistURL: URL) -> Double {
        guard FileManager.default.fileExists(atPath: playlistURL.path),
              let content = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return 0
        }
        let playlist = HLSManifestParser.parseMediaPlaylist(from: content)
        let playlistDir = playlistURL.deletingLastPathComponent()
        var maxBitsPerSecond = 0.0

        for segment in playlist.segments {
            guard segment.duration > 0 else { continue }
            let segmentURL = resolveLocalURI(segment.uri, relativeTo: playlistDir)
            guard segmentURL.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: segmentURL.path),
                  let size = attributes[.size] as? NSNumber else {
                continue
            }
            let bitsPerSecond = size.doubleValue * 8 / segment.duration
            maxBitsPerSecond = max(maxBitsPerSecond, bitsPerSecond)
        }

        return maxBitsPerSecond
    }

    private static func resolveLocalURI(_ uri: String, relativeTo directory: URL) -> URL {
        if let absolute = URL(string: uri), absolute.scheme != nil {
            return absolute
        }
        return directory.appendingPathComponent(uri)
    }

    private static func codecTag(for track: AudioTrack) -> String? {
        let text = [track.source, track.name, track.language, track.sourceName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if text.contains("eac3") || text.contains("e-ac-3") || text.contains("ec-3") {
            return "ec-3"
        }
        if text.contains("ac3") || text.contains("ac-3") {
            return "ac-3"
        }
        if text.contains("mp3") {
            return "mp4a.40.34"
        }
        if text.contains("aac") ||
            text.contains("truehd") ||
            text.contains("dts") ||
            text.contains("flac") ||
            text.contains("alac") ||
            text.contains("pcm") {
            return "mp4a.40.2"
        }
        return track.isSpatial ? "ec-3" : "mp4a.40.2"
    }

    private static func channelCountTag(for track: AudioTrack) -> String? {
        let text = [track.name, track.language]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if text.contains("7.1") { return "8" }
        if text.contains("5.1") { return "6" }
        if text.contains("2.0") || text.contains("stereo") { return "2" }
        return track.isSpatial ? "6" : nil
    }

    private static func hlsVideoCodecTag(codec: String) -> String {
        let c = codec.lowercased()
        if c.contains("hevc") || c.contains("h265") { return "hvc1.1.6.L150.90" }
        if c.contains("h264") || c.contains("avc") { return "avc1.640028" }
        return "hvc1.1.6.L150.90"
    }

    private static func hlsAudioCodecTag(codec: String, channels: Int) -> String {
        let c = codec.lowercased()
        if c.contains("eac3") || c.contains("e-ac-3") || c.contains("ec-3") { return "ec-3" }
        if c.contains("ac3") || c.contains("ac-3") { return "ac-3" }
        if c.contains("mp3") { return "mp4a.40.34" }
        return "mp4a.40.2"
    }

    private static func streamName(resolution: CGSize, isHDR: Bool) -> String {
        let height = Int(resolution.height)
        guard height > 0 else { return "" }
        let label: String
        switch height {
        case 2160...: label = "2160p"
        case 1440...: label = "1440p"
        case 1080...: label = "1080p"
        case 720...: label = "720p"
        case 480...: label = "480p"
        default: label = "\(height)p"
        }
        return isHDR ? "\(label)-hdr" : label
    }

    private static func mergedCodecs(existing: String?, adding codecs: [String]) -> [String] {
        var result: [String] = []
        for codec in (existing ?? "").split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            if !codec.isEmpty && !result.contains(codec) {
                result.append(codec)
            }
        }
        for codec in codecs where !codec.isEmpty && !result.contains(codec) {
            result.append(codec)
        }
        return result
    }

    private static func streamEntries(from master: String) -> [StreamEntry] {
        let lines = master.components(separatedBy: "\n")
        var entries: [StreamEntry] = []
        var pendingInfoLine: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingInfoLine = trimmed
            } else if let infoLine = pendingInfoLine,
                      !trimmed.isEmpty,
                      !trimmed.hasPrefix("#") {
                if isLocalMasterURI(trimmed) {
                    entries.append(StreamEntry(infoLine: infoLine, uri: trimmed))
                }
                pendingInfoLine = nil
            }
        }

        return entries
    }

    private static func streamInfoLine(in master: String, matchingVariantURI variantURI: String, bandwidth: Double) -> String? {
        let variants = HLSManifestParser.parseStreamVariants(from: master)
        if let exactMatch = variants.first(where: { $0.uri == variantURI }) {
            return exactMatch.streamInfoLine
        }
        return variants.first { abs($0.bandwidth - bandwidth) < 0.5 }?.streamInfoLine
    }

    private static func fallbackStreamInfoLine(name: String?, bandwidth: Double, resolution: String?, videoRange: String?) -> String {
        var attributes: [String] = []
        if let name, !name.isEmpty {
            attributes.append(#"NAME="\#(hlsEscaped(name))""#)
        }
        attributes.append("BANDWIDTH=\(Int(bandwidth))")
        if let resolution, !resolution.isEmpty {
            attributes.append("RESOLUTION=\(resolution)")
        }
        if let videoRange, !videoRange.isEmpty {
            attributes.append("VIDEO-RANGE=\(videoRange)")
        }
        return "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",")
    }

    private static func upsertStreamEntry(_ entry: StreamEntry, into entries: [StreamEntry]) -> [StreamEntry] {
        var result = entries
        if let index = result.firstIndex(where: { $0.uri == entry.uri }) {
            result[index] = entry
        } else {
            result.append(entry)
        }
        return result
    }

    private static func sortStreamEntries(_ entries: [StreamEntry], destDir: URL, mediaSummary: MediaSummary) -> [StreamEntry] {
        entries.sorted {
            entryBandwidth($0, destDir: destDir, mediaSummary: mediaSummary) >
                entryBandwidth($1, destDir: destDir, mediaSummary: mediaSummary)
        }
    }

    private static func entryBandwidth(_ entry: StreamEntry, destDir: URL, mediaSummary: MediaSummary) -> Double {
        let playlistBandwidth = estimatedBandwidth(forPlaylistAt: destDir.appendingPathComponent(entry.uri))
        if playlistBandwidth > 0 {
            return playlistBandwidth + mediaSummary.maxAudioBandwidth
        }
        return Double(attributeValue("BANDWIDTH", inLine: entry.infoLine) ?? "") ?? 0
    }

    private static func localHLSURI(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              isLocalRelativeMediaSource(value),
              value.hasSuffix(".m3u8") else { return nil }
        return value
    }

    private static func isLocalRelativeMediaSource(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("/") { return false }
        if let url = URL(string: value), url.scheme != nil {
            return false
        }
        return true
    }

    private static func setQuotedAttribute(_ key: String, value: String, in line: String) -> String {
        let replacement = #"\#(key)="\#(hlsEscaped(value))""#
        if let range = line.range(of: "\(key)=(\"[^\"]*\"|[^,]*)", options: .regularExpression) {
            return line.replacingCharacters(in: range, with: replacement)
        }
        return line + ",\(replacement)"
    }

    private static func setBareAttribute(_ key: String, value: String, in line: String) -> String {
        let replacement = "\(key)=\(value)"
        if let range = line.range(of: "\(key)=(\"[^\"]*\"|[^,]*)", options: .regularExpression) {
            return line.replacingCharacters(in: range, with: replacement)
        }
        return line + ",\(replacement)"
    }

    private static func removeAttribute(_ key: String, from line: String) -> String {
        guard let range = line.range(of: ",?\(key)=(\"[^\"]*\"|[^,]*)", options: .regularExpression) else {
            return line
        }
        var result = line.replacingCharacters(in: range, with: "")
        result = result.replacingOccurrences(of: "#EXT-X-STREAM-INF:,", with: "#EXT-X-STREAM-INF:")
        return result
    }

    private static func attributeValue(_ key: String, inLine line: String) -> String? {
        HLSManifestParser.attribute(key, inLine: line)
    }

    private static func hlsVersion(from master: String) -> Int {
        for line in master.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-VERSION:") {
                return Int(trimmed.replacingOccurrences(of: "#EXT-X-VERSION:", with: "")) ?? 0
            }
        }
        return 0
    }

    private static func hlsEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isLocalMasterURI(_ uri: String) -> Bool {
        !uri.hasPrefix("http") && !uri.hasPrefix("/") && !uri.isEmpty
    }

    private static func masterDirectory(metadataFolder: String, season: Int?, episode: Int?) -> URL {
        var url = ContentImportService.contentDirectoryURL.appendingPathComponent(metadataFolder)
        if let season, let episode {
            url = url.appendingPathComponent(episodeSubfolder(season: season, episode: episode))
        }
        return url
    }

    private static func episodeSubfolder(season: Int, episode: Int) -> String {
        "season_\(season)_episode_\(episode)"
    }

    private static func findEpisode(in metadata: ContentMetadata, season: Int?, episode: Int?) -> EpisodeInfo? {
        guard let episode else { return nil }
        let resolvedSeason = season ?? 1
        return metadata.allEpisodes.first { $0.season == resolvedSeason && $0.episode == episode }
    }
}
