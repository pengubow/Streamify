import Foundation
import Combine
import UIKit
import AVFoundation

// MARK: - Download item state
enum DownloadStatus: String, Codable {
    case pending
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

// MARK: - Actor for thread-safe segment index tracking
actor SegmentIndexTracker {
    private var nextIndex: Int = 0

    func getNextIndex() -> Int {
        let index = nextIndex
        nextIndex += 1
        return index
    }

    func currentIndex() -> Int {
        return nextIndex
    }
}

/// Actor that coordinates rate-limit backoff across VidLink segment downloads.
/// Coordinates VidLink rate-limit detection across concurrent download tasks.
/// When an HTML response or rate-limit status code is detected, throws
/// `ImportError.rateLimitPauseAndResume` to stop the download task. The download manager
/// catches this and does an actual pause-for-10-seconds-then-resume cycle, just like
/// manual pause/unpause — flushing all stale connections and starting fresh.
actor VidLinkRateLimitHandler {
    /// Duration in seconds to wait when a rate limit / HTML response is detected.
    static let backoffDuration: TimeInterval = 10

    private var isRateLimited = false

    /// Signal that a rate limit was hit. Throws `ImportError.rateLimitPauseAndResume` to
    /// cancel the current download task. The download manager catches this and does an actual
    /// pause-for-10-seconds-then-resume cycle, just like manual pause/unpause.
    func triggerPauseAndResume() async throws -> Never {
        if isRateLimited {
            // Already being handled — just throw to stop this task too
            StreamifyLogger.log("VidLinkRateLimitHandler: Rate limit already being handled, stopping this task")
            throw ImportError.rateLimitPauseAndResume
        }

        isRateLimited = true

        StreamifyLogger.log("VidLinkRateLimitHandler: Rate limit/HTML detected — will pause download for \(Int(Self.backoffDuration))s then resume (mimics pause/unpause)")

        throw ImportError.rateLimitPauseAndResume
    }

    /// Check if rate limit has been triggered (other tasks should stop too).
    func checkRateLimited() throws {
        if isRateLimited {
            throw ImportError.rateLimitPauseAndResume
        }
    }
}

// MARK: - Download item model
class DownloadItem: ObservableObject, Identifiable, Codable {
    let id: String
    let contentId: String
    var videoUrl: String
    let episodeIndex: Int?  // nil for movies
    var seasonIndex: Int?   // nil for movies, mutable for episode downloads
    let episodeTitle: String?
    let quality: VideoQuality
    let selectedBandwidth: Double?  // Selected HLS bandwidth for quality
    let qualityName: String?  // Human-readable quality name (e.g., "1080p")
    let dateAdded: Date
    var fallbackUrls: [String]  // Alternative source URLs to try on failure

    /// TMDB ID for VidLink token refresh on download resume (nil for non-VidLink sources)
    var tmdbId: Int?

    /// Source attribution name (e.g., "VidLink", source file name) for identifying where this quality was downloaded from
    var sourceName: String?

    /// Resolution string from HLS variant (e.g., "1920x1080"), populated during download
    var selectedResolution: String?

    /// VIDEO-RANGE from HLS master playlist (e.g., "PQ", "HLG", "SDR"), populated during download
    var selectedVideoRange: String?

    /// Local playable file name when the downloaded file needed a container remux.
    var localFileNameOverride: String?
    var generatedAudioTracks: [AudioTrack]?
    var generatedSubtitleTracks: [SubtitleTrack]?
    var resumeData: Data?

    @Published var progress: Double = 0
    @Published var status: DownloadStatus = .pending
    @Published var errorMessage: String?
    @Published var currentTrackName: String? = nil  // Human-readable name of the track currently downloading (e.g., "1080p")

    // Resume support - track downloaded segments (for concurrent downloads)
    var downloadedSegmentIndices: Set<Int> = []
    var totalSegments: Int = 0

    // Concurrent download settings
    var concurrentDownloads: Int = 6  // Number of segments to download simultaneously

    var progressPercent: Int {
        Int(progress * 100)
    }

    // Resolve the series ID from contentId (strips _epN suffix for episode downloads)
    var seriesId: String? {
        guard episodeIndex != nil, contentId.contains("_ep") else { return nil }
        return contentId.components(separatedBy: "_ep").first
    }

    // Resolve the content's library ID (series ID for episodes, contentId for movies)
    var libraryContentId: String {
        seriesId ?? contentId
    }

    // Look up content metadata from the library
    var contentMetadata: ContentMetadata? {
        let safeId = libraryContentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? libraryContentId
        return ContentImportService.loadMetadata(from: safeId)
    }

    // Display title from metadata
    var displayTitle: String {
        contentMetadata?.title ?? libraryContentId
    }

    // Display type from metadata
    var displayType: ContentType {
        contentMetadata?.type ?? (episodeIndex != nil ? .series : .movie)
    }

    enum CodingKeys: String, CodingKey {
        case id = "i"
        case contentId = "ci"
        case videoUrl = "vu"
        case episodeIndex = "ei"
        case seasonIndex = "si"
        case episodeTitle = "et"
        case quality = "q"
        case selectedBandwidth = "sb"
        case qualityName = "qn"
        case dateAdded = "da"
        case progress = "p"
        case status = "s"
        case errorMessage = "em"
        case downloadedSegmentIndices = "di"
        case totalSegments = "ts"
        case concurrentDownloads = "cd"
        case fallbackUrls = "fu"
        case tmdbId = "ti"
        case sourceName = "sn"
        case selectedResolution = "sr"
        case selectedVideoRange = "svr"
        case currentTrackName = "ctn"
        case resumeData = "rd"
    }

    private enum LegacyKeys: String, CodingKey {
        case id, contentId
        case videoUrl, episodeIndex, seasonIndex, episodeTitle, quality, selectedBandwidth, qualityName, dateAdded
        case progress, status, errorMessage
        case downloadedSegmentIndices, totalSegments, concurrentDownloads
        case fallbackUrls
    }

    init(
        id: String = UUID().uuidString,
        contentId: String,
        videoUrl: String,
        episodeIndex: Int? = nil,
        episodeTitle: String? = nil,
        quality: VideoQuality = .auto,
        selectedBandwidth: Double? = nil,
        qualityName: String? = nil,
        dateAdded: Date = Date(),
        fallbackUrls: [String] = []
    ) {
        self.id = id
        self.contentId = contentId
        self.videoUrl = videoUrl
        self.episodeIndex = episodeIndex
        self.episodeTitle = episodeTitle
        self.quality = quality
        self.selectedBandwidth = selectedBandwidth
        self.qualityName = qualityName
        self.dateAdded = dateAdded
        self.fallbackUrls = fallbackUrls
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? lc.decode(String.self, forKey: .id)
        contentId = try c.decodeIfPresent(String.self, forKey: .contentId) ?? lc.decode(String.self, forKey: .contentId)
        videoUrl = try c.decodeIfPresent(String.self, forKey: .videoUrl) ?? lc.decode(String.self, forKey: .videoUrl)
        episodeIndex = try c.decodeIfPresent(Int.self, forKey: .episodeIndex) ?? lc.decodeIfPresent(Int.self, forKey: .episodeIndex)
        seasonIndex = try c.decodeIfPresent(Int.self, forKey: .seasonIndex) ?? lc.decodeIfPresent(Int.self, forKey: .seasonIndex)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle) ?? lc.decodeIfPresent(String.self, forKey: .episodeTitle)
        quality = try c.decodeIfPresent(VideoQuality.self, forKey: .quality) ?? lc.decode(VideoQuality.self, forKey: .quality)
        selectedBandwidth = try c.decodeIfPresent(Double.self, forKey: .selectedBandwidth) ?? lc.decodeIfPresent(Double.self, forKey: .selectedBandwidth)
        qualityName = try c.decodeIfPresent(String.self, forKey: .qualityName) ?? lc.decodeIfPresent(String.self, forKey: .qualityName)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? lc.decode(Date.self, forKey: .dateAdded)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? lc.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? lc.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .pending
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage) ?? lc.decodeIfPresent(String.self, forKey: .errorMessage)
        downloadedSegmentIndices = try c.decodeIfPresent(Set<Int>.self, forKey: .downloadedSegmentIndices) ?? lc.decodeIfPresent(Set<Int>.self, forKey: .downloadedSegmentIndices) ?? []
        totalSegments = try c.decodeIfPresent(Int.self, forKey: .totalSegments) ?? lc.decodeIfPresent(Int.self, forKey: .totalSegments) ?? 0
        concurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .concurrentDownloads) ?? lc.decodeIfPresent(Int.self, forKey: .concurrentDownloads) ?? 6
        fallbackUrls = try c.decodeIfPresent([String].self, forKey: .fallbackUrls) ?? lc.decodeIfPresent([String].self, forKey: .fallbackUrls) ?? []
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        selectedResolution = try c.decodeIfPresent(String.self, forKey: .selectedResolution)
        selectedVideoRange = try c.decodeIfPresent(String.self, forKey: .selectedVideoRange)
        currentTrackName = try c.decodeIfPresent(String.self, forKey: .currentTrackName)
        resumeData = try c.decodeIfPresent(Data.self, forKey: .resumeData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(contentId, forKey: .contentId)
        try container.encode(videoUrl, forKey: .videoUrl)
        try container.encodeIfPresent(episodeIndex, forKey: .episodeIndex)
        try container.encodeIfPresent(seasonIndex, forKey: .seasonIndex)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encode(quality, forKey: .quality)
        try container.encodeIfPresent(selectedBandwidth, forKey: .selectedBandwidth)
        try container.encodeIfPresent(qualityName, forKey: .qualityName)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(progress, forKey: .progress)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        // Only persist download tracking fields for non-completed downloads
        if status != .completed {
            try container.encode(downloadedSegmentIndices, forKey: .downloadedSegmentIndices)
            try container.encode(totalSegments, forKey: .totalSegments)
            try container.encode(concurrentDownloads, forKey: .concurrentDownloads)
            try container.encodeIfPresent(currentTrackName, forKey: .currentTrackName)
            try container.encodeIfPresent(resumeData, forKey: .resumeData)
        }
        try container.encode(fallbackUrls, forKey: .fallbackUrls)
        try container.encodeIfPresent(tmdbId, forKey: .tmdbId)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(selectedResolution, forKey: .selectedResolution)
        try container.encodeIfPresent(selectedVideoRange, forKey: .selectedVideoRange)
    }
}

// MARK: - Track download item (for individual subtitle/audio downloads from player picker)
class TrackDownloadItem: ObservableObject, Identifiable, Codable {
    let id: String
    let contentId: String
    let contentTitle: String
    let trackType: String  // "subtitle", "audio", or "video"
    let language: String
    let episodeTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let sourceUrl: String?  // Source URL for cross-source disambiguation (quality downloads)
    let downloadURL: String?       // The actual URL to download from (persisted for resume)
    let destFolderPath: String?    // Destination folder relative to Content dir (for resume)
    let filePrefix: String?        // File name prefix e.g. "ep1_" (for resume)
    let metadataFolder: String?    // Metadata folder path (for resume)
    let trackId: String?           // Original track ID (for metadata update on resume)
    let languageId: String?        // Language ID of the track (for metadata update on resume)
    let isHLS: Bool                // Whether download URL is HLS (for audio resume)
    @Published var progress: Double = 0
    @Published var status: DownloadStatus = .queued
    @Published var errorMessage: String?
    /// The task performing the download — set by the creator so DownloadsView can cancel it
    var downloadTask: Task<Void, Never>?

    enum CodingKeys: String, CodingKey {
        case id = "i"
        case contentId = "ci"
        case contentTitle = "ct"
        case trackType = "tt"
        case language = "l"
        case episodeTitle = "et"
        case seasonNumber = "sn"
        case episodeNumber = "en"
        case sourceUrl = "su"
        case downloadURL = "du"
        case destFolderPath = "df"
        case filePrefix = "fp"
        case metadataFolder = "mf"
        case trackId = "tid"
        case languageId = "lid"
        case isHLS = "hls"
        case progress = "p"
        case status = "s"
        case errorMessage = "em"
    }

    init(id: String = UUID().uuidString, contentId: String, contentTitle: String, trackType: String, language: String, episodeTitle: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, sourceUrl: String? = nil, downloadURL: String? = nil, destFolderPath: String? = nil, filePrefix: String? = nil, metadataFolder: String? = nil, trackId: String? = nil, languageId: String? = nil, isHLS: Bool = false) {
        self.id = id
        self.contentId = contentId
        self.contentTitle = contentTitle
        self.trackType = trackType
        self.language = language
        self.episodeTitle = episodeTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.sourceUrl = sourceUrl
        self.downloadURL = downloadURL
        self.destFolderPath = destFolderPath
        self.filePrefix = filePrefix
        self.metadataFolder = metadataFolder
        self.trackId = trackId
        self.languageId = languageId
        self.isHLS = isHLS
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contentId = try c.decode(String.self, forKey: .contentId)
        contentTitle = try c.decode(String.self, forKey: .contentTitle)
        trackType = try c.decode(String.self, forKey: .trackType)
        language = try c.decode(String.self, forKey: .language)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
        destFolderPath = try c.decodeIfPresent(String.self, forKey: .destFolderPath)
        filePrefix = try c.decodeIfPresent(String.self, forKey: .filePrefix)
        metadataFolder = try c.decodeIfPresent(String.self, forKey: .metadataFolder)
        trackId = try c.decodeIfPresent(String.self, forKey: .trackId)
        languageId = try c.decodeIfPresent(String.self, forKey: .languageId)
        isHLS = try c.decodeIfPresent(Bool.self, forKey: .isHLS) ?? false
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .queued
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(contentId, forKey: .contentId)
        try c.encode(contentTitle, forKey: .contentTitle)
        try c.encode(trackType, forKey: .trackType)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try c.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(sourceUrl, forKey: .sourceUrl)
        try c.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try c.encodeIfPresent(destFolderPath, forKey: .destFolderPath)
        try c.encodeIfPresent(filePrefix, forKey: .filePrefix)
        try c.encodeIfPresent(metadataFolder, forKey: .metadataFolder)
        try c.encodeIfPresent(trackId, forKey: .trackId)
        try c.encodeIfPresent(languageId, forKey: .languageId)
        try c.encode(isHLS, forKey: .isHLS)
        try c.encode(progress, forKey: .progress)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    /// Whether this item has enough persisted info to be resumed by DownloadManager
    var canResume: Bool {
        downloadURL != nil && destFolderPath != nil
    }

    var displayName: String {
        let typeLabel = trackType == "subtitle" ? "Subtitle" : (trackType == "video" ? "Quality" : "Audio")
        if let epTitle = episodeTitle, let s = seasonNumber, let e = episodeNumber {
            return "\(typeLabel): \(language) — S\(s)E\(e): \(epTitle)"
        }
        return "\(typeLabel): \(language)"
    }
}

// MARK: - URLSession download delegate for progress reporting
private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64, Int64) -> Void)?
    var onCompletion: ((URL?, URLResponse?, Error?) -> Void)?
    private var resumeOffset: Int64 = 0
    private var resumeExpectedTotal: Int64 = 0

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onCompletion?(location, downloadTask.response, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = resumeExpectedTotal > 0 ? resumeExpectedTotal : totalBytesExpectedToWrite
        let written = resumeOffset > 0 ? min(resumeOffset + totalBytesWritten, max(expected, resumeOffset + totalBytesWritten)) : totalBytesWritten
        onProgress?(bytesWritten, written, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        resumeOffset = fileOffset
        resumeExpectedTotal = expectedTotalBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onCompletion?(nil, task.response, error)
        }
    }
}

private final class URLSessionDownloadTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    func set(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func cancelProducingResumeData(_ handler: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel(byProducingResumeData: { resumeData in
            handler(resumeData)
        })
    }
}

