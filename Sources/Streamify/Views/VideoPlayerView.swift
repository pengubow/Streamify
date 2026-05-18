import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

// MARK: - Main video player view

struct VideoPlayerView: View {
    let content: SavedContent
    let videoURL: URL
    let episodeInfo: EpisodeInfo?
    let onDismiss: () -> Void
    let onRequestNextEpisode: ((EpisodeInfo, URLCheckSkipper, @escaping @MainActor @Sendable (String) -> Void, @escaping @MainActor @Sendable () -> Void) async -> EpisodeChangeRequest?)?  // Accepts current episode to find next; returns next episode request or nil
    let onAddToLibraryAndRequestNext: ((EpisodeInfo, URLCheckSkipper, @escaping @MainActor @Sendable (String) -> Void, @escaping @MainActor @Sendable () -> Void) async -> EpisodeChangeRequest?)?  // Accepts current episode; adds to library and returns next episode request
    let onGoToBrowse: (() -> Void)?  // Navigate to Browse tab
    let isInLibrary: Bool  // Whether content is in library
    let onlineUrls: [String]  // Online HLS/file URLs for switching from downloaded to online play
    let onlineUrlSourceNames: [String: String]  // Mapping of online URL → source name for attribution
    let preloadedAudioTracks: [AudioTrack]?  // Pre-parsed HLS audio tracks
    let streamingSubtitles: [SubtitleTrack]?  // Streaming source subtitles to merge
    let preloadedQualities: [HLSQuality]?  // Pre-parsed HLS qualities
    @StateObject var viewModel = PlayerViewModel()
    @ObservedObject var downloadManager = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State var showControls: Bool = false  // Start with controls hidden
    @State var brightness: Double = Double(UIScreen.main.brightness)
    @State var dragStartBrightness: Double? = nil  // For relative brightness drag
    @State var showQualitySheet: Bool = false
    @State var pausedPlaybackForPicker: Bool = false
    @State var shouldResumeAfterPicker: Bool = false
    @State var hideWorkItem: DispatchWorkItem?
    @State var saveProgressTimer: Timer?
    @State var isUserSeeking: Bool = false  // Track if user is dragging the seek bar
    @State var previewTime: Double = 0  // Time preview while seeking
    @State var hasCalledDismiss: Bool = false  // Prevent double-calling onDismiss
    @State var playerReadyCancellable: AnyCancellable?  // For observing player ready state

    @State var hasProcessedReadyState: Bool = false  // Track if we've handled the ready state for this episode
    @State var isAnimatingExit: Bool = false  // Drives the landscape→portrait rotation animation on exit
    
    // Switch to online play
    @State var showSwitchToOnlineAlert: Bool = false
    @State var hasLocalFile: Bool = false  // Track if local file exists (for showing "Downloaded" in quality picker)
    @State var expandedQualityGroup: String?  // Tracks which quality group is expanded in picker
    
    // Current episode state - allows changing episodes without dismissing
    @State var currentVideoURL: URL
    @State var currentEpisodeInfo: EpisodeInfo?
    
    // Track if we're transitioning to next episode
    @State var isTransitioningToNext: Bool = false
    @State var transitionMessage: String = "Loading next episode..."
    /// Non-nil while `switchToOnlinePlay()` is in progress; cancel to abort the switch.
    @State var switchToOnlineTask: Task<Void, Never>? = nil
    /// Non-nil while `playNextEpisode()` or `addToLibraryAndPlayNext()` is resolving the next episode URL.
    @State var nextEpisodeTask: Task<Void, Never>? = nil
    /// Non-nil while a specific URL is being validated during `switchToOnlinePlay()`.
    /// Set to `nil` during service fetches (Torrentio/VidLink/111Movies) that can't be skipped individually.
    @State var onlineSwitchFetchingURL: String? = nil
    /// Allows the user to skip the current URL being validated in `switchToOnlinePlay()`.
    @State var onlineSwitchSkipper: URLCheckSkipper? = nil
    
    // Animated skip button state
    @State var skipBackwardAccumulated: Double = 0
    @State var skipForwardAccumulated: Double = 0
    @State var skipBackwardTextOpacity: Double = 0
    @State var skipForwardTextOpacity: Double = 0
    @State var skipBackwardTextOffset: CGFloat = 0
    @State var skipForwardTextOffset: CGFloat = 0
    @State var skipBackwardActive: Bool = false
    @State var skipForwardActive: Bool = false
    @State var skipBackwardFadeInTask: DispatchWorkItem?
    @State var skipBackwardFadeOutTask: DispatchWorkItem?
    @State var skipForwardFadeInTask: DispatchWorkItem?
    @State var skipForwardFadeOutTask: DispatchWorkItem?
    @State var skipBackwardStaticOpacity: Double = 1
    @State var skipForwardStaticOpacity: Double = 1
    @State var skipBackwardRestoreTask: DispatchWorkItem?
    @State var skipForwardRestoreTask: DispatchWorkItem?
    @State var skipBurstShouldResume: Bool = false
    @State var skipAudioSyncGeneration: Int = 0
    /// Debounce work items — fire the audio sync after the user stops pressing the skip buttons.
    @State var skipForwardSyncTask: DispatchWorkItem?
    @State var skipBackwardSyncTask: DispatchWorkItem?
    @State var pipSeekAudioSyncTask: DispatchWorkItem?
    
    // Subtitle state
    @State var showSubtitleSheet: Bool = false
    @AppStorage("selectedSubtitleLanguage") var selectedSubtitleLanguage: String = ""  // empty means subtitles off
    @AppStorage("selectedSubtitleTrackId") var selectedSubtitleTrackId: String = ""
    @AppStorage("preferredSubtitleLanguages") var preferredSubtitleLanguages: String = "English"
    @AppStorage("vidLinkEnabled") var vidLinkEnabled: Bool = true
    @AppStorage("movies111Enabled") var movies111Enabled: Bool = true
    @AppStorage("torrentioEnabled") var torrentioEnabled: Bool = false
    @State var subtitleCues: [SubtitleCue] = []
    @State var currentSubtitleText: String = ""
    @State var showSubtitleErrorAlert: Bool = false
    @State var expandedSubtitleGroup: String?  // Track which subtitle group is expanded
    @State var nativeMatroskaSubtitleTask: Task<Void, Never>? = nil
    @State var nativeMatroskaSubtitleTrackId: String? = nil
    @State var isSubtitlePreparing: Bool = false
    
