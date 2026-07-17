enum StreamifySourceGrouping {
    static func rank(_ sourceName: String?) -> Int {
        switch sourceName {
        case "VidLove": return 10
        case "Torrentio": return 90
        default: return 50
        }
    }
}
