import AVFoundation
import AVKit
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Constants
/// Tolerance for detecting 16:9 aspect ratio (± 0.05 of 1.778).
/// Used to distinguish padded 16:9 frames (with baked-in bars) from
/// actual content dimensions.
private let k16x9Ratio: CGFloat = 16.0 / 9.0
private let k16x9Tolerance: CGFloat = 0.05
private let kBoundedHLSForwardBufferDuration: TimeInterval = 30
private let kTrimmedForwardBufferDuration: TimeInterval = 1

// MARK: - Player Layer View
/// Custom UIView using CAMetalLayer as root with AVPlayerLayer as sublayer.
/// CAMetalLayer provides wantsExtendedDynamicRangeContent for HDR/EDR support.
/// AVPlayerLayer handles video decoding and rendering natively (same path as Safari).
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    let playerLayer = AVPlayerLayer()

    private var readyObservation: NSKeyValueObservation?

    /// The actual content aspect ratio (width/height), learned from a
    /// non-padded video variant (e.g., 1080p at 1920×800 = 2.4:1).
    /// When playing a padded variant (16:9 frame with baked-in letterbox
    /// bars, common in 4K), this ratio determines additional cropping so
    /// the visible video matches the un-padded variant.
    var contentAspectRatio: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        clipsToBounds = true
        metalLayer.isOpaque = true
        if #available(iOS 16.0, *) {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
        // Match the sublayer's contentsScale to the screen so the
        // compositor renders video at the correct pixel density.
        // Without this, playerLayer defaults to 1.0 while the root
        // CAMetalLayer is at screen scale — the mismatch can cause
        // higher-resolution content (4K) to composite incorrectly.
        playerLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(playerLayer)

        // Re-layout when the player layer has displayable content so
        // videoRect is accurate for letterbox-bar detection.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Set to view bounds first so videoRect is calculated for this size.
        playerLayer.frame = bounds
        // Update scale in case the view moved to a different screen
        playerLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale

        let vr = playerLayer.videoRect
        guard vr.width > 1 && vr.height > 1 else {
            CATransaction.commit()
            return
        }

        let resolvedSafeArea = StreamifySafeArea.resolvedInsets(fallback: safeAreaInsets)
        guard StreamifySafeArea.shouldCropVideoToFill(bounds: bounds, safeAreaInsets: resolvedSafeArea) else {
            CATransaction.commit()
            return
        }

        // 1. Scale to fill both dimensions — removes player-added
        //    letterbox bars (top/bottom) AND pillar bars (left/right).
        let scaleX = bounds.width / vr.width
        let scaleY = bounds.height / vr.height
        var scale = max(scaleX, scaleY)

        // 2. Handle baked-in letterbox bars (e.g., 4K at 16:9 with
        //    cinema content inside). If we know the actual content
        //    aspect ratio from a non-padded variant, compute additional
        //    scaling so only the movie content fills the view.
        if contentAspectRatio > 0 {
            let frameRatio = vr.width / vr.height
            if contentAspectRatio > frameRatio + k16x9Tolerance {
                // Content is wider than the video frame → baked-in bars.
                // Scale = contentAR / frameAR crops them exactly.
                // Add a 1.5% margin so sub-pixel bar remnants are hidden.
                let bakedBarScale = (contentAspectRatio / frameRatio) * 1.015
                scale = max(scale, bakedBarScale)
            }
        }

        if scale > 1.005 {
            let newWidth = bounds.width * scale
            let newHeight = bounds.height * scale
            playerLayer.frame = CGRect(
                x: (bounds.width - newWidth) / 2,
                y: (bounds.height - newHeight) / 2,
                width: newWidth,
                height: newHeight
            )
        }

        CATransaction.commit()
    }

    deinit {
        readyObservation?.invalidate()
    }
}

// MARK: - PiP Delegate
/// Handles AVPictureInPictureControllerDelegate callbacks and forwards to engine callbacks.
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onWillStop: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    var onRestoreUI: ((@escaping (Bool) -> Void) -> Void)?

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onDidStart?()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onWillStop?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onDidStop?()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        onFailedToStart?(error)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if let onRestoreUI {
            onRestoreUI(completionHandler)
        } else {
            completionHandler(true)
        }
    }
}