    // Audio state
    @State var showAudioSheet: Bool = false
    @AppStorage("selectedAudioLanguage") var selectedAudioLanguage: String = ""  // empty means embedded/default audio
    @AppStorage("selectedAudioTrackId") var selectedAudioTrackId: String = ""  // trackId of selected audio track
    @State var showAudioErrorAlert: Bool = false
    @State var externalAudioPlayer: AVPlayer?
    @State var embeddedAudioPlayer: AVPlayer?
    @State var embeddedAudioObservers: [NSKeyValueObservation] = []
    @State var embeddedAudioIsSpatial: Bool = false
    @State var hlsAudioTracks: [AudioTrack] = []  // Audio tracks parsed from HLS manifests
    @State var currentStreamingSubtitles: [SubtitleTrack]? = nil  // Mutable streaming subtitles (updated on episode transitions)
    @State var expandedAudioGroup: String?  // Track which audio group is expanded
    @State var audioFallbackMessage: String? = nil  // Message when fallback audio was used
    @State var isAudioBuffering: Bool = false  // External audio is still loading
    @State var audioBufferingObservers: [NSKeyValueObservation] = []  // KVO observers for audio buffering
    @State var audioSyncGeneration: Int = 0  // Cancels stale async audio sync completions
    @State var activeAudioSyncGeneration: Int? = nil
    @State var isSyncingSeparateAudio: Bool = false
    @State var separateAudioSyncOffsetSeconds: Double = 0
    @State var separateAudioPausedForVideoBuffering: Bool = false
    @State var videoBufferingPauseTask: DispatchWorkItem?
    @State var remoteCommandTargets: [RemoteCommandTarget] = []

    @State var gateAudioStartForNextResume: Bool = false
    @State var lastPiPObservedVideoTime: Double?
    @State var lastPiPObservationDate: Date?

    // Volume overlay state
    @State var lastOutputVolume: Float?
    @State var displayedOutputVolume: Float = 0
    @State var isVolumeOverlayVisible: Bool = false
    @State var hideVolumeOverlayTask: DispatchWorkItem?

    // Variant picker state (for duplicate languageIds)
    @State var showAudioVariantSheet: Bool = false
    @State var audioVariantTracks: [AudioTrack] = []  // Tracks for the variant picker
    @State var showSubtitleVariantSheet: Bool = false
    @State var subtitleVariantTracks: [SubtitleTrack] = []  // Tracks for the variant picker
    
    // Picker download state
    @State var downloadingTrackLanguage: String? = nil  // Language currently being downloaded
    @State var downloadingTrackProgress: Double = 0  // Download progress 0..1
    @State var downloadingTrackTask: Task<Void, Never>? = nil
    @State var downloadingTrackId: String? = nil  // DownloadManager track download ID
    
    // Quality download state — quality downloads now use DownloadManager's main download queue (addQueuedDownload)
    // so pause/resume/cancel/progress are all handled by DownloadManager and shown via findMatchingMainDownload()
    @State var pickerRefreshId: Int = 0  // Incremented on delete to force picker UI refresh
    @State var refreshedSubtitles: [SubtitleTrack]? = nil  // Refreshed from disk when external download completes
    @State var refreshedAudioTracks: [AudioTrack]? = nil  // Refreshed from disk when external download completes
    @State var refreshedDownloadedQualities: [DownloadedVideoQuality]? = nil  // Refreshed from disk when external download completes
    @State var activePlayingQualityName: String? = nil  // Tracks which downloaded quality is currently playing
    @State var activePlayingQualityId: String? = nil  // Unique qualityId of the actively playing downloaded quality
    
    // Initialize state with initial values
    init(content: SavedContent, videoURL: URL, episodeInfo: EpisodeInfo?, onDismiss: @escaping () -> Void, onRequestNextEpisode: ((EpisodeInfo, URLCheckSkipper, @escaping @MainActor @Sendable (String) -> Void, @escaping @MainActor @Sendable () -> Void) async -> EpisodeChangeRequest?)? = nil, onAddToLibraryAndRequestNext: ((EpisodeInfo, URLCheckSkipper, @escaping @MainActor @Sendable (String) -> Void, @escaping @MainActor @Sendable () -> Void) async -> EpisodeChangeRequest?)? = nil, onGoToBrowse: (() -> Void)? = nil, isInLibrary: Bool, onlineUrls: [String] = [], onlineUrlSourceNames: [String: String] = [:], preloadedAudioTracks: [AudioTrack]? = nil, streamingSubtitles: [SubtitleTrack]? = nil, preloadedQualities: [HLSQuality]? = nil) {
        self.content = content
        self.videoURL = videoURL
        self.episodeInfo = episodeInfo
        self.onDismiss = onDismiss
        self.onRequestNextEpisode = onRequestNextEpisode
        self.onAddToLibraryAndRequestNext = onAddToLibraryAndRequestNext
        self.onGoToBrowse = onGoToBrowse
        self.isInLibrary = isInLibrary
        self.onlineUrls = onlineUrls
        self.onlineUrlSourceNames = onlineUrlSourceNames
        self.preloadedAudioTracks = preloadedAudioTracks
        self.streamingSubtitles = streamingSubtitles
        self.preloadedQualities = preloadedQualities
        
        // Initialize state with initial values
        _currentVideoURL = State(initialValue: videoURL)
        _currentEpisodeInfo = State(initialValue: episodeInfo)
        _currentStreamingSubtitles = State(initialValue: streamingSubtitles)
    }

