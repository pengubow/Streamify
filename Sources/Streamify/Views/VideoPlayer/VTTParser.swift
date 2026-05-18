import Foundation

// MARK: - VTT Parser
func parseVTT(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    // Normalize line endings: \r\n and \r → \n to avoid empty-line artifacts
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var i = 0
    
    while i < lines.count {
        let line = lines[i]
        // Look for timestamp lines: "00:00:00.000 --> 00:00:00.000"
        if line.contains("-->") {
            let parts = line.components(separatedBy: "-->")
            if parts.count == 2,
               let start = parseVTTTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
               let end = parseVTTTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") {
                // Collect text lines until empty line
                var textLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    textLines.append(lines[i])
                    i += 1
                }
                if !textLines.isEmpty {
                    let text = textLines.joined(separator: "\n")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
                }
                continue
            }
        }
        i += 1
    }
    return cues
}

private func parseVTTTimestamp(_ str: String) -> Double? {
    // Supports "HH:MM:SS.mmm" or "MM:SS.mmm"
    let components = str.components(separatedBy: ":")
    guard components.count >= 2 else { return nil }
    
    if components.count == 3 {
        guard let h = Double(components[0]),
              let m = Double(components[1]),
              let s = Double(components[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return h * 3600 + m * 60 + s
    } else {
        guard let m = Double(components[0]),
              let s = Double(components[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return m * 60 + s
    }
}

