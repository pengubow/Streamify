enum StreamifySourceGrouping {
    static func rank(_ sourceName: String?) -> Int {
        switch sourceName {
        case "111Movies": return 10
        case "VidLink": return 20
        case "Torrentio": return 90
        default: return 50
        }
    }
}