    static func exactPlayerTime(for seconds: Double) -> CMTime {
        CMTime(seconds: max(seconds, 0), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    }

    static let embeddedAudioSyncThreshold: Double = 0.12
    static let pipSeekJumpThreshold: Double = 2.0
    static let skipInterval: Double = 10 // seconds per skip button tap
    static let skipButtonDebounceDelay: TimeInterval = 0.4 // seconds to wait after last tap before syncing audio
    static let volumeOverlayVisibleDuration: TimeInterval = 1.0
    static let outputVolumeStepCount: Float = 16
    static let maxDisplayUrlLength: Int = 60
    static let displayUrlSuffixLength: Int = 57

    // Get episode number from currentEpisodeInfo (for progress tracking)
    var episodeNumber: Int? {
        currentEpisodeInfo?.episode
    }
    
    // Check if this is a movie (no episodeInfo means movie)
    var isMovie: Bool {
        currentEpisodeInfo == nil
    }
    
    // Get all episodes
    var allEpisodes: [EpisodeInfo] {
        content.metadata.allEpisodes
    }
    
    // Get current episode array index
    var currentEpisodeArrayIndex: Int? {
        guard let ep = currentEpisodeInfo else { return nil }
        return allEpisodes.firstIndex(where: { $0.season == ep.season && $0.episode == ep.episode })
    }
    
    // Check if there's a next episode
    var hasNextEpisode: Bool {
        guard let idx = currentEpisodeArrayIndex else { return false }
        return idx < allEpisodes.count - 1
    }
    
    // Whether embedded audio is globally disabled for this content
    var isEmbeddedAudioDisabled: Bool {
        // Check content metadata flag
        if content.metadata.embeddedAudioDisabled { return true }
        // Also check source content flag
        let allSources = SourcesManager.allContent()
        if let src = allSources.first(where: { $0.id == content.id }), src.embeddedAudioDisabled {
            return true
        }
        // Legacy: check per-track isDisabled flag
        if audioTracksDisableEmbedded(currentEpisodeInfo?.audioTracks) { return true }
        if audioTracksDisableEmbedded(refreshedAudioTracks) { return true }
        if audioTracksDisableEmbedded(content.metadata.audioTracks) { return true }
        return false
    }

    func audioTracksDisableEmbedded(_ tracks: [AudioTrack]?) -> Bool {
        tracks?.contains(where: { $0.isEmbedded && $0.isDisabled }) == true
    }
    
    // Get available subtitles for current content
    // Shows all metadata subtitles for local playback (re-download handled on click).
    // For online playback, also includes subtitles from sources.
    var availableSubtitles: [SubtitleTrack] {
        var subs: [SubtitleTrack] = []
        let folderPaths = buildFolderPaths()
        
        // Helper to check if a local subtitle source actually exists on disk
        func localSubSourceExists(_ source: String, language: String) -> Bool {
            let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return false }
            if localContentFileURL(from: source, folderPaths: folderPaths) != nil { return true }
            if URL(string: source)?.scheme != nil { return false }
            if findLocalFile(named: source, in: folderPaths) != nil { return true }
            let names = possibleLocalFileNames(language: language, source: source, trackType: "subtitle", defaultExtension: "vtt")
            return findLocalFile(possibleNames: names, in: folderPaths) != nil
        }
        
        // Helper to merge tracks without collapsing same-language variants from different sources.
        // Downloaded tracks keep their original trackId, so the local copy replaces its remote source.
        func merge(_ newTracks: [SubtitleTrack]) {
            for track in newTracks {
                let sourceKey = canonicalTrackSourceKey(track.source, folderPaths: folderPaths)
                if let idx = subs.firstIndex(where: {
                    $0.trackId == track.trackId ||
                        (!sourceKey.isEmpty && canonicalTrackSourceKey($0.source, folderPaths: folderPaths) == sourceKey)
                }) {
                    let existing = subs[idx]
                    let existingIsLocal = localSubSourceExists(existing.source, language: existing.language)
                    let newIsLocal = localSubSourceExists(track.source, language: track.language)
                    if !existingIsLocal && newIsLocal {
                        subs[idx] = track
                    } else if !existingIsLocal && !newIsLocal && track.source.hasPrefix("http") && !existing.source.hasPrefix("http") {
                        // Existing has stale local reference, replace with remote
                        subs[idx] = track
                    }
                } else {
                    subs.append(track)
                }
            }
        }

        func subtitleLanguageKey(_ track: SubtitleTrack) -> String {
            let raw = track.languageId.hasPrefix("subtitle_") ? track.language : track.languageId
            return normalizedAudioLanguage(raw.isEmpty ? track.language : raw)
        }

        func appendMPVTracks(_ newTracks: [SubtitleTrack]) {
            let shouldPreferEmbeddedMatroskaSubtitles = viewModel.isUsingMPVPlayback &&
                viewModel.isLocalFile &&
                MatroskaPlaybackSupport.isMatroskaURL(currentVideoURL)
            for track in newTracks where track.sourceName == "MKV" {
                if shouldPreferEmbeddedMatroskaSubtitles {
                    let mpvLanguage = subtitleLanguageKey(track)
                    subs.removeAll { existing in
                        guard !viewModel.isMPVSubtitleTrack(existing),
                              subtitleLanguageKey(existing) == mpvLanguage else { return false }
                        return existing.sourceName == "MKV" || !isSubtitleLocallyAvailable(existing)
                    }
                }
                guard !subs.contains(where: { $0.trackId == track.trackId }) else { continue }
                subs.append(track)
            }
        }
        
        if let ep = currentEpisodeInfo {
            // Episode: start with episode-level subtitles from metadata
            // Include stored metadata subtitles for local playback, and also merge
            // any locally-downloaded tracks for online playback (download picker tracks)
            if viewModel.isLocalFile {
                if let epSubs = ep.subtitles, !epSubs.isEmpty {
                    merge(epSubs)
                }
                // Fall back to content-level subtitles if episode has none
                if subs.isEmpty, let contentSubs = content.metadata.subtitles, !contentSubs.isEmpty {
                    merge(contentSubs)
                }
            } else {
                // Online playback: still merge any locally-downloaded tracks from metadata
                // so download picker downloads appear in the picker
                if let epSubs = ep.subtitles?.filter({ !$0.source.isEmpty && !$0.source.hasPrefix("http") }), !epSubs.isEmpty {
                    merge(epSubs)
                }
                if subs.isEmpty, let contentSubs = content.metadata.subtitles?.filter({ !$0.source.isEmpty && !$0.source.hasPrefix("http") }), !contentSubs.isEmpty {
                    merge(contentSubs)
                }
            }
            // Merge refreshed subtitles from disk (after external download completes)
            if let refreshed = refreshedSubtitles {
                merge(refreshed)
            }
            // Also check source subtitles (for both local and online playback)
            let allSources = SourcesManager.allContent()
            for sourceContent in allSources where sourceContent.id == content.id {
                // Episode-level source subtitles
                if let epSubs = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles {
                    merge(epSubs)
                }
                // Content-level source subtitles as fallback
                if let contentSubs = sourceContent.subtitles {
                    merge(contentSubs)
                }
            }
            // Merge VidLink subtitles
            if let vlSubs = currentStreamingSubtitles {
                merge(vlSubs)
            }
            appendMPVTracks(viewModel.mpvSubtitleTracks)
            return subs
        }
        
        // For movies (no episode): use content-level subtitles
        // Include stored metadata subtitles for local playback, and also merge
        // any locally-downloaded tracks for online playback (download picker tracks)
        if viewModel.isLocalFile {
            merge(content.metadata.subtitles ?? [])
        } else {
            // Online playback: still merge any locally-downloaded tracks from metadata
            let localSubs = (content.metadata.subtitles ?? []).filter { !$0.source.isEmpty && !$0.source.hasPrefix("http") }
            if !localSubs.isEmpty { merge(localSubs) }
        }
        // Merge refreshed subtitles from disk (after external download completes)
        if let refreshed = refreshedSubtitles {
            merge(refreshed)
        }
        
        // Also include from sources (for both local and online playback)
        let allSources = SourcesManager.allContent()
        for sourceContent in allSources where sourceContent.id == content.id {
            merge(sourceContent.subtitles ?? [])
        }
        
        // Merge VidLink subtitles
        if let vlSubs = currentStreamingSubtitles {
            merge(vlSubs)
        }
        appendMPVTracks(viewModel.mpvSubtitleTracks)

        return subs
    }
    
