import Foundation
import AVFoundation
import AVKit
import Combine
import UIKit

// MARK: - Simple logger
nonisolated enum StreamifyLogger {
    static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("streamify.log")
    }

    // ISO8601DateFormatter is expensive to instantiate; reuse a single shared instance.
    private static let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Truncate the log file. Call once on app launch so each session starts fresh.
    static func clear() {
        try? Data().write(to: logFileURL, options: .atomic)
    }

    static func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}

// MARK: - HLS Quality variant
struct HLSQuality: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bandwidth: Double
    let resolution: String?
    let videoRange: String?    // e.g., "SDR", "HDR", "HLG", "PQ"
    let frameRate: String?     // e.g., "24", "30", "60"
    let sourceUrl: String?     // The m3u8 URL this quality was parsed from
    let variantUrl: String?    // The variant media playlist URL (resolved from master)
    let sourceName: String?    // Source attribution (e.g., "VidLink", "111Movies", source file name)
    let displayDetail: String? // Extra source detail for direct-file stream options
    
    init(name: String, bandwidth: Double, resolution: String?, videoRange: String?, frameRate: String?, sourceUrl: String?, variantUrl: String?, sourceName: String? = nil, displayDetail: String? = nil) {
        self.name = name
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.sourceUrl = sourceUrl
        self.variantUrl = variantUrl
        self.sourceName = sourceName
        self.displayDetail = displayDetail
    }
    
    // Helper to check if this is HDR (includes HLG and PQ)
    var isHDR: Bool {
        guard let range = videoRange?.uppercased() else { return false }
        return range == "HDR" || range == "HLG" || range == "PQ"
    }
    
    // Unique key for deduplication (resolution + HDR + frameRate)
    var qualityKey: String {
        let res = resolution ?? "unknown"
        let hdr = isHDR ? "HDR" : "SDR"
        let fps = frameRate ?? ""
        return "\(res)_\(hdr)_\(fps)"
    }

    var isDirectFileSource: Bool {
        guard let sourceUrl else { return false }
        return !Self.looksLikeHLS(sourceUrl)
    }

    static func looksLikeHLS(_ sourceUrl: String) -> Bool {
        sourceUrl.localizedCaseInsensitiveContains(".m3u8")
    }

    static func directFileQuality(urlString: String, sourceName: String? = nil, name: String? = nil, displayDetail: String? = nil) -> HLSQuality? {
        guard let url = URL(string: urlString) else { return nil }
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let containerName = ext.isEmpty ? "File" : ext.uppercased()
        let decodedName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let metadata = directFileMetadata(from: decodedName, fallbackContainer: containerName)
        let detail = displayDetail ?? [url.host, decodedName.isEmpty ? nil : decodedName]
            .compactMap { $0 }
            .joined(separator: " - ")

        return HLSQuality(
            name: name ?? metadata.name,
            bandwidth: metadata.bandwidth,
            resolution: metadata.resolution,
            videoRange: metadata.videoRange,
            frameRate: metadata.frameRate,
            sourceUrl: urlString,
            variantUrl: nil,
            sourceName: sourceName,
            displayDetail: detail.isEmpty ? nil : detail
        )
    }

    private struct DirectFileMetadata {
        let name: String
        let bandwidth: Double
        let resolution: String?
        let videoRange: String?
        let frameRate: String?
    }

    private static func directFileMetadata(from fileName: String, fallbackContainer: String) -> DirectFileMetadata {
        let readableName = fileNameWithoutExtension(fileName)
        let lowered = readableName.lowercased()
        let tokens = Set(languageAndQualityTokens(from: readableName))

        let resolutionInfo: (label: String, resolution: String?, bandwidth: Double)
        if tokens.contains("2160p") || tokens.contains("4k") || tokens.contains("uhd") {
            resolutionInfo = ("2160p", "3840x2160", 25_000_000)
        } else if tokens.contains("1440p") {
            resolutionInfo = ("1440p", "2560x1440", 16_000_000)
        } else if tokens.contains("1080p") || tokens.contains("fhd") {
            resolutionInfo = ("1080p", "1920x1080", 8_000_000)
        } else if tokens.contains("720p") || tokens.contains("hd") {
            resolutionInfo = ("720p", "1280x720", 4_000_000)
        } else if tokens.contains("576p") {
            resolutionInfo = ("576p", "1024x576", 2_500_000)
        } else if tokens.contains("480p") || tokens.contains("sd") {
            resolutionInfo = ("480p", "854x480", 1_500_000)
        } else {
            resolutionInfo = (fallbackContainer, nil, 0)
        }

        let videoRange: String?
        if tokens.contains("hlg") {
            videoRange = "HLG"
        } else if tokens.contains("pq") {
            videoRange = "PQ"
        } else if tokens.contains("hdr") ||
                    tokens.contains("hdr10") ||
                    tokens.contains("hdr10plus") ||
                    tokens.contains("dv") ||
                    tokens.contains("dovi") ||
                    lowered.contains("dolby vision") {
            videoRange = "HDR"
        } else {
            videoRange = nil
        }

        let frameRate = ["120", "60", "50", "30", "25", "24"].first { fps in
            tokens.contains("\(fps)fps") || tokens.contains("\(fps)hz") || lowered.contains("\(fps) fps")
        }

        return DirectFileMetadata(
            name: resolutionInfo.label,
            bandwidth: resolutionInfo.bandwidth,
            resolution: resolutionInfo.resolution,
            videoRange: videoRange,
            frameRate: frameRate
        )
    }

    private static func fileNameWithoutExtension(_ fileName: String) -> String {
        guard !fileName.isEmpty else { return fileName }
        let nsName = fileName as NSString
        let ext = nsName.pathExtension
        guard !ext.isEmpty else { return fileName }
        return nsName.deletingPathExtension
    }

    private static func languageAndQualityTokens(from value: String) -> [String] {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "+", with: "plus")
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    static func == (lhs: HLSQuality, rhs: HLSQuality) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - HLS Audio Rendition (parsed from #EXT-X-MEDIA:TYPE=AUDIO)
struct HLSAudioRendition: Identifiable, Hashable {
    let id = UUID()
    let groupId: String      // GROUP-ID from HLS
    let language: String     // Language code (e.g., "en", "es")
    let name: String         // Display name (e.g., "English", "Español")
    let uri: String?         // URI to audio playlist (nil for default embedded)
    let isDefault: Bool      // DEFAULT=YES
    let autoSelect: Bool     // AUTOSELECT=YES
    let channels: String?    // CHANNELS (e.g., "2", "6", "16/JOC" for Atmos)
    let bandwidth: Double?   // Estimated bandwidth (from associated STREAM-INF)
    let codecs: String?      // Audio codec from EXT-X-MEDIA CODECS attribute (e.g., "ec-3", "ac-3")
    
    var isSpatial: Bool {
        // Dolby Atmos uses JOC (Joint Object Coding) channel layout
        if let ch = channels, (ch.contains("JOC") || ch.contains("/")) {
            return true
        }
        // Detect spatial audio from codec strings (ec-3, ac-3, e-ac-3 can carry spatial audio)
        if let c = codecs?.lowercased() {
            if c.contains("ec-3") || c.contains("ac-3") || c.contains("e-ac-3") {
                return true
            }
        }
        return false
    }
    
    /// Convert to AudioTrack model
    func toAudioTrack(hlsBaseUrl: String, sourceName: String? = nil) -> AudioTrack {
        let source: String
        if let uri = uri, !uri.isEmpty {
            // Resolve relative URI against base URL
            if uri.hasPrefix("http") {
                source = uri
            } else if let base = URL(string: hlsBaseUrl) {
                source = base.deletingLastPathComponent().appendingPathComponent(uri).absoluteString
            } else {
                source = uri
            }
        } else {
            source = ""  // embedded
        }
        
        return AudioTrack(
            language: name,
            source: source,
            isSpatial: isSpatial,
            languageId: language,
            name: name,
            bandwidth: bandwidth,
            trackId: TrackIdentity.stableTrackId(
                type: "audio",
                source: source.isEmpty ? hlsBaseUrl : source,
                languageId: language,
                name: name,
                sourceName: sourceName,
                extra: groupId
            ),
            sourceName: sourceName
        )
    }
    
    static func == (lhs: HLSAudioRendition, rhs: HLSAudioRendition) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// A quality option that may be available from multiple source URLs
struct MultiSourceQuality: Identifiable {
    let id = UUID()
    let name: String
    let bandwidth: Double
    let resolution: String?
    let videoRange: String?
    let frameRate: String?
    let sourceUrls: [String]  // All m3u8 URLs that provide this quality
    let sourceName: String?   // Source attribution (e.g., "VidLink", "111Movies", source file name)
    let displayDetail: String?
    
    init(name: String, bandwidth: Double, resolution: String?, videoRange: String?, frameRate: String?, sourceUrls: [String], sourceName: String? = nil, displayDetail: String? = nil) {
        self.name = name
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.sourceUrls = sourceUrls
        self.sourceName = sourceName
        self.displayDetail = displayDetail
    }
    
    var isHDR: Bool {
        guard let range = videoRange?.uppercased() else { return false }
        return range == "HDR" || range == "HLG" || range == "PQ"
    }

    var isDirectFileSource: Bool {
        guard let first = sourceUrls.first else { return false }
        return !first.localizedCaseInsensitiveContains(".m3u8")
    }
}

@MainActor
class PlayerViewModel: ObservableObject {
    // MARK: - Published state
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isBuffering: Bool = false
    @Published var isHLS: Bool = false
    @Published var isLocalFile: Bool = false
    @Published var selectedQuality: VideoQuality = .auto
    @Published var availableQualities: [HLSQuality] = []
    @Published var showSkipIntro: Bool = false
    @Published var showNextEpisode: Bool = false
    @Published var localFileResolution: String = ""
    @Published var isReadyToPlay: Bool = false
    @Published var isPlayingHDR: Bool = false
    @Published var loadedTimeRanges: [(start: Double, end: Double)] = []
    @Published var autoQualityLabel: String = ""
    @Published var autoQualityIsHDR: Bool = false
    @Published var autoQualitySourceName: String? = nil
    @Published var needsExternalAudioSync: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var hasAccessDeniedPlayback: Bool = false
    @Published var mpvAudioTracks: [AudioTrack] = []
    @Published var mpvSubtitleTracks: [SubtitleTrack] = []
    @Published var selectedMPVAudioTrackId: String? = nil
    @Published var selectedMPVSubtitleTrackId: String? = nil
    /// Raw MPVTrackInfo for audio tracks — used by the HLS transcoder to get
    /// codec strings, channel counts, and stream indices.
    @Published var mpvRawAudioTracks: [MPVTrackInfo] = []
    /// Raw MPVTrackInfo for subtitle tracks — used by the HLS transcoder.
    @Published var mpvRawSubtitleTracks: [MPVTrackInfo] = []
    @Published var mpvLiveSubtitleText: String = ""
    
    

    // MARK: - Custom Player (AVPlayerLayer-rendered)
    // Always uses AVPlayerLayer for native video rendering with full HDR support.
    // AVPlayerLayer handles HDR (PQ/HLG) natively — same rendering path as Safari.
    private(set) var customEngine: CustomPlayerEngine?
    private(set) var mpvEngine: MPVDirectPlayerEngine?

    
    /// Convenience accessor — proxies to the custom engine's internal AVPlayer.
    /// Used by code that needs direct AVPlayer access (audio tracks, time ranges, etc.).
    var player: AVPlayer? { customEngine?.player }
    
    /// Convenience accessor — proxies to the custom engine's internal AVPlayerItem's asset.
    var asset: AVAsset? { customEngine?.playerItem?.asset }
    
    /// Convenience accessor — proxies to the custom engine's internal AVPlayerItem.
    var playerItem: AVPlayerItem? { customEngine?.playerItem }

    var isUsingMPVPlayback: Bool { mpvEngine != nil }

    // MARK: - Private state
    private var loadingTask: Task<Void, Never>?
    private var lastIndicatedBitrate: Double = 0
    private var lastObservedBitrate: Double = 0
    
    // Source error retry state
    private var sourceRetryTask: Task<Void, Never>?
    private var lastSetupUrl: URL?
    private var currentPlaybackUrl: URL?
    /// Seek target and play intent stored when recovering from AVErrorMediaServicesWereReset.
    /// Consumed once by the next `onReadyToPlay` callback, then cleared.
    private var pendingSeekAfterReady: Double? = nil
    private var pendingPlayAfterReady: Bool = false
    private var lastSetupIntro: Double?
    private var lastSetupIntroDuration: Double?
    private var lastSetupEnd: Double?
    private var lastSetupSourceNames: [String: String] = [:]
    
    private var isSeeking = false
    private var seekGeneration = 0

    // HDR variant mode: when playing HDR variant playlists (PQ, HLG, or
    // any VIDEO-RANGE != SDR), AVPlayer's native ABR can switch between
    // SDR and HDR renditions causing visible brightness flashes. In this
    // mode we handle quality switching manually, restricting picks to
    // same-range variants so the display stays in a stable EDR state.
    private var isHDRVariantMode: Bool = false
    private var currentVariantQuality: HLSQuality?
    private var abrTimer: Timer?
    
    /// The source URL that auto mode is locked to.
    /// In auto mode, the player should only consider qualities from this source
    /// to prevent ABR from jumping between different sources (e.g., own source → VidLink).
    private(set) var activeAutoSourceUrl: String?

    private static func isTorrentioQuality(_ quality: HLSQuality) -> Bool {
        quality.sourceName == "Torrentio" ||
            (quality.sourceUrl?.localizedCaseInsensitiveContains("torrentio.strem.fun") ?? false) ||
            (quality.variantUrl?.localizedCaseInsensitiveContains("torrentio.strem.fun") ?? false)
    }

    static func shouldUseMPVDirectPlayback(for url: URL) -> Bool {
        MPVDirectPlayerEngine.isAvailable && MatroskaPlaybackSupport.isMatroskaURL(url)
    }

    /// Candidate qualities for auto labels and ABR. Prefer the active source.
    /// If that source has no parsed variants, fall back to non-Torrentio sources first.
    /// Torrentio is only considered when it is the only source represented.
    private func autoCandidateQualities(requireVariantURL: Bool = false) -> [HLSQuality] {
        let base = requireVariantURL ? availableQualities.filter { $0.variantUrl != nil } : availableQualities
        if let activeSource = activeAutoSourceUrl {
            let sourceFiltered = base.filter { $0.sourceUrl == activeSource }
            if !sourceFiltered.isEmpty {
                return sourceFiltered
            }
        }

        let nonTorrentio = base.filter { !Self.isTorrentioQuality($0) }
        return nonTorrentio.isEmpty ? base : nonTorrentio
    }
    
    /// The "real" content playback position.
    /// Returns the custom engine's current time, falling back to the @Published currentTime.
    var realPlaybackTime: Double {
        if let engine = mpvEngine {
            let time = engine.currentTime
            return time.isFinite ? time : currentTime
        }
        guard let engine = customEngine else { return currentTime }
        let time = engine.currentTime
        return time.isFinite ? time : currentTime
    }
    
    /// Whether the player's embedded audio is muted.
    var isPlayerMuted: Bool {
        get { mpvEngine?.isMuted ?? customEngine?.isMuted ?? false }
        set {
            if let mpvEngine {
                mpvEngine.isMuted = newValue
            } else {
                customEngine?.isMuted = newValue
            }
        }
    }

    /// Whether PiP is supported on this device.
    var isPiPSupported: Bool {
        if let mpvEngine { return mpvEngine.isPiPSupported }
        return customEngine?.isPiPSupported ?? AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Toggle PiP on/off.
    func togglePiP() {
        if let mpvEngine {
            mpvEngine.togglePiP()
        } else {
            customEngine?.togglePiP()
        }
    }
    
    /// The current playback rate (0 = paused, 1 = normal).
    var playbackRate: Float {
        if let mpvEngine {
            return mpvEngine.isPlaying ? mpvEngine.currentSpeed : 0
        }
        return customEngine?.isPlaying == true ? (customEngine?.playbackRate ?? 1.0) : 0
    }
    
    // Intro/end markers
    private var introStart: Double = 0
    private var introDuration: Double = 0
    private var endTime: Double?

    // MARK: - Setup
    func setup(url: URL, intro: Double?, introDuration: Double?, end: Double?, preloadedQualities: [HLSQuality]? = nil, sourceNames: [String: String] = [:]) {
        cleanup()
        
        // Save setup params for source retry
        self.lastSetupUrl = url
        self.lastSetupIntro = intro
        self.lastSetupIntroDuration = introDuration
        self.lastSetupEnd = end
        self.lastSetupSourceNames = sourceNames
        self.sourceRetryTask?.cancel()
        self.sourceRetryTask = nil

        self.introStart = intro ?? 0
        self.introDuration = introDuration ?? 0
        self.endTime = end
        
        // Check if this is a local file or served from local server (downloaded content)
        let isLocalServer = url.host == "localhost" || url.host == "127.0.0.1"
        self.isLocalFile = url.isFileURL || isLocalServer
        
        // Check if it's an HLS stream — detect m3u8 for both local and remote content.
        // Local HLS (served via localhost) is still HLS and needs proper codec handling.
        self.isHLS = url.pathExtension == "m3u8" || url.absoluteString.contains(".m3u8")
        
        StreamifyLogger.log("PlayerViewModel: setup URL=\(url.absoluteString) isLocalFile=\(isLocalFile) isHLS=\(isHLS) preloadedQualities=\(preloadedQualities?.count ?? 0)")

        // Apply preloaded qualities immediately if available (e.g., VidLink qualities fetched
        // during local playback). This makes them visible in the quality picker regardless of
        // whether the current URL is local or remote.
        if let preloaded = preloadedQualities, !preloaded.isEmpty, (isLocalFile || !isHLS) {
            self.availableQualities = preloaded
            StreamifyLogger.log("PlayerViewModel: Applied \(preloaded.count) preloaded qualities")
        }

        if Self.shouldUseMPVDirectPlayback(for: url) {
            let isLocalMPVFile = url.isFileURL || isLocalServer
            self.isHLS = false
            self.isLocalFile = isLocalMPVFile
            self.activeAutoSourceUrl = isLocalMPVFile ? nil : url.absoluteString
            if let quality = (preloadedQualities ?? availableQualities).first(where: { $0.sourceUrl == url.absoluteString || $0.variantUrl == url.absoluteString }) {
                self.autoQualityLabel = quality.name
                self.autoQualityIsHDR = quality.isHDR
                self.autoQualitySourceName = quality.sourceName
                self.isPlayingHDR = quality.isHDR
            } else if let quality = HLSQuality.directFileQuality(urlString: url.absoluteString, sourceName: sourceNames[url.absoluteString]) {
                let qualityIsHDR = quality.isHDR || (isLocalMPVFile && self.isPlayingHDR)
                self.autoQualityLabel = quality.name
                self.autoQualityIsHDR = qualityIsHDR
                self.autoQualitySourceName = quality.sourceName
                self.isPlayingHDR = qualityIsHDR
            }
            startMPVPlayer(url: url)
        } else if isLocalServer && (url.pathExtension == "m3u8" || url.absoluteString.contains(".m3u8")) {
            // For local server HLS, ensure the server is running before starting the player.
            loadingTask = Task {
                let running = await LocalServer.shared.ensureRunningAsync()
                StreamifyLogger.log("PlayerViewModel: Local server ensureRunningAsync result: \(running)")
                await getLocalHLSResolution(from: url)
                await MainActor.run {
                    self.startPlayer(url: url)
                }
            }
        } else if isHLS && !isLocalFile {
            // For remote HLS, parse qualities from ALL sources (including VidLink) first,
            // then start the player with the best quality variant.
            loadingTask = Task {
                let masterURL = url
                
                // Use preloaded qualities if available, otherwise parse from sources
                if let preloaded = preloadedQualities, !preloaded.isEmpty {
                    await MainActor.run {
                        self.availableQualities = preloaded
                    }
                    StreamifyLogger.log("PlayerViewModel: Using \(preloaded.count) pre-parsed qualities, skipping HLS parse")
                } else {
                    await self.parseHLSQualities(from: masterURL)
                }
                
                await MainActor.run {
                    // Lock auto mode to the source being played
                    self.activeAutoSourceUrl = masterURL.absoluteString
                    
                    // Pre-select the auto quality label to the best available quality
                    // so the UI shows the expected quality immediately.
                    // Start at the highest quality and let AVPlayer's native ABR adapt down.
                    let candidates = self.autoCandidateQualities(requireVariantURL: false)
                    if let best = candidates.max(by: { $0.bandwidth < $1.bandwidth }) {
                        self.autoQualityLabel = best.name
                        self.autoQualityIsHDR = best.isHDR
                        self.autoQualitySourceName = best.sourceName
                    }
                    
                    // Check if any HDR variants exist (PQ, HLG, or generic HDR).
                    // When HDR variants are present, use manual variant switching
                    // to prevent AVPlayer from mixing SDR and HDR renditions
                    // (which causes visible brightness flashes as the display
                    // enters/exits EDR mode).
                    let variantCandidates = self.autoCandidateQualities(requireVariantURL: true)
                    let hasHDRVariants = variantCandidates.contains { $0.isHDR }
                    if hasHDRVariants {
                        self.isHDRVariantMode = true
                        // Start with the highest quality HDR variant
                        let initialVariant = self.pickBestVariant(forBitrate: 0)
                        if let variant = initialVariant, let urlStr = variant.variantUrl, let variantURL = URL(string: urlStr) {
                            self.currentVariantQuality = variant
                            self.isPlayingHDR = variant.isHDR
                            self.autoQualityLabel = variant.name
                            self.autoQualityIsHDR = variant.isHDR
                            self.autoQualitySourceName = variant.sourceName
                            StreamifyLogger.log("PlayerViewModel: HDR variant mode — starting with best quality \(variant.name) (\(Int(variant.bandwidth)) bps)")
                            self.startPlayer(url: variantURL)
                            self.startABRTimer()
                        } else {
                            // Fallback: no variant URLs available, try master directly
                            StreamifyLogger.log("PlayerViewModel: HDR detected but no variant URLs — falling back to master")
                            self.startPlayer(url: masterURL)
                        }
                    } else {
                        // SDR-only: play master directly at best quality,
                        // AVPlayer's native ABR will adapt down if needed.
                        self.startPlayer(url: masterURL)
                        StreamifyLogger.log("PlayerViewModel: SDR-only HLS — starting at best quality, AVPlayer ABR will adapt")
                    }
                }
            }
        } else {
            startPlayer(url: url)
        }
    }
    
    /// Creates the custom player engine and begins playback setup.
    private func startPlayer(url: URL) {
        mpvEngine?.cleanup()
        mpvEngine = nil
        mpvAudioTracks = []
        mpvSubtitleTracks = []
        mpvRawAudioTracks = []
        mpvRawSubtitleTracks = []
        mpvLiveSubtitleText = ""
        selectedMPVAudioTrackId = nil
        selectedMPVSubtitleTrackId = nil

        configurePlaybackAudioSession(context: "AVPlayer")
        
        let engine = CustomPlayerEngine()
        setupCustomPlayerCallbacks(engine)
        // Load BEFORE publishing the engine — this creates the AVPlayerLayer video view.
        // CustomPlayerView.makeUIView() needs videoView to be non-nil at first render.
        engine.load(url: url, isHLS: isHLS, isLocalFile: isLocalFile)
        currentPlaybackUrl = url
        self.customEngine = engine
        
        // For local files, try to get resolution from the URL directly
        if isLocalFile {
            Task {
                let asset = AVURLAsset(url: url)
                await getLocalFileResolution(asset: asset)
            }
        } else if isHLS && !isHDRVariantMode && availableQualities.isEmpty {
            loadingTask = Task {
                await parseHLSQualities(from: url)
            }
        }
        
        StreamifyLogger.log("PlayerViewModel: startPlayer URL=\(url.absoluteString)")
    }

    private func startMPVPlayer(url: URL) {
        customEngine?.cleanup()
        customEngine = nil
        mpvAudioTracks = []
        mpvSubtitleTracks = []
        mpvRawAudioTracks = []
        mpvRawSubtitleTracks = []
        mpvLiveSubtitleText = ""
        selectedMPVAudioTrackId = nil
        selectedMPVSubtitleTrackId = nil
        isPiPActive = false

        configurePlaybackAudioSession(context: "MPV")

        let engine = MPVDirectPlayerEngine(preferHDROutput: isPlayingHDR)
        setupMPVPlayerCallbacks(engine)
        currentPlaybackUrl = url
        mpvEngine = engine
        isBuffering = true
        engine.load(url: url, requestHeaders: requestHeaders(for: url))
        StreamifyLogger.log("PlayerViewModel: startMPVPlayer URL=\(url.absoluteString)")
    }

    private func configurePlaybackAudioSession(context: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
            try activatePlaybackAudioSession(audioSession)
        } catch {
            do {
                try audioSession.setCategory(.playback)
                try activatePlaybackAudioSession(audioSession)
            } catch {
                StreamifyLogger.log("PlayerViewModel: Failed to configure AVAudioSession: \(error.localizedDescription)")
            }
        }
    }

    private func activatePlaybackAudioSession(_ audioSession: AVAudioSession) throws {
        // iOS detects the output route and multichannel capabilities automatically;
        // explicit setPreferredOutputNumberOfChannels is not needed and causes
        // "multichannel available" rather than native multichannel recognition.
        try audioSession.setActive(true)
    }

    private func requestHeaders(for url: URL) -> [String: String] {
        if VidLinkService.isVidLinkProxyURL(url.absoluteString) {
            return ["Referer": VidLinkService.vidLinkReferer]
        }
        return [:]
    }

    private func setupMPVPlayerCallbacks(_ engine: MPVDirectPlayerEngine) {
        engine.onStateChanged = { [weak self] state in
            guard let self else { return }
            if state.duration > 0, abs(self.duration - state.duration) > 0.05 {
                self.duration = state.duration
            }
            if self.isReadyToPlay, !self.isSeeking {
                let timeDelta = abs(self.currentTime - state.position)
                if timeDelta > (state.isPlaying ? 0.05 : 0.25) {
                    self.currentTime = state.position
                    self.updateIntroState()
                }
            }
            if self.isPlaying != state.isPlaying {
                self.isPlaying = state.isPlaying
            }
            if self.isBuffering != state.isLoading {
                self.isBuffering = state.isLoading
            }
            let nextRanges: [(start: Double, end: Double)]
            if state.duration > 0 {
                nextRanges = [(start: state.position, end: min(min(state.buffered, state.position + 30), state.duration))]
            } else {
                nextRanges = []
            }
            let rangeTolerance = state.isPlaying ? 0.25 : 2.0
            if !Self.loadedTimeRangesAreClose(self.loadedTimeRanges, nextRanges, tolerance: rangeTolerance) {
                self.loadedTimeRanges = nextRanges
            }
        }

        engine.onReadyToPlay = { [weak self] in
            guard let self else { return }
            self.isReadyToPlay = true
            self.isBuffering = false
            self.logHDRPlaybackStatus()
        }

        engine.onTracksChanged = { [weak self] audioTracks, subtitleTracks in
            guard let self else { return }
            self.mpvAudioTracks = audioTracks.map(Self.audioTrack(fromMPV:))
            self.mpvSubtitleTracks = subtitleTracks.map(Self.subtitleTrack(fromMPV:))
            self.selectedMPVAudioTrackId = audioTracks.first(where: { $0.selected }).map { "mpv-audio-\($0.id)" }
            self.selectedMPVSubtitleTrackId = subtitleTracks.first(where: { $0.selected }).map { "mpv-subtitle-\($0.id)" }
            self.mpvRawAudioTracks = audioTracks
            self.mpvRawSubtitleTracks = subtitleTracks
        }

        engine.onFinished = { [weak self] in
            self?.isPlaying = false
        }

        engine.onSubtitleText = { [weak self] text in
            self?.mpvLiveSubtitleText = text
        }

        engine.onError = { [weak self] message in
            guard let self else { return }
            self.isReadyToPlay = false
            self.isBuffering = false
            StreamifyLogger.log("PlayerViewModel: MPV error - \(message)")
        }

        engine.onPiPActiveChanged = { [weak self] active in
            self?.isPiPActive = active
        }
    }

    private static func loadedTimeRangesAreClose(
        _ lhs: [(start: Double, end: Double)],
        _ rhs: [(start: Double, end: Double)],
        tolerance: Double
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            abs(left.start - right.start) < tolerance &&
                abs(left.end - right.end) < tolerance
        }
    }

    private static func audioTrack(fromMPV track: MPVTrackInfo) -> AudioTrack {
        let language = mpvLanguageDisplay(for: track) ?? displayLabel(forMPV: track, fallback: "Audio \(track.index + 1)")
        let label = displayLabel(forMPV: track, fallback: language)
        let display = displayNameWithLanguage(language: language, label: label, track: track)
        let codec = track.codec.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? track.codec
        return AudioTrack(
            language: language,
            source: "mpv://audio/\(track.id)?index=\(track.index)&codec=\(codec)&channels=\(track.demuxChannelCount)",
            isSpatial: isSpatialMPVAudio(track),
            languageId: languageId(forMPV: track, fallback: "audio_\(track.id)"),
            name: display == language ? nil : display,
            trackId: "mpv-audio-\(track.id)",
            sourceName: "MKV"
        )
    }

    private static func subtitleTrack(fromMPV track: MPVTrackInfo) -> SubtitleTrack {
        let language = mpvLanguageDisplay(for: track) ?? displayLabel(forMPV: track, fallback: "Subtitle \(track.index + 1)")
        let codec = track.codec.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? track.codec
        return SubtitleTrack(
            language: language,
            source: "mpv://subtitle/\(track.id)?index=\(track.index)&codec=\(codec)",
            languageId: languageId(forMPV: track, fallback: "subtitle_\(track.id)"),
            name: nil,
            trackId: "mpv-subtitle-\(track.id)",
            sourceName: track.external ? "External" : "MKV"
        )
    }

    private static func displayLabel(forMPV track: MPVTrackInfo, fallback: String) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && !isBareLanguageLabel(title, track: track) { return title }
        let lang = track.lang.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty {
            return mpvLanguageDisplay(for: track) ?? lang.uppercased()
        }
        return fallback
    }

    private static func languageId(forMPV track: MPVTrackInfo, fallback: String) -> String {
        if let code = mpvLanguageCode(for: track) { return code }
        return fallback
    }

    private static func mpvLanguageDisplay(for track: MPVTrackInfo) -> String? {
        guard let code = mpvLanguageCode(for: track) else { return nil }
        return localizedLanguageName(for: code)
    }

    private static func mpvLanguageCode(for track: MPVTrackInfo) -> String? {
        languageCode(from: track.lang) ?? languageCode(from: track.title)
    }

    private static func languageCode(from rawValue: String) -> String? {
        let tokens = languageAndQualityTokens(from: rawValue)
        guard !tokens.isEmpty else { return nil }
        for token in tokens {
            if let code = LanguageSupport.aliases[token] {
                return code
            }
        }
        return nil
    }

    private static func localizedLanguageName(for code: String) -> String {
        LanguageSupport.displayName(for: code)
    }

    private static func isBareLanguageLabel(_ title: String, track: MPVTrackInfo) -> Bool {
        guard let code = mpvLanguageCode(for: track) else { return false }
        let tokens = languageAndQualityTokens(from: title)
        guard !tokens.isEmpty else { return false }
        let languageTokens = tokens.filter { LanguageSupport.aliases[$0] == code }
        let subtitleNoiseTokens: Set<String> = ["sub", "subs", "subtitle", "subtitles", "sdh", "cc", "forced"]
        return !languageTokens.isEmpty && tokens.allSatisfy { token in
            LanguageSupport.aliases[token] == code || subtitleNoiseTokens.contains(token)
        }
    }

    private static func displayNameWithLanguage(language: String, label: String, track: MPVTrackInfo) -> String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, trimmedLabel.localizedCaseInsensitiveCompare(language) != .orderedSame else {
            return language
        }
        if labelContainsLanguage(trimmedLabel, track: track, language: language) {
            return trimmedLabel
        }
        return "\(language) \(trimmedLabel)"
    }

    private static func labelContainsLanguage(_ label: String, track: MPVTrackInfo, language: String) -> Bool {
        if label.range(of: language, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        guard let code = mpvLanguageCode(for: track) else { return false }
        return languageAndQualityTokens(from: label).contains { LanguageSupport.aliases[$0] == code }
    }

    private static func isSpatialMPVAudio(_ track: MPVTrackInfo) -> Bool {
        let combined = "\(track.title) \(track.codec)".lowercased()
        if combined.contains("atmos") || combined.contains("truehd") || combined.contains("eac3") ||
            combined.contains("e-ac-3") || combined.contains("ec-3") || combined.contains("ac-3") ||
            combined.contains("ddp") || combined.contains("dd+") || combined.contains("dts") {
            return true
        }
        return track.demuxChannelCount >= 6
    }

    private static func languageAndQualityTokens(from value: String) -> [String] {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "+", with: "plus")
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Custom Player Callbacks
    /// Wire up CustomPlayerEngine callbacks to update @Published properties.
    /// This bridges the custom engine's callback pattern to SwiftUI's reactive state.
    private func setupCustomPlayerCallbacks(_ engine: CustomPlayerEngine) {
        engine.onTimeUpdate = { [weak self] time in
            guard let self else { return }
            guard self.isReadyToPlay, !self.isSeeking else { return }
            self.currentTime = time
            self.updateIntroState()
            self.updateLoadedTimeRanges()
        }
        
        engine.onDurationChanged = { [weak self] dur in
            guard let self else { return }
            // Only update if duration is positive — prevent overwriting saved duration with 0
            if dur > 0 {
                self.duration = dur
            }
        }
        
        engine.onReadyToPlay = { [weak self] in
            self?.isReadyToPlay = true
            self?.logHDRPlaybackStatus()
            // If a recovery seek was scheduled (e.g. after AVErrorMediaServicesWereReset),
            // restore the saved position and resume playback.
            guard let self, let seekTime = self.pendingSeekAfterReady else { return }
            let shouldPlay = self.pendingPlayAfterReady
            self.pendingSeekAfterReady = nil
            self.pendingPlayAfterReady = false
            self.customEngine?.seek(time: seekTime) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if shouldPlay { self.play() }
                }
            }
        }
        
        engine.onPlaybackStateChanged = { [weak self] playing in
            self?.isPlaying = playing
        }
        
        engine.onBufferingChanged = { [weak self] buffering in
            self?.isBuffering = buffering
        }
        
        engine.onFinished = { [weak self] in
            self?.isPlaying = false
        }
        
        engine.onError = { [weak self] error in
            guard let self else { return }
            self.isReadyToPlay = false
            let nsError = error as? NSError
            if let nsError {
                StreamifyLogger.log("PlayerViewModel: Player error — \(nsError.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
            } else {
                StreamifyLogger.log("PlayerViewModel: Player error — \(error?.localizedDescription ?? "unknown")")
            }
            
            // AVErrorMediaServicesWereReset (-11819): the system media server crashed and
            // invalidated all AVPlayer instances. Recreate the player and restore position.
            let isMediaServicesReset = self.isMediaServicesResetError(error)
            if isMediaServicesReset, let url = self.currentPlaybackUrl ?? self.lastSetupUrl {
                StreamifyLogger.log("PlayerViewModel: Media services reset — reloading player in 1.5s")
                self.sourceRetryTask?.cancel()
                let savedTime = self.currentTime
                let wasPlaying = self.isPlaying
                self.sourceRetryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                    guard let self, !Task.isCancelled else { return }
                    StreamifyLogger.log("PlayerViewModel: Media services reset — reloading player")
                    await MainActor.run {
                        // Re-activate the audio session: after a media-services reset iOS
                        // restarts mediaserverd but the session is no longer active.
                        do {
                            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                            try AVAudioSession.sharedInstance().setActive(true)
                        } catch {
                            StreamifyLogger.log("PlayerViewModel: Failed to reactivate AVAudioSession after reset: \(error.localizedDescription)")
                        }
                        self.pendingSeekAfterReady = savedTime
                        self.pendingPlayAfterReady = wasPlaying
                        let engine: CustomPlayerEngine
                        if let existingEngine = self.customEngine {
                            engine = existingEngine
                        } else {
                            engine = CustomPlayerEngine()
                            self.setupCustomPlayerCallbacks(engine)
                            self.customEngine = engine
                        }
                        engine.load(url: url, isHLS: self.isHLS, isLocalFile: self.isLocalFile)
                        self.currentPlaybackUrl = url
                    }
                }
            // For VidLink sources, retry after 10 seconds (VidLink can return HTML/rate limit)
            } else if VidLinkService.isVidLinkProxyURL(self.lastSetupUrl?.absoluteString ?? "") {
                StreamifyLogger.log("PlayerViewModel: VidLink error detected, retrying in 10s...")
                self.sourceRetryTask?.cancel()
                self.sourceRetryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    guard let self, !Task.isCancelled else { return }
                    guard let url = self.lastSetupUrl else { return }
                    StreamifyLogger.log("PlayerViewModel: VidLink retry — reloading player")
                    await MainActor.run {
                        // Reload the player engine with the same URL
                        self.customEngine?.load(url: url, isHLS: self.isHLS, isLocalFile: self.isLocalFile)
                        self.currentPlaybackUrl = url
                    }
                }
            }
        }
        
        engine.onAccessLogUpdate = { [weak self] indicatedBitrate, observedBitrate, uri in
            guard let self else { return }
            StreamifyLogger.log("PlayerItem AccessLog: indicatedBitrate=\(indicatedBitrate) observedBitrate=\(observedBitrate) URI=\(uri ?? "nil")")
            if let uri, TorrentioService.isFailedAccessURL(uri) {
                StreamifyLogger.log("PlayerViewModel: Torrentio failed-access video detected; suppressing progress for this source")
                self.hasAccessDeniedPlayback = true
            }
            // Cache observed bitrate for ABR decisions
            if observedBitrate > 0 {
                self.lastObservedBitrate = observedBitrate
            }
            if self.isHDRVariantMode {
                // In HDR variant mode, indicatedBitrate is -1 (single variant).
                // Auto label and HDR are updated by the ABR timer / switchToVariant.
            } else {
                self.updateAutoQualityLabel(indicatedBitrate: indicatedBitrate)
            }
        }

        engine.onPiPActiveChanged = { [weak self] active in
            self?.isPiPActive = active
        }
    }

    private func isMediaServicesResetError(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        if nsError.domain == AVFoundationErrorDomain,
           nsError.code == AVError.Code.mediaServicesWereReset.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMediaServicesResetError(underlying)
        }
        return false
    }
    
    // MARK: - Get resolution for local files
    private func getLocalFileResolution(asset: AVURLAsset) async {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = tracks.first {
                let size = try await videoTrack.load(.naturalSize)
                await MainActor.run {
                    self.localFileResolution = "\(Int(size.width))x\(Int(size.height))"
                }
            }
        } catch {
            StreamifyLogger.log("Failed to get local file resolution: \(error)")
        }
    }
    
    // MARK: - Get resolution for local HLS (served via local server)
    private func getLocalHLSResolution(from url: URL) async {
        // For downloaded HLS, we downloaded the highest quality
        // Try to get the resolution and VIDEO-RANGE from the m3u8 file
        do {
            // Use ephemeral session to avoid URLSession.shared connection-pool issues
            // with the simple NWConnection-based local server
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            
            let (data, _) = try await session.data(from: url)
            guard let content = String(data: data, encoding: .utf8) else { return }
            
            // The URL may point to a media playlist (variant) which has #EXTINF segments
            // but no #EXT-X-STREAM-INF attributes (those live in the master playlist).
            // If we don't find STREAM-INF lines, look for master.m3u8 in parent directories.
            var manifestToParse = content
            let hasStreamInf = content.contains("#EXT-X-STREAM-INF:")
            var matchingVariantURL: URL?
            
            if !hasStreamInf {
                // This is a media playlist — try to find master.m3u8 in parent directories
                // Downloaded content structure: .../episode_folder/quality_subfolder/video.m3u8
                // master.m3u8 is saved at: .../episode_folder/master.m3u8
                let masterContent = await findAndReadMasterM3U8(fromVariantURL: url)
                if let master = masterContent {
                    manifestToParse = master
                    matchingVariantURL = url
                    StreamifyLogger.log("Local HLS: Found master.m3u8 for HDR/resolution detection")
                } else {
                    StreamifyLogger.log("Local HLS: No master.m3u8 found, media playlist has no STREAM-INF")
                }
            }
            
            // Parse for resolution, VIDEO-RANGE, and CODECS in the manifest
            let (highestResolution, highestVideoRange, highestCodecs) = parseStreamInfAttributes(
                from: manifestToParse,
                matchingVariantURL: matchingVariantURL
            )
            
            await MainActor.run {
                if let res = highestResolution {
                    // Convert "1920x1080" to "1080p"
                    let parts = res.components(separatedBy: "x")
                    if let heightStr = parts.last, let height = Int(heightStr) {
                        if height >= 2160 {
                            self.localFileResolution = "2160p"
                        } else if height >= 1080 {
                            self.localFileResolution = "1080p"
                        } else if height >= 720 {
                            self.localFileResolution = "720p"
                        } else if height >= 480 {
                            self.localFileResolution = "480p"
                        } else {
                            self.localFileResolution = res
                        }
                    } else {
                        self.localFileResolution = res
                    }
                } else {
                    // Default for downloaded HLS
                    self.localFileResolution = ""
                }
                
                // Detect HDR from VIDEO-RANGE attribute
                var detectedHDR = false
                let explicitVideoRange = highestVideoRange?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let range = explicitVideoRange, !range.isEmpty {
                    let manifestHDR = range == "PQ" || range == "HLG" || range == "HDR"
                    if manifestHDR {
                        detectedHDR = true
                        StreamifyLogger.log("Local HLS: HDR detected from manifest VIDEO-RANGE=\(range)")
                    }
                }
                
                // Fallback: detect Dolby Vision from CODECS. HEVC Main10 alone
                // can be SDR, so VIDEO-RANGE remains the source of truth for
                // PQ/HLG/HDR10.
                if !detectedHDR, let codecs = highestCodecs?.lowercased() {
                    let hdrCodecPatterns = ["dvh1", "dvhe", "dva1", "dvav"]
                    if hdrCodecPatterns.contains(where: { codecs.contains($0) }) {
                        detectedHDR = true
                        StreamifyLogger.log("Local HLS: HDR detected from CODECS=\(codecs)")
                    }
                }

                if detectedHDR {
                    self.isPlayingHDR = true
                } else if let range = explicitVideoRange, !range.isEmpty {
                    self.isPlayingHDR = false
                    StreamifyLogger.log("Local HLS: SDR detected from manifest VIDEO-RANGE=\(range)")
                } else if self.autoQualityIsHDR || self.isPlayingHDR {
                    self.isPlayingHDR = true
                    StreamifyLogger.log("Local HLS: Keeping HDR from saved quality metadata")
                } else {
                    self.isPlayingHDR = false
                }
            }
        } catch {
            StreamifyLogger.log("Failed to get local HLS resolution: \(error)")
        }
    }
    
    /// Try to find and read a master.m3u8 from parent directories of the variant URL.
    /// Downloaded content saves master.m3u8 in the episode/content folder, while variant
    /// media playlists live in quality subfolders (e.g., ep1_video_4k_UUID/video.m3u8).
    private func findAndReadMasterM3U8(fromVariantURL url: URL) async -> String? {
        // Search the local file system directly instead of making HTTP requests.
        // This is faster, more reliable, and avoids encoding mismatches between
        // the URL path and the on-disk folder names.
        //
        // Typical structure on disk:
        //   Content/<contentId>/season_S_episode_E/master.m3u8        ← master is here
        //   Content/<contentId>/season_S_episode_E/<quality_dir>/video.m3u8  ← variant
        //
        // The URL from the local server encodes the relative path after the base:
        //   http://localhost:8080/<contentId>/season_S_episode_E/<quality_dir>/video.m3u8
        //
        // We extract the percent-encoded path from absoluteString (not url.path which
        // decodes %20 → space) so that it matches folder names saved with percent-encoded IDs.
        
        let contentDirPath = ContentImportService.contentDirectoryURL.path
        
        // Extract the percent-encoded URL path from absoluteString.
        // url.path decodes percent encoding, but on-disk folder names may contain literal
        // percent-encoded characters (e.g. "My%20Show") because appendingPathComponent
        // on file URLs treats them as literal.
        let urlStr = url.absoluteString
        guard let schemeEnd = urlStr.range(of: "://"),
              let pathStart = urlStr[schemeEnd.upperBound...].firstIndex(of: "/") else {
            StreamifyLogger.log("Local HLS: Cannot extract path from \(urlStr)")
            return nil
        }
        let encodedPath = String(urlStr[pathStart...])
        
        // Remove the filename (video.m3u8) to get the directory
        var currentDir = (encodedPath as NSString).deletingLastPathComponent as String
        
        StreamifyLogger.log("Local HLS: Looking for master.m3u8 on disk, starting dir: \(currentDir)")
        
        // Try up to 3 parent levels
        for level in 0..<3 {
            guard !currentDir.isEmpty && currentDir != "/" else { break }
            
            let relDir = currentDir.hasPrefix("/") ? String(currentDir.dropFirst()) : currentDir
            let masterFilePath = contentDirPath + "/" + relDir + "/master.m3u8"
            
            StreamifyLogger.log("Local HLS: Trying master.m3u8 (level \(level)): \(masterFilePath)")
            
            if FileManager.default.fileExists(atPath: masterFilePath) {
                if let content = try? String(contentsOfFile: masterFilePath, encoding: .utf8),
                   content.contains("#EXTM3U"),
                   content.contains("#EXT-X-STREAM-INF:") {
                    StreamifyLogger.log("Local HLS: Found valid master.m3u8 at level \(level)")
                    return content
                }
            }
            
            // Move up one directory
            currentDir = (currentDir as NSString).deletingLastPathComponent as String
        }
        
        // Fallback: try with URL.path (decoded percent encoding) in case the on-disk
        // folder names use unencoded characters (e.g. spaces).
        var decodedDir = (url.path as NSString).deletingLastPathComponent as String
        
        for level in 0..<3 {
            guard !decodedDir.isEmpty && decodedDir != "/" else { break }
            
            let relDir = decodedDir.hasPrefix("/") ? String(decodedDir.dropFirst()) : decodedDir
            let masterURL = URL(fileURLWithPath: contentDirPath)
                .appendingPathComponent(relDir)
                .appendingPathComponent("master.m3u8")
            
            if FileManager.default.fileExists(atPath: masterURL.path) {
                if let content = try? String(contentsOf: masterURL, encoding: .utf8),
                   content.contains("#EXTM3U"),
                   content.contains("#EXT-X-STREAM-INF:") {
                    StreamifyLogger.log("Local HLS: Found valid master.m3u8 (decoded path) at level \(level)")
                    return content
                }
            }
            
            decodedDir = (decodedDir as NSString).deletingLastPathComponent as String
        }
        
        StreamifyLogger.log("Local HLS: master.m3u8 NOT found on disk after searching parent directories")
        
        return nil
    }
    
    /// Parse #EXT-X-STREAM-INF attributes from an HLS manifest, returning the
    /// resolution, VIDEO-RANGE, and CODECS of the highest-bandwidth variant.
    private func parseStreamInfAttributes(from content: String, matchingVariantURL: URL? = nil) -> (resolution: String?, videoRange: String?, codecs: String?) {
        let variants = HLSManifestParser.parseStreamVariants(from: content)
        let selectedVariant = matchingVariantURL.flatMap { url in
            variants.first { variant in
                streamVariantURI(variant.uri, matches: url)
            }
        } ?? variants.max(by: { $0.bandwidth < $1.bandwidth })

        return (selectedVariant?.resolution, selectedVariant?.videoRange, selectedVariant?.codecs)
    }

    private func streamVariantURI(_ uri: String, matches url: URL) -> Bool {
        if uri == url.absoluteString {
            return true
        }

        let decodedURI = uri.removingPercentEncoding ?? uri
        let candidates = [
            url.absoluteString,
            url.path,
            url.path.removingPercentEncoding ?? url.path
        ]

        return candidates.contains { candidate in
            candidate.hasSuffix("/\(uri)") ||
            candidate.hasSuffix(uri) ||
            candidate.hasSuffix("/\(decodedURI)") ||
            candidate.hasSuffix(decodedURI)
        }
    }
    
    // MARK: - Parse HLS qualities from m3u8
    func parseHLSQualities(from url: URL) async {
        do {
            let request: URLRequest
            if VidLinkService.isVidLinkProxyURL(url.absoluteString), let vidLinkReq = VidLinkService.makeRequest(for: url.absoluteString, timeoutInterval: 10) {
                request = vidLinkReq
            } else {
                var r = URLRequest(url: url)
                r.timeoutInterval = 10
                request = r
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let content = String(data: data, encoding: .utf8) else { return }
            
            var qualities: [HLSQuality] = []
            
            let lines = content.components(separatedBy: "\n")
            var pendingStreamInf: (bandwidth: Double, resolution: String?, videoRange: String?, frameRate: String?)? = nil
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                    // Parse all attributes
                    var bandwidth: Double = 0
                    var resolution: String? = nil
                    var videoRange: String? = nil
                    var frameRate: String? = nil
                    
                    let attributes = trimmed.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                    
                    // Parse key=value pairs, handling quoted values with commas
                    let pairs = Self.parseAttributeString(attributes)
                    
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
                        default:
                            break
                        }
                    }
                    
                    pendingStreamInf = (bandwidth, resolution, videoRange, frameRate)
                } else if let info = pendingStreamInf, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    // This line is the variant media playlist URL
                    let resolvedVariantUrl = URL(string: trimmed, relativeTo: url)?.absoluteURL.absoluteString
                    
                    let qualityName = HLSManifestParser.qualityName(
                        resolution: info.resolution,
                        bandwidth: info.bandwidth
                    )
                    
                    qualities.append(HLSQuality(
                        name: qualityName,
                        bandwidth: info.bandwidth,
                        resolution: info.resolution,
                        videoRange: info.videoRange,
                        frameRate: info.frameRate,
                        sourceUrl: url.absoluteString,
                        variantUrl: resolvedVariantUrl
                    ))
                    
                    pendingStreamInf = nil
                }
            }
            
            // Sort by bandwidth (highest first)
            qualities.sort { $0.bandwidth > $1.bandwidth }
            
            await MainActor.run {
                self.availableQualities = qualities
                // Retry auto quality label + HDR update with cached bitrate
                // (access log may have fired before qualities were parsed)
                if self.lastIndicatedBitrate > 0 {
                    self.updateAutoQualityLabel(indicatedBitrate: self.lastIndicatedBitrate)
                }
                // Extract the actual content aspect ratio from non-16:9 variants
                // (e.g., 1080p at 1920×800 = 2.4:1). Pass to the engine so it can
                // crop baked-in letterbox bars in padded 16:9 variants (4K).
                let ratio16x9: CGFloat = 16.0 / 9.0
                let contentRatio: CGFloat? = qualities.compactMap { quality -> CGFloat? in
                    guard let res = quality.resolution else { return nil }
                    let parts = res.components(separatedBy: "x")
                    guard parts.count == 2,
                          let w = Double(parts[0]),
                          let h = Double(parts[1]),
                          w > 0 && h > 0 else { return nil }
                    let ratio = CGFloat(w / h)
                    return abs(ratio - ratio16x9) < 0.05 ? nil : ratio
                }.max()  // widest non-16:9 ratio = most likely the true content ratio
                if let contentRatio {
                    self.customEngine?.setContentAspectRatio(contentRatio)
                }
            }
        } catch {
            // No qualities found on error - leave empty to show "No quality options found"
            await MainActor.run {
                self.availableQualities = []
            }
        }
    }
    
    /// Static helper to pre-parse HLS qualities from a single URL before the player opens.
    static func parseHLSQualitiesStatic(from url: URL, sourceName: String? = nil) async -> [HLSQuality] {
        // For VidLink, retry if we get HTML instead of a valid m3u8 (rate limit / Cloudflare)
        let isVL = VidLinkService.isVidLinkProxyURL(url.absoluteString)
        let maxAttempts = isVL ? 5 : 1
        for attempt in 1...maxAttempts {
            let qualities = await parseHLSQualitiesStaticOnce(from: url, sourceName: sourceName)
            if !qualities.isEmpty {
                return qualities
            }
            if isVL && attempt < maxAttempts {
                StreamifyLogger.log("parseHLSQualitiesStatic: VidLink returned empty/HTML on attempt \(attempt), waiting 10s before retry...")
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }
        return []
    }
    
    private static func parseHLSQualitiesStaticOnce(from url: URL, sourceName: String? = nil) async -> [HLSQuality] {
        let isVL = VidLinkService.isVidLinkProxyURL(url.absoluteString)
        do {
            let request: URLRequest
            if isVL, let vidLinkReq = VidLinkService.makeRequest(for: url.absoluteString, timeoutInterval: 10) {
                request = vidLinkReq
            } else {
                var r = URLRequest(url: url)
                r.timeoutInterval = 10
                request = r
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let content = String(data: data, encoding: .utf8) else { return [] }
            
            var qualities: [HLSQuality] = []
            let lines = content.components(separatedBy: "\n")
            var pendingStreamInf: (bandwidth: Double, resolution: String?, videoRange: String?, frameRate: String?)? = nil
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                    var bandwidth: Double = 0
                    var resolution: String? = nil
                    var videoRange: String? = nil
                    var frameRate: String? = nil
                    
                    let attributes = trimmed.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                    let pairs = Self.parseAttributeString(attributes)
                    
                    for (key, value) in pairs {
                        switch key {
                        case "BANDWIDTH": bandwidth = Double(value) ?? 0
                        case "RESOLUTION": resolution = value
                        case "VIDEO-RANGE": videoRange = value
                        case "FRAME-RATE": frameRate = value
                        default: break
                        }
                    }
                    pendingStreamInf = (bandwidth, resolution, videoRange, frameRate)
                } else if let info = pendingStreamInf, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    let resolvedVariantUrl = URL(string: trimmed, relativeTo: url)?.absoluteURL.absoluteString
                    let qualityName = HLSManifestParser.qualityName(
                        resolution: info.resolution,
                        bandwidth: info.bandwidth
                    )
                    
                    qualities.append(HLSQuality(
                        name: qualityName,
                        bandwidth: info.bandwidth,
                        resolution: info.resolution,
                        videoRange: info.videoRange,
                        frameRate: info.frameRate,
                        sourceUrl: url.absoluteString,
                        variantUrl: resolvedVariantUrl,
                        sourceName: isVL ? "VidLink" : sourceName
                    ))
                    pendingStreamInf = nil
                }
            }
            
            qualities.sort { $0.bandwidth > $1.bandwidth }
            return qualities
        } catch {
            StreamifyLogger.log("parseHLSQualitiesStatic: Error parsing \(url): \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Parse qualities from multiple HLS URLs and merge
    // Parses each m3u8 URL, deduplicates by resolution+HDR+frameRate,
    // and tracks all source URLs that provide each quality
    static func parseMultiSourceQualities(from urls: [String], sourceNames: [String: String] = [:]) async -> [MultiSourceQuality] {
        var allQualities: [HLSQuality] = []
        
        await withTaskGroup(of: [HLSQuality].self) { group in
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                let isVidLinkSource = VidLinkService.isVidLinkProxyURL(urlString)
                let urlSourceName = isVidLinkSource ? "VidLink" : sourceNames[urlString]
                group.addTask {
                    do {
                        var request: URLRequest
                        if isVidLinkSource, let vidLinkReq = VidLinkService.makeRequest(for: urlString, timeoutInterval: 10) {
                            request = vidLinkReq
                        } else {
                            request = URLRequest(url: url)
                            request.timeoutInterval = 10
                        }
                        let (data, _) = try await URLSession.shared.data(for: request)
                        guard let content = String(data: data, encoding: .utf8) else { return [] }
                        
                        var qualities: [HLSQuality] = []
                        let lines = content.components(separatedBy: "\n")
                        for line in lines {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                                var bandwidth: Double = 0
                                var resolution: String? = nil
                                var videoRange: String? = nil
                                var frameRate: String? = nil
                                
                                let attributes = trimmed.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                                let pairs = Self.parseAttributeString(attributes)
                                
                                for (key, value) in pairs {
                                    switch key {
                                    case "BANDWIDTH": bandwidth = Double(value) ?? 0
                                    case "RESOLUTION": resolution = value
                                    case "VIDEO-RANGE": videoRange = value
                                    case "FRAME-RATE": frameRate = value
                                    default: break
                                    }
                                }
                                
                                let qualityName = HLSManifestParser.qualityName(
                                    resolution: resolution,
                                    bandwidth: bandwidth
                                )
                                
                                qualities.append(HLSQuality(
                                    name: qualityName,
                                    bandwidth: bandwidth,
                                    resolution: resolution,
                                    videoRange: videoRange,
                                    frameRate: frameRate,
                                    sourceUrl: urlString,
                                    variantUrl: nil,
                                    sourceName: urlSourceName
                                ))
                            }
                        }
                        return qualities
                    } catch {
                        return []
                    }
                }
            }
            
            for await qualities in group {
                allQualities.append(contentsOf: qualities)
            }
        }
        
        // Merge by qualityKey (resolution + HDR + frameRate)
        var mergedByKey: [String: MultiSourceQuality] = [:]
        var orderedKeys: [String] = []
        
        for quality in allQualities {
            let key = quality.qualityKey
            if let existing = mergedByKey[key] {
                // Add source URL if not already tracked
                if let sourceUrl = quality.sourceUrl, !existing.sourceUrls.contains(sourceUrl) {
                    var urls = existing.sourceUrls
                    urls.append(sourceUrl)
                    // sourceName: prefer the first non-nil name, or combine them
                    let mergedSourceName = existing.sourceName ?? quality.sourceName
                    mergedByKey[key] = MultiSourceQuality(
                        name: existing.name,
                        bandwidth: max(existing.bandwidth, quality.bandwidth),
                        resolution: existing.resolution,
                        videoRange: existing.videoRange,
                        frameRate: existing.frameRate,
                        sourceUrls: urls,
                        sourceName: mergedSourceName
                    )
                }
            } else {
                mergedByKey[key] = MultiSourceQuality(
                    name: quality.name,
                    bandwidth: quality.bandwidth,
                    resolution: quality.resolution,
                    videoRange: quality.videoRange,
                    frameRate: quality.frameRate,
                    sourceUrls: [quality.sourceUrl].compactMap { $0 },
                    sourceName: quality.sourceName
                )
                orderedKeys.append(key)
            }
        }
        
        // Sort by bandwidth (highest first)
        return orderedKeys.compactMap { mergedByKey[$0] }
            .sorted { $0.bandwidth > $1.bandwidth }
    }
    
    // MARK: - Static HLS attribute parser (for use in static methods)
    private nonisolated static func parseAttributeString(_ attributes: String) -> [(key: String, value: String)] {
        HLSManifestParser.parseAttributes(attributes)
    }
    
    // MARK: - Parse qualities from multiple HLS URLs without merging
    // Returns individual HLSQuality entries for each source/quality combination.
    // Deduplicates by (sourceUrl, qualityKey) to avoid duplicate entries from same source.
    static func parseAllSourceQualities(from urls: [String], sourceNames: [String: String] = [:]) async -> [HLSQuality] {
        var allQualities: [HLSQuality] = []
        
        await withTaskGroup(of: [HLSQuality].self) { group in
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                let isVL = VidLinkService.isVidLinkProxyURL(urlString)
                let sn = isVL ? "VidLink" : sourceNames[urlString]
                group.addTask {
                    if !HLSQuality.looksLikeHLS(urlString) {
                        return HLSQuality.directFileQuality(urlString: urlString, sourceName: sn).map { [$0] } ?? []
                    }
                    return await Self.parseHLSQualitiesStatic(from: url, sourceName: sn)
                }
            }
            for await qualities in group {
                allQualities.append(contentsOf: qualities)
            }
        }
        
        // Deduplicate by (sourceUrl, qualityKey) to avoid duplicate entries from same source
        var seen: Set<String> = []
        var deduplicated: [HLSQuality] = []
        for q in allQualities {
            let key = "\(q.sourceUrl ?? "")_\(q.qualityKey)"
            if !seen.contains(key) {
                seen.insert(key)
                deduplicated.append(q)
            }
        }
        
        return deduplicated.sorted { $0.bandwidth > $1.bandwidth }
    }
    
    // MARK: - Set quality based on HLS quality
    func setHLSQuality(_ quality: HLSQuality) {
        // Store the selected quality name and source for display
        selectedQualityName = quality.name
        selectedQualitySourceUrl = quality.sourceUrl
        selectedQuality = .max // Mark as non-auto so presentationSize observer doesn't overwrite
        
        if isHDRVariantMode {
            // In HDR variant mode, actually switch to this variant's playlist
            stopABRTimer()
            switchToVariant(quality)
        } else {
            playerItem?.preferredPeakBitRate = quality.bandwidth
            // Set HDR from the quality's manifest metadata immediately
            isPlayingHDR = quality.isHDR
        }
    }
    
    // MARK: - Parse HLS audio renditions from m3u8
    /// Parses #EXT-X-MEDIA:TYPE=AUDIO lines from an HLS master playlist.
    /// Also estimates bandwidth from associated STREAM-INF AUDIO group references.
    static func parseHLSAudioRenditions(from url: URL) async -> (renditions: [HLSAudioRendition], embeddedAudioIsSpatial: Bool) {
        do {
            var request: URLRequest
            if VidLinkService.isVidLinkProxyURL(url.absoluteString), let vidLinkReq = VidLinkService.makeRequest(for: url.absoluteString, timeoutInterval: 10) {
                request = vidLinkReq
            } else {
                request = URLRequest(url: url)
                request.timeoutInterval = 10
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let content = String(data: data, encoding: .utf8) else { return ([], false) }
            return parseHLSAudioRenditions(from: content, baseUrl: url.absoluteString)
        } catch {
            StreamifyLogger.log("Failed to parse HLS audio renditions from \(url): \(error.localizedDescription)")
            return ([], false)
        }
    }
    
    /// Parse HLS audio renditions from manifest content string
    static func parseHLSAudioRenditions(from content: String, baseUrl: String) -> (renditions: [HLSAudioRendition], embeddedAudioIsSpatial: Bool) {
        var renditions: [HLSAudioRendition] = []
        // Track bandwidth per audio group from STREAM-INF lines
        var audioBandwidthByGroup: [String: Double] = [:]
        var embeddedAudioIsSpatial = false

        let lines = content.components(separatedBy: "\n")
        var mediaAudioGroups = Set<String>()
        var embeddedAudioGroups = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attributes = trimmed.replacingOccurrences(of: "#EXT-X-MEDIA:", with: "")
            let pairs = parseAttributeString(attributes)
            var type = ""
            var groupId = ""
            var uri: String?
            for (key, value) in pairs {
                switch key {
                case "TYPE": type = value
                case "GROUP-ID": groupId = value
                case "URI": uri = value
                default: break
                }
            }
            guard type == "AUDIO" else { continue }
            guard !groupId.isEmpty else { continue }
            mediaAudioGroups.insert(groupId)
            if uri?.isEmpty != false {
                embeddedAudioGroups.insert(groupId)
            }
        }

        // First pass: collect audio bandwidth and CODECS from STREAM-INF lines
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = trimmed.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                let pairs = parseAttributeString(attributes)
                var audioGroup: String?
                var bandwidth: Double = 0
                var streamCodecs: String?
                for (key, value) in pairs {
                    switch key {
                    case "AUDIO": audioGroup = value
                    case "BANDWIDTH": bandwidth = Double(value) ?? 0
                    case "CODECS": streamCodecs = value
                    default: break
                    }
                }
                if let group = audioGroup, bandwidth > 0 {
                    // Use the maximum bandwidth associated with this audio group
                    audioBandwidthByGroup[group] = max(audioBandwidthByGroup[group] ?? 0, bandwidth)
                }
                // STREAM-INF CODECS can include external AUDIO group codecs. Only treat it
                // as embedded audio when there is no external audio group, or when that
                // group is explicitly embedded with no URI.
                if let codecs = streamCodecs?.lowercased() {
                    let hasSpatialCodec = codecs.contains("ec-3") || codecs.contains("ac-3") || codecs.contains("e-ac-3")
                    let referencesExternalGroup = audioGroup.map { mediaAudioGroups.contains($0) && !embeddedAudioGroups.contains($0) } ?? false
                    if hasSpatialCodec && !referencesExternalGroup {
                        embeddedAudioIsSpatial = true
                    }
                }
            }
        }
        
        // Second pass: parse EXT-X-MEDIA:TYPE=AUDIO lines
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = trimmed.replacingOccurrences(of: "#EXT-X-MEDIA:", with: "")
                let pairs = parseAttributeString(attributes)
                
                var type = ""
                var groupId = ""
                var language = ""
                var name = ""
                var uri: String?
                var isDefault = false
                var autoSelect = false
                var channels: String?
                var mediaCodecs: String?
                
                for (key, value) in pairs {
                    switch key {
                    case "TYPE": type = value
                    case "GROUP-ID": groupId = value
                    case "LANGUAGE": language = value
                    case "NAME": name = value
                    case "URI": uri = value
                    case "DEFAULT": isDefault = value.uppercased() == "YES"
                    case "AUTOSELECT": autoSelect = value.uppercased() == "YES"
                    case "CHANNELS": channels = value
                    case "CODECS": mediaCodecs = value
                    default: break
                    }
                }
                
                guard type == "AUDIO" else { continue }
                
                // Estimate audio bandwidth (typically ~10% of stream bandwidth for stereo,
                // ~15% for surround) - use a heuristic from the group's stream bandwidth
                var estimatedBandwidth: Double?
                if let streamBw = audioBandwidthByGroup[groupId] {
                    // Audio is typically 64-384 kbps depending on channels
                    if let ch = channels {
                        if ch.contains("JOC") || ch == "16/JOC" {
                            estimatedBandwidth = 768_000  // Atmos ~768kbps
                        } else if ch == "6" || ch == "8" {
                            estimatedBandwidth = 384_000  // 5.1/7.1 ~384kbps
                        } else {
                            estimatedBandwidth = 128_000  // Stereo ~128kbps
                        }
                    } else {
                        // Estimate ~10% of total stream bandwidth
                        estimatedBandwidth = streamBw * 0.1
                    }
                }
                
                renditions.append(HLSAudioRendition(
                    groupId: groupId,
                    language: language,
                    name: name.isEmpty ? language : name,
                    uri: uri,
                    isDefault: isDefault,
                    autoSelect: autoSelect,
                    channels: channels,
                    bandwidth: estimatedBandwidth,
                    codecs: mediaCodecs
                ))
            }
        }
        
        return (renditions: renditions, embeddedAudioIsSpatial: embeddedAudioIsSpatial)
    }
    
    // MARK: - Parse HLS subtitle renditions from m3u8
    /// Parses #EXT-X-MEDIA:TYPE=SUBTITLES lines from an HLS master playlist.
    static func parseHLSSubtitleRenditions(from url: URL) async -> [SubtitleTrack] {
        do {
            let request: URLRequest
            if VidLinkService.isVidLinkProxyURL(url.absoluteString), let vidLinkReq = VidLinkService.makeRequest(for: url.absoluteString, timeoutInterval: 10) {
                request = vidLinkReq
            } else {
                var r = URLRequest(url: url)
                r.timeoutInterval = 10
                request = r
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let content = String(data: data, encoding: .utf8) else { return [] }
            return parseHLSSubtitleRenditions(from: content, baseUrl: url.absoluteString)
        } catch {
            StreamifyLogger.log("Failed to parse HLS subtitle renditions from \(url): \(error.localizedDescription)")
            return []
        }
    }

    /// Parse HLS subtitle renditions from manifest content string.
    /// Expects `#EXT-X-MEDIA:TYPE=SUBTITLES` lines with at least LANGUAGE and URI attributes.
    /// FORCED=YES tracks are labelled "(Forced)". Relative URIs are resolved against `baseUrl`.
    static func parseHLSSubtitleRenditions(from content: String, baseUrl: String) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MEDIA:") else { continue }

            let attributes = trimmed.replacingOccurrences(of: "#EXT-X-MEDIA:", with: "")
            let pairs = parseAttributeString(attributes)

            var type = ""
            var language = ""
            var name = ""
            var uri: String?
            var isForced = false

            for (key, value) in pairs {
                switch key {
                case "TYPE": type = value
                case "LANGUAGE": language = value
                case "NAME": name = value
                case "URI": uri = value
                case "FORCED": isForced = value.uppercased() == "YES"
                default: break
                }
            }

            guard type == "SUBTITLES" else { continue }
            guard let rawUri = uri, !rawUri.isEmpty else { continue }

            // Resolve relative URI against base URL
            let resolvedSource: String
            if rawUri.hasPrefix("http") {
                resolvedSource = rawUri
            } else if let base = URL(string: baseUrl) {
                resolvedSource = base.deletingLastPathComponent().appendingPathComponent(rawUri).absoluteString
            } else {
                resolvedSource = rawUri
            }

            let displayName: String
            if isForced {
                displayName = name.isEmpty ? "\(language) (Forced)" : "\(name) (Forced)"
            } else {
                displayName = name.isEmpty ? language : name
            }

            tracks.append(SubtitleTrack(
                language: displayName,
                source: resolvedSource,
                languageId: language,
                name: displayName
            ))
        }

        return tracks
    }
    
    // Store selected quality name and source URL for display
    @Published var selectedQualityName: String = "Auto"
    @Published var selectedQualitySourceUrl: String? = nil

    private func updateIntroState() {
        let inIntro = introDuration > 0 &&
            currentTime >= introStart &&
            currentTime < (introStart + introDuration)
        showSkipIntro = inIntro

        // endTime is an absolute timestamp (seconds from start) at which to show the "Next Episode" button
        if let endAbsolute = endTime, endAbsolute > 0 {
            if currentTime >= endAbsolute {
                showNextEpisode = true
            } else {
                showNextEpisode = false
            }
        } else {
            showNextEpisode = false
        }
    }

    private func updateLoadedTimeRanges() {
        guard let playerItem = playerItem, duration > 0 else { return }
        let ranges = playerItem.loadedTimeRanges.compactMap { value -> (start: Double, end: Double)? in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
            guard start.isFinite && end.isFinite else { return nil }
            return (start: start, end: end)
        }
        loadedTimeRanges = ranges
    }

    private func updateAutoQualityLabel(indicatedBitrate: Double) {
        guard indicatedBitrate > 0 else { return }
        lastIndicatedBitrate = indicatedBitrate
        // Find the closest matching quality by bandwidth, restricted to the active source
        // when possible. Torrentio is a separate direct-file source, so auto mode only
        // considers it when it is the only source represented.
        let candidateQualities = autoCandidateQualities()
        var bestMatch: HLSQuality?
        var bestDiff = Double.infinity
        for quality in candidateQualities {
            let diff = abs(quality.bandwidth - indicatedBitrate)
            if diff < bestDiff {
                bestDiff = diff
                bestMatch = quality
            }
        }
        if let match = bestMatch {
            // In HDR variant mode, isPlayingHDR is managed by switchToVariant()
            // and must NOT be overridden by bitrate matching — the match can
            // oscillate between SDR and HDR qualities when the indicated
            // bitrate falls near a boundary, causing the badge to flicker.
            if !isHDRVariantMode {
                isPlayingHDR = match.isHDR
            }
            // Only update the auto label text when in auto mode
            if selectedQuality == .auto {
                autoQualityLabel = match.name
                autoQualityIsHDR = match.isHDR
                autoQualitySourceName = match.sourceName
            }
        }
    }

    // MARK: - Playback controls

    private func beginSeek() -> Int {
        seekGeneration += 1
        isSeeking = true
        return seekGeneration
    }

    @discardableResult
    private func finishSeek(_ generation: Int) -> Bool {
        guard generation == seekGeneration else { return false }
        isSeeking = false
        return true
    }

    func isMPVAudioTrack(_ track: AudioTrack) -> Bool {
        track.trackId.hasPrefix("mpv-audio-")
    }

    func isMPVSubtitleTrack(_ track: SubtitleTrack) -> Bool {
        track.trackId.hasPrefix("mpv-subtitle-")
    }

    func selectMPVAudioTrack(_ track: AudioTrack?) {
        guard let engine = mpvEngine else { return }
        guard let track else {
            selectedMPVAudioTrackId = nil
            engine.selectAudio(id: nil)
            return
        }
        selectedMPVAudioTrackId = track.trackId
        engine.selectAudio(id: Self.mpvTrackId(from: track.trackId, prefix: "mpv-audio-"))
    }

    func disableMPVAudioOutput() {
        mpvEngine?.disableAudio()
    }

    func selectMPVSubtitleTrack(_ track: SubtitleTrack?) {
        guard let engine = mpvEngine else { return }
        guard let track else {
            engine.clearExternalSubtitles(selecting: nil)
            return
        }
        engine.clearExternalSubtitles(selecting: Self.mpvTrackId(from: track.trackId, prefix: "mpv-subtitle-"))
    }

    private static func mpvTrackId(from trackId: String, prefix: String) -> Int? {
        guard trackId.hasPrefix(prefix) else { return nil }
        return Int(trackId.dropFirst(prefix.count))
    }
    
    /// Start or resume playback.
    func play(onStarted: (() -> Void)? = nil) {
        isPlaying = true
        if let mpvEngine {
            mpvEngine.play(onStarted: onStarted)
        } else {
            customEngine?.play(onStarted: onStarted)
        }
    }

    /// Pause playback.
    func pause() {
        isPlaying = false
        mpvEngine?.pause()
        customEngine?.pause()
    }

    /// Resume playback after seek/scrub.
    func resume(onStarted: (() -> Void)? = nil) {
        isPlaying = true
        if let mpvEngine {
            mpvEngine.play(onStarted: onStarted)
        } else {
            customEngine?.play(onStarted: onStarted)
        }
    }

    /// Skip by the given number of seconds (positive = forward, negative = backward).
    /// Returns the actual seconds skipped (clamped to [0, duration]).
    /// Pauses before seeking so decoders stop cleanly. After the seek,
    /// a simple play() restarts playback — this replicates what manual
    /// unpause does, which is the only thing that reliably syncs audio.
    /// If the player was paused, it stays paused after the skip.
    @discardableResult
    func skip(by seconds: Double, resumeAfterSeek: Bool = true, completion: ((Bool) -> Void)? = nil) -> Double {
        guard customEngine != nil || mpvEngine != nil else { return 0 }
        let playerTime = realPlaybackTime
        let oldTime = isSeeking || abs(currentTime - playerTime) > 0.75 ? currentTime : playerTime
        let newTime = min(max(oldTime + seconds, 0), duration)
        let actualSkip = newTime - oldTime
        currentTime = newTime
        
        let wasPlaying = isPlaying

        let generation = beginSeek()
        customEngine?.pause()
        mpvEngine?.pause()
        seekEngine(to: newTime) { [weak self] finished in
            Task { @MainActor in
                guard self?.finishSeek(generation) == true else { return }
                guard finished else {
                    completion?(false)
                    return
                }
                if wasPlaying && resumeAfterSeek {
                    self?.play()
                } else {
                    self?.customEngine?.pause()
                    self?.mpvEngine?.pause()
                }
                completion?(true)
            }
        }
        return actualSkip
    }

    func seek(to seconds: Double) {
        guard customEngine != nil || mpvEngine != nil else { return }
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        currentTime = clamped
        let generation = beginSeek()
        seekEngine(to: clamped) { [weak self] finished in
            Task { @MainActor in
                guard self?.finishSeek(generation) == true else { return }
                guard finished else {
                    return
                }
            }
        }
    }
    
    func seek(to seconds: Double, completion: @escaping @MainActor @Sendable () -> Void) {
        guard customEngine != nil || mpvEngine != nil else {
            completion()
            return
        }
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        currentTime = clamped
        let generation = beginSeek()
        seekEngine(to: clamped) { [weak self] _ in
            Task { @MainActor in
                guard self?.finishSeek(generation) == true else { return }
                completion()
            }
        }
    }

    private func seekEngine(to seconds: Double, completion: ((Bool) -> Void)? = nil) {
        if let mpvEngine {
            mpvEngine.seek(time: seconds, completion: completion)
        } else {
            customEngine?.seek(time: seconds, completion: completion)
        }
    }
    
    /// Resets the player by pausing, re-seeking to the current position, and resuming.
    /// This flushes stale decoder state.
    func resetPlayerItem(completion: @escaping @Sendable () -> Void) {
        guard customEngine != nil || mpvEngine != nil else {
            completion()
            return
        }
        let savedTime = realPlaybackTime
        let wasPlaying = isPlaying
        customEngine?.pause()
        mpvEngine?.pause()
        seekEngine(to: savedTime) { [weak self] _ in
            Task { @MainActor in
                if wasPlaying {
                    self?.play()
                }
                StreamifyLogger.log("PlayerViewModel: resetPlayerItem complete — time=\(savedTime)s")
                completion()
            }
        }
    }

    func skipIntro(resumeAfterSeek: Bool = true, completion: (() -> Void)? = nil) {
        showSkipIntro = false
        let wasPlaying = isPlaying
        let target = introStart + introDuration
        // Update currentTime synchronously (same pattern as skip(by:)) so any
        // external caller — e.g. syncExternalAudio — immediately reads the
        // post-skip target position rather than the stale pre-skip position.
        currentTime = target
        // Use the same pause→seek→play pattern that skip(by:) uses.
        // Seeking while playing then resuming causes desync; pausing first
        // gives decoders a clean restart (like manual unpause).
        customEngine?.pause()
        mpvEngine?.pause()
        seek(to: target) { [weak self] in
            if wasPlaying && resumeAfterSeek {
                self?.play()
            }
            completion?()
        }
    }

    // MARK: - Quality control
    func setQuality(_ quality: VideoQuality) {
        selectedQuality = quality
        selectedQualityName = "Auto"
        selectedQualitySourceUrl = nil
        
        if isHDRVariantMode {
            // In PQ variant mode, restart ABR to let it pick the best variant
            if quality == .auto {
                startABRTimer()
                // Immediately evaluate and switch if we have throughput data
                evaluateABR()
            } else {
                // Non-auto preset: pick the closest variant and switch
                stopABRTimer()
                let targetBitrate = quality.peakBitRate > 0 ? quality.peakBitRate : Double.infinity
                if let best = pickBestVariant(forBitrate: targetBitrate) {
                    switchToVariant(best)
                }
            }
        } else {
            playerItem?.preferredPeakBitRate = quality.peakBitRate
            // Re-apply cached bitrate to update auto label and HDR state
            if lastIndicatedBitrate > 0 {
                updateAutoQualityLabel(indicatedBitrate: lastIndicatedBitrate)
            }
        }
    }

    // MARK: - HDR playback detection
    
    /// Check whether the display is actually rendering in HDR.
    /// Uses UIScreen EDR headroom APIs (iOS 16+) and inspects the
    /// currently playing video track's color metadata.
    /// Sets `isPlayingHDR` so the UI can show an indicator.
    ///
    /// In HDR variant mode, format descriptors are unreliable (MPEG-TS
    /// segments don't expose PQ/HLG transfer functions to AVPlayer). HDR
    /// status is instead determined from the manifest's VIDEO-RANGE attribute
    /// on the quality metadata (set by switchToVariant / setup), so we skip
    /// the override here.
    func logHDRPlaybackStatus() {
        if isUsingMPVPlayback {
            StreamifyLogger.log("HDR Check: MPV direct playback - keeping source metadata isPlayingHDR=\(isPlayingHDR)")
            return
        }

        // In HDR variant mode, trust the quality metadata — format descriptors
        // don't report HDR for MPEG-TS variant playlists.
        if isHDRVariantMode {
            let metadataHDR = currentVariantQuality?.isHDR ?? false
            StreamifyLogger.log("HDR Check: HDR variant mode — using quality metadata isHDR=\(metadataHDR) (skipping format descriptor check)")
            isPlayingHDR = metadataHDR
            return
        }
        
        // For local files (downloaded content served via localhost), format descriptors
        // are unreliable — MPEG-TS segments don't expose PQ/HLG transfer functions to
        // AVPlayer. HDR state for local files is determined by getLocalHLSResolution()
        // which parses master.m3u8 for VIDEO-RANGE and CODECS attributes.
        // Don't override that result here.
        if isLocalFile {
            StreamifyLogger.log("HDR Check: Local file — trusting manifest/metadata isPlayingHDR=\(isPlayingHDR) (skipping format descriptor check)")
            return
        }

        Task { @MainActor in
            let currentHeadroom: CGFloat
            let potentialHeadroom: CGFloat
            if #available(iOS 16.0, *) {
                currentHeadroom = UIScreen.main.currentEDRHeadroom
                potentialHeadroom = UIScreen.main.potentialEDRHeadroom
            } else {
                currentHeadroom = 1
                potentialHeadroom = 1
            }
            let edrActive = currentHeadroom > 1.0
            StreamifyLogger.log("HDR Check: currentEDRHeadroom=\(currentHeadroom) potentialEDRHeadroom=\(potentialHeadroom) isHDRActive=\(edrActive)")
            
            // Check video track color metadata for HDR transfer functions
            var trackHDR = false
            if let item = self.playerItem {
                do {
                    let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
                    for (i, track) in videoTracks.enumerated() {
                        let formatDescriptions = try await track.load(.formatDescriptions)
                        for desc in formatDescriptions {
                            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                                let colorPrimaries = extensions["ColorPrimaries"] as? String ?? "unknown"
                                let transferFunction = extensions["TransferFunction"] as? String ?? "unknown"
                                let isPQ = transferFunction.contains("2084") || transferFunction.lowercased().contains("pq")
                                let isHLG = transferFunction.lowercased().contains("hlg")
                                let isBT2020 = colorPrimaries.contains("2020")
                                StreamifyLogger.log("HDR Check: track[\(i)] colorPrimaries=\(colorPrimaries) transferFunction=\(transferFunction) isBT2020=\(isBT2020) isPQ=\(isPQ) isHLG=\(isHLG)")
                                if isPQ || isHLG {
                                    trackHDR = true
                                }
                            }
                        }
                    }
                } catch {
                    StreamifyLogger.log("HDR Check: Failed to inspect video tracks: \(error.localizedDescription)")
                }
            }
            
            self.isPlayingHDR = trackHDR
            StreamifyLogger.log("HDR Check: isPlayingHDR=\(self.isPlayingHDR) (edrActive=\(edrActive) trackHDR=\(trackHDR))")
        }
    }

    // MARK: - HDR Variant ABR (Adaptive Bitrate)
    
    /// Picks the best variant quality that fits within the given bitrate.
    /// Uses 80% of available bandwidth as safety margin.
    /// If bitrate is 0 or unavailable, returns the highest quality.
    private func pickBestVariant(forBitrate bitrate: Double) -> HLSQuality? {
        // Prefer HDR variants (PQ, HLG, generic HDR) when in HDR variant
        // mode, so we never fall back to SDR and cause brightness flashes.
        // If no HDR variants exist, fall back to all available qualities.
        var candidates = autoCandidateQualities(requireVariantURL: true).filter { $0.isHDR }
        if candidates.isEmpty {
            candidates = autoCandidateQualities(requireVariantURL: true)
        }
        guard !candidates.isEmpty else { return nil }
        
        // Sort by bandwidth ascending for selection
        let sorted = candidates.sorted { $0.bandwidth < $1.bandwidth }
        
        if bitrate <= 0 {
            // No measurement available — pick the highest quality and let ABR adapt down
            return sorted.last
        }
        
        // Use 80% of observed bandwidth as safe threshold
        let safeBitrate = bitrate * 0.8
        
        // Pick the highest quality that fits within the safe bandwidth
        var best: HLSQuality? = sorted.first  // fallback to lowest
        for quality in sorted {
            if quality.bandwidth <= safeBitrate {
                best = quality
            } else {
                break
            }
        }
        return best
    }
    
    /// Starts the ABR timer that evaluates network speed every 10 seconds.
    private func startABRTimer() {
        stopABRTimer()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateABR()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        abrTimer = timer
    }
    
    /// Stops the ABR timer.
    private func stopABRTimer() {
        abrTimer?.invalidate()
        abrTimer = nil
    }
    
    /// Evaluates current network throughput and switches variant if needed.
    private func evaluateABR() {
        guard isHDRVariantMode, selectedQuality == .auto else { return }
        guard lastObservedBitrate > 0 else { return }
        
        let bestVariant = pickBestVariant(forBitrate: lastObservedBitrate)
        guard let variant = bestVariant else { return }
        
        // Only switch if the variant is different from what's currently playing
        if let current = currentVariantQuality, current.variantUrl == variant.variantUrl {
            // Same variant — just update the label
            autoQualityLabel = variant.name
            autoQualityIsHDR = variant.isHDR
            autoQualitySourceName = variant.sourceName
            return
        }
        
        StreamifyLogger.log("PlayerViewModel ABR: observedBitrate=\(Int(lastObservedBitrate)) bps → switching to \(variant.name) (\(Int(variant.bandwidth)) bps)")
        switchToVariant(variant)
    }
    
    /// Switches to a different variant media playlist, preserving playback position.
    private func switchToVariant(_ quality: HLSQuality) {
        guard let urlStr = quality.variantUrl, let variantURL = URL(string: urlStr) else {
            StreamifyLogger.log("PlayerViewModel: switchToVariant failed — no variant URL for \(quality.name)")
            return
        }
        
        // Save real content position before replacing the item.
        let savedRealTime = realPlaybackTime
        let wasPlaying = isPlaying
        
        StreamifyLogger.log("PlayerViewModel: Switching to variant \(quality.name) URL=\(urlStr) savedRealTime=\(savedRealTime)")
        
        guard let engine = customEngine else { return }
        let generation = beginSeek()
        engine.pause()
        engine.replaceURL(variantURL, isHLS: true)
        currentPlaybackUrl = variantURL
        let seekTarget = max(savedRealTime - 1.0, 0)
        engine.seek(time: seekTarget) { [weak self] _ in
            Task { @MainActor in
                guard self?.finishSeek(generation) == true else { return }
                if wasPlaying {
                    self?.play {
                        self?.needsExternalAudioSync = true
                    }
                } else {
                    self?.needsExternalAudioSync = true
                }
            }
        }
        currentVariantQuality = quality
        isPlayingHDR = quality.isHDR
        if selectedQuality == .auto {
            autoQualityLabel = quality.name
            autoQualityIsHDR = quality.isHDR
            autoQualitySourceName = quality.sourceName
        }
    }

    // MARK: - Cleanup
    func cleanup() {
        StreamifyLogger.log("PlayerViewModel: cleanup() called")
        
        // Clean up custom player engine
        customEngine?.cleanup()
        customEngine = nil
        mpvEngine?.cleanup()
        mpvEngine = nil
        currentPlaybackUrl = nil
        pendingSeekAfterReady = nil
        pendingPlayAfterReady = false
        
        // Cancel any ongoing loading tasks (HLS parsing, resolution fetching)
        loadingTask?.cancel()
        loadingTask = nil
        
        // Cancel source retry task
        sourceRetryTask?.cancel()
        sourceRetryTask = nil
        
        // Stop ABR timer
        stopABRTimer()
        
        // Reset state
        isPlaying = false
        currentTime = 0
        duration = 0
        seekGeneration += 1
        isSeeking = false
        isReadyToPlay = false
        isPlayingHDR = false
        isBuffering = false
        availableQualities = []
        mpvAudioTracks = []
        mpvSubtitleTracks = []
        mpvRawAudioTracks = []
        mpvRawSubtitleTracks = []
        selectedMPVAudioTrackId = nil
        selectedMPVSubtitleTrackId = nil
        isHDRVariantMode = false
        currentVariantQuality = nil
        lastObservedBitrate = 0
        lastIndicatedBitrate = 0
        autoQualityLabel = ""
        autoQualityIsHDR = false
        autoQualitySourceName = nil
        selectedQualityName = "Auto"
        selectedQualitySourceUrl = nil
        activeAutoSourceUrl = nil
        hasAccessDeniedPlayback = false
        
        StreamifyLogger.log("PlayerViewModel: cleanup() completed")
    }
}