// MARK: - Custom Player Engine
/// Media player built on AVFoundation with AVPlayerLayer for video rendering.
/// Uses AVPlayer for media transport/decoding (supports HLS, local files, audio/video)
/// and AVPlayerLayer for native video display with full HDR support.
/// Custom Streamify UI is overlaid on top — this just handles the video layer.
@MainActor
final class CustomPlayerEngine: ObservableObject {

    // MARK: - Callbacks (set by PlayerViewModel)
    var onReadyToPlay: (() -> Void)?
    var onTimeUpdate: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error?) -> Void)?
    /// Fired when a new access log entry arrives (indicatedBitrate, observedBitrate, URI).
    /// Used by PlayerViewModel for ABR quality label and PQ variant switching decisions.
    var onAccessLogUpdate: ((Double, Double, String?) -> Void)?
    /// PiP state callbacks.
    var onPiPActiveChanged: ((Bool) -> Void)?
    var onPiPRestoreUI: ((@escaping (Bool) -> Void) -> Void)?

    // MARK: - Public State

    var currentTime: Double {
        guard let player else { return 0 }
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    var duration: Double {
        guard let item = playerItem else { return 0 }
        let d = CMTimeGetSeconds(item.duration)
        return d.isFinite ? d : 0
    }

    var isPlaying: Bool {
        (player?.rate ?? 0) > 0
    }

    var isMuted: Bool {
        get { player?.isMuted ?? false }
        set { player?.isMuted = newValue }
    }

    var playbackRate: Float {
        get { player?.rate ?? 0 }
        set { player?.rate = newValue }
    }

    /// The UIView that renders video via AVPlayerLayer.
    /// For audio-only content this is a plain black view.
    private(set) var videoView: UIView?
    
    // MARK: - Internal — AVPlayer

    /// Readable externally so PlayerViewModel can access audio tracks, loaded time ranges, etc.
    /// Only settable within this class.
    private(set) var player: AVPlayer?
    private(set) var playerItem: AVPlayerItem?
    private var timeObserver: Any?

    // MARK: - Internal — AVPlayerLayer
    
    private var playerLayerView: PlayerLayerView?
    private var hasVideoTrack = false

    // MARK: - Internal — PiP (Picture-in-Picture)
    private var pipController: AVPictureInPictureController?
    private let pipDelegate = PiPDelegate()

    /// Whether PiP is supported on this device.
    var isPiPSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Whether PiP is currently active.
    var isPiPActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    // MARK: - Internal — Content Aspect Ratio
    /// The actual content aspect ratio learned from a non-padded variant
    /// (e.g., 1080p at 1920×800 → 2.4). Used to detect baked-in bars
    /// in padded variants like 4K at 3840×2160 (16:9 frame).
    private var knownContentAspectRatio: CGFloat = 0

    // MARK: - Internal — KVO Observations

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var finishObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var pendingPlaybackStartCallback: (() -> Void)?
    /// The forward buffer duration set at load time; used by restoreDecoderBuffers().
    private var normalForwardBufferDuration: TimeInterval = 0

    // MARK: - Init

    init() {
        setupVideoView()
    }

    // MARK: - Video View Setup

    private func setupVideoView() {
        let view = PlayerLayerView(frame: .zero)
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        playerLayerView = view
        videoView = view
    }

    /// Set the actual content aspect ratio (width/height) learned from
    /// HLS manifest parsing. This enables early baked-bar detection
    /// before the player has seen a non-16:9 presentationSize.
    func setContentAspectRatio(_ ratio: CGFloat) {
        guard ratio > 0 else { return }
        knownContentAspectRatio = ratio
        // Apply immediately if currently playing a 16:9 variant.
        let size = playerItem?.presentationSize ?? .zero
        if size.width > 0 && size.height > 0 {
            let currentRatio = size.width / size.height
            let is16x9 = abs(currentRatio - k16x9Ratio) < k16x9Tolerance
            if is16x9 {
                playerLayerView?.contentAspectRatio = ratio
                playerLayerView?.setNeedsLayout()
            }
        }
    }

    // MARK: - PiP (Picture-in-Picture)

    /// Set up PiP controller after the player layer is connected.
    /// Called automatically after load() once the player is attached.
    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer = playerLayerView?.playerLayer else { return }

        // Reuse existing controller if layer hasn't changed
        if pipController?.playerLayer === playerLayer { return }

        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
        controller.delegate = pipDelegate

        pipDelegate.onWillStart = { [weak self] in
            Task { @MainActor in
                self?.onPiPActiveChanged?(true)
                StreamifyLogger.log("CustomPlayerEngine: PiP will start")
            }
        }
        pipDelegate.onWillStop = { [weak self] in
            Task { @MainActor in
                self?.onPiPActiveChanged?(false)
                StreamifyLogger.log("CustomPlayerEngine: PiP will stop")
            }
        }
        pipDelegate.onDidStop = { [weak self] in
            Task { @MainActor in
                self?.onPiPActiveChanged?(false)
                StreamifyLogger.log("CustomPlayerEngine: PiP did stop")
            }
        }
        pipDelegate.onRestoreUI = { [weak self] completionHandler in
            Task { @MainActor in
                if let restoreUI = self?.onPiPRestoreUI {
                    restoreUI(completionHandler)
                } else {
                    completionHandler(true)
                }
            }
        }

        pipController = controller
        StreamifyLogger.log("CustomPlayerEngine: PiP controller configured")
    }

    /// Toggle PiP on/off.
    func togglePiP() {
        guard let pipController else {
            StreamifyLogger.log("CustomPlayerEngine: PiP not available")
            return
        }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - Load Media

    /// Load a media URL. Supports local files, remote files, and HLS (m3u8).
    func load(url: URL, isHLS: Bool = false, isLocalFile: Bool = false) {
        cleanupInternal()

        // Ensure video view is ready (may have been cleared by cleanup)
        if playerLayerView == nil { setupVideoView() }

        let asset: AVURLAsset
        if VidLinkService.isVidLinkProxyURL(url.absoluteString) {
            // VidLink proxy URLs require Referer header for all requests (playlists + segments)
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Referer": VidLinkService.vidLinkReferer]
            ])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)

        applyForwardBufferPolicy(to: item, isHLS: isHLS || Self.looksLikeHLS(url))

        playerItem = item
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        
        // Connect the player to AVPlayerLayer for native video rendering.
        // AVPlayerLayer handles HDR (PQ/HLG) natively — same as Safari.
        playerLayerView?.playerLayer.player = player

        setupObservers()
        setupTimeObserver()
        setupPiP()

        // Detect video tracks (for logging — AVPlayerLayer handles rendering automatically)
        Task { [weak self] in
            guard let self else { return }
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                await MainActor.run {
                    if !videoTracks.isEmpty {
                        self.hasVideoTrack = true
                        StreamifyLogger.log("CustomPlayerEngine: Video track found — AVPlayerLayer rendering active")
                    } else {
                        self.hasVideoTrack = false
                        StreamifyLogger.log("CustomPlayerEngine: Audio-only content")
                    }
                }
            } catch {
                StreamifyLogger.log("CustomPlayerEngine: Track detection failed — \(error.localizedDescription)")
            }
        }

        StreamifyLogger.log("CustomPlayerEngine: Loading \(url.lastPathComponent) (HLS: \(isHLS), local: \(isLocalFile))")
    }

    // MARK: - Playback Controls

    func play(onStarted: (() -> Void)? = nil) {
        if let onStarted {
            pendingPlaybackStartCallback = onStarted
        }
        restoreDecoderBuffers()
        player?.play()
        firePendingPlaybackStartIfNeeded()
        StreamifyLogger.log("CustomPlayerEngine: play()")
    }

    func pause() {
        pendingPlaybackStartCallback = nil
        player?.pause()
        trimDecoderBuffers()
        StreamifyLogger.log("CustomPlayerEngine: pause()")
    }

    private static func looksLikeHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.localizedCaseInsensitiveContains(".m3u8")
    }

    private func applyForwardBufferPolicy(to item: AVPlayerItem, isHLS: Bool) {
        if isHLS {
            // Cap the forward buffer for ALL HLS (including local/localhost).
            // Without this cap, AVFoundation's byte-range prefetching can buffer the
            // entire remaining file when the server supports Range requests, exhausting
            // mediaserverd memory and triggering AVErrorMediaServicesWereReset (-11819).
            normalForwardBufferDuration = kBoundedHLSForwardBufferDuration
        } else {
            normalForwardBufferDuration = 0
        }
        item.preferredForwardBufferDuration = normalForwardBufferDuration
    }

    /// Shrink the forward decode buffer to 1 second while paused so the media
    /// server can release decoder memory.  Called on pause and app-background.
    func trimDecoderBuffers() {
        guard let item = playerItem,
              item.preferredForwardBufferDuration != kTrimmedForwardBufferDuration else { return }
        item.preferredForwardBufferDuration = kTrimmedForwardBufferDuration
    }

    /// Restore the forward decode buffer to the playback-time value.
    /// Called on play and app-foreground.
    func restoreDecoderBuffers() {
        guard let item = playerItem,
              item.preferredForwardBufferDuration != normalForwardBufferDuration else { return }
        item.preferredForwardBufferDuration = normalForwardBufferDuration
    }

    /// Seek to a position in seconds with zero tolerance (frame-accurate).
    func seek(time seconds: Double, completion: ((Bool) -> Void)? = nil) {
        let clamped = max(seconds, 0)
        let cmTime = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }

    /// Replace the current media with a new URL (e.g., for quality switching).
    func replaceURL(_ url: URL, isHLS: Bool? = nil) {
        clearObservers()
        pendingPlaybackStartCallback = nil

        let asset: AVURLAsset
        if VidLinkService.isVidLinkProxyURL(url.absoluteString) {
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Referer": VidLinkService.vidLinkReferer]
            ])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        let shouldBoundHLS = isHLS ?? Self.looksLikeHLS(url)
        applyForwardBufferPolicy(to: item, isHLS: shouldBoundHLS)
        playerItem = item
        player?.replaceCurrentItem(with: item)

        setupObservers()

        StreamifyLogger.log("CustomPlayerEngine: Replaced URL — \(url.lastPathComponent) (HLS: \(shouldBoundHLS))")
    }

    /// Get player item tracks for a given media type.
    func tracks(mediaType: AVMediaType) -> [AVPlayerItemTrack] {
        playerItem?.tracks.filter { $0.assetTrack?.mediaType == mediaType } ?? []
    }

    // MARK: - KVO Observers

    private func setupObservers() {
        clearObservers()
        guard let item = playerItem, let player else { return }

        // Player item status
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(item.status)
            }
        }

        // Player rate → isPlaying callback.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onPlaybackStateChanged?(player.rate > 0)
                self.firePendingPlaybackStartIfNeeded()
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatusChange(player.timeControlStatus)
            }
        }

        // Buffer empty → show buffering indicator
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.isPlaybackBufferEmpty {
                    self.onBufferingChanged?(true)
                }
            }
        }

        // Likely to keep up → buffer is actually ready.
        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.isPlaybackLikelyToKeepUp {
                    self.onBufferingChanged?(false)
                }
            }
        }

        // Duration changes
        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let dur = CMTimeGetSeconds(item.duration)
                if dur.isFinite && dur > 0 {
                    self.onDurationChanged?(dur)
                }
            }
        }

        // End of playback
        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onFinished?()
                StreamifyLogger.log("CustomPlayerEngine: Playback finished")
            }
        }

        // Playback error
        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.onError?(error)
                StreamifyLogger.log("CustomPlayerEngine: Error — \(error?.localizedDescription ?? "unknown")")
            }
        }

        // Access log — stream selection & variant info (for ABR / quality label)
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let accessLog = self.playerItem?.accessLog(),
                      let event = accessLog.events.last else { return }
                self.onAccessLogUpdate?(event.indicatedBitrate, event.observedBitrate, event.uri)
            }
        }

        // Presentation size — detect content aspect ratio and trigger re-layout.
        // When a non-16:9 size is seen (e.g., 1920×800 from 1080p), we learn the
        // actual content ratio. When a 16:9 size appears (e.g., 3840×2160 from 4K),
        // we pass the known content ratio to PlayerLayerView so it can crop the
        // baked-in letterbox bars that pad the 16:9 frame.
        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let size = self.playerItem?.presentationSize ?? .zero
                if size.width > 0 && size.height > 0 {
                    let ratio = size.width / size.height
                    let is16x9 = abs(ratio - k16x9Ratio) < k16x9Tolerance
                    if !is16x9 {
                        self.knownContentAspectRatio = ratio
                    }
                    // For 16:9 variants with a known wider content ratio,
                    // enable baked-bar cropping. Otherwise, clear it.
                    self.playerLayerView?.contentAspectRatio =
                        (is16x9 && self.knownContentAspectRatio > 0)
                        ? self.knownContentAspectRatio : 0
                }
                self.playerLayerView?.setNeedsLayout()
            }
        }

    }

    private func firePendingPlaybackStartIfNeeded() {
        guard let player, player.rate > 0, player.timeControlStatus == .playing else { return }
        guard let callback = pendingPlaybackStartCallback else { return }
        pendingPlaybackStartCallback = nil
        callback()
    }

    private func handleTimeControlStatusChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            onBufferingChanged?(false)
            firePendingPlaybackStartIfNeeded()
        case .waitingToPlayAtSpecifiedRate:
            onBufferingChanged?(true)
        case .paused:
            onBufferingChanged?(false)
        @unknown default:
            break
        }
    }

    private func setupTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.onTimeUpdate?(seconds)
                }
            }
        }
    }

    /// When the player item is ready, re-check for video tracks that weren't available
    /// during initial asset inspection (common with HLS where the manifest must be parsed first).
    private func redetectVideoTracksIfNeeded() {
        guard !hasVideoTrack, let item = playerItem else { return }
        let hasVideo = item.tracks.contains { $0.assetTrack?.mediaType == .video }
        if hasVideo {
            hasVideoTrack = true
            StreamifyLogger.log("CustomPlayerEngine: Video track found (deferred HLS detection) — AVPlayerLayer rendering active")
        }
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            redetectVideoTracksIfNeeded()
            let dur = duration
            if dur > 0 { onDurationChanged?(dur) }
            onReadyToPlay?()
            StreamifyLogger.log("CustomPlayerEngine: Ready to play (duration: \(String(format: "%.1f", dur))s)")
        case .failed:
            let error = playerItem?.error
            onError?(error)
            StreamifyLogger.log("CustomPlayerEngine: Failed — \(error?.localizedDescription ?? "unknown")")
        default:
            break
        }
    }

    // MARK: - Cleanup

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        likelyToKeepUpObservation?.invalidate()
        likelyToKeepUpObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil

        if let obs = finishObserver {
            NotificationCenter.default.removeObserver(obs)
            finishObserver = nil
        }
        if let obs = errorObserver {
            NotificationCenter.default.removeObserver(obs)
            errorObserver = nil
        }
        if let obs = accessLogObserver {
            NotificationCenter.default.removeObserver(obs)
            accessLogObserver = nil
        }
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
    }

    private func cleanupInternal() {
        // Stop PiP before tearing down the player
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil

        clearObservers()

        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        player?.pause()
        pendingPlaybackStartCallback = nil
        playerLayerView?.playerLayer.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        normalForwardBufferDuration = 0
        hasVideoTrack = false
        knownContentAspectRatio = 0
        playerLayerView?.contentAspectRatio = 0
    }

    /// Stop playback and release all resources.
    func cleanup() {
        cleanupInternal()
        StreamifyLogger.log("CustomPlayerEngine: cleanup()")
    }
}