    // Get available audio tracks for current content
    var availableAudioTracks: [AudioTrack] {
        var tracks: [AudioTrack] = []
        let folderPaths = buildFolderPaths()
        
        // Helper to check if a local audio source actually exists on disk
        func localSourceExists(_ source: String, language: String) -> Bool {
            let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return false }
            if localContentFileURL(from: source, folderPaths: folderPaths) != nil { return true }
            if URL(string: source)?.scheme != nil { return false }
            if findLocalFile(named: source, in: folderPaths) != nil { return true }
            let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
            return hlsAudioDirExistsOnDisk(language: language, prefix: prefix, folderPaths: folderPaths)
        }
        
        // Helper to merge tracks without collapsing same-language variants from
        // different sources/codecs. When the same concrete source appears twice,
        // prefer local source and upgrade isSpatial from parsed tracks.
        func merge(_ newTracks: [AudioTrack]) {
            for track in newTracks {
                let sourceKey = canonicalTrackSourceKey(track.source, folderPaths: folderPaths)
                if let idx = tracks.firstIndex(where: {
                    $0.trackId == track.trackId ||
                        (!sourceKey.isEmpty && canonicalTrackSourceKey($0.source, folderPaths: folderPaths) == sourceKey)
                }) {
                    let existing = tracks[idx]
                    let existingLooksLocal = !existing.source.isEmpty && !existing.source.hasPrefix("http")
                    let existingIsLocal = existingLooksLocal && localSourceExists(existing.source, language: existing.language)
                    let newIsLocal = !track.source.isEmpty && !track.source.hasPrefix("http") && localSourceExists(track.source, language: track.language)
                    // Replace remote with local, or upgrade isSpatial
                    if !existingIsLocal && newIsLocal {
                        tracks[idx] = AudioTrack(
                            language: track.language, source: track.source,
                            isSpatial: existing.isSpatial || track.isSpatial,
                            languageId: track.languageId, name: track.name,
                            bandwidth: track.bandwidth, trackId: track.trackId,
                            sourceName: track.sourceName,
                            originalTrackId: track.originalTrackId ?? existing.originalTrackId
                        )
                    } else if existingLooksLocal && !existingIsLocal && track.source.hasPrefix("http") {
                        // Existing has stale local reference (file missing), replace with remote
                        tracks[idx] = AudioTrack(
                            language: track.language, source: track.source,
                            isSpatial: existing.isSpatial || track.isSpatial,
                            languageId: track.languageId.isEmpty ? existing.languageId : track.languageId,
                            name: track.name ?? existing.name,
                            bandwidth: track.bandwidth ?? existing.bandwidth,
                            trackId: track.trackId.isEmpty ? existing.trackId : track.trackId,
                            sourceName: track.sourceName ?? existing.sourceName,
                            originalTrackId: track.originalTrackId ?? existing.originalTrackId
                        )
                    } else if track.isSpatial && !existing.isSpatial {
                        tracks[idx] = AudioTrack(
                            language: existing.language, source: existing.source,
                            isSpatial: true,
                            languageId: existing.languageId, name: existing.name,
                            bandwidth: existing.bandwidth, trackId: existing.trackId,
                            sourceName: existing.sourceName,
                            originalTrackId: existing.originalTrackId
                        )
                    }
                } else {
                    tracks.append(track)
                }
            }
        }

        func appendMPVTracks(_ newTracks: [AudioTrack]) {
            for track in newTracks where !tracks.contains(where: { $0.trackId == track.trackId }) {
                tracks.append(track)
            }
        }
        
        if let ep = currentEpisodeInfo {
            // Episode: start with episode-level audio tracks from metadata
            // Include stored metadata audio tracks for local playback, and also merge
            // any locally-downloaded tracks for online playback (download picker tracks)
            if viewModel.isLocalFile {
                if let epTracks = ep.audioTracks, !epTracks.isEmpty {
                    merge(epTracks)
                }
                // Fall back to content-level audio tracks if episode has none
                if tracks.isEmpty, let contentTracks = content.metadata.audioTracks, !contentTracks.isEmpty {
                    merge(contentTracks)
                }
            } else {
                // Online playback: still merge any locally-downloaded tracks from metadata
                if let epTracks = ep.audioTracks?.filter({ !$0.isEmbedded && !$0.source.isEmpty && !$0.source.hasPrefix("http") }), !epTracks.isEmpty {
                    merge(epTracks)
                }
                if tracks.isEmpty, let contentTracks = content.metadata.audioTracks?.filter({ !$0.isEmbedded && !$0.source.isEmpty && !$0.source.hasPrefix("http") }), !contentTracks.isEmpty {
                    merge(contentTracks)
                }
            }
            // Merge refreshed audio tracks from disk (after external download completes)
            if let refreshed = refreshedAudioTracks {
                merge(refreshed)
            }
            // Also check source audio tracks (for both local and online playback)
            let allSources = SourcesManager.allContent()
            for sourceContent in allSources where sourceContent.id == content.id {
                // Episode-level source audio tracks
                if let epTracks = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks {
                    merge(epTracks)
                }
                // Content-level source audio tracks as fallback
                if let contentTracks = sourceContent.audioTracks {
                    merge(contentTracks)
                }
            }
            // Merge HLS-parsed audio tracks
            merge(hlsAudioTracks)
            appendMPVTracks(viewModel.mpvAudioTracks)
            return tracks
        }
        
