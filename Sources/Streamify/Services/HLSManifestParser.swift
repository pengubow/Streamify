import Foundation

enum HLSManifestParser {
    struct StreamVariant {
        let bandwidth: Double
        let uri: String
        let resolution: String?
        let videoRange: String?
        let frameRate: String?
        let codecs: String?
        let audioGroup: String?
        let streamInfoLine: String
    }

    struct MediaSegment {
        let uri: String
        let duration: Double
    }

    struct MediaPlaylist {
        let segments: [MediaSegment]
        let initSegmentURI: String?
    }

    static func parseAttributes(_ attributes: String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        var currentKey = ""
        var currentValue = ""
        var inQuotes = false
        var i = attributes.startIndex

        while i < attributes.endIndex {
            let char = attributes[i]
            if char == "=" && !inQuotes {
                currentKey = currentValue.trimmingCharacters(in: .whitespaces)
                currentValue = ""
            } else if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                if !currentKey.isEmpty {
                    result.append((key: currentKey, value: currentValue.trimmingCharacters(in: .whitespaces)))
                }
                currentKey = ""
                currentValue = ""
            } else {
                currentValue.append(char)
            }
            i = attributes.index(after: i)
        }

        if !currentKey.isEmpty {
            result.append((key: currentKey, value: currentValue.trimmingCharacters(in: .whitespaces)))
        }

        return result
    }

    static func attribute(_ key: String, inAttributes attributes: String) -> String? {
        parseAttributes(attributes).first { $0.key == key }?.value
    }

    static func attribute(_ key: String, inLine line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return attribute(key, inAttributes: String(line[line.index(after: colon)...]))
    }

    static func parseStreamVariants(from content: String) -> [StreamVariant] {
        let lines = content.components(separatedBy: "\n")
        var variants: [StreamVariant] = []
        var pendingInfo: (bandwidth: Double, resolution: String?, videoRange: String?, frameRate: String?, codecs: String?, audioGroup: String?, line: String)?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = trimmed.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                let pairs = parseAttributes(attributes)
                var bandwidth: Double = 0
                var resolution: String?
                var videoRange: String?
                var frameRate: String?
                var codecs: String?
                var audioGroup: String?

                for (key, value) in pairs {
                    switch key {
                    case "BANDWIDTH":
                        bandwidth = Double(value) ?? 0
                    case "RESOLUTION":
                        resolution = value
                    case "VIDEO-RANGE":
                        videoRange = value
                    case "FRAME-RATE":
                        frameRate = value
                    case "CODECS":
                        codecs = value
                    case "AUDIO":
                        audioGroup = value
                    default:
                        break
                    }
                }

                pendingInfo = (bandwidth, resolution, videoRange, frameRate, codecs, audioGroup, trimmed)
            } else if let info = pendingInfo,
                      !trimmed.isEmpty,
                      !trimmed.hasPrefix("#") {
                variants.append(StreamVariant(
                    bandwidth: info.bandwidth,
                    uri: trimmed,
                    resolution: info.resolution,
                    videoRange: info.videoRange,
                    frameRate: info.frameRate,
                    codecs: info.codecs,
                    audioGroup: info.audioGroup,
                    streamInfoLine: info.line
                ))
                pendingInfo = nil
            }
        }

        return variants
    }

    static func parseMediaPlaylist(from content: String, defaultDuration: Double = 10.0) -> MediaPlaylist {
        let lines = content.components(separatedBy: "\n")
        var segments: [MediaSegment] = []
        var currentDuration = defaultDuration
        var initSegmentURI: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXTINF:") {
                let durationString = trimmed
                    .replacingOccurrences(of: "#EXTINF:", with: "")
                    .replacingOccurrences(of: ",", with: "")
                currentDuration = Double(durationString) ?? defaultDuration
            } else if trimmed.hasPrefix("#EXT-X-MAP:") {
                initSegmentURI = attribute("URI", inLine: trimmed)
            } else if trimmed.hasPrefix("#EXT") {
                continue
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                segments.append(MediaSegment(uri: trimmed, duration: currentDuration))
            }
        }

        return MediaPlaylist(segments: segments, initSegmentURI: initSegmentURI)
    }

    static func qualityName(resolution: String?, bandwidth: Double) -> String {
        if let resolution {
            let parts = resolution.components(separatedBy: "x")
            if let heightString = parts.last, let height = Int(heightString) {
                return "\(height)p"
            }
            return resolution
        }

        return "\(Int(bandwidth / 1_000_000))Mbps"
    }
}