// MARK: - Download Manager for background downloads
@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    private static let networkRetryAttempts = 4
    private static let networkRetryDelayNanoseconds: UInt64 = 1_000_000_000

    /// Posted when any download (main or track) completes. Player can observe this to refresh local file state.
    static let downloadCompletedNotification = Notification.Name("DownloadManager.downloadCompleted")

    private static func fileExtension(for source: String) -> String? {
        let withoutQuery = source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? source
        let ext = (withoutQuery as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    private static func looksLikeHLS(_ source: String) -> Bool {
        source.localizedCaseInsensitiveContains(".m3u8")
    }

    private static func isHDRVideoRange(_ range: String?) -> Bool {
        guard let range = range?.uppercased() else { return false }
        return range == "PQ" || range == "HLG" || range == "HDR"
    }

    private static func downloadMetadataSuggestsHDR(_ download: DownloadItem, localSource: String) -> Bool {
        let text = [
            download.qualityName,
            download.selectedVideoRange,
            localSource,
            download.videoUrl,
            download.sourceName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return textSuggestsHDR(text)
    }

    private static func textSuggestsHDR(_ text: String) -> Bool {
        let pattern = #"(?i)(^|[^A-Za-z0-9])(HDR10\+?|HDR|HLG|PQ|DV|DOVI|Dolby\s+Vision)([^A-Za-z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isLocalVideoFileName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasSuffix(".mp4") ||
            lowercased.hasSuffix(".mov") ||
            lowercased.hasSuffix(".m4v") ||
            lowercased.hasSuffix(".mkv") ||
            lowercased.hasSuffix(".webm")
    }

    nonisolated private static func byteProgress(totalBytesWritten: Int64, totalBytesExpected: Int64) -> Double {
        if totalBytesExpected > 0 {
            return min(max(Double(totalBytesWritten) / Double(totalBytesExpected), 0), 1)
        }
        let mb = Double(totalBytesWritten) / (1024.0 * 1024.0)
        return min(0.95, mb / (mb + 20.0))
    }

    @Published var downloads: [DownloadItem] = []
    @Published var trackDownloads: [TrackDownloadItem] = []  // Individual track downloads from player picker
    @Published var activeDownloads: [String: URLSessionDownloadTask] = [:]
    @Published var lastError: String?
    @Published var showErrorAlert: Bool = false
    @Published var libraryRefreshNeeded: Bool = false

    /// Counter tracking how many callers are currently setting up track downloads.
    /// While > 0, processQueue() will not start the next video download to avoid
    /// a race between adding queued videos and starting their associated tracks.
    private var pendingTrackSetupCount: Int = 0

    /// Call before adding queued video downloads + starting track downloads.
    /// Prevents processQueue() from prematurely starting the queued video while tracks are still being set up.
    func beginTrackSetup() {
        pendingTrackSetupCount += 1
    }

    /// Call after track downloads finish and triggerProcessQueue() is about to be called.
    func endTrackSetup() {
        pendingTrackSetupCount = max(0, pendingTrackSetupCount - 1)
    }

    private var urlSession: URLSession!
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTaskTokens: [String: UUID] = [:]
    private var lastProgressBroadcast: Date = .distantPast

    // Dedicated URLSession for downloads that can be invalidated on cancel
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// Dedicated URLSession for VidLink segment downloads with shorter timeouts.
    /// VidLink connections can go stale (Cloudflare edge connection resets) —
    /// a 30s request timeout ensures we detect stalled fetches quickly and retry.
    /// NOT static — can be recreated to flush stale connections (mimics pause/unpause behavior).
    private static var vidLinkSession: URLSession = makeVidLinkSession()

    private static func makeVidLinkSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        // Force new connections instead of reusing potentially stale ones
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Recreate the VidLink URLSession to flush stale connections.
    /// Called during rate-limit recovery — mimics what pause/unpause does naturally
    /// (cancelling old URLSession tasks and creating fresh connections).
    static func resetVidLinkSession() {
        // Cancel all tasks on the old session before replacing it.
        // invalidateAndCancel immediately cancels all tasks and prevents the session
        // from creating new connections, which is more reliable than getAllTasks+cancel.
        let oldSession = vidLinkSession
        vidLinkSession = makeVidLinkSession()
        oldSession.invalidateAndCancel()
        StreamifyLogger.log("DownloadManager: Reset VidLink URLSession (invalidated old session, created fresh)")
    }

    // File paths
    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var downloadsFileURL: URL {
        documentsURL.appendingPathComponent("downloads.json")
    }

    private static var downloadsZlibURL: URL {
        documentsURL.appendingPathComponent("downloads.json.zlib")
    }

    private static var trackDownloadsZlibURL: URL {
        documentsURL.appendingPathComponent("track_downloads.json.zlib")
    }

    private static var contentDirectoryURL: URL {
        documentsURL.appendingPathComponent("Content")
    }

    private init() {
        // Setup background URL session
        let config = URLSessionConfiguration.background(withIdentifier: "com.streamify.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: .main)

        // Load saved downloads
        loadDownloads()
        loadTrackDownloads()
    }

    // MARK: - Persistence

    private func loadDownloads() {
        let savedDownloads: [DownloadItem]
        do {
            savedDownloads = try CompressedJSON.readWithFallback(
                [DownloadItem].self,
                compressedURL: Self.downloadsZlibURL,
                plainURL: Self.downloadsFileURL
            )
        } catch {
            StreamifyLogger.log("DownloadManager: Failed to load downloads: \(error.localizedDescription)")
            savedDownloads = []
        }

        // Reset all in-flight and queued statuses to paused (app was closed)
        // This preserves any downloaded progress and allows the user to resume manually
        var needsSave = false
        for download in savedDownloads {
            if download.status == .downloading || download.status == .pending || download.status == .queued {
                download.status = .paused
                download.errorMessage = "Download paused - app was closed. Tap resume to continue."
                needsSave = true
            }
        }

        // Remove completed and cancelled downloads on restart — they are no longer useful
        let filtered = savedDownloads.filter { $0.status != .completed && $0.status != .cancelled }
        if filtered.count != savedDownloads.count {
            needsSave = true
        }
        downloads = filtered

        // Save the updated states
        if needsSave {
            saveDownloads()
        }
    }

    private func saveDownloads() {
        do {
            try CompressedJSON.write(downloads, to: Self.downloadsZlibURL)
        } catch {
            StreamifyLogger.log("Failed to save downloads: \(error)")
        }
    }

    /// Public method called when the app enters background to persist download state.
    /// Saves all current download progress so it survives app termination.
    func saveDownloadsOnBackground() {
        saveDownloads()
        saveTrackDownloads()
    }

    // MARK: - Track Download Persistence

    private func saveTrackDownloads() {
        // Only persist non-completed, non-cancelled track downloads
        let toSave = trackDownloads.filter { $0.status != .completed && $0.status != .cancelled }
        guard !toSave.isEmpty else {
            // Clean up file if nothing to persist
            try? FileManager.default.removeItem(at: Self.trackDownloadsZlibURL)
            return
        }
        do {
            try CompressedJSON.write(toSave, to: Self.trackDownloadsZlibURL)
        } catch {
            StreamifyLogger.log("Failed to save track downloads: \(error)")
        }
    }

    private func loadTrackDownloads() {
        guard FileManager.default.fileExists(atPath: Self.trackDownloadsZlibURL.path) else { return }

        let saved: [TrackDownloadItem]
        do {
            saved = try CompressedJSON.read([TrackDownloadItem].self, from: Self.trackDownloadsZlibURL)
        } catch {
            StreamifyLogger.log("DownloadManager: Failed to load track downloads: \(error.localizedDescription)")
            return
        }

        // Reset in-flight statuses to paused (app was closed, task is gone)
        for item in saved {
            if item.status == .downloading || item.status == .pending || item.status == .queued {
                item.status = .paused
                item.errorMessage = "Download paused - app was closed."
            }
            // Task references are lost on restart
            item.downloadTask = nil
        }

        // Remove completed, cancelled, and failed items on restart
        let filtered = saved.filter { $0.status != .completed && $0.status != .cancelled && $0.status != .failed }
        trackDownloads = filtered

        if !filtered.isEmpty {
            StreamifyLogger.log("DownloadManager: Restored \(filtered.count) paused track download(s)")
        }

        // Clean up the file
        saveTrackDownloads()
    }

    // MARK: - Queue Management

    /// Check if there's currently an active (downloading) download — includes both video and track downloads
    private var hasActiveDownload: Bool {
        downloads.contains { $0.status == .downloading } ||
        trackDownloads.contains { $0.status == .downloading }
    }

    /// Notify observers of progress changes (throttled to avoid excessive re-renders)
    func broadcastProgressIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastProgressBroadcast) >= 0.5 {
            lastProgressBroadcast = now
            objectWillChange.send()
        }
    }

    /// Start the next queued download if no active download is running
    private func processQueue() {
        guard !hasActiveDownload else { return }
        // Don't start a queued video while another caller is still setting up track downloads
        // for a newly-queued batch — tracks need to be registered first so hasActiveDownload
        // correctly reflects the ongoing work.
        guard pendingTrackSetupCount == 0 else { return }
        if let nextQueued = downloads.first(where: { $0.status == .queued }) {
            startDownload(nextQueued)
            // Notify observers so UI reflects the status change from .queued to .downloading
            objectWillChange.send()
        }
    }

    // MARK: - Helper to resolve segment URL
    private func resolveSegmentURL(_ segmentURL: String, baseURL: URL, variantURL: URL) -> URL? {
        if segmentURL.hasPrefix("http") {
            return URL(string: segmentURL)
        } else if segmentURL.hasPrefix("/") {
            return URL(string: "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(segmentURL)")
        } else {
            return variantURL.deletingLastPathComponent().appendingPathComponent(segmentURL)
        }
    }

    private struct SelectedHLSVariant {
        let variant: HLSManifestParser.StreamVariant
        let url: URL
        let content: String
    }

    private func downloadableHLSVariants(from masterContent: String) -> [HLSManifestParser.StreamVariant] {
        HLSManifestParser.parseStreamVariants(from: masterContent)
            .filter { $0.bandwidth > 0 }
            .sorted { $0.bandwidth > $1.bandwidth }
    }

    private func preferredBandwidth(for download: DownloadItem, variants: [HLSManifestParser.StreamVariant]) -> Double {
        if let bandwidth = download.selectedBandwidth {
            return bandwidth
        }

        switch download.quality {
        case .auto, .max:
            return variants.first?.bandwidth ?? 8_000_000
        case .high:
            return variants.first { $0.bandwidth <= 8_000_000 }?.bandwidth ?? variants.first?.bandwidth ?? 8_000_000
        case .medium:
            return variants.first { $0.bandwidth <= 4_000_000 }?.bandwidth ?? variants.first?.bandwidth ?? 4_000_000
        case .low:
            return variants.first { $0.bandwidth <= 1_500_000 }?.bandwidth ?? variants.first?.bandwidth ?? 1_500_000
        }
    }

    private func bestHLSVariant(from variants: [HLSManifestParser.StreamVariant], selectedBandwidth: Double) -> HLSManifestParser.StreamVariant? {
        if let exactMatch = variants.first(where: { $0.bandwidth == selectedBandwidth }) {
            return exactMatch
        }
        if let closestMatch = variants.first(where: { $0.bandwidth <= selectedBandwidth }) {
            return closestMatch
        }
        return variants.first
    }

    private func loadSelectedHLSVariant(
        masterContent: String,
        sourceURL: URL,
        variants: [HLSManifestParser.StreamVariant],
        selectedBandwidth: Double
    ) async throws -> SelectedHLSVariant {
        if variants.isEmpty {
            // Some sources provide a media playlist directly instead of a
            // master playlist. In that case the input URL is already the
            // selected variant playlist.
            guard masterContent.contains("#EXTINF:") else {
                throw ImportError.downloadFailed
            }
            return SelectedHLSVariant(
                variant: HLSManifestParser.StreamVariant(
                    bandwidth: selectedBandwidth,
                    uri: sourceURL.absoluteString,
                    resolution: nil,
                    videoRange: nil,
                    frameRate: nil,
                    codecs: nil,
                    audioGroup: nil,
                    streamInfoLine: ""
                ),
                url: sourceURL,
                content: masterContent
            )
        }

        guard let bestVariant = bestHLSVariant(from: variants, selectedBandwidth: selectedBandwidth),
              let variantURL = resolveSegmentURL(bestVariant.uri, baseURL: sourceURL, variantURL: sourceURL) else {
            throw ImportError.downloadFailed
        }

        try Task.checkCancellation()
        let (variantData, _) = try await fetchData(from: variantURL)
        try Task.checkCancellation()
        guard let variantContent = String(data: variantData, encoding: .utf8) else {
            throw ImportError.downloadFailed
        }

        return SelectedHLSVariant(variant: bestVariant, url: variantURL, content: variantContent)
    }

    /// Fetch data from a URL, applying VidLink Referer header if the URL is a VidLink proxy URL.
    /// VidLink proxy URLs always need `Referer: https://vidlink.pro/`.
    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        return try await Self.fetchDataStatic(from: url)
    }

    /// Static version of fetchData for use in @Sendable closures (TaskGroup).
    /// Auto-detects VidLink URLs and adds the Referer header when needed.
    private static func fetchDataStatic(from url: URL) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 1...networkRetryAttempts {
            try Task.checkCancellation()

            do {
                if VidLinkService.isVidLinkProxyURL(url.absoluteString) {
                    var request = URLRequest(url: url)
                    request.setValue(VidLinkService.vidLinkReferer, forHTTPHeaderField: "Referer")
                    return try await vidLinkSession.data(for: request)
                }
                return try await URLSession.shared.data(from: url)
            } catch {
                try Task.checkCancellation()
                lastError = error
                guard attempt < networkRetryAttempts else { break }
                StreamifyLogger.log("DownloadManager: data request attempt \(attempt)/\(networkRetryAttempts) failed for \(url.absoluteString): \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: networkRetryDelayNanoseconds)
            }
        }

        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private static func downloadWithRetry(
        from url: URL,
        resumeData: Data? = nil,
        onProgress: (@Sendable (Int64, Int64, Int64) -> Void)? = nil,
        onResumeData: (@Sendable (Data?) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        var lastError: Error?

        for attempt in 1...networkRetryAttempts {
            try Task.checkCancellation()

            do {
                return try await downloadOnce(
                    from: url,
                    resumeData: attempt == 1 ? resumeData : nil,
                    onProgress: onProgress,
                    onResumeData: onResumeData
                )
            } catch {
                try Task.checkCancellation()
                lastError = error
                guard attempt < networkRetryAttempts else { break }
                StreamifyLogger.log("DownloadManager: file request attempt \(attempt)/\(networkRetryAttempts) failed for \(url.absoluteString): \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: networkRetryDelayNanoseconds)
            }
        }

        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private static func downloadOnce(
        from url: URL,
        resumeData: Data? = nil,
        onProgress: (@Sendable (Int64, Int64, Int64) -> Void)?,
        onResumeData: (@Sendable (Data?) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let taskHolder = URLSessionDownloadTaskHolder()
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                taskHolder.set(task)

                delegate.onProgress = { bytesWritten, totalBytesWritten, totalBytesExpected in
                    onProgress?(bytesWritten, totalBytesWritten, totalBytesExpected)
                }

                delegate.onCompletion = { tempURL, response, error in
                    guard !hasResumed else { return }
                    hasResumed = true
                    if let error {
                        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                        if resumeData != nil {
                            onResumeData?(resumeData)
                        }
                        continuation.resume(throwing: error)
                        return
                    }
                    onResumeData?(nil)
                    guard let tempURL, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    let stableTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: stableTempURL)
                        continuation.resume(returning: (stableTempURL, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }

                task.resume()
            }
        } onCancel: {
            taskHolder.cancelProducingResumeData { resumeData in
                if resumeData != nil {
                    onResumeData?(resumeData)
                }
            }
        }
    }

    private func effectiveConcurrentDownloadCount(for download: DownloadItem) -> Int {
        guard Self.looksLikeHLS(download.videoUrl) else {
            return 1
        }
        return max(1, download.concurrentDownloads)
    }

    /// Check if downloaded data is an HTML error page (e.g. Cloudflare rate limit).
    /// Returns true if the data appears to be valid video/media content, false if it looks like HTML.
    static func isValidSegmentData(_ data: Data) -> Bool {
        // Too small to be a real video segment
        if data.count < 512 {
            return false
        }
        // Check the very beginning of the data for HTML signatures.
        // Only check the first 64 bytes to avoid false positives from video content
        // that might incidentally contain HTML-like strings later in the file.
        let headerSize = min(data.count, 64)
        let headerData = data.prefix(headerSize)
        if let headerStr = String(data: headerData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if headerStr.hasPrefix("<!doctype") || headerStr.hasPrefix("<html") || headerStr.hasPrefix("<head") {
                return false
            }
        }
        return true
    }

    /// Fetch a VidLink segment with validation and rate-limit retry.
    /// If the response is an HTML page (Cloudflare), waits 10 seconds, regenerates the token,
    /// gets a new m3u8, and retries downloading the segment with the new URL.
    /// Uses a shared VidLinkRateLimitHandler to coordinate backoff and token regeneration.
    private static func fetchVidLinkSegmentWithRetry(
        from url: URL,
        rateLimitHandler: VidLinkRateLimitHandler
    ) async throws -> (Data, URLResponse) {
        // If rate limit was already triggered by another concurrent task, stop immediately
        try await rateLimitHandler.checkRateLimited()

        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetchDataStatic(from: url)
        } catch {
            try Task.checkCancellation()
            let nsError = error as NSError
            let isTimeout = nsError.code == NSURLErrorTimedOut
            let isConnectionLost = nsError.code == NSURLErrorNetworkConnectionLost
            let isNotConnected = nsError.code == NSURLErrorNotConnectedToInternet

            if isTimeout || isConnectionLost || isNotConnected {
                StreamifyLogger.log("DownloadManager: VidLink fetch error (\(nsError.code)) for \(url.lastPathComponent), triggering pause-and-resume")
                // Throw to trigger pause-and-resume cycle (like pause/unpause)
                try await rateLimitHandler.triggerPauseAndResume()
            }
            throw error
        }

        // Check HTTP status code for rate limiting
        if let httpResponse = response as? HTTPURLResponse,
           (httpResponse.statusCode == 403 || httpResponse.statusCode == 429 || httpResponse.statusCode == 503) {
            StreamifyLogger.log("DownloadManager: VidLink rate limit (HTTP \(httpResponse.statusCode)) for \(url.lastPathComponent), triggering pause-and-resume")
            try await rateLimitHandler.triggerPauseAndResume()
        }

        // Validate the downloaded data isn't an HTML error page
        if !isValidSegmentData(data) {
            StreamifyLogger.log("DownloadManager: VidLink segment is HTML/invalid (\(data.count) bytes) for \(url.lastPathComponent), triggering pause-and-resume")
            try await rateLimitHandler.triggerPauseAndResume()
        }

        return (data, response)
    }

    // MARK: - Add download (queued)

    /// Add a download as queued (never starts it immediately).
    /// Used when tracks download first and video should queue behind them.
    func addQueuedDownload(
        contentId: String,
        videoUrl: String,
        episodeIndex: Int? = nil,
        seasonIndex: Int? = nil,
        episodeTitle: String? = nil,
        quality: VideoQuality = .auto,
        selectedBandwidth: Double? = nil,
        qualityName: String? = nil,
        allEpisodes: [EpisodeInfo]? = nil,
        fallbackUrls: [String] = [],
        tmdbId: Int? = nil,
        sourceName: String? = nil,
        selectedResolution: String? = nil,
        selectedVideoRange: String? = nil
    ) {
        let activeStatuses: Set<DownloadStatus> = [.queued, .downloading, .paused, .pending]
        if downloads.contains(where: {
            $0.contentId == contentId &&
                $0.episodeIndex == episodeIndex &&
                $0.seasonIndex == seasonIndex &&
                $0.videoUrl == videoUrl &&
                activeStatuses.contains($0.status)
        }) {
            StreamifyLogger.log("DownloadManager: Ignoring duplicate queued download for \(contentId) \(videoUrl)")
            return
        }

        let download: DownloadItem
        if let bw = selectedBandwidth {
            let resolvedQualityName = qualityName ?? Self.qualityNameForBandwidth(bw)
            download = DownloadItem(
                contentId: contentId,
                videoUrl: videoUrl,
                episodeIndex: episodeIndex,
                episodeTitle: episodeTitle,
                quality: .auto,
                selectedBandwidth: bw,
                qualityName: resolvedQualityName,
                fallbackUrls: fallbackUrls
            )
        } else {
            download = DownloadItem(
                contentId: contentId,
                videoUrl: videoUrl,
                episodeIndex: episodeIndex,
                episodeTitle: episodeTitle,
                quality: quality
            )
        }
        download.seasonIndex = seasonIndex
        download.tmdbId = tmdbId
        download.sourceName = sourceName
        download.selectedResolution = selectedResolution
        download.selectedVideoRange = selectedVideoRange
        if !Self.looksLikeHLS(videoUrl) {
            download.concurrentDownloads = 1
        }
        download.status = .queued

        downloads.insert(download, at: 0)
        saveDownloads()
        objectWillChange.send()
    }

    /// Manually trigger queue processing (e.g., after track downloads finish)
    func triggerProcessQueue() {
        processQueue()
    }

    // MARK: - Helper to get quality name from bandwidth
    private static func qualityNameForBandwidth(_ bandwidth: Double) -> String {
        if bandwidth >= 8_000_000 {
            return "1080p"
        } else if bandwidth >= 5_000_000 {
            return "720p"
        } else if bandwidth >= 2_500_000 {
            return "480p"
        } else {
            return "360p"
        }
    }

    private func refreshProviderURLIfNeeded(for download: DownloadItem) async {
        guard let tmdbId = download.tmdbId else { return }

        if download.sourceName == "Torrentio" {
            // Preserve URLSession resume data for normal pause/unpause. We only refresh
            // Torrentio links for queued/new starts or when no resumable partial exists.
            guard download.resumeData == nil else { return }
            let result: TorrentioService.TorrentioResult?
            if let episodeIndex = download.episodeIndex, let seasonIndex = download.seasonIndex {
                result = await TorrentioService.fetchEpisodeStream(tmdbId: tmdbId, season: seasonIndex, episode: episodeIndex)
            } else {
                result = await TorrentioService.fetchMovieStream(tmdbId: tmdbId)
            }
            guard let option = result.flatMap({
                TorrentioService.matchingOption(
                    in: $0.options,
                    previousURL: download.videoUrl,
                    qualityName: download.qualityName,
                    resolution: download.selectedResolution
                )
            }) else { return }
            var changed = false
            if option.url != download.videoUrl {
                download.videoUrl = option.url
                download.resumeData = nil
                changed = true
                StreamifyLogger.log("DownloadManager: Refreshed Torrentio URL for \(download.displayTitle)")
            }
            if download.selectedResolution == nil {
                download.selectedResolution = option.resolution
                changed = true
            }
            if download.selectedVideoRange == nil {
                download.selectedVideoRange = option.videoRange
                changed = true
            }
            if changed {
                saveDownloads()
            }
            return
        }

        guard VidLinkService.isVidLinkProxyURL(download.videoUrl) || download.sourceName == "VidLink" else {
            return
        }

        StreamifyLogger.log("DownloadManager: Regenerating VidLink token for TMDB \(tmdbId)")
        let result: VidLinkService.VidLinkResult?
        if let episodeIndex = download.episodeIndex, let seasonIndex = download.seasonIndex {
            result = await VidLinkService.fetchEpisodeStream(tmdbId: tmdbId, season: seasonIndex, episode: episodeIndex)
        } else {
            result = await VidLinkService.fetchMovieStream(tmdbId: tmdbId)
        }
        if let newUrl = result?.hlsUrl {
            download.videoUrl = newUrl
            saveDownloads()
            StreamifyLogger.log("DownloadManager: Refreshed VidLink URL for \(download.displayTitle)")
        }
    }

    // MARK: - Start download

    private func startDownload(_ download: DownloadItem, allEpisodes: [EpisodeInfo]? = nil) {
        guard downloadTasks[download.id] == nil else {
            StreamifyLogger.log("DownloadManager: Ignoring duplicate start for \(download.displayTitle)")
            return
        }

        download.status = .downloading
        saveDownloads()
        let downloadId = download.id
        let taskToken = UUID()
        downloadTaskTokens[downloadId] = taskToken

        let task = Task {
            defer {
                if self.downloadTaskTokens[downloadId] == taskToken {
                    self.downloadTasks.removeValue(forKey: downloadId)
                    self.downloadTaskTokens.removeValue(forKey: downloadId)
                }
            }

            do {
                await self.refreshProviderURLIfNeeded(for: download)
                guard let url = URL(string: download.videoUrl) else {
                    throw URLError(.badURL)
                }

                // Download video
                await MainActor.run {
                    download.progress = 0
                    download.currentTrackName = download.qualityName
                    self.saveDownloads()
                }

                if Self.looksLikeHLS(download.videoUrl) {
                    try await downloadHLSStream(download: download, url: url)
                } else {
                    try await downloadFile(download: download, url: url)
                }

                // Check if cancelled
                if Task.isCancelled { return }

                download.progress = 1.0
                download.status = .completed
                download.currentTrackName = nil
                self.saveDownloads()
                self.objectWillChange.send()  // Force UI update for 100% completion

                // Add to library if not already there
                await self.addToLibraryIfNeeded(download, allEpisodes: allEpisodes)

                NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                self.processQueue()
            } catch {
                // Don't update status if cancelled
                if Task.isCancelled { return }

                StreamifyLogger.log("Download failed for \(download.displayTitle): \(error.localizedDescription)")

                // VidLink rate limit — silently wait then auto-resume (no UI status change)
                if let importErr = error as? ImportError, importErr == .rateLimitPauseAndResume {
                    StreamifyLogger.log("DownloadManager: VidLink rate limit — waiting 10s then auto-resuming \(download.displayTitle)")
                    self.saveDownloads()

                    // Wait before resuming (like manual pause/unpause)
                    try? await Task.sleep(nanoseconds: UInt64(VidLinkRateLimitHandler.backoffDuration * 1_000_000_000))

                    // Check if user manually cancelled during the wait
                    if Task.isCancelled { return }
                    if download.status == .paused || download.status == .failed { return }

                    // Auto-resume the download (picks up from saved segment indices)
                    StreamifyLogger.log("DownloadManager: Auto-resuming VidLink download after 10s wait for \(download.displayTitle)")
                    // Set to paused briefly so resumeDownload accepts it
                    download.status = .paused
                    self.downloadTasks.removeValue(forKey: downloadId)
                    self.downloadTaskTokens.removeValue(forKey: downloadId)
                    await MainActor.run {
                        self.resumeDownload(download)
                    }
                    return
                }

                // Check if it's a network error - auto-pause instead of fail
                if self.isNetworkError(error) {
                    // Network error - auto-pause and save progress silently
                    download.status = .paused
                    download.currentTrackName = nil
                    download.errorMessage = "Network connection lost. Download paused - tap resume when back online."
                    self.saveDownloads()
                    // Force UI update so download moves from "Downloading" to "Paused" section with resume button
                    self.downloads = self.downloads
                    StreamifyLogger.log("Network error - auto-paused download for \(download.displayTitle), \(download.progressPercent)%")
                    self.processQueue()
                } else if !download.fallbackUrls.isEmpty {
                    // Try next fallback URL (already on @MainActor via class)
                    await MainActor.run {
                        let nextUrl = download.fallbackUrls.removeFirst()
                        download.videoUrl = nextUrl
                        download.progress = 0
                        download.downloadedSegmentIndices = []
                        download.totalSegments = 0
                        download.resumeData = nil
                        download.errorMessage = nil
                        self.saveDownloads()

                        StreamifyLogger.log("Download failed, trying fallback source for \(download.displayTitle)")

                        // Restart with fallback URL
                        self.downloadTasks.removeValue(forKey: downloadId)
                        self.downloadTaskTokens.removeValue(forKey: downloadId)
                        self.startDownload(download, allEpisodes: allEpisodes)
                    }
                    return
                } else {
                    // Real error — clean up partial downloads and fail
                    self.deleteDownloadedSegmentsOnly(for: download)
                    self.cleanupOrphanedFiles(for: download)

                    download.status = .failed
                    download.currentTrackName = nil
                    download.errorMessage = error.localizedDescription
                    self.saveDownloads()

                    // Show error notification
                    await MainActor.run {
                        self.lastError = "\(download.displayTitle): \(error.localizedDescription)"
                        self.showErrorAlert = true
                    }

                    self.processQueue()
                }
            }
        }

        downloadTasks[downloadId] = task
    }

    // MARK: - Shared folder path helpers

    /// Build the relative folder path for a download item (episode subfolder or movie root).
    /// Centralises the `season_X_episode_Y` convention so every call-site stays consistent.
    static func folderPath(for download: DownloadItem) -> String {
        if let epIdx = download.episodeIndex, download.contentId.contains("_ep") {
            let seriesId = download.contentId.components(separatedBy: "_ep").first ?? download.contentId
            return episodeFolderPath(contentId: seriesId, season: download.seasonIndex ?? 1, episode: epIdx)
        }
        return (download.contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? download.contentId)
    }

    /// Build `<contentId>/season_<S>_episode_<E>` from raw components.
    /// Use this from any site that needs to construct an episode subfolder path.
    nonisolated static func episodeFolderPath(contentId: String, season: Int, episode: Int) -> String {
        let safeId = contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
        return "\(safeId)/\(episodeSubfolder(season: season, episode: episode))"
    }

    /// Build just the `season_<S>_episode_<E>` subfolder name.
    /// Use when the base path (e.g. `content.folderPath`) is already known.
    nonisolated static func episodeSubfolder(season: Int, episode: Int) -> String {
        "season_\(season)_episode_\(episode)"
    }

    /// Build the quality-specific subfolder name for a download (e.g., `video_1080p_<uuid>` or `ep1_video_720p_<uuid>`).
    /// Returns an empty string if the download has no quality name.
    nonisolated static func qualitySubdirName(qualityName: String?, downloadId: String, episodeIndex: Int? = nil) -> String {
        guard let qName = qualityName, !qName.isEmpty else { return "" }
        let safeName = safeFileComponent(qName)
        let prefix = episodeIndex.map { "ep\($0)_" } ?? ""
        return "\(prefix)video_\(safeName)_\(downloadId)"
    }

    nonisolated private static func shortDownloadId(_ downloadId: String) -> String {
        String(downloadId.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    nonisolated private static func safeFileComponent(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(cleaned)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "video" : collapsed
    }

    private static func uniqueDirectVideoFileName(for download: DownloadItem, sourceURL url: URL) -> String {
        let ext = fileExtension(for: url.absoluteString) ?? "mp4"
        let suffix = shortDownloadId(download.id)
        let quality = safeFileComponent(download.qualityName ?? "video")

        if let epIdx = download.episodeIndex {
            return "episode_\(epIdx)_\(quality)_\(suffix).\(ext)"
        }

        let decoded = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        let base = safeFileComponent(decoded.isEmpty ? "video_\(quality)" : decoded)
        return "\(base)_\(suffix).\(ext)"
    }

    // MARK: - Check if error is a network error
    private func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        // Also check for common network-related errors
        let networkErrorCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorCannotFindHost
        ]
        return networkErrorCodes.contains(nsError.code)
    }

    // MARK: - Download regular file

    private func downloadFile(download: DownloadItem, url: URL) async throws {
        // Check if cancelled before starting
        try Task.checkCancellation()
        download.totalSegments = 0
        download.downloadedSegmentIndices.removeAll()
        download.concurrentDownloads = 1

        let folderPath = Self.folderPath(for: download)
        let destDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Download the file with byte progress. Non-HLS direct downloads do not
        // have segment counts, so URLSession's byte counts are the only useful
        // progress signal here.
        let (tempURL, response) = try await Self.downloadWithRetry(from: url, resumeData: download.resumeData) { _, totalBytesWritten, totalBytesExpected in
            let fileProgress = Self.byteProgress(totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpected)
            Task { @MainActor in
                download.progress = fileProgress
                self.broadcastProgressIfNeeded()
            }
        } onResumeData: { resumeData in
            Task { @MainActor in
                download.resumeData = resumeData
                self.saveDownloads()
            }
        }
        try Task.checkCancellation()
        if let finalUrl = response.url, TorrentioService.isFailedAccessURL(finalUrl.absoluteString) {
            StreamifyLogger.log("DownloadManager: Torrentio failed-access file detected at \(finalUrl.absoluteString)")
            try? FileManager.default.removeItem(at: tempURL)
            throw ImportError.accessDenied
        }

        let fileName = Self.uniqueDirectVideoFileName(for: download, sourceURL: url)

        let destURL = destDir.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        download.localFileNameOverride = fileName
        download.resumeData = nil

        // Download thumbnail — for episodes, skip (series thumbnail is in the root folder);
        // for movies, download if not already present.
        let contentMeta = download.contentMetadata
        if download.episodeIndex == nil {
            let thumbUrl = contentMeta?.thumbnail
            if let thumbUrl = thumbUrl, thumbUrl.hasPrefix("http"), let url = URL(string: thumbUrl) {
                _ = try? await downloadThumbnail(download: download, from: url, to: destDir)
            }
        }

        // Check for cancellation before updating progress
        try Task.checkCancellation()

        await MainActor.run {
            download.progress = 1.0
            self.saveDownloads()
            self.objectWillChange.send()  // Force UI update for 100% completion
        }
    }

    // MARK: - Download HLS stream

    private func downloadHLSStream(download: DownloadItem, url: URL) async throws {
        let folderPath = Self.folderPath(for: download)
        let destDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Download thumbnail — for episodes, skip (series thumbnail is in the root folder);
        // for movies, download if not already present.
        if download.episodeIndex == nil {
            let movieThumbUrl = download.contentMetadata?.thumbnail
            if let thumbUrl = movieThumbUrl, thumbUrl.hasPrefix("http"), let thumbURL = URL(string: thumbUrl) {
                _ = try? await downloadThumbnail(download: download, from: thumbURL, to: destDir)
            }
        }

        // Check if cancelled before fetching master playlist
        try Task.checkCancellation()

        // Fetch master playlist (use VidLink referer if this is a VidLink download)
        let needsProxyHeaders = download.tmdbId != nil
        let (masterData, _) = try await fetchData(from: url)
        try Task.checkCancellation()

        guard let masterContent = String(data: masterData, encoding: .utf8) else {
            throw ImportError.downloadFailed
        }

        // Validate the master playlist is actual HLS content, not an HTML error page
        if !masterContent.contains("#EXTM3U") {
            if needsProxyHeaders {
                StreamifyLogger.log("DownloadManager: Master playlist is not valid HLS content (VidLink rate-limited) — triggering retry")
                throw ImportError.rateLimitPauseAndResume
            }
            StreamifyLogger.log("DownloadManager: Master playlist is not valid HLS content")
            throw ImportError.downloadFailed
        }

        let variants = downloadableHLSVariants(from: masterContent)

        // Use selectedBandwidth if provided (from quality picker), otherwise use quality enum
        let selectedBandwidth = preferredBandwidth(for: download, variants: variants)
        let selectedVariant = try await loadSelectedHLSVariant(
            masterContent: masterContent,
            sourceURL: url,
            variants: variants,
            selectedBandwidth: selectedBandwidth
        )
        let bestVariant = selectedVariant.variant
        let variantURL = selectedVariant.url
        let variantContent = selectedVariant.content

        download.selectedResolution = bestVariant.resolution
        download.selectedVideoRange = bestVariant.videoRange
        await MainActor.run { self.saveDownloads() }
        
        // Validate the playlist is actually HLS content, not an HTML error page
        if !variantContent.contains("#EXTM3U") && !variantContent.contains("#EXTINF") {
            if needsProxyHeaders {
                StreamifyLogger.log("DownloadManager: Variant playlist is not valid HLS content (VidLink rate-limited) — triggering retry")
                throw ImportError.rateLimitPauseAndResume
            }
            StreamifyLogger.log("DownloadManager: Variant playlist is not valid HLS content")
            throw ImportError.downloadFailed
        }

        // Parse variant playlist for segments and fMP4 initialization segment
        let mediaPlaylist = HLSManifestParser.parseMediaPlaylist(from: variantContent)
        let segments = mediaPlaylist.segments.map(\.uri)
        let segmentDurations = mediaPlaylist.segments.map(\.duration)
        let initSegmentURI = mediaPlaylist.initSegmentURI

        // Download all segments - use quality-named subfolder with download UUID for uniqueness
        let qualitySubdir: String
        let segmentsDirName: String
        if let qName = download.qualityName, !qName.isEmpty {
            qualitySubdir = Self.qualitySubdirName(qualityName: qName, downloadId: download.id, episodeIndex: download.episodeIndex)
            segmentsDirName = "segments"
        } else {
            qualitySubdir = ""
            segmentsDirName = download.episodeIndex.map { "segments_ep\($0)" } ?? "segments"
        }
        let videoDir = qualitySubdir.isEmpty ? destDir : destDir.appendingPathComponent(qualitySubdir)
        let segmentsDir = videoDir.appendingPathComponent(segmentsDirName)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        // Download fMP4 initialization segment if present (required for .m4s playback)
        // Uses VidLink rate-limit-aware fetch if the download is from VidLink
        var localInitSegmentName: String? = nil
        if let initURI = initSegmentURI,
           let initURL = resolveSegmentURL(initURI, baseURL: url, variantURL: variantURL) {
            let (initData, _): (Data, URLResponse)
            if needsProxyHeaders {
                let initHandler = VidLinkRateLimitHandler()
                (initData, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                    from: initURL, rateLimitHandler: initHandler)
            } else {
                (initData, _) = try await fetchData(from: initURL)
            }
            try Task.checkCancellation()
            let initExt = initURL.pathExtension.isEmpty ? "mp4" : initURL.pathExtension
            let initSegName = "init.\(initExt)"
            localInitSegmentName = initSegName
            let initPath = segmentsDir.appendingPathComponent(initSegName)
            try initData.write(to: initPath)
            StreamifyLogger.log("Downloaded fMP4 init segment: \(initSegName) from \(initURL)")
        }

        // Set total segments for progress tracking
        download.totalSegments = segments.count

        // Resolve all segment URLs into an array (Sendable-safe for TaskGroup)
        let resolvedSegmentURLs: [URL] = segments.enumerated().compactMap { (index, segmentURL) -> URL? in
            resolveSegmentURL(segmentURL, baseURL: url, variantURL: variantURL)
        }

        guard resolvedSegmentURLs.count == segments.count else {
            throw ImportError.downloadFailed
        }

        // Download segments using TaskGroup with actor for thread safety
        // VidLink downloads use same concurrency as non-VidLink; rate-limit backoff is coordinated via VidLinkRateLimitHandler
        let concurrentCount = effectiveConcurrentDownloadCount(for: download)

        // Track segment extensions for playlist creation
        var segmentExtensions: [String?] = Array(repeating: nil, count: segments.count)
        let indexTracker = SegmentIndexTracker()
        let rateLimitHandler = VidLinkRateLimitHandler()

        try await withThrowingTaskGroup(of: (index: Int, ext: String).self) { group in
            // Add initial tasks up to concurrent limit
            for _ in 0..<min(concurrentCount, segments.count) {
                group.addTask {
                    let index = await indexTracker.getNextIndex()

                    // Check for cancellation
                    try Task.checkCancellation()

                    let segmentURLResolved = resolvedSegmentURLs[index]

                    do {
                        let (data, _): (Data, URLResponse)
                        if needsProxyHeaders {
                            (data, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                                from: segmentURLResolved, rateLimitHandler: rateLimitHandler)
                        } else {
                            (data, _) = try await DownloadManager.fetchDataStatic(from: segmentURLResolved)
                        }
                        try Task.checkCancellation()

                        // Determine extension
                        let originalExtension = segmentURLResolved.pathExtension.isEmpty ? "ts" : segmentURLResolved.pathExtension
                        let segmentFileName = String(format: "segment_%d.%@", index + 1, originalExtension)
                        let segmentPath = segmentsDir.appendingPathComponent(segmentFileName)
                        try data.write(to: segmentPath)

                        return (index, originalExtension)
                    } catch {
                        // Re-throw cancellation errors
                        if error is CancellationError {
                            throw error
                        }
                        StreamifyLogger.log("Failed to download segment \(index): \(error)")
                        throw error
                    }
                }
            }

            // Process completed tasks and add new ones
            for try await result in group {
                let (index, ext) = result
                segmentExtensions[index] = ext

                // Update progress
                await MainActor.run {
                    download.downloadedSegmentIndices.insert(index)
                    download.progress = Double(download.downloadedSegmentIndices.count) / Double(segments.count)
                    self.saveDownloads()
                    self.broadcastProgressIfNeeded()
                }

                // Add more tasks if there are remaining segments
                let currentIndex = await indexTracker.currentIndex()

                if currentIndex < segments.count {
                    group.addTask {
                        let segmentIndex = await indexTracker.getNextIndex()

                        try Task.checkCancellation()

                        let segmentURLResolved = resolvedSegmentURLs[segmentIndex]

                        do {
                            let (data, _): (Data, URLResponse)
                            if needsProxyHeaders {
                                (data, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                                    from: segmentURLResolved, rateLimitHandler: rateLimitHandler)
                            } else {
                                (data, _) = try await DownloadManager.fetchDataStatic(from: segmentURLResolved)
                            }
                            try Task.checkCancellation()

                            let originalExtension = segmentURLResolved.pathExtension.isEmpty ? "ts" : segmentURLResolved.pathExtension
                            let segmentFileName = String(format: "segment_%d.%@", segmentIndex + 1, originalExtension)
                            let segmentPath = segmentsDir.appendingPathComponent(segmentFileName)
                            try data.write(to: segmentPath)

                            return (segmentIndex, originalExtension)
                        } catch {
                            if error is CancellationError {
                                throw error
                            }
                            StreamifyLogger.log("Failed to download segment \(segmentIndex): \(error)")
                            throw error
                        }
                    }
                }
            }
        }

        // Fill in any missing extensions with default
        for i in 0..<segmentExtensions.count {
            if segmentExtensions[i] == nil {
                segmentExtensions[i] = resolvedSegmentURLs[i].pathExtension.isEmpty ? "ts" : resolvedSegmentURLs[i].pathExtension
            }
        }

        let finalSegmentExtensions = segmentExtensions.map { $0 ?? "ts" }

        // Create local m3u8 playlist with RELATIVE paths
        // AVPlayer requires relative paths for local HLS to work properly
        // Use VERSION:7 for fMP4 (with EXT-X-MAP), VERSION:6 for MPEG-TS
        let isFMP4 = localInitSegmentName != nil
        let hlsVersion = isFMP4 ? 7 : 6
        let maxSegmentDuration = Int(ceil(segmentDurations.max() ?? 10.0))
        var localPlaylist = "#EXTM3U\n"
        localPlaylist += "#EXT-X-VERSION:\(hlsVersion)\n"
        localPlaylist += "#EXT-X-TARGETDURATION:\(maxSegmentDuration)\n"
        localPlaylist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        localPlaylist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        localPlaylist += "#EXT-X-INDEPENDENT-SEGMENTS\n"

        // Include fMP4 initialization segment reference if present
        if let initName = localInitSegmentName {
            localPlaylist += "#EXT-X-MAP:URI=\"\(segmentsDirName)/\(initName)\"\n"
        }

        StreamifyLogger.log("Creating local m3u8 playlist at: \(videoDir.path)")
        StreamifyLogger.log("Segments directory: \(segmentsDirName)")
        StreamifyLogger.log("Number of segments: \(segmentDurations.count)")
        StreamifyLogger.log("fMP4 mode: \(isFMP4), init segment: \(localInitSegmentName ?? "none")")

        for (index, duration) in segmentDurations.enumerated() {
            localPlaylist += String(format: "#EXTINF:%.3f,\n", duration)
            // Use relative path - segments are in a subdirectory
            // Use the actual segment extension that was saved
            let segmentExt = index < finalSegmentExtensions.count ? finalSegmentExtensions[index] : "ts"
            localPlaylist += "\(segmentsDirName)/segment_\(index + 1).\(segmentExt)\n"
        }

        localPlaylist += "#EXT-X-ENDLIST\n"

        // When using quality subfolder, put m3u8 inside the subfolder as video.m3u8
        // Otherwise keep the old naming: episode_{N}.m3u8 or video.m3u8
        let fileName: String
        let localM3U8Path: URL
        if !qualitySubdir.isEmpty {
            fileName = "video.m3u8"
            localM3U8Path = videoDir.appendingPathComponent(fileName)
        } else {
            fileName = download.episodeIndex.map { "episode_\($0).m3u8" } ?? "video.m3u8"
            localM3U8Path = destDir.appendingPathComponent(fileName)
        }
        try localPlaylist.write(to: localM3U8Path, atomically: true, encoding: .utf8)

        let localVariantPath = qualitySubdir.isEmpty ? fileName : "\(qualitySubdir)/\(fileName)"
        writeLocalMasterPlaylist(
            sourceMaster: masterContent,
            selectedVariantURI: bestVariant.uri,
            selectedLocalVariantURI: localVariantPath,
            selectedBandwidth: bestVariant.bandwidth,
            selectedResolution: bestVariant.resolution,
            selectedVideoRange: bestVariant.videoRange,
            destDir: destDir,
            download: download
        )

        StreamifyLogger.log("M3U8 file written to: \(localM3U8Path.path)")
        StreamifyLogger.log("M3U8 file exists: \(FileManager.default.fileExists(atPath: localM3U8Path.path))")
        StreamifyLogger.log("M3U8 content preview: \(localPlaylist.prefix(500))")
    }

    /// Rebuild the canonical local master manifest after audio/subtitle metadata changes.
    /// `master.m3u8` is the app's local metadata surface for qualities and HLS renditions.
    func refreshLocalMasterPlaylist(metadataFolder: String, episode: EpisodeInfo? = nil) {
        LocalHLSMasterPlaylist.refresh(metadataFolder: metadataFolder, episode: episode)
    }

    func cleanupLocalContentFolderIfEmpty(metadataFolder: String, episode: EpisodeInfo? = nil) {
        let isLibraryRoot = isLibraryFolder(metadataFolder)
        let targetDir = localMasterDirectory(
            metadataFolder: metadataFolder,
            season: episode?.season,
            episode: episode?.episode
        )
        removeLocalMasterIfEmpty(in: targetDir)

        if FileManager.default.fileExists(atPath: targetDir.path),
           !hasLocalDownloadContent(in: targetDir),
           !(episode == nil && isLibraryRoot) {
            try? FileManager.default.removeItem(at: targetDir)
            StreamifyLogger.log("Cleanup: Removed local folder with no downloaded content: \(targetDir.path)")
        }

        guard episode != nil else { return }
        let seriesDir = ContentImportService.contentDirectoryURL.appendingPathComponent(metadataFolder)
        if FileManager.default.fileExists(atPath: seriesDir.path),
           !hasLocalDownloadContent(in: seriesDir),
           !isLibraryRoot {
            try? FileManager.default.removeItem(at: seriesDir)
            StreamifyLogger.log("Cleanup: Removed series folder with no downloaded content: \(seriesDir.path)")
        }
    }

    private func writeLocalMasterPlaylist(
        sourceMaster: String,
        selectedVariantURI: String,
        selectedLocalVariantURI: String,
        selectedBandwidth: Double,
        selectedResolution: String?,
        selectedVideoRange: String?,
        destDir: URL,
        download: DownloadItem
    ) {
        let metadataFolder = download.libraryContentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? download.libraryContentId
        let season = download.episodeIndex == nil ? nil : (download.seasonIndex ?? 1)
        let episode = download.episodeIndex
        LocalHLSMasterPlaylist.writeAfterVideoDownload(
            sourceMaster: sourceMaster,
            selectedVariantURI: selectedVariantURI,
            selectedLocalVariantURI: selectedLocalVariantURI,
            selectedBandwidth: selectedBandwidth,
            selectedResolution: selectedResolution,
            selectedVideoRange: selectedVideoRange,
            destDir: destDir,
            metadataFolder: metadataFolder,
            season: season,
            episode: episode,
            qualityName: download.qualityName
        )
    }

    private func isLocalMasterURI(_ uri: String) -> Bool {
        !uri.hasPrefix("http") && !uri.hasPrefix("/") && !uri.isEmpty
    }

    private func localMasterHasStreamEntries(_ master: String) -> Bool {
        var expectingURI = false
        for line in master.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                expectingURI = true
                continue
            }

            guard expectingURI, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if isLocalMasterURI(trimmed) {
                return true
            }
            expectingURI = false
        }
        return false
    }

    private func localMasterDirectory(metadataFolder: String, season: Int?, episode: Int?) -> URL {
        var url = ContentImportService.contentDirectoryURL.appendingPathComponent(metadataFolder)
        if let season, let episode {
            url = url.appendingPathComponent(Self.episodeSubfolder(season: season, episode: episode))
        }
        return url
    }

    private func removeLocalMasterIfEmpty(in directory: URL) {
        let masterPath = directory.appendingPathComponent("master.m3u8")
        guard FileManager.default.fileExists(atPath: masterPath.path),
              let content = try? String(contentsOf: masterPath, encoding: .utf8),
              !localMasterHasStreamEntries(content) else { return }
        try? FileManager.default.removeItem(at: masterPath)
        StreamifyLogger.log("Cleanup: Removed local master with no stream entries: \(masterPath.path)")
    }

    private func hasLocalDownloadContent(in directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if name == "metadata.json" ||
                name == "metadata.json.zlib" ||
                name.hasPrefix("thumbnail") ||
                name.hasPrefix("poster_thumbnail") {
                continue
            }

            if name == "master.m3u8" {
                guard let content = try? String(contentsOf: entry, encoding: .utf8),
                      localMasterHasStreamEntries(content) else { continue }
                return true
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if hasLocalDownloadContent(in: entry) {
                    return true
                }
                continue
            }

            let lowercased = name.lowercased()
            if lowercased.hasSuffix(".m3u8") ||
                lowercased.hasSuffix(".mp4") ||
                lowercased.hasSuffix(".mov") ||
                lowercased.hasSuffix(".m4v") ||
                lowercased.hasSuffix(".mkv") ||
                lowercased.hasSuffix(".webm") ||
                lowercased.hasSuffix(".ts") ||
                lowercased.hasSuffix(".m4s") ||
                lowercased.hasSuffix(".vtt") ||
                lowercased.hasSuffix(".srt") ||
                lowercased.hasSuffix(".ass") ||
                lowercased.hasSuffix(".ssa") ||
                lowercased.hasSuffix(".mp3") ||
                lowercased.hasSuffix(".m4a") ||
                lowercased.hasSuffix(".aac") ||
                lowercased.hasSuffix(".opus") ||
                lowercased.hasSuffix(".ogg") {
                return true
            }
        }

        return false
    }

    // MARK: - Download thumbnail

    private func downloadThumbnail(download: DownloadItem, from url: URL, to destDir: URL, name: String = "thumbnail") async throws -> String? {
        try Task.checkCancellation()

        let (tempURL, _) = try await Self.downloadWithRetry(from: url)
        try Task.checkCancellation()

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let thumbnailName = "\(name).\(ext)"
        let thumbnailURL = destDir.appendingPathComponent(thumbnailName)
        try FileManager.default.moveItem(at: tempURL, to: thumbnailURL)
        return thumbnailName
    }

    // MARK: - Single-track download helpers (shared by bulk downloads and player standalone downloads)

    /// Build the canonical local file name for a subtitle track download.
    static func subtitleFileName(for track: SubtitleTrack, prefix: String) -> String {
        let ext: String
        if let url = URL(string: track.source), !url.pathExtension.isEmpty {
            ext = url.pathExtension
        } else {
            ext = "vtt"
        }
        let fileName = "\(prefix)subtitle_\(track.language.lowercased().replacingOccurrences(of: " ", with: "_"))_\(track.trackId).\(ext)"
        return "subtitles/\(fileName)"
    }

    /// Build the canonical local file name for a single-file audio track download.
    static func audioFileName(for track: AudioTrack, prefix: String) -> String {
        let ext: String
        if let url = URL(string: track.source), !url.pathExtension.isEmpty {
            ext = url.pathExtension
        } else {
            ext = "mp3"
        }
        return "\(prefix)audio_\(track.language.lowercased().replacingOccurrences(of: " ", with: "_"))_\(track.trackId).\(ext)"
    }

    /// Download a single subtitle track to `destDir`.
    /// Returns the local file name on success. Throws on cancellation or network error.
    /// Returns `nil` when the file was invalid (HTML, too small) — callers should keep the remote track.
    func downloadSingleSubtitleTrack(
        track: SubtitleTrack,
        to destDir: URL,
        prefix: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String? {
        guard track.source.hasPrefix("http"), let url = URL(string: track.source) else { return nil }

        let fileName = Self.subtitleFileName(for: track, prefix: prefix)
        let destURL = destDir.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Skip if already on disk
        if FileManager.default.fileExists(atPath: destURL.path) {
            return fileName
        }

        let (tempURL, _) = try await Self.downloadWithRetry(from: url) { _, totalBytesWritten, totalBytesExpected in
            onProgress?(Self.byteProgress(totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpected))
        }
        try Task.checkCancellation()

        // Validate size
        let tempSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        if tempSize < 100 {
            try? FileManager.default.removeItem(at: tempURL)
            StreamifyLogger.log("Subtitle download too small (\(tempSize) bytes), skipping: \(track.language)")
            return nil
        }
        // Validate not HTML
        if let fileHandle = FileHandle(forReadingAtPath: tempURL.path) {
            defer { fileHandle.closeFile() }
            let headerData = fileHandle.readData(ofLength: 64)
            if let headerStr = String(data: headerData, encoding: .utf8)?.lowercased(),
               headerStr.contains("<!doctype") || headerStr.contains("<html") {
                try? FileManager.default.removeItem(at: tempURL)
                StreamifyLogger.log("Subtitle download is HTML, not subtitle: \(track.language)")
                return nil
            }
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        onProgress?(1.0)
        StreamifyLogger.log("Downloaded subtitle: \(track.language) -> \(fileName)")
        return fileName
    }

    /// Download a single audio track (single file, NOT HLS) to `destDir`.
    /// Returns the local file name on success. Throws on cancellation or network error.
    /// Returns `nil` when the file was invalid (HTML, too small).
    func downloadSingleAudioFile(
        track: AudioTrack,
        to destDir: URL,
        prefix: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String? {
        guard track.source.hasPrefix("http"), let url = URL(string: track.source) else { return nil }

        let fileName = Self.audioFileName(for: track, prefix: prefix)
        let destURL = destDir.appendingPathComponent(fileName)

        // Skip if already on disk
        if FileManager.default.fileExists(atPath: destURL.path) {
            return fileName
        }

        let (tempURL, response) = try await Self.downloadWithRetry(from: url) { _, totalBytesWritten, totalBytesExpected in
            onProgress?(Self.byteProgress(totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpected))
        }
        try Task.checkCancellation()

        // Validate content-type
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") {
            try? FileManager.default.removeItem(at: tempURL)
            StreamifyLogger.log("Audio download is HTML, not audio: \(track.language)")
            return nil
        }

        // Validate minimum size
        let tempSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        if tempSize < 1024 {
            try? FileManager.default.removeItem(at: tempURL)
            StreamifyLogger.log("Audio download too small (\(tempSize) bytes), likely not audio: \(track.language)")
            return nil
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        onProgress?(1.0)
        StreamifyLogger.log("Downloaded audio: \(track.language) -> \(fileName)")
        return fileName
    }

    // MARK: - Download HLS audio playlist with segments
    func downloadHLSAudioPlaylist(
        from playlistURL: URL, track: AudioTrack, to destDir: URL, prefix: String,
        download: DownloadItem?, downloadedCount: Int, totalToDownload: Int,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let lang = track.language.lowercased().replacingOccurrences(of: " ", with: "_")
        let audioDirName = "\(prefix)audio_\(lang)_\(track.trackId)"
        let audioDir = destDir.appendingPathComponent(audioDirName)
        let segmentsDirName = "segments"
        let segmentsDir = audioDir.appendingPathComponent(segmentsDirName)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        // Fetch the audio playlist
        let (playlistData, _) = try await fetchData(from: playlistURL)
        try Task.checkCancellation()

        guard let playlistContent = String(data: playlistData, encoding: .utf8) else {
            throw ImportError.downloadFailed
        }

        let baseURL = playlistURL.deletingLastPathComponent()
        let lines = playlistContent.components(separatedBy: "\n")

        // Parse segments and init segment from playlist
        var segmentURLs: [URL] = []
        var segmentDurations: [Double] = []
        var initSegmentURI: String?
        var currentDuration: Double = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect fMP4 init segment
            if trimmed.hasPrefix("#EXT-X-MAP:") {
                if let uriRange = trimmed.range(of: "URI=\"") {
                    let afterURI = trimmed[uriRange.upperBound...]
                    if let endQuote = afterURI.firstIndex(of: "\"") {
                        initSegmentURI = String(afterURI[..<endQuote])
                    }
                }
            }

            // Parse segment duration
            if trimmed.hasPrefix("#EXTINF:") {
                let durationStr = trimmed.replacingOccurrences(of: "#EXTINF:", with: "").replacingOccurrences(of: ",", with: "")
                currentDuration = Double(durationStr) ?? 0
            }

            // Collect segment URLs
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                let segURL: URL
                if trimmed.hasPrefix("http") {
                    segURL = URL(string: trimmed) ?? baseURL.appendingPathComponent(trimmed)
                } else {
                    segURL = baseURL.appendingPathComponent(trimmed)
                }
                segmentURLs.append(segURL)
                segmentDurations.append(currentDuration)
                currentDuration = 0
            }
        }

        // Download init segment if present
        var localInitName: String?
        if let initURI = initSegmentURI {
            let initURL: URL
            if initURI.hasPrefix("http") {
                initURL = URL(string: initURI) ?? baseURL.appendingPathComponent(initURI)
            } else {
                initURL = baseURL.appendingPathComponent(initURI)
            }
            let initExt = initURL.pathExtension.isEmpty ? "mp4" : initURL.pathExtension
            let initFileName = "init.\(initExt)"
            let initDest = segmentsDir.appendingPathComponent(initFileName)

            if !FileManager.default.fileExists(atPath: initDest.path) {
                let (initData, _) = try await DownloadManager.fetchDataStatic(from: initURL)
                try initData.write(to: initDest)
            }
            localInitName = initFileName
            StreamifyLogger.log("Downloaded HLS audio init segment: \(initFileName)")
        }

        // Download all segments
        let totalSegments = segmentURLs.count
        var segmentExtensions: [String] = []

        for (index, segURL) in segmentURLs.enumerated() {
            try Task.checkCancellation()

            let segExt = segURL.pathExtension.isEmpty ? "m4s" : segURL.pathExtension
            segmentExtensions.append(segExt)
            let segFileName = "segment_\(index + 1).\(segExt)"
            let segDest = segmentsDir.appendingPathComponent(segFileName)

            // Skip if already downloaded
            if FileManager.default.fileExists(atPath: segDest.path) {
                continue
            }

            let (segData, _) = try await DownloadManager.fetchDataStatic(from: segURL)
            try segData.write(to: segDest)

            // Update progress within audio stage
            let segProgress = Double(index + 1) / Double(max(totalSegments, 1))
            if let dl = download {
                let totalProgress = (Double(downloadedCount) + segProgress) / Double(max(totalToDownload, 1))
                await MainActor.run {
                    dl.progress = totalProgress
                    self.broadcastProgressIfNeeded()
                }
            }
            onProgress?(segProgress)
        }

        StreamifyLogger.log("Downloaded \(totalSegments) HLS audio segments for \(track.language)")

        // Create local audio m3u8 playlist
        let isFMP4 = localInitName != nil
        let hlsVersion = isFMP4 ? 7 : 6
        let maxDuration = Int(ceil(segmentDurations.max() ?? 10.0))
        var localPlaylist = "#EXTM3U\n"
        localPlaylist += "#EXT-X-VERSION:\(hlsVersion)\n"
        localPlaylist += "#EXT-X-TARGETDURATION:\(maxDuration)\n"
        localPlaylist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        localPlaylist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        localPlaylist += "#EXT-X-INDEPENDENT-SEGMENTS\n"

        if let initName = localInitName {
            localPlaylist += "#EXT-X-MAP:URI=\"\(segmentsDirName)/\(initName)\"\n"
        }

        for (index, duration) in segmentDurations.enumerated() {
            localPlaylist += String(format: "#EXTINF:%.3f,\n", duration)
            let segExt = index < segmentExtensions.count ? segmentExtensions[index] : "m4s"
            localPlaylist += "\(segmentsDirName)/segment_\(index + 1).\(segExt)\n"
        }
        localPlaylist += "#EXT-X-ENDLIST\n"

        let audioM3U8Name = "\(audioDirName).m3u8"
        let audioM3U8Path = audioDir.appendingPathComponent(audioM3U8Name)
        try localPlaylist.write(to: audioM3U8Path, atomically: true, encoding: .utf8)

        StreamifyLogger.log("Created local HLS audio playlist: \(audioM3U8Path.path)")

        // Return relative path from destDir: e.g., "audio_russian/audio_russian.m3u8"
        return "\(audioDirName)/\(audioM3U8Name)"
    }

    // MARK: - Add to library after download

    /// Merge new subtitle tracks with existing ones, preserving locally-downloaded tracks.
    /// When a track exists locally in `existing` but has an HTTP source in `new`, the local
    /// version is kept. Also preserves local tracks not present in `new` at all.
    private func mergeSubtitleTracks(new: [SubtitleTrack]?, existing: [SubtitleTrack]?) -> [SubtitleTrack]? {
        guard let new = new else { return existing }
        guard let existing = existing else { return new }
        var result = new
        for track in existing {
            if let index = result.firstIndex(where: { $0.trackId == track.trackId }) {
                if !track.source.isEmpty && !track.source.hasPrefix("http") && result[index].source.hasPrefix("http") {
                    result[index] = track
                }
                continue
            }
            if result.contains(where: { !$0.source.isEmpty && $0.source == track.source }) {
                continue
            }
            result.append(track)
        }
        return result
    }

    /// Merge new audio tracks with existing ones, preserving locally-downloaded tracks.
    /// When a track exists locally in `existing` but has an HTTP source in `new`, the local
    /// version is kept. Also preserves local tracks not present in `new` at all.
    private func mergeAudioTracks(new: [AudioTrack]?, existing: [AudioTrack]?) -> [AudioTrack]? {
        guard let new = new else { return existing }
        guard let existing = existing else { return new }
        var result = new
        for track in existing {
            if track.source.isEmpty && !new.isEmpty {
                continue
            }
            if let index = result.firstIndex(where: { $0.trackId == track.trackId }) {
                if !track.source.isEmpty && !track.source.hasPrefix("http") && result[index].source.hasPrefix("http") {
                    result[index] = track
                }
                continue
            }
            if result.contains(where: { !$0.source.isEmpty && $0.source == track.source }) {
                continue
            }
            result.append(track)
        }
        return result
    }

    private func addToLibraryIfNeeded(_ download: DownloadItem, allEpisodes: [EpisodeInfo]? = nil) async {
        let library = ContentImportService.loadLibrary()

        // Determine local video file path
        var localFile: String? = nil
        var localHlsUrl: String? = nil
        let videoComplete = download.status == .completed

        if videoComplete {
            if download.videoUrl.contains(".m3u8") {
                if let qName = download.qualityName, !qName.isEmpty {
                    // Quality-based subfolder with UUID: ep1_video_1080p_uuid/video.m3u8
                    let subdir = Self.qualitySubdirName(qualityName: qName, downloadId: download.id, episodeIndex: download.episodeIndex)
                    localHlsUrl = "\(subdir)/video.m3u8"
                } else if let episodeIndex = download.episodeIndex {
                    localHlsUrl = "episode_\(episodeIndex).m3u8"
                } else {
                    localHlsUrl = "video.m3u8"
                }
            } else {
                if let override = download.localFileNameOverride {
                    if override.hasSuffix(".m3u8") {
                        localHlsUrl = override
                    } else {
                        localFile = override
                    }
                } else if let episodeIndex = download.episodeIndex {
                    if let sourceURL = URL(string: download.videoUrl) {
                        localFile = Self.uniqueDirectVideoFileName(for: download, sourceURL: sourceURL)
                    } else {
                        let ext = Self.fileExtension(for: download.videoUrl) ?? "mp4"
                        localFile = "episode_\(episodeIndex)_\(Self.shortDownloadId(download.id)).\(ext)"
                    }
                } else {
                    if let sourceURL = URL(string: download.videoUrl) {
                        localFile = Self.uniqueDirectVideoFileName(for: download, sourceURL: sourceURL)
                    } else {
                        localFile = download.videoUrl.split(separator: "/").last.map(String.init)
                    }
                }
            }
        }

        // Build DownloadedVideoQuality entry when a named quality was downloaded,
        // so the player's quality picker can show the source badge (e.g., "VidLink")
        let newDownloadedQuality: DownloadedVideoQuality? = {
            guard let qName = download.qualityName, !qName.isEmpty,
                  let localSource = localHlsUrl ?? localFile else { return nil }
            // Detect HDR from VIDEO-RANGE attribute stored during download
            let isHDR = Self.isHDRVideoRange(download.selectedVideoRange) ||
                Self.downloadMetadataSuggestsHDR(download, localSource: localSource)
            return DownloadedVideoQuality(
                name: qName,
                bandwidth: download.selectedBandwidth ?? 0,
                resolution: download.selectedResolution,
                isHDR: isHDR,
                localSource: localSource,
                sourceName: download.sourceName,
                sourceUrl: download.videoUrl
            )
        }()

        // Only propagate qualityName when the video download completed.
        let effectiveQualityName: String? = videoComplete ? download.qualityName : nil

        // Check for local subtitle files on disk
        let updatedSubtitles: [SubtitleTrack]? = {
            // Fallback: check if local subtitle files exist on disk (e.g., for resumed downloads)
            let existingContent = library.first(where: { $0.id == download.libraryContentId })
            let tracks = existingContent?.metadata.subtitles ?? download.contentMetadata?.subtitles
            let subtitles = tracks ?? []
            if subtitles.isEmpty {
                return download.generatedSubtitleTracks
            }
            let prefix = download.episodeIndex.map { "ep\($0)_" } ?? ""
            let folderPath: String
            if let fp = existingContent?.folderPath, !fp.isEmpty {
                folderPath = fp
            } else {
                folderPath = Self.folderPath(for: download)
            }
            let destDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)
            let existingOrDownloaded = subtitles.map { track in
                guard track.source.hasPrefix("http") else { return track }
                let fileName = Self.subtitleFileName(for: track, prefix: prefix)
                let localPath = destDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localPath.path) {
                    return SubtitleTrack(language: track.language, source: fileName, languageId: track.languageId, trackId: track.trackId, sourceName: track.sourceName)
                }
                return track
            }
            return mergeSubtitleTracks(new: download.generatedSubtitleTracks, existing: existingOrDownloaded)
        }()

        // Check for local audio files on disk
        let updatedAudioTracks: [AudioTrack]? = {
            let existingContent = library.first(where: { $0.id == download.libraryContentId })
            let tracks = existingContent?.metadata.audioTracks ?? download.contentMetadata?.audioTracks
            let audioTracks = tracks ?? []
            if audioTracks.isEmpty {
                return download.generatedAudioTracks
            }
            let prefix = download.episodeIndex.map { "ep\($0)_" } ?? ""
            let folderPath: String
            if let fp = existingContent?.folderPath, !fp.isEmpty {
                folderPath = fp
            } else {
                folderPath = Self.folderPath(for: download)
            }
            let destDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)
            let existingOrDownloaded = audioTracks.map { track in
                guard !track.isEmbedded else { return track }
                guard track.source.hasPrefix("http") else { return track }
                let ext: String
                if let url = URL(string: track.source), !url.pathExtension.isEmpty {
                    ext = url.pathExtension
                } else {
                    ext = "mp3"
                }
                let fileName = "\(prefix)audio_\(track.language.lowercased().replacingOccurrences(of: " ", with: "_"))_\(track.trackId).\(ext)"
                let localPath = destDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localPath.path) {
                    return AudioTrack(language: track.language, source: fileName, isSpatial: track.isSpatial, languageId: track.languageId, name: track.name, trackId: track.trackId, sourceName: track.sourceName)
                }
                return track
            }
            return mergeAudioTracks(new: download.generatedAudioTracks, existing: existingOrDownloaded)
        }()

        // Check if this is an episode download (has _ep in contentId)
        if download.episodeIndex != nil && download.contentId.contains("_ep") {
            let seriesId = download.contentId.components(separatedBy: "_ep").first ?? download.contentId
            let safeId = seriesId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesId
            let season = download.seasonIndex ?? 1

            // Check if series already exists in library
            if let existingContent = library.first(where: { $0.id == seriesId }) {
                let metadata = existingContent.metadata

                // Always prefer fresh metadata episodes over stale allEpisodes to preserve
                // tracks downloaded between stages (e.g., subtitle downloaded in stage 2
                // must not be lost when video completes in stage 3).
                // Use allEpisodes only when fresh metadata has no episodes at all.
                let freshEpisodes = metadata.episodes ?? []
                var episodes = freshEpisodes.isEmpty ? (allEpisodes ?? []) : freshEpisodes

                if let episodeIndex = download.episodeIndex,
                   let episodeIdx = episodes.firstIndex(where: { $0.season == season && $0.episode == episodeIndex }) {
                    let currentEpisode = episodes[episodeIdx]

                    episodes[episodeIdx] = currentEpisode.copying(
                        localFile: .some(localHlsUrl ?? localFile ?? currentEpisode.localFile),
                        qualityName: .some(effectiveQualityName ?? currentEpisode.qualityName),
                        subtitles: .some(mergeSubtitleTracks(new: updatedSubtitles, existing: currentEpisode.subtitles)),
                        audioTracks: .some(mergeAudioTracks(new: updatedAudioTracks, existing: currentEpisode.audioTracks)),
                        downloadedVideoQualities: .some(mergeDownloadedQuality(newDownloadedQuality, into: currentEpisode.downloadedVideoQualities))
                    )
                } else {
                    let newEpisode = EpisodeInfo(
                        season: download.seasonIndex ?? 1,
                        episode: download.episodeIndex ?? 1,
                        title: download.episodeTitle ?? "Episode \(download.episodeIndex ?? 1)",
                        description: "",
                        thumbnailUrl: nil,
                        file: localFile,
                        hlsUrl: localHlsUrl,
                        localFile: localHlsUrl ?? localFile,
                        intro: nil,
                        introDuration: nil,
                        end: nil,
                        qualityName: effectiveQualityName,
                        subtitles: updatedSubtitles,
                        audioTracks: updatedAudioTracks,
                        downloadedVideoQualities: mergeDownloadedQuality(newDownloadedQuality, into: nil)
                    )
                    episodes.append(newEpisode)
                }

                // Also update episode within seasons if present
                var updatedSeasons = metadata.seasons
                if let episodeIndex = download.episodeIndex, var seasons = updatedSeasons {
                    for sIdx in seasons.indices {
                        if var sEpisodes = seasons[sIdx].episodes, seasons[sIdx].season == season,
                           let eIdx = sEpisodes.firstIndex(where: { $0.episode == episodeIndex }) {
                            let currentEp = sEpisodes[eIdx]
                            sEpisodes[eIdx] = currentEp.copying(
                                localFile: .some(localHlsUrl ?? localFile ?? currentEp.localFile),
                                qualityName: .some(effectiveQualityName ?? currentEp.qualityName),
                                subtitles: .some(mergeSubtitleTracks(new: updatedSubtitles, existing: currentEp.subtitles)),
                                audioTracks: .some(mergeAudioTracks(new: updatedAudioTracks, existing: currentEp.audioTracks)),
                                downloadedVideoQualities: .some(mergeDownloadedQuality(newDownloadedQuality, into: currentEp.downloadedVideoQualities))
                            )
                            seasons[sIdx] = SeasonInfo(
                                season: seasons[sIdx].season,
                                title: seasons[sIdx].title,
                                thumbnailUrl: seasons[sIdx].thumbnailUrl,
                                episodes: sEpisodes
                            )
                        }
                    }
                    updatedSeasons = seasons
                }

                let updatedMetadata = metadata.copying(
                    seasons: .some(updatedSeasons),
                    episodes: .some(episodes)
                )

                let updatedContent = SavedContent(
                    id: existingContent.id,
                    metadata: updatedMetadata,
                    folderPath: existingContent.folderPath.isEmpty ? safeId : existingContent.folderPath,
                    dateAdded: existingContent.dateAdded
                )

                ContentImportService.addToLibrary(updatedContent)

                await MainActor.run {
                    self.libraryRefreshNeeded = true
                }
                return
            }

            // Series doesn't exist in library - load metadata from content folder
            let existingMetadata = ContentImportService.loadMetadata(from: safeId)
            // Always prefer fresh metadata episodes over stale allEpisodes
            let freshEps = existingMetadata?.episodes ?? []
            var episodes: [EpisodeInfo] = freshEps.isEmpty ? (allEpisodes ?? []) : freshEps

            if let episodeIndex = download.episodeIndex {
                if let episodeIdx = episodes.firstIndex(where: { $0.season == season && $0.episode == episodeIndex }) {
                    let currentEpisode = episodes[episodeIdx]
                    episodes[episodeIdx] = currentEpisode.copying(
                        file: .some(localFile ?? currentEpisode.file),
                        hlsUrl: .some(localHlsUrl ?? currentEpisode.hlsUrl),
                        localFile: .some(localHlsUrl ?? localFile),
                        qualityName: .some(effectiveQualityName ?? currentEpisode.qualityName),
                        subtitles: .some(mergeSubtitleTracks(new: updatedSubtitles, existing: currentEpisode.subtitles)),
                        audioTracks: .some(mergeAudioTracks(new: updatedAudioTracks, existing: currentEpisode.audioTracks)),
                        downloadedVideoQualities: .some(mergeDownloadedQuality(newDownloadedQuality, into: currentEpisode.downloadedVideoQualities))
                    )
                } else {
                    let newEpisode = EpisodeInfo(
                        season: download.seasonIndex ?? 1,
                        episode: episodeIndex,
                        title: download.episodeTitle ?? "Episode \(episodeIndex)",
                        description: "",
                        thumbnailUrl: nil,
                        file: localFile,
                        hlsUrl: localHlsUrl,
                        localFile: localHlsUrl ?? localFile,
                        intro: nil,
                        introDuration: nil,
                        end: nil,
                        qualityName: effectiveQualityName,
                        subtitles: updatedSubtitles,
                        audioTracks: updatedAudioTracks,
                        downloadedVideoQualities: mergeDownloadedQuality(newDownloadedQuality, into: nil)
                    )
                    episodes.append(newEpisode)
                }
            }

            episodes.sort { $0.episode < $1.episode }

            // Also update episode within seasons if present
            var updatedSeasons = existingMetadata?.seasons
            if let episodeIndex = download.episodeIndex, var seasons = updatedSeasons {
                for sIdx in seasons.indices {
                    if var sEpisodes = seasons[sIdx].episodes, seasons[sIdx].season == season,
                       let eIdx = sEpisodes.firstIndex(where: { $0.episode == episodeIndex }) {
                        let currentEp = sEpisodes[eIdx]
                        sEpisodes[eIdx] = currentEp.copying(
                            localFile: .some(localHlsUrl ?? localFile ?? currentEp.localFile),
                            qualityName: .some(effectiveQualityName ?? currentEp.qualityName),
                            subtitles: .some(mergeSubtitleTracks(new: updatedSubtitles, existing: currentEp.subtitles)),
                            audioTracks: .some(mergeAudioTracks(new: updatedAudioTracks, existing: currentEp.audioTracks)),
                            downloadedVideoQualities: .some(mergeDownloadedQuality(newDownloadedQuality, into: currentEp.downloadedVideoQualities))
                        )
                        seasons[sIdx] = SeasonInfo(
                            season: seasons[sIdx].season,
                            title: seasons[sIdx].title,
                            thumbnailUrl: seasons[sIdx].thumbnailUrl,
                            episodes: sEpisodes
                        )
                    }
                }
                updatedSeasons = seasons
            }

            let metadata = ContentMetadata(
                id: seriesId,
                title: existingMetadata?.title ?? seriesId,
                description: existingMetadata?.description ?? "",
                type: .series,
                genre: existingMetadata?.genre,
                genres: existingMetadata?.genres,
                thumbnail: existingMetadata?.thumbnail,
                posterThumbnail: existingMetadata?.posterThumbnail,
                file: nil,
                hlsUrl: existingMetadata?.hlsUrl ?? (download.videoUrl.contains(".m3u8") ? download.videoUrl : nil),
                intro: nil,
                introDuration: nil,
                end: nil,
                seasons: updatedSeasons,
                episodes: episodes,
                subtitles: existingMetadata?.subtitles,
                audioTracks: existingMetadata?.audioTracks,
                embeddedAudioDisabled: existingMetadata?.embeddedAudioDisabled ?? false,
                downloadedVideoQualities: existingMetadata?.downloadedVideoQualities
            )

            let savedContent = SavedContent(
                id: seriesId,
                metadata: metadata,
                folderPath: safeId,
                dateAdded: Date()
            )

            ContentImportService.addToLibrary(savedContent)

            await MainActor.run {
                self.libraryRefreshNeeded = true
            }
            return
        }

        // For movies (no episodeIndex) or other content
        let safeId = download.contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? download.contentId
        let folderPath = safeId

        // Check if content already exists - update with local file path if needed
        if let existingContent = library.first(where: { $0.id == download.contentId }) {
            let updatedMetadata = existingContent.metadata.copying(
                file: .some(localFile ?? existingContent.metadata.file),
                hlsUrl: .some(localHlsUrl ?? existingContent.metadata.hlsUrl),
                downloadedQuality: .some(effectiveQualityName ?? existingContent.metadata.downloadedQuality),
                subtitles: .some(mergeSubtitleTracks(new: updatedSubtitles, existing: existingContent.metadata.subtitles)),
                audioTracks: .some(mergeAudioTracks(new: updatedAudioTracks, existing: existingContent.metadata.audioTracks)),
                downloadedVideoQualities: .some(mergeDownloadedQuality(newDownloadedQuality, into: existingContent.metadata.downloadedVideoQualities))
            )

            let updatedFolderPath = existingContent.folderPath.isEmpty ? folderPath : existingContent.folderPath

            let updatedContent = SavedContent(
                id: existingContent.id,
                metadata: updatedMetadata,
                folderPath: updatedFolderPath,
                dateAdded: existingContent.dateAdded
            )

            ContentImportService.addToLibrary(updatedContent)

            await MainActor.run {
                self.libraryRefreshNeeded = true
            }
            return
        }

        // Create new content entry - load metadata from content folder
        let existingMetadata = ContentImportService.loadMetadata(from: folderPath)
        let metadata = ContentMetadata(
            id: download.contentId,
            title: existingMetadata?.title ?? download.contentId,
            description: existingMetadata?.description ?? "",
            type: existingMetadata?.type ?? (download.episodeIndex != nil ? .series : .movie),
            genre: existingMetadata?.genre,
            genres: existingMetadata?.genres,
            thumbnail: existingMetadata?.thumbnail,
            posterThumbnail: existingMetadata?.posterThumbnail,
            file: localFile,
            hlsUrl: localHlsUrl,
            intro: existingMetadata?.intro,
            introDuration: existingMetadata?.introDuration,
            end: existingMetadata?.end,
            episodes: nil,
            downloadedQuality: effectiveQualityName,
            subtitles: mergeSubtitleTracks(new: updatedSubtitles, existing: existingMetadata?.subtitles),
            audioTracks: mergeAudioTracks(new: updatedAudioTracks, existing: existingMetadata?.audioTracks),
            embeddedAudioDisabled: existingMetadata?.embeddedAudioDisabled ?? false,
            downloadedVideoQualities: mergeDownloadedQuality(newDownloadedQuality, into: existingMetadata?.downloadedVideoQualities)
        )

        let savedContent = SavedContent(
            id: download.contentId,
            metadata: metadata,
            folderPath: folderPath,
            dateAdded: Date()
        )

        ContentImportService.addToLibrary(savedContent)

        await MainActor.run {
            self.libraryRefreshNeeded = true
        }
    }

    /// Merge a new DownloadedVideoQuality into an existing list, avoiding duplicates by localSource.
    private func mergeDownloadedQuality(_ newQuality: DownloadedVideoQuality?, into existing: [DownloadedVideoQuality]?) -> [DownloadedVideoQuality]? {
        guard let nq = newQuality else { return existing }
        var list = existing ?? []
        // Replace only the exact stored entry. Same-name/source qualities can be
        // different releases/files and must stay as separate picker rows.
        if let idx = list.firstIndex(where: {
            $0.qualityId == nq.qualityId || $0.localSource == nq.localSource
        }) {
            list[idx] = nq
        } else {
            list.append(nq)
        }
        return list
    }

    // MARK: - Cancel download

    func cancelDownload(_ download: DownloadItem) {
        StreamifyLogger.log("DownloadManager: Cancelling download \(download.id) - \(download.displayTitle)")

        NetworkRequestManager.shared.cancelAll(for: download.id)

        // Cancel the task if it's running - this cancels the Swift Task
        // which will properly cancel any ongoing URLSession data tasks
        if let task = downloadTasks[download.id] {
            task.cancel()
            downloadTasks.removeValue(forKey: download.id)
            downloadTaskTokens.removeValue(forKey: download.id)
        }

        // Delete only the downloaded segments/temp files, NOT the entire folder
        deleteDownloadedSegmentsOnly(for: download)
        cleanupOrphanedFiles(for: download)
        download.resumeData = nil

        // Remove the download from the array entirely
        downloads.removeAll { $0.id == download.id }
        saveDownloads()

        StreamifyLogger.log("DownloadManager: Download cancelled and all network connections terminated")

        // Force UI update
        objectWillChange.send()

        // Start next queued download
        processQueue()
    }

    // MARK: - Delete only downloaded segments (preserve folder and metadata)

    /// Check if OTHER downloads (besides `excludingId`) share the same content folder and are still
    /// active, queued, paused, or pending — meaning the folder must not be deleted.
    private func hasOtherDownloadsForSameContent(_ download: DownloadItem) -> Bool {
        let folderPath = Self.folderPath(for: download)
        let keepStatuses: Set<DownloadStatus> = [.downloading, .queued, .paused, .pending, .completed]
        return downloads.contains { other in
            other.id != download.id &&
            Self.folderPath(for: other) == folderPath &&
            keepStatuses.contains(other.status)
        }
    }

    private func isLibraryFolder(_ folderPath: String) -> Bool {
        let normalized = folderPath.split(separator: "/").first.map(String.init) ?? folderPath
        return ContentImportService.loadLibrary().contains { content in
            content.folderPath == normalized || content.folderPath == folderPath
        }
    }

    private func deleteDownloadedSegmentsOnly(for download: DownloadItem) {
        let folderPath = Self.folderPath(for: download)
        let contentDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)

        guard FileManager.default.fileExists(atPath: contentDir.path) else { return }

        // For HLS downloads with quality name, segments are in a quality subdir
        if let qName = download.qualityName, !qName.isEmpty {
            let qualitySubdir = Self.qualitySubdirName(qualityName: qName, downloadId: download.id, episodeIndex: download.episodeIndex)
            let qualityDir = contentDir.appendingPathComponent(qualitySubdir)

            // Delete the entire quality directory (contains segments/)
            if FileManager.default.fileExists(atPath: qualityDir.path) {
                do {
                    try FileManager.default.removeItem(at: qualityDir)
                } catch {
                    StreamifyLogger.log("Failed to delete quality dir: \(error)")
                }
            }
        }

        // Only delete non-quality segments/m3u8 if no other downloads share this content folder
        if !hasOtherDownloadsForSameContent(download) {
            // Also delete the non-quality segments directory (for downloads without quality name)
            let segmentsDirName = download.episodeIndex.map { "segments_ep\($0)" } ?? "segments"
            let segmentsDir = contentDir.appendingPathComponent(segmentsDirName)

            // Delete segments directory
            if FileManager.default.fileExists(atPath: segmentsDir.path) {
                do {
                    try FileManager.default.removeItem(at: segmentsDir)
                } catch {
                    StreamifyLogger.log("Failed to delete segments: \(error)")
                }
            }

            // Delete the m3u8 playlist file
            let m3u8FileName = download.episodeIndex.map { "episode_\($0).m3u8" } ?? "video.m3u8"
            let m3u8Path = contentDir.appendingPathComponent(m3u8FileName)
            if FileManager.default.fileExists(atPath: m3u8Path.path) {
                do {
                    try FileManager.default.removeItem(at: m3u8Path)
                } catch {
                    StreamifyLogger.log("Failed to delete m3u8 file: \(error)")
                }
            }
        }

        // For movie downloads, check if folder is now empty (except metadata/thumbnail) and remove if so
        // This keeps the movie in library even if download is cancelled
        if download.episodeIndex == nil && !hasOtherDownloadsForSameContent(download) {
            do {
                let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: contentDir.path)
                // Only keep folder if it has thumbnails
                let hasKeepableContent = remainingFiles.contains { file in
                    file == "metadata.json" || file.hasPrefix("thumbnail") || file.hasPrefix("poster_thumbnail")
                }

                // If no keepable content and folder is essentially empty, remove it
                if !hasKeepableContent && remainingFiles.isEmpty {
                    try FileManager.default.removeItem(at: contentDir)
                }
            } catch {
                StreamifyLogger.log("Error checking movie folder contents: \(error)")
            }
        }
    }

    // MARK: - Cleanup orphaned files (master.m3u8, empty folders) after download failure/cancel

    /// Cleans up master.m3u8, episode thumbnails, and empty folders that remain after a download fails or is cancelled.
    /// Called after deleteDownloadedSegmentsOnly to handle files that function preserves.
    private func cleanupOrphanedFiles(for download: DownloadItem) {
        // If other downloads share this content folder, skip cleanup entirely
        if hasOtherDownloadsForSameContent(download) { return }

        let folderPath = Self.folderPath(for: download)
        let contentDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)
        guard FileManager.default.fileExists(atPath: contentDir.path) else { return }

        // Delete master.m3u8 if no video content remains
        let masterPath = contentDir.appendingPathComponent("master.m3u8")
        if FileManager.default.fileExists(atPath: masterPath.path) {
            // Check if there's any actual video content that needs the master m3u8
            let hasVideoContent: Bool = {
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: contentDir.path) else { return false }
                return files.contains { file in
                    let lowercased = file.lowercased()
                    // Match media files and quality subdirectories.
                    // Movie quality dirs: "video_4k_<uuid>", episode quality dirs: "ep4_video_4k_<uuid>"
                    return (lowercased.hasSuffix(".m3u8") && lowercased != "master.m3u8") ||
                    Self.isLocalVideoFileName(lowercased) ||
                    lowercased.hasPrefix("video_") || (lowercased.hasPrefix("ep") && lowercased.contains("_video_"))
                }
            }()

            if !hasVideoContent {
                try? FileManager.default.removeItem(at: masterPath)
                StreamifyLogger.log("Cleanup: Removed orphaned master.m3u8 from \(folderPath)")
            }
        }

        // For episode folders: remove if only metadata-like files remain (no actual content)
        if download.episodeIndex != nil {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: contentDir.path) {
                let hasActualContent = files.contains { file in
                    let lowercased = file.lowercased()
                    // Keep folder only if it has video, audio, or subtitle content.
                    // Episode quality dirs: "ep4_video_4k_<uuid>", movie quality dirs: "video_4k_<uuid>"
                    return lowercased.hasSuffix(".m3u8") || Self.isLocalVideoFileName(lowercased) || lowercased.hasSuffix(".vtt") ||
                    lowercased.hasSuffix(".srt") || lowercased.hasSuffix(".ass") || lowercased.hasSuffix(".mp3") ||
                    lowercased.hasSuffix(".m4a") || lowercased.hasSuffix(".aac") ||
                    lowercased.hasPrefix("video_") || lowercased.hasPrefix("audio_") || lowercased.hasPrefix("hls_audio_") ||
                    lowercased.hasPrefix("subtitle_") || lowercased == "subtitles" ||
                    (lowercased.hasPrefix("ep") && lowercased.contains("_video_"))
                }
                if !hasActualContent {
                    try? FileManager.default.removeItem(at: contentDir)
                    StreamifyLogger.log("Cleanup: Removed empty episode folder \(folderPath)")

                    // Also check if the series folder is now empty (only metadata/thumbnails)
                    let seriesDir = contentDir.deletingLastPathComponent()
                    let seriesFolder = folderPath.split(separator: "/").first.map(String.init) ?? folderPath
                    if let seriesFiles = try? FileManager.default.contentsOfDirectory(atPath: seriesDir.path) {
                        let hasSeasonFolders = seriesFiles.contains { $0.hasPrefix("season_") }
                        if !hasSeasonFolders {
                            // No episode folders left — check if only metadata files remain
                            let onlyMetadata = seriesFiles.allSatisfy { file in
                                file == "metadata.json" || file == "metadata.json.zlib" || file.hasPrefix("thumbnail") || file.hasPrefix("poster_thumbnail")
                            }
                            if onlyMetadata && !isLibraryFolder(seriesFolder) {
                                try? FileManager.default.removeItem(at: seriesDir)
                                StreamifyLogger.log("Cleanup: Removed empty series folder")
                            }
                        }
                    }
                }
            }
        } else {
            // For movie folders: remove if only metadata/thumbnails remain
            if let files = try? FileManager.default.contentsOfDirectory(atPath: contentDir.path) {
                let hasActualContent = files.contains { file in
                    let lowercased = file.lowercased()
                    return lowercased.hasSuffix(".m3u8") || Self.isLocalVideoFileName(lowercased) || lowercased.hasSuffix(".vtt") ||
                    lowercased.hasSuffix(".srt") || lowercased.hasSuffix(".ass") || lowercased.hasSuffix(".mp3") ||
                    lowercased.hasSuffix(".m4a") || lowercased.hasSuffix(".aac") ||
                    lowercased.hasPrefix("video_") || lowercased.hasPrefix("audio_") || lowercased.hasPrefix("hls_audio_") ||
                    lowercased.hasPrefix("subtitle_") || lowercased == "subtitles"
                }
                if !hasActualContent && !isLibraryFolder(folderPath) {
                    try? FileManager.default.removeItem(at: contentDir)
                    StreamifyLogger.log("Cleanup: Removed movie folder with no downloadable content \(folderPath)")
                }
            }
        }
    }

    // MARK: - Remove download

    func removeDownload(_ download: DownloadItem) {
        downloads.removeAll { $0.id == download.id }
        saveDownloads()
    }

    // MARK: - Retry download

    func retryDownload(_ download: DownloadItem) {
        if let task = downloadTasks[download.id] {
            task.cancel()
            downloadTasks.removeValue(forKey: download.id)
            downloadTaskTokens.removeValue(forKey: download.id)
        }
        download.progress = 0
        download.errorMessage = nil
        download.resumeData = nil
        download.downloadedSegmentIndices.removeAll()
        download.totalSegments = 0

        // Queue or start based on whether another download is active
        if hasActiveDownload {
            download.status = .queued
            saveDownloads()
        } else {
            download.status = .pending
            saveDownloads()
            startDownload(download)
        }
    }

    // MARK: - Pause download

    func pauseDownload(_ download: DownloadItem) {
        StreamifyLogger.log("DownloadManager: Pausing download \(download.id) - \(download.displayTitle)")

        // Cancel the task if it's running
        if let task = downloadTasks[download.id] {
            task.cancel()
            downloadTasks.removeValue(forKey: download.id)
            downloadTaskTokens.removeValue(forKey: download.id)
        }

        // Set status to paused - progress is already saved
        download.status = .paused
        saveDownloads()

        if download.totalSegments > 0 {
            StreamifyLogger.log("DownloadManager: Download paused at \(download.progressPercent)% (\(download.downloadedSegmentIndices.count)/\(download.totalSegments) segments)")
        } else {
            StreamifyLogger.log("DownloadManager: Direct file download paused at \(download.progressPercent)%")
        }

        // Force UI update - trigger objectWillChange to re-render filtered lists
        downloads = downloads  // Trigger @Published change

        // Start next queued download
        processQueue()
    }

    // MARK: - Resume download

    func resumeDownload(_ download: DownloadItem) {
        StreamifyLogger.log("DownloadManager: Resuming download \(download.id) - \(download.displayTitle)")

        guard downloadTasks[download.id] == nil else {
            StreamifyLogger.log("DownloadManager: Ignoring duplicate resume for \(download.displayTitle)")
            return
        }

        // If another download is active, queue this one instead
        if hasActiveDownload {
            download.status = .queued
            download.errorMessage = nil
            saveDownloads()
            downloads = downloads
            return
        }

        download.status = .downloading
        download.errorMessage = nil
        saveDownloads()

        // Force UI update - trigger @Published change to re-render filtered lists
        downloads = downloads

        let downloadId = download.id
        let taskToken = UUID()
        downloadTaskTokens[downloadId] = taskToken

        let task = Task {
            defer {
                if self.downloadTaskTokens[downloadId] == taskToken {
                    self.downloadTasks.removeValue(forKey: downloadId)
                    self.downloadTaskTokens.removeValue(forKey: downloadId)
                }
            }

            do {
                await self.refreshProviderURLIfNeeded(for: download)

                guard let url = URL(string: download.videoUrl) else {
                    throw ImportError.downloadFailed
                }

                // Check if cancelled
                if Task.isCancelled { return }

                // Resume video download
                await MainActor.run {
                    if download.currentTrackName == nil {
                        download.currentTrackName = download.qualityName
                    }
                    self.saveDownloads()
                }

                // Resume HLS stream from last saved segment
                if Self.looksLikeHLS(download.videoUrl) {
                    try await resumeHLSStream(download: download, url: url)
                } else {
                    // Direct files use URLSession resume data when the server provides it.
                    try await downloadFile(download: download, url: url)
                }

                // Check if cancelled
                if Task.isCancelled { return }

                download.progress = 1.0
                download.status = .completed
                download.currentTrackName = nil
                self.saveDownloads()
                self.objectWillChange.send()  // Force UI update for 100% completion

                // Add to library if not already there
                await self.addToLibraryIfNeeded(download, allEpisodes: nil)

                NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                self.processQueue()
            } catch {
                // Don't update status if cancelled (paused)
                if Task.isCancelled { return }

                StreamifyLogger.log("Download failed for \(download.displayTitle): \(error.localizedDescription)")

                // VidLink rate limit — silently wait then auto-resume (no UI error)
                if let importErr = error as? ImportError, importErr == .rateLimitPauseAndResume {
                    StreamifyLogger.log("DownloadManager: VidLink rate limit on resume — waiting 10s then auto-resuming \(download.displayTitle)")
                    self.saveDownloads()

                    try? await Task.sleep(nanoseconds: UInt64(VidLinkRateLimitHandler.backoffDuration * 1_000_000_000))

                    if Task.isCancelled { return }
                    if download.status == .paused || download.status == .failed { return }

                    StreamifyLogger.log("DownloadManager: Auto-resuming VidLink download after 10s wait for \(download.displayTitle)")
                    download.status = .paused
                    self.downloadTasks.removeValue(forKey: downloadId)
                    self.downloadTaskTokens.removeValue(forKey: downloadId)
                    await MainActor.run {
                        self.resumeDownload(download)
                    }
                    return
                }

                // Check if it's a network error - auto-pause
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain {
                    // Network error - auto-pause and save progress silently
                    download.status = .paused
                    download.currentTrackName = nil
                    download.errorMessage = "Network error - download paused. Tap resume when back online."
                    self.saveDownloads()
                    StreamifyLogger.log("Network error - auto-paused download, \(download.downloadedSegmentIndices.count) segments")
                    self.processQueue()
                } else {
                    // Real error — clean up partial downloads and fail
                    self.deleteDownloadedSegmentsOnly(for: download)
                    self.cleanupOrphanedFiles(for: download)

                    download.status = .failed
                    download.currentTrackName = nil
                    download.errorMessage = error.localizedDescription
                    self.saveDownloads()

                    // Show error notification (only for non-network errors)
                    await MainActor.run {
                        self.lastError = "\(download.displayTitle): \(error.localizedDescription)"
                        self.showErrorAlert = true
                    }
                    self.processQueue()
                }
            }
        }

        downloadTasks[downloadId] = task
    }

    // MARK: - Resume HLS stream from last saved segment

    private func resumeHLSStream(download: DownloadItem, url: URL) async throws {
        let needsProxyHeaders = download.tmdbId != nil

        let folderPath = Self.folderPath(for: download)
        let destDir = Self.contentDirectoryURL.appendingPathComponent(folderPath)

        // Use quality-named subfolder matching downloadHLSStream structure
        let qualitySubdir: String
        let segmentsDirName: String
        if let qName = download.qualityName, !qName.isEmpty {
            qualitySubdir = Self.qualitySubdirName(qualityName: qName, downloadId: download.id, episodeIndex: download.episodeIndex)
            segmentsDirName = "segments"
        } else {
            qualitySubdir = ""
            segmentsDirName = download.episodeIndex.map { "segments_ep\($0)" } ?? "segments"
        }
        let videoDir = qualitySubdir.isEmpty ? destDir : destDir.appendingPathComponent(qualitySubdir)
        let segmentsDir = videoDir.appendingPathComponent(segmentsDirName)

        // Ensure segments directory exists (may have been deleted during cancel)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        // Fetch master playlist
        try Task.checkCancellation()
        let (masterData, _) = try await fetchData(from: url)
        try Task.checkCancellation()

        guard let masterContent = String(data: masterData, encoding: .utf8) else {
            throw ImportError.downloadFailed
        }

        // Validate the master playlist is actual HLS content
        if !masterContent.contains("#EXTM3U") {
            if needsProxyHeaders {
                StreamifyLogger.log("DownloadManager: Resume master playlist is not valid HLS content (VidLink rate-limited) — triggering retry")
                throw ImportError.rateLimitPauseAndResume
            }
            StreamifyLogger.log("DownloadManager: Resume master playlist is not valid HLS content")
            throw ImportError.downloadFailed
        }

        let variants = downloadableHLSVariants(from: masterContent)

        // Use the same bandwidth as before
        let selectedBandwidth = download.selectedBandwidth ?? variants.first?.bandwidth ?? 8_000_000

        let selectedVariant = try await loadSelectedHLSVariant(
            masterContent: masterContent,
            sourceURL: url,
            variants: variants,
            selectedBandwidth: selectedBandwidth
        )
        let bestVariant = selectedVariant.variant
        let variantURL = selectedVariant.url
        let variantContent = selectedVariant.content

        download.selectedResolution = bestVariant.resolution
        download.selectedVideoRange = bestVariant.videoRange
        await MainActor.run { self.saveDownloads() }

        // Validate the variant playlist is actual HLS content
        if !variantContent.contains("#EXTM3U") && !variantContent.contains("#EXTINF") {
            if needsProxyHeaders {
                StreamifyLogger.log("DownloadManager: Resume variant playlist is not valid HLS content (VidLink rate-limited) — triggering retry")
                throw ImportError.rateLimitPauseAndResume
            }
            StreamifyLogger.log("DownloadManager: Resume variant playlist is not valid HLS content")
            throw ImportError.downloadFailed
        }

        // Parse segments and fMP4 initialization segment
        let mediaPlaylist = HLSManifestParser.parseMediaPlaylist(from: variantContent)
        let segments = mediaPlaylist.segments.map(\.uri)
        let segmentDurations = mediaPlaylist.segments.map(\.duration)
        let initSegmentURI = mediaPlaylist.initSegmentURI

        // Download fMP4 initialization segment if not already present
        var localInitSegmentName: String? = nil
        if let initURI = initSegmentURI,
           let initURL = resolveSegmentURL(initURI, baseURL: url, variantURL: variantURL) {
            let initExt = initURL.pathExtension.isEmpty ? "mp4" : initURL.pathExtension
            let initSegName = "init.\(initExt)"
            localInitSegmentName = initSegName
            let initPath = segmentsDir.appendingPathComponent(initSegName)
            if !FileManager.default.fileExists(atPath: initPath.path) {
                let (initData, _): (Data, URLResponse)
                if needsProxyHeaders {
                    let initHandler = VidLinkRateLimitHandler()
                    (initData, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                        from: initURL, rateLimitHandler: initHandler)
                } else {
                    (initData, _) = try await DownloadManager.fetchDataStatic(from: initURL)
                }
                try Task.checkCancellation()
                try initData.write(to: initPath)
                StreamifyLogger.log("Downloaded fMP4 init segment on resume: \(initSegName)")
            }
        }

        // Update total segments if not set
        if download.totalSegments == 0 {
            download.totalSegments = segments.count
        }

        // Load existing segment extensions from already downloaded files
        var segmentExtensions: [String] = Array(repeating: "ts", count: segments.count)
        let allFiles = try? FileManager.default.contentsOfDirectory(atPath: segmentsDir.path)
        for i in 0..<segments.count {
            let segmentFile = allFiles?.first { $0.hasPrefix("segment_\(i + 1).") }
            if let file = segmentFile {
                segmentExtensions[i] = file.components(separatedBy: ".").last ?? "ts"
            }
        }

        // Identify segments that still need to be downloaded
        let segmentsToDownload = (0..<segments.count).filter { !download.downloadedSegmentIndices.contains($0) }

        // Resolve ALL segment URLs into an array (Sendable-safe for TaskGroup)
        let resolvedSegmentURLs: [URL] = segments.enumerated().compactMap { (index, segmentURL) -> URL? in
            resolveSegmentURL(segmentURL, baseURL: url, variantURL: variantURL)
        }

        guard resolvedSegmentURLs.count == segments.count else {
            throw ImportError.downloadFailed
        }

        // Download remaining segments — VidLink uses same concurrency; rate-limit backoff is coordinated via VidLinkRateLimitHandler
        let concurrentCount = effectiveConcurrentDownloadCount(for: download)

        let indexTracker = SegmentIndexTracker()
        let remainingIndices = segmentsToDownload
        let rateLimitHandler = VidLinkRateLimitHandler()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<min(concurrentCount, remainingIndices.count) {
                group.addTask {
                    let pointerIndex = await indexTracker.getNextIndex()
                    guard pointerIndex < remainingIndices.count else {
                        throw ImportError.downloadFailed
                    }
                    let index = remainingIndices[pointerIndex]

                    try Task.checkCancellation()

                    let segmentURLResolved = resolvedSegmentURLs[index]

                    do {
                        let (data, _): (Data, URLResponse)
                        if needsProxyHeaders {
                            (data, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                                from: segmentURLResolved, rateLimitHandler: rateLimitHandler)
                        } else {
                            (data, _) = try await DownloadManager.fetchDataStatic(from: segmentURLResolved)
                        }
                        try Task.checkCancellation()

                        let originalExtension = segmentURLResolved.pathExtension.isEmpty ? "ts" : segmentURLResolved.pathExtension
                        let segmentFileName = String(format: "segment_%d.%@", index + 1, originalExtension)
                        let segmentPath = segmentsDir.appendingPathComponent(segmentFileName)
                        try data.write(to: segmentPath)

                        return index
                    } catch {
                        if error is CancellationError {
                            throw error
                        }
                        StreamifyLogger.log("Failed to download segment \(index): \(error)")
                        throw error
                    }
                }
            }

            for try await completedIndex in group {
                await MainActor.run {
                    download.downloadedSegmentIndices.insert(completedIndex)
                    download.progress = Double(download.downloadedSegmentIndices.count) / Double(segments.count)
                    self.saveDownloads()
                    self.broadcastProgressIfNeeded()
                }

                let completedUrl = resolvedSegmentURLs[completedIndex]
                segmentExtensions[completedIndex] = completedUrl.pathExtension.isEmpty ? "ts" : completedUrl.pathExtension

                let currentPointer = await indexTracker.currentIndex()

                if currentPointer < remainingIndices.count {
                    group.addTask {
                        let pointerIndex = await indexTracker.getNextIndex()
                        guard pointerIndex < remainingIndices.count else {
                            throw ImportError.downloadFailed
                        }
                        let segmentIndex = remainingIndices[pointerIndex]

                        try Task.checkCancellation()

                        let segmentURLResolved = resolvedSegmentURLs[segmentIndex]

                        do {
                            let (data, _): (Data, URLResponse)
                            if needsProxyHeaders {
                                (data, _) = try await DownloadManager.fetchVidLinkSegmentWithRetry(
                                    from: segmentURLResolved, rateLimitHandler: rateLimitHandler)
                            } else {
                                (data, _) = try await DownloadManager.fetchDataStatic(from: segmentURLResolved)
                            }
                            try Task.checkCancellation()

                            let originalExtension = segmentURLResolved.pathExtension.isEmpty ? "ts" : segmentURLResolved.pathExtension
                            let segmentFileName = String(format: "segment_%d.%@", segmentIndex + 1, originalExtension)
                            let segmentPath = segmentsDir.appendingPathComponent(segmentFileName)
                            try data.write(to: segmentPath)

                            return segmentIndex
                        } catch {
                            if error is CancellationError {
                                throw error
                            }
                            StreamifyLogger.log("Failed to download segment \(segmentIndex): \(error)")
                            throw error
                        }
                    }
                }
            }
        }

        // Create local m3u8 playlist
        let isFMP4 = localInitSegmentName != nil
        let hlsVersion = isFMP4 ? 7 : 6
        let maxSegDuration = Int(ceil(segmentDurations.max() ?? 10.0))
        var localPlaylist = "#EXTM3U\n"
        localPlaylist += "#EXT-X-VERSION:\(hlsVersion)\n"
        localPlaylist += "#EXT-X-TARGETDURATION:\(maxSegDuration)\n"
        localPlaylist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        localPlaylist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        localPlaylist += "#EXT-X-INDEPENDENT-SEGMENTS\n"

        if let initName = localInitSegmentName {
            localPlaylist += "#EXT-X-MAP:URI=\"\(segmentsDirName)/\(initName)\"\n"
        }

        for (index, duration) in segmentDurations.enumerated() {
            localPlaylist += String(format: "#EXTINF:%.3f,\n", duration)
            let segmentExt = index < segmentExtensions.count ? segmentExtensions[index] : "ts"
            localPlaylist += "\(segmentsDirName)/segment_\(index + 1).\(segmentExt)\n"
        }

        localPlaylist += "#EXT-X-ENDLIST\n"

        // Write m3u8 matching the quality subfolder structure from downloadHLSStream
        let fileName: String
        let localM3U8Path: URL
        if !qualitySubdir.isEmpty {
            fileName = "video.m3u8"
            localM3U8Path = videoDir.appendingPathComponent(fileName)
        } else {
            fileName = download.episodeIndex.map { "episode_\($0).m3u8" } ?? "video.m3u8"
            localM3U8Path = destDir.appendingPathComponent(fileName)
        }
        try localPlaylist.write(to: localM3U8Path, atomically: true, encoding: .utf8)

        let localVariantPath = qualitySubdir.isEmpty ? fileName : "\(qualitySubdir)/\(fileName)"
        writeLocalMasterPlaylist(
            sourceMaster: masterContent,
            selectedVariantURI: bestVariant.uri,
            selectedLocalVariantURI: localVariantPath,
            selectedBandwidth: bestVariant.bandwidth,
            selectedResolution: bestVariant.resolution,
            selectedVideoRange: bestVariant.videoRange,
            destDir: destDir,
            download: download
        )

        StreamifyLogger.log("Resume: M3U8 file written to: \(localM3U8Path.path)")
    }

    // MARK: - Get active downloads

    func getActiveDownloads() -> [DownloadItem] {
        downloads.filter { $0.status == .downloading || $0.status == .pending || $0.status == .queued }
    }

    // MARK: - Get completed downloads

    func getCompletedDownloads() -> [DownloadItem] {
        downloads.filter { $0.status == .completed }
    }

    // MARK: - Get failed downloads

    func getFailedDownloads() -> [DownloadItem] {
        downloads.filter { $0.status == .failed }
    }

    // MARK: - Track download management (for player picker downloads)

    @discardableResult
    func addTrackDownload(contentId: String, contentTitle: String, trackType: String, language: String, episodeInfo: EpisodeInfo? = nil, sourceUrl: String? = nil, downloadURL: String? = nil, destFolderPath: String? = nil, filePrefix: String? = nil, metadataFolder: String? = nil, trackId: String? = nil, languageId: String? = nil, isHLS: Bool = false) -> String {
        let item = TrackDownloadItem(
            contentId: contentId,
            contentTitle: contentTitle,
            trackType: trackType,
            language: language,
            episodeTitle: episodeInfo?.title,
            seasonNumber: episodeInfo?.season,
            episodeNumber: episodeInfo?.episode,
            sourceUrl: sourceUrl,
            downloadURL: downloadURL,
            destFolderPath: destFolderPath,
            filePrefix: filePrefix,
            metadataFolder: metadataFolder,
            trackId: trackId,
            languageId: languageId,
            isHLS: isHLS
        )
        trackDownloads.append(item)
        saveTrackDownloads()
        objectWillChange.send()  // Notify observers so queued track downloads appear immediately
        return item.id
    }

    /// Transition a track download from queued to downloading
    func startTrackDownload(id: String) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.status = .downloading
            saveTrackDownloads()
            objectWillChange.send()
        }
    }

    func updateTrackDownloadProgress(id: String, progress: Double) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.progress = progress
            broadcastProgressIfNeeded()
        }
    }

    func completeTrackDownload(id: String) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.status = .completed
            item.progress = 1.0
        }
        saveTrackDownloads()
        objectWillChange.send()
        NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
        // Remove completed track downloads after a longer delay so users can see the result
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.trackDownloads.removeAll { $0.id == id }
            self?.saveTrackDownloads()
        }
        // Start next queued download now that this track is done
        processQueue()
    }

    func failTrackDownload(id: String, error: String) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.status = .failed
            item.errorMessage = error
        }
        saveTrackDownloads()
        objectWillChange.send()
        // Remove failed track downloads after a delay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.trackDownloads.removeAll { $0.id == id }
            self?.saveTrackDownloads()
        }
        // Start next queued download now that this track is done
        processQueue()
    }

    func pauseTrackDownload(id: String) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.downloadTask?.cancel()
            item.downloadTask = nil
            item.status = .paused
        }
        saveTrackDownloads()
        objectWillChange.send()
    }

    func cancelTrackDownload(id: String) {
        if let item = trackDownloads.first(where: { $0.id == id }) {
            item.downloadTask?.cancel()
            item.downloadTask = nil
            item.status = .cancelled
        }
        trackDownloads.removeAll { $0.id == id }
        saveTrackDownloads()
        objectWillChange.send()
        // Start next queued download now that this track is done
        processQueue()
    }

    func clearTrackDownload(id: String) {
        // Remove the paused entry entirely so the user can start fresh
        trackDownloads.removeAll { $0.id == id }
        saveTrackDownloads()
        objectWillChange.send()
    }

    /// Resume a paused track download using its persisted URL and destination info.
    /// The download restarts from scratch (track downloads are typically small files).
    func resumeTrackDownload(id: String) {
        guard let item = trackDownloads.first(where: { $0.id == id }),
              item.canResume,
              let urlString = item.downloadURL,
              let url = URL(string: urlString),
              let destFolderPath = item.destFolderPath else {
            // Can't resume — not enough info persisted (legacy item)
            return
        }

        let destDir = ContentImportService.contentDirectoryURL.appendingPathComponent(destFolderPath)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let prefix = item.filePrefix ?? ""
        let metadataFolder = item.metadataFolder ?? item.contentId
        let trackDownloadId = item.id
        let trackType = item.trackType
        let trackLanguage = item.language
        let trackLangId = item.languageId ?? item.language.lowercased().replacingOccurrences(of: " ", with: "_")
        let trackIdStr = item.trackId ?? UUID().uuidString
        let isHLS = item.isHLS
        // Build episode info for metadata update
        let episode: EpisodeInfo?
        if let s = item.seasonNumber, let e = item.episodeNumber {
            episode = EpisodeInfo(season: s, episode: e, title: item.episodeTitle ?? "")
        } else {
            episode = nil
        }

        // Reset progress and status
        item.progress = 0
        item.status = .queued
        item.errorMessage = nil
        saveTrackDownloads()
        objectWillChange.send()

        // Create a download task
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }

            // Wait for any active track download to finish
            while await MainActor.run(body: {
                self.trackDownloads.contains { $0.status == .downloading && $0.id != trackDownloadId }
            }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // Check if still exists (user may have cancelled while waiting)
            guard await MainActor.run(body: { self.trackDownloads.contains { $0.id == trackDownloadId } }) else { return }

            await MainActor.run {
                self.startTrackDownload(id: trackDownloadId)
            }

            do {
                if trackType == "subtitle" {
                    let track = SubtitleTrack(language: trackLanguage, source: urlString, languageId: trackLangId, trackId: trackIdStr)
                    let localName = try await self.downloadSingleSubtitleTrack(
                        track: track, to: destDir, prefix: prefix,
                        onProgress: { progress in
                            Task { @MainActor in
                                DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                            }
                        }
                    )
                    guard let fileName = localName else {
                        await MainActor.run { self.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid") }
                        return
                    }
                    await MainActor.run {
                        self.updateTrackInMetadataAfterResume(metadataFolder: metadataFolder, episode: episode, trackType: trackType, trackId: trackIdStr, localSource: fileName)
                        self.completeTrackDownload(id: trackDownloadId)
                        self.libraryRefreshNeeded = true
                        NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                        StreamifyLogger.log("DownloadManager: Resumed subtitle download -> \(fileName)")
                    }
                } else if trackType == "audio" {
                    let track = AudioTrack(language: trackLanguage, source: urlString, languageId: trackLangId, trackId: trackIdStr)
                    let localSource: String
                    if isHLS {
                        localSource = try await self.downloadHLSAudioPlaylist(
                            from: url, track: track, to: destDir, prefix: prefix,
                            download: nil, downloadedCount: 0, totalToDownload: 1,
                            onProgress: { progress in
                                Task { @MainActor in
                                    DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                                }
                            }
                        )
                    } else {
                        guard let name = try await self.downloadSingleAudioFile(
                            track: track, to: destDir, prefix: prefix,
                            onProgress: { progress in
                                Task { @MainActor in
                                    DownloadManager.shared.updateTrackDownloadProgress(id: trackDownloadId, progress: progress)
                                }
                            }
                        ) else {
                            await MainActor.run { self.failTrackDownload(id: trackDownloadId, error: "Downloaded file was invalid") }
                            return
                        }
                        localSource = name
                    }
                    await MainActor.run {
                        self.updateTrackInMetadataAfterResume(metadataFolder: metadataFolder, episode: episode, trackType: trackType, trackId: trackIdStr, localSource: localSource)
                        self.completeTrackDownload(id: trackDownloadId)
                        self.libraryRefreshNeeded = true
                        NotificationCenter.default.post(name: DownloadManager.downloadCompletedNotification, object: nil)
                        StreamifyLogger.log("DownloadManager: Resumed audio download -> \(localSource)")
                    }
                }
            } catch {
                await MainActor.run {
                    let wasPaused = self.trackDownloads.first(where: { $0.id == trackDownloadId })?.status == .paused
                    if wasPaused {
                        StreamifyLogger.log("DownloadManager: Resumed track download paused for \(trackLanguage)")
                    } else if !(error is CancellationError) {
                        self.failTrackDownload(id: trackDownloadId, error: error.localizedDescription)
                        StreamifyLogger.log("DownloadManager: Resumed track download failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        item.downloadTask = task
    }

    /// Update metadata after a resumed track download completes.
    /// Uses `.copying()` since EpisodeInfo/ContentMetadata properties are `let`.
    private func updateTrackInMetadataAfterResume(metadataFolder: String, episode: EpisodeInfo?, trackType: String, trackId: String, localSource: String) {
        guard var metadata = ContentImportService.loadMetadata(from: metadataFolder) else { return }

        if let ep = episode {
            if var seasons = metadata.seasons {
                for sIdx in seasons.indices {
                    if var eps = seasons[sIdx].episodes {
                        for eIdx in eps.indices {
                            if eps[eIdx].episode == ep.episode && seasons[sIdx].season == ep.season {
                                if trackType == "subtitle" {
                                    var subs = eps[eIdx].subtitles ?? []
                                    for tIdx in subs.indices where subs[tIdx].trackId == trackId {
                                        subs[tIdx] = SubtitleTrack(language: subs[tIdx].language, source: localSource, languageId: subs[tIdx].languageId, name: subs[tIdx].name, trackId: subs[tIdx].trackId, sourceName: subs[tIdx].sourceName)
                                    }
                                    eps[eIdx] = eps[eIdx].copying(subtitles: subs)
                                } else if trackType == "audio" {
                                    var audios = eps[eIdx].audioTracks ?? []
                                    for tIdx in audios.indices where audios[tIdx].trackId == trackId {
                                        audios[tIdx] = AudioTrack(language: audios[tIdx].language, source: localSource, languageId: audios[tIdx].languageId, name: audios[tIdx].name, trackId: audios[tIdx].trackId, sourceName: audios[tIdx].sourceName)
                                    }
                                    eps[eIdx] = eps[eIdx].copying(audioTracks: audios)
                                }
                            }
                        }
                        seasons[sIdx] = SeasonInfo(season: seasons[sIdx].season, title: seasons[sIdx].title,
                                                    thumbnailUrl: seasons[sIdx].thumbnailUrl, episodes: eps)
                    }
                }
                metadata = metadata.copying(seasons: seasons)
            }
            // Also update flat episodes
            if var episodes = metadata.episodes {
                for eIdx in episodes.indices {
                    if episodes[eIdx].episode == ep.episode {
                        if trackType == "subtitle" {
                            var subs = episodes[eIdx].subtitles ?? []
                            for tIdx in subs.indices where subs[tIdx].trackId == trackId {
                                subs[tIdx] = SubtitleTrack(language: subs[tIdx].language, source: localSource, languageId: subs[tIdx].languageId, name: subs[tIdx].name, trackId: subs[tIdx].trackId, sourceName: subs[tIdx].sourceName)
                            }
                            episodes[eIdx] = episodes[eIdx].copying(subtitles: subs)
                        } else if trackType == "audio" {
                            var audios = episodes[eIdx].audioTracks ?? []
                            for tIdx in audios.indices where audios[tIdx].trackId == trackId {
                                audios[tIdx] = AudioTrack(language: audios[tIdx].language, source: localSource, languageId: audios[tIdx].languageId, name: audios[tIdx].name, trackId: audios[tIdx].trackId, sourceName: audios[tIdx].sourceName)
                            }
                            episodes[eIdx] = episodes[eIdx].copying(audioTracks: audios)
                        }
                    }
                }
                metadata = metadata.copying(episodes: episodes)
            }
        } else {
            // Movie
            if trackType == "subtitle" {
                var subs = metadata.subtitles ?? []
                for tIdx in subs.indices where subs[tIdx].trackId == trackId {
                    subs[tIdx] = SubtitleTrack(language: subs[tIdx].language, source: localSource, languageId: subs[tIdx].languageId, name: subs[tIdx].name, trackId: subs[tIdx].trackId, sourceName: subs[tIdx].sourceName)
                }
                metadata = metadata.copying(subtitles: subs)
            } else if trackType == "audio" {
                var audios = metadata.audioTracks ?? []
                for tIdx in audios.indices where audios[tIdx].trackId == trackId {
                    audios[tIdx] = AudioTrack(language: audios[tIdx].language, source: localSource, languageId: audios[tIdx].languageId, name: audios[tIdx].name, trackId: audios[tIdx].trackId, sourceName: audios[tIdx].sourceName)
                }
                metadata = metadata.copying(audioTracks: audios)
            }
        }

        ContentImportService.saveMetadata(metadata, to: metadataFolder)
        refreshLocalMasterPlaylist(metadataFolder: metadataFolder, episode: episode)
    }
}