        // For movies: use content-level audio tracks
        // Include stored metadata audio tracks for local playback, and also merge
        // any locally-downloaded tracks for online playback (download picker tracks)
        if viewModel.isLocalFile {
            merge(content.metadata.audioTracks ?? [])
        } else {
            // Online playback: still merge any locally-downloaded tracks from metadata
            let localAudio = (content.metadata.audioTracks ?? []).filter { !$0.isEmbedded && !$0.source.isEmpty && !$0.source.hasPrefix("http") }
            if !localAudio.isEmpty { merge(localAudio) }
        }
        // Merge refreshed audio tracks from disk (after external download completes)
        if let refreshed = refreshedAudioTracks {
            merge(refreshed)
        }
        
        // Also include from sources (for both local and online playback)
        let allSources = SourcesManager.allContent()
        for sourceContent in allSources where sourceContent.id == content.id {
            merge(sourceContent.audioTracks ?? [])
        }
        
        // Merge HLS-parsed audio tracks
        merge(hlsAudioTracks)
        appendMPVTracks(viewModel.mpvAudioTracks)

        return tracks
    }
    
    /// Whether there are audio tracks usable in the current playback mode.
    /// During local playback, only locally downloaded (non-embedded) tracks count.
    /// During streaming, any non-embedded track counts.
    var hasUsableAudioTracks: Bool {
        let _ = pickerRefreshId
        let tracks = availableAudioTracks.filter { !$0.isEmbedded }
        if viewModel.isUsingMPVPlayback {
            return !tracks.isEmpty
        }
        if viewModel.isLocalFile {
            return tracks.contains { isAudioLocallyAvailable($0) }
        }
        return !tracks.isEmpty
    }
    
    /// Whether there are subtitles usable in the current playback mode.
    /// During local playback, only locally downloaded subtitles count.
    /// During streaming, any subtitle counts.
    var hasUsableSubtitles: Bool {
        let _ = pickerRefreshId
        let subs = availableSubtitles
        if viewModel.isUsingMPVPlayback {
            return !subs.isEmpty
        }
        if viewModel.isLocalFile {
            return subs.contains { isSubtitleLocallyAvailable($0) }
        }
        return !subs.isEmpty
    }
    
    /// Build the list of folder paths to check for local track files.
    /// Order: episode-specific folder → content folder → effective folder (id-based fallback).
    func buildFolderPaths() -> [String] {
        var paths: [String] = []
        if let ep = currentEpisodeInfo {
            paths.append(resolveEpisodeFolderPath(for: ep))
        }
        if !content.folderPath.isEmpty {
            paths.append(content.folderPath)
        }
        let effPath = effectiveFolderPath
        if !paths.contains(effPath) {
            paths.append(effPath)
        }
        return paths
    }
    
    /// Build possible local file names for a downloaded track.
    /// Uses language + extension naming convention with optional episode prefix.
    func possibleLocalFileNames(language: String, source: String, trackType: String, defaultExtension: String) -> [String] {
        let lang = language.lowercased().replacingOccurrences(of: " ", with: "_")
        let ext: String
        if source.hasPrefix("http"), let u = URL(string: source), !u.pathExtension.isEmpty {
            ext = u.pathExtension
        } else {
            ext = defaultExtension
        }
        if let ep = currentEpisodeInfo {
            return [
                "ep\(ep.episode)_\(trackType)_\(lang).\(ext)",
                "\(trackType)_\(lang).\(ext)"
            ]
        } else {
            return ["\(trackType)_\(lang).\(ext)"]
        }
    }
    
    /// Search folder paths for an existing local file, returning its URL if found.
    func findLocalFile(named source: String, in folderPaths: [String]) -> URL? {
        for folder in folderPaths where !folder.isEmpty {
            let localURL = ContentImportService.contentDirectoryURL
                .appendingPathComponent(folder)
                .appendingPathComponent(source)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }
        return nil
    }
    
    /// Search folder paths for any of the possible file names, returning the first match.
    func findLocalFile(possibleNames: [String], in folderPaths: [String]) -> URL? {
        for folder in folderPaths where !folder.isEmpty {
            for fileName in possibleNames {
                let localURL = ContentImportService.contentDirectoryURL
                    .appendingPathComponent(folder)
                    .appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return localURL
                }
            }
        }
        return nil
    }
    
    func localContentFileURL(from source: String, folderPaths: [String]) -> URL? {
        let sourceStr = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceStr.isEmpty else { return nil }

        if let url = URL(string: sourceStr), url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        if sourceStr.hasPrefix("/") {
            let url = URL(fileURLWithPath: sourceStr)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        if let url = URL(string: sourceStr),
           let host = url.host,
           host == "localhost" || host == "127.0.0.1" {
            let relativePath = String(url.path.drop(while: { $0 == "/" }))
            guard !relativePath.isEmpty else { return nil }
            let localURL = ContentImportService.contentDirectoryURL.appendingPathComponent(relativePath)
            return FileManager.default.fileExists(atPath: localURL.path) ? localURL : nil
        }

        if let url = URL(string: sourceStr), url.scheme != nil {
            return nil
        }

        return findLocalFile(named: sourceStr, in: folderPaths)
    }

    func canonicalTrackSourceKey(_ source: String, folderPaths: [String]) -> String {
        let sourceStr = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceStr.isEmpty else { return "" }
        if let url = localContentFileURL(from: sourceStr, folderPaths: folderPaths) {
            return "file:" + url.standardizedFileURL.path.lowercased()
        }
        return sourceStr.lowercased()
    }
    
    // Check if a subtitle track has a locally downloaded file
    func isSubtitleLocallyAvailable(_ track: SubtitleTrack) -> Bool {
        let sourceStr = track.source
        let folderPaths = buildFolderPaths()

        if localContentFileURL(from: sourceStr, folderPaths: folderPaths) != nil {
            return true
        }
        if !sourceStr.hasPrefix("http") && !sourceStr.isEmpty {
            return false
        }
        // It's a remote URL - check if a local downloaded version exists on disk
        let names = possibleLocalFileNames(language: track.language, source: sourceStr, trackType: "subtitle", defaultExtension: "vtt")
        return findLocalFile(possibleNames: names, in: folderPaths) != nil
    }
    
    // Check if an audio track has a locally downloaded file
    func isAudioLocallyAvailable(_ track: AudioTrack) -> Bool {
        if track.isEmbedded { return true }
        let sourceStr = track.source
        let folderPaths = buildFolderPaths()

        // If it's a local file reference (not http), check if it exists
        if localContentFileURL(from: sourceStr, folderPaths: folderPaths) != nil {
            return true
        }
        if !sourceStr.hasPrefix("http") && !sourceStr.isEmpty {
            return false
        }
        // It's a remote URL - check if a local downloaded version exists on disk
        let names = possibleLocalFileNames(language: track.language, source: sourceStr, trackType: "audio", defaultExtension: "mp3")
        if findLocalFile(possibleNames: names, in: folderPaths) != nil { return true }
        // Also check for HLS audio directory directly on disk (without requiring server)
        let prefix = currentEpisodeInfo.map { "ep\($0.episode)_" } ?? ""
        return hlsAudioDirExistsOnDisk(language: track.language, prefix: prefix, folderPaths: folderPaths)
    }
    
    /// Check if a locally downloaded HLS audio directory exists on disk (without starting the server).
    func hlsAudioDirExistsOnDisk(language: String, prefix: String, folderPaths: [String]) -> Bool {
        let lang = language.lowercased().replacingOccurrences(of: " ", with: "_")
        let dirNames = prefix.isEmpty ? ["audio_\(lang)"] : ["\(prefix)audio_\(lang)", "audio_\(lang)"]
        for folder in folderPaths where !folder.isEmpty {
            for dirName in dirNames {
                let m3u8Path = ContentImportService.contentDirectoryURL
                    .appendingPathComponent(folder)
                    .appendingPathComponent(dirName)
                    .appendingPathComponent("\(dirName).m3u8")
                if FileManager.default.fileExists(atPath: m3u8Path.path) {
                    return true
                }
            }
        }
        return false
    }
    
    // Resolve the episode-specific folder path for subtitle lookups
    func resolveEpisodeFolderPath(for episode: EpisodeInfo) -> String {
        return DownloadManager.episodeFolderPath(contentId: content.id, season: episode.season, episode: episode.episode)
    }
    
    // Resolve subtitle URL for a given track, with local file fallback
    func resolveSubtitleURL(for track: SubtitleTrack) -> URL? {
        let sourceStr = track.source
        let folderPaths = buildFolderPaths()
        
        // Check if it's a local file reference
        if !sourceStr.hasPrefix("http") {
            if let url = findLocalFile(named: sourceStr, in: folderPaths) {
                return url
            }
        }
        // Check if a local downloaded version exists (by language naming convention)
        let names = possibleLocalFileNames(language: track.language, source: sourceStr, trackType: "subtitle", defaultExtension: "vtt")
        if let url = findLocalFile(possibleNames: names, in: folderPaths) {
            return url
        }
        // Try as remote URL
        if sourceStr.hasPrefix("http"), let url = URL(string: sourceStr) {
            return url
        }
        // Fallback: look up subtitle URL from sources
        let allSources = SourcesManager.allContent()
        if let sourceContent = allSources.first(where: { $0.id == content.id }),
           let sourceTrack = sourceContent.subtitles?.first(where: { $0.language == track.language }),
           sourceTrack.source.hasPrefix("http"),
           let url = URL(string: sourceTrack.source) {
            return url
        }
        // Final fallback: try resolving a remote URL (from metadata, etc.)
        if let remoteURL = resolveRemoteSubtitleURL(for: track) {
            return remoteURL
        }
        return nil
    }

    /// Resolve a remote (HTTP) source URL for an audio track, looking up from all sources.
    /// Used when the merged track has a local source but we need the remote URL for downloading.
    func resolveRemoteAudioURL(for track: AudioTrack) -> URL? {
        // If the track itself has an HTTP source, use it directly
        if track.source.hasPrefix("http"), let url = URL(string: track.source) {
            return url
        }
        // Check HLS-parsed audio tracks (from master playlist parsing)
        if let hlsTrack = hlsAudioTracks.first(where: { $0.language.lowercased() == track.language.lowercased() }),
           hlsTrack.source.hasPrefix("http"), let url = URL(string: hlsTrack.source) {
            return url
        }
        // Look up from sources
        let allSources = SourcesManager.allContent()
        for sourceContent in allSources where sourceContent.id == content.id {
            if let ep = currentEpisodeInfo {
                if let epTrack = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks?.first(where: { $0.language.lowercased() == track.language.lowercased() }),
                   epTrack.source.hasPrefix("http"), let url = URL(string: epTrack.source) {
                    return url
                }
            }
            if let contentTrack = sourceContent.audioTracks?.first(where: { $0.language.lowercased() == track.language.lowercased() }),
               contentTrack.source.hasPrefix("http"), let url = URL(string: contentTrack.source) {
                return url
            }
        }
        // Check content metadata
        if let epTracks = currentEpisodeInfo.flatMap({ ep in content.metadata.episodes?.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.audioTracks }),
           let match = epTracks.first(where: { $0.language.lowercased() == track.language.lowercased() && $0.source.hasPrefix("http") }),
           let url = URL(string: match.source) {
            return url
        }
        if let match = content.metadata.audioTracks?.first(where: { $0.language.lowercased() == track.language.lowercased() && $0.source.hasPrefix("http") }),
           let url = URL(string: match.source) {
            return url
        }
        return nil
    }

    /// Resolve a remote (HTTP) source URL for a subtitle track, looking up from all sources.
    func resolveRemoteSubtitleURL(for track: SubtitleTrack) -> URL? {
        if track.source.hasPrefix("http"), let url = URL(string: track.source) {
            return url
        }
        let allSources = SourcesManager.allContent()
        for sourceContent in allSources where sourceContent.id == content.id {
            if let ep = currentEpisodeInfo {
                if let epTrack = sourceContent.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles?.first(where: { $0.language.lowercased() == track.language.lowercased() }),
                   epTrack.source.hasPrefix("http"), let url = URL(string: epTrack.source) {
                    return url
                }
            }
            if let contentTrack = sourceContent.subtitles?.first(where: { $0.language.lowercased() == track.language.lowercased() }),
               contentTrack.source.hasPrefix("http"), let url = URL(string: contentTrack.source) {
                return url
            }
        }
        if let epSubs = currentEpisodeInfo.flatMap({ ep in content.metadata.episodes?.first(where: { $0.season == ep.season && $0.episode == ep.episode })?.subtitles }),
           let match = epSubs.first(where: { $0.language.lowercased() == track.language.lowercased() && $0.source.hasPrefix("http") }),
           let url = URL(string: match.source) {
            return url
        }
        if let match = content.metadata.subtitles?.first(where: { $0.language.lowercased() == track.language.lowercased() && $0.source.hasPrefix("http") }),
           let url = URL(string: match.source) {
            return url
        }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

    // Video layer — Custom Metal renderer
            if let engine = viewModel.mpvEngine {
                MPVDirectPlayerView(engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let engine = viewModel.customEngine {
                CustomPlayerView(engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Subtitle text overlay
            if !currentSubtitleText.isEmpty {
                VStack {
                    Spacer()
                    Text(currentSubtitleText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.52))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, 32)
                        .padding(.bottom, showControls ? 98 : 32)
                }
                .allowsHitTesting(false)
            }

            // Tap target when controls are hidden
            if !showControls {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showControls = true }
                        scheduleHideControls()
                    }
            }

            // Controls overlay with fade in/out animation
            ZStack {
                if showControls {
                    controlsOverlay
                        .compositingGroup()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showControls)
            .onChange(of: showControls) { visible in
                if visible {
                    // Reset static "10" text when controls reappear
                    skipBackwardActive = false
                    skipForwardActive = false
                    skipBackwardStaticOpacity = 1
                    skipForwardStaticOpacity = 1
                }
            }
            .onChange(of: viewModel.needsExternalAudioSync) { needsSync in
                if needsSync {
                    viewModel.needsExternalAudioSync = false
                    syncSeparateAudio(shouldResume: viewModel.playbackRate > 0 || viewModel.isPlaying)
                }
            }
            .onChange(of: viewModel.isBuffering) { buffering in
                guard hasSeparateAudioPlayer else { return }
                if buffering {
                    markSeekedPlaybackNeedsVideoGate()
                    scheduleSeparateAudioPauseIfVideoClockStalls()
                } else if separateAudioPausedForVideoBuffering && !isSyncingSeparateAudio && (viewModel.isPlaying || viewModel.playbackRate > 0) {
                    cancelVideoBufferingPauseTask()
                    separateAudioPausedForVideoBuffering = false
                    syncSeparateAudio(shouldResume: true)
                } else if !buffering {
                    cancelVideoBufferingPauseTask()
                    separateAudioPausedForVideoBuffering = false
                }
            }
            .onChange(of: viewModel.isPlaying) { isPlaying in
                if isPlaying && isPickerOrSwitchAlertPresented {
                    pausePlaybackForPresentedPicker()
                    return
                }
                guard hasSeparateAudioPlayer else { return }
                if isPlaying {
                    // React to play events that come from PiP system controls, which bypass
                    // our normal button handlers and go directly to AVPlayer.
                    guard shouldHandlePiPPlaybackEvent else { return }
                    playWithSyncedAudio()
                } else if !isSyncingSeparateAudio {
                    pauseSeparateAudio(cancelSync: !(skipBurstShouldResume || isDeferredAudioSyncPending))
                }
            }
            .onChange(of: viewModel.isPiPActive) { active in
                resetPiPSeekObservation()
                guard active, hasSeparateAudioPlayer else { return }
                syncSeparateAudio(shouldResume: viewModel.isPlaying || viewModel.playbackRate > 0)
                StreamifyLogger.log("Audio: PiP active — separate audio sync armed")
            }
            .onChange(of: viewModel.currentTime) { _ in
                observePiPVideoSeekAndSyncSeparateAudioIfNeeded()
                // Update subtitle cue whenever the playback time changes
                if !subtitleCues.isEmpty {
                    let ct = viewModel.currentTime
                    let cue = subtitleCues.first { ct >= $0.startTime && ct <= $0.endTime }
                    let newText = cue?.text ?? ""
                    if newText != currentSubtitleText {
                        currentSubtitleText = newText
                    }
                }
            }
            .onChange(of: viewModel.mpvLiveSubtitleText) { text in
                // Feed live mpv sub-text into the overlay when no pre-parsed cues are loaded.
                // This covers both streaming MPV subtitles and local MKV fallback when
                // WebVTT extraction is unavailable.
                if subtitleCues.isEmpty {
                    currentSubtitleText = text
                }
            }

            // Skip Intro button - only show if intro value exists
            if viewModel.showSkipIntro && (currentEpisodeInfo?.intro != nil || content.metadata.intro != nil) {
                skipIntroButton
            }

            // Next Episode / Watch Something Else button
            if viewModel.showNextEpisode {
                nextEpisodeButtons
            }

            // Loading indicator — hidden when controls are visible to avoid overlapping with pause button.
            if (viewModel.isBuffering || isAudioBuffering || isSubtitlePreparing) &&
                !showControls &&
                !isTransitioningToNext {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    if isSubtitlePreparing {
                        Text("Preparing subtitles...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: showControls)
            }

            // Transition overlay — always visible on top of controls with translucent background
            if isTransitioningToNext {
                ZStack {
                    StreamifyGrayBlurBackdrop()
                    VStack(spacing: 20) {
                        Text(transitionMessage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        // Show the URL currently being validated (mirrors ContentDetailView behaviour)
                        if let fetchingURL = onlineSwitchFetchingURL {
                            Text(fetchingURL)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        if switchToOnlineTask != nil || nextEpisodeTask != nil {
                            HStack(spacing: 12) {
                                // Skip: only shown while a specific URL is being checked
                                if onlineSwitchSkipper != nil && onlineSwitchFetchingURL != nil {
                                    Button("Skip") {
                                        onlineSwitchSkipper?.skip()
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                // Cancel: aborts the entire switch or next-episode resolution
                                Button("Cancel") {
                                    if switchToOnlineTask != nil {
                                        cancelSwitchToOnlinePlay()
                                    } else {
                                        cancelNextEpisode()
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .streamifyPromptPanel()
                    .padding(.horizontal, 32)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: isTransitioningToNext)
            }

            volumeChangeOverlay
                .zIndex(1000)

            HiddenSystemVolumeHUDView()
                .frame(width: 2, height: 2)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            .scaleEffect(isAnimatingExit ? min(1.0, geometry.size.height / geometry.size.width) : 1.0)
            .rotationEffect(.degrees(isAnimatingExit ? -90 : 0))
            .animation(.easeInOut(duration: 0.35), value: isAnimatingExit)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // Lock to landscape and force rotation before setting up player
            OrientationManager.shared.rotate(to: .landscapeLeft)
            // Set initial quality name for local playback
            if videoURL.isFileURL || videoURL.host == "localhost" {
                activePlayingQualityName = resolveActiveLocalQualityName()
            }
            setupRemoteCommandHandlers()
            setupPlayer()
            prepareVolumeMonitoring()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // App is backgrounding — trim decoder buffers on all players to
                // release memory held by mediaserverd and reduce crash risk.
                viewModel.customEngine?.trimDecoderBuffers()
                trimSeparateAudioBuffers()
            case .active:
                // App returned to foreground — restore buffers so playback can
                // prefetch freely again.
                if viewModel.isPlaying {
                    viewModel.customEngine?.restoreDecoderBuffers()
                    restoreSeparateAudioBuffers()
                }
            default:
                break
            }
        }
        .onDisappear {
            // Force portrait when leaving video player
            OrientationManager.shared.rotate(to: .portrait)
            // Save progress before leaving
            saveProgress()
            // Handle end-of-playback: mark movies/series as watched, advance to next episode
            handleEndOfPlayback()
            viewModel.cleanup()
            MatroskaPlaybackSupport.cleanupTransientStreams()
            stopProgressSaving()
            externalAudioPlayer?.pause()
            externalAudioPlayer = nil
            cancelNativeMatroskaSubtitlePreparation()
            stopCompensatedEmbeddedAudio(unmuteMain: false)
            audioBufferingObservers.removeAll()
            teardownRemoteCommandHandlers()
            hideVolumeOverlayTask?.cancel()
            hideVolumeOverlayTask = nil
            resetPiPSeekObservation()
            // Cancel any in-progress track download task
            downloadingTrackTask?.cancel()
            downloadingTrackTask = nil
            // Call onDismiss to ensure LibraryView refreshes (handles swipe-to-dismiss)
            // Only call if not already called from back button
            if !hasCalledDismiss {
                hasCalledDismiss = true
                onDismiss()
            }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            observePiPVideoSeekAndSyncSeparateAudioIfNeeded()
        }
        .onChange(of: viewModel.hasAccessDeniedPlayback) { denied in
            guard denied else { return }
            showControls = true
            if !viewModel.availableQualities.isEmpty {
                showQualitySheet = true
            }
        }
        .onChange(of: viewModel.mpvAudioTracks) { tracks in
            handleMPVAudioTracksChanged(tracks)
            pickerRefreshId += 1
            reapplyAudioAfterTrackDiscovery()
        }
        .onChange(of: viewModel.mpvSubtitleTracks) { _ in
            pickerRefreshId += 1
            if hasProcessedReadyState,
               (!selectedSubtitleTrackId.isEmpty || !selectedSubtitleLanguage.isEmpty) {
                restoreSubtitleTrackAfterPlayerReady()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in
            let systemBrightness = Double(UIScreen.main.brightness)
            if abs(brightness - systemBrightness) > 0.01 {
                brightness = systemBrightness
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            handleAudioRouteChange(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            handleAudioSessionInterruption(notification)
        }
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume)) { volume in
            handleOutputVolumeChange(volume)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            handleOutputVolumeChange(AVAudioSession.sharedInstance().outputVolume)
        }
        .onReceive(NotificationCenter.default.publisher(for: DownloadManager.downloadCompletedNotification)) { _ in
            // A download completed externally — refresh local file detection and picker state
            let newHasLocal = checkHasLocalFile()
            if newHasLocal != hasLocalFile {
                hasLocalFile = newHasLocal
            }
            // Re-read metadata from disk so newly downloaded tracks appear in pickers
            let metadataFolder = effectiveFolderPath
            if let freshMetadata = ContentImportService.loadMetadata(from: metadataFolder) {
                if let ep = currentEpisodeInfo {
                    // Find the episode in fresh metadata
                    let freshEp = freshMetadata.allEpisodes.first(where: { $0.season == ep.season && $0.episode == ep.episode })
                    refreshedSubtitles = freshEp?.subtitles ?? freshMetadata.subtitles
                    refreshedAudioTracks = freshEp?.audioTracks ?? freshMetadata.audioTracks
                    refreshedDownloadedQualities = freshEp?.downloadedVideoQualities ?? freshMetadata.downloadedVideoQualities
                } else {
                    refreshedSubtitles = freshMetadata.subtitles
                    refreshedAudioTracks = freshMetadata.audioTracks
                    refreshedDownloadedQualities = freshMetadata.downloadedVideoQualities
                }
            }
            pickerRefreshId += 1
            
            // Re-parse HLS audio tracks from master.m3u8 (may have been saved by a quality download)
            let folderPaths = buildFolderPaths()
            Task {
                for folder in folderPaths where !folder.isEmpty {
                    let masterPath = ContentImportService.contentDirectoryURL
                        .appendingPathComponent(folder)
                        .appendingPathComponent("master.m3u8")
                    if FileManager.default.fileExists(atPath: masterPath.path) {
                        let result = await PlayerViewModel.parseHLSAudioRenditions(from: masterPath)
                        let parsed = result.renditions.map { $0.toAudioTrack(hlsBaseUrl: masterPath.absoluteString) }
                        if !parsed.isEmpty {
                            await MainActor.run {
                                hlsAudioTracks = parsed
                            }
                            break
                        }
                    }
                }
            }
        }
        .onChange(of: showQualitySheet) { _ in handlePickerPresentationChange() }
        .onChange(of: showSubtitleSheet) { _ in handlePickerPresentationChange() }
        .onChange(of: showAudioSheet) { _ in handlePickerPresentationChange() }
        .onChange(of: showSubtitleVariantSheet) { _ in handlePickerPresentationChange() }
        .onChange(of: showAudioVariantSheet) { _ in handlePickerPresentationChange() }
        .onChange(of: showSwitchToOnlineAlert) { _ in handlePickerPresentationChange() }
        .statusBarHidden(true)
        .streamifyPersistentSystemOverlaysHidden()
        .preferredColorScheme(.dark)
        .streamifyBottomPopup(isPresented: $showQualitySheet) {
            qualityPicker
        }
        .streamifyBottomPopup(isPresented: $showSubtitleSheet) {
            subtitlePicker
        }
        .streamifyBottomPopup(isPresented: $showAudioSheet) {
            audioPicker
        }
        .streamifyBottomPopup(isPresented: $showSubtitleVariantSheet) {
            subtitleVariantPicker
        }
        .streamifyBottomPopup(isPresented: $showAudioVariantSheet) {
            audioVariantPicker
        }
        .streamifyCenteredPopup(isPresented: $showSwitchToOnlineAlert, dismissOnBackdrop: false) {
            StreamifyCenteredPrompt(
                title: "Switch to Online Play",
                message: "Switch from downloaded to online streaming? Your progress will be saved.",
                primaryTitle: "Switch",
                secondaryTitle: "Stay Offline",
                primaryAction: {
                    showSwitchToOnlineAlert = false
                    switchToOnlinePlay()
                },
                secondaryAction: {
                    showSwitchToOnlineAlert = false
                    playWithSyncedAudio()
                }
            )
        }
    }
}
