import Foundation
import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#endif

struct MPVTrackInfo: Equatable, Sendable {
    let index: Int
    let id: Int
    let type: String
    let title: String
    let lang: String
    let codec: String
    let demuxChannelCount: Int
    let demuxSamplerate: Int
    let external: Bool
    let selected: Bool
}

struct MPVPlaybackState: Sendable {
    let isLoading: Bool
    let isPlaying: Bool
    let isEnded: Bool
    let duration: Double
    let position: Double
    let buffered: Double
    let speed: Float
}

#if os(iOS) && canImport(UIKit)
import AVFoundation
import AVKit
import QuartzCore

private let kMPVForwardBufferDuration: Double = 30
private let kMPVDemuxerMaxBytes: Int = 128 * 1024 * 1024  // 128 MB; large enough to avoid periodic buffer-compaction stalls

enum MPVDirectVideoOutputKind {
    case metal
    case avFoundation
}

private let MPV_FORMAT_STRING: CInt = 1
private let MPV_FORMAT_FLAG: CInt = 3
private let MPV_FORMAT_INT64: CInt = 4
private let MPV_FORMAT_DOUBLE: CInt = 5
private let MPV_EVENT_NONE: CInt = 0
private let MPV_EVENT_SHUTDOWN: CInt = 1
private let MPV_EVENT_LOG_MESSAGE: CInt = 2
private let MPV_EVENT_END_FILE: CInt = 7
private let MPV_EVENT_FILE_LOADED: CInt = 8
private let MPV_EVENT_PROPERTY_CHANGE: CInt = 22
private let MPV_END_FILE_REASON_ERROR: CInt = 4

struct mpv_event {
    var event_id: CInt
    var error: CInt
    var reply_userdata: UInt64
    var data: UnsafeMutableRawPointer?
}

private struct mpv_event_property {
    var name: UnsafePointer<CChar>!
    var format: CInt
    var data: UnsafeMutableRawPointer?
}

private struct mpv_event_end_file {
    var reason: CInt
    var error: CInt
    var playlist_entry_id: Int64
    var playlist_insert_id: Int64
    var playlist_insert_num_entries: CInt
}

private struct mpv_event_log_message {
    var prefix: UnsafePointer<CChar>!
    var level: UnsafePointer<CChar>!
    var text: UnsafePointer<CChar>!
    var log_level: CInt
}

private typealias mpv_wakeup_cb = @convention(c) (UnsafeMutableRawPointer?) -> Void

@_silgen_name("mpv_create") private func c_mpv_create() -> OpaquePointer?
@_silgen_name("mpv_initialize") private func c_mpv_initialize(_ ctx: OpaquePointer?) -> CInt
@_silgen_name("mpv_terminate_destroy") func c_mpv_terminate_destroy(_ ctx: OpaquePointer?)
@_silgen_name("mpv_request_log_messages") func c_mpv_request_log_messages(_ ctx: OpaquePointer?, _ minLevel: UnsafePointer<CChar>) -> CInt
@_silgen_name("mpv_set_option") private func c_mpv_set_option(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ format: CInt, _ data: UnsafeRawPointer?) -> CInt
@_silgen_name("mpv_set_option_string") private func c_mpv_set_option_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>?) -> CInt
@_silgen_name("mpv_set_property") private func c_mpv_set_property(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ format: CInt, _ data: UnsafeRawPointer?) -> CInt
@_silgen_name("mpv_set_property_string") private func c_mpv_set_property_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>?) -> CInt
@_silgen_name("mpv_get_property") private func c_mpv_get_property(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ format: CInt, _ data: UnsafeMutableRawPointer?) -> CInt
@_silgen_name("mpv_get_property_string") private func c_mpv_get_property_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("mpv_command") private func c_mpv_command(_ ctx: OpaquePointer?, _ args: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> CInt
@_silgen_name("mpv_command_async") private func c_mpv_command_async(_ ctx: OpaquePointer?, _ replyUserdata: UInt64, _ args: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> CInt
@_silgen_name("mpv_observe_property") private func c_mpv_observe_property(_ ctx: OpaquePointer?, _ replyUserdata: UInt64, _ name: UnsafePointer<CChar>, _ format: CInt) -> CInt
@_silgen_name("mpv_set_wakeup_callback") private func c_mpv_set_wakeup_callback(_ ctx: OpaquePointer?, _ cb: mpv_wakeup_cb?, _ data: UnsafeMutableRawPointer?)
@_silgen_name("mpv_wait_event") func c_mpv_wait_event(_ ctx: OpaquePointer?, _ timeout: Double) -> UnsafeMutablePointer<mpv_event>?
@_silgen_name("mpv_error_string") func c_mpv_error_string(_ error: CInt) -> UnsafePointer<CChar>
@_silgen_name("mpv_free") private func c_mpv_free(_ data: UnsafeMutableRawPointer?)

final class StreamifyMPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    @available(iOS 16.0, *)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

final class MPVDirectVideoView: UIView {
    private let hostedMetalLayer: StreamifyMPVMetalLayer?
    private let hostedDisplayLayer: AVSampleBufferDisplayLayer?
    let outputKind: MPVDirectVideoOutputKind
    let mpvWindowObject: AnyObject
    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer? { hostedDisplayLayer }
    var onSurfaceReady: (() -> Void)?
    var onVideoFitModeChanged: ((Bool) -> Void)?
    private(set) var shouldCropVideoToFill = false

    init(outputKind: MPVDirectVideoOutputKind = .metal) {
        self.outputKind = outputKind
        switch outputKind {
        case .avFoundation:
            let layer = AVSampleBufferDisplayLayer()
            self.hostedMetalLayer = nil
            self.hostedDisplayLayer = layer
            self.mpvWindowObject = layer
        case .metal:
            let layer = StreamifyMPVMetalLayer()
            self.hostedMetalLayer = layer
            self.hostedDisplayLayer = nil
            self.mpvWindowObject = layer
        }
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        if let hostedMetalLayer {
            hostedMetalLayer.framebufferOnly = true
            hostedMetalLayer.backgroundColor = UIColor.black.cgColor
            hostedMetalLayer.contentsScale = UIScreen.main.nativeScale
            if #available(iOS 16.0, *) {
                hostedMetalLayer.wantsExtendedDynamicRangeContent = true
            }
            layer.addSublayer(hostedMetalLayer)
        } else if let hostedDisplayLayer {
            hostedDisplayLayer.backgroundColor = UIColor.black.cgColor
            hostedDisplayLayer.contentsScale = UIScreen.main.nativeScale
            hostedDisplayLayer.isOpaque = true
            hostedDisplayLayer.videoGravity = .resizeAspect
            layer.addSublayer(hostedDisplayLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshDrawableSize()
    }

    func refreshDrawableSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let hostedMetalLayer {
            hostedMetalLayer.frame = bounds
            hostedMetalLayer.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
            hostedMetalLayer.drawableSize = CGSize(
                width: max(bounds.width * hostedMetalLayer.contentsScale, 2),
                height: max(bounds.height * hostedMetalLayer.contentsScale, 2)
            )
        } else if let hostedDisplayLayer {
            hostedDisplayLayer.frame = bounds
            hostedDisplayLayer.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
            hostedDisplayLayer.videoGravity = shouldCropVideoToFill ? .resizeAspectFill : .resizeAspect
        }
        CATransaction.commit()
        let resolvedSafeArea = StreamifySafeArea.resolvedInsets(fallback: safeAreaInsets)
        let nextShouldCrop = StreamifySafeArea.shouldCropVideoToFill(bounds: bounds, safeAreaInsets: resolvedSafeArea)
        if nextShouldCrop != shouldCropVideoToFill {
            shouldCropVideoToFill = nextShouldCrop
            hostedDisplayLayer?.videoGravity = nextShouldCrop ? .resizeAspectFill : .resizeAspect
            onVideoFitModeChanged?(nextShouldCrop)
        }
        if bounds.width > 2 && bounds.height > 2 {
            onSurfaceReady?()
        }
    }

    func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(iOS 16.0, *) {
            hostedMetalLayer?.wantsExtendedDynamicRangeContent = enabled
        }
        if #available(iOS 17.0, *) {
            hostedDisplayLayer?.wantsExtendedDynamicRangeContent = enabled
        }
        CATransaction.commit()
    }

    func warmSampleBufferTimebase(currentTime: Double, isPlaying: Bool) {
        guard let hostedDisplayLayer else { return }
        if hostedDisplayLayer.controlTimebase == nil {
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            hostedDisplayLayer.controlTimebase = timebase
        }
        syncSampleBufferTimebase(currentTime: currentTime, isPlaying: isPlaying)
    }

    func syncSampleBufferTimebase(currentTime: Double, isPlaying: Bool) {
        guard let timebase = hostedDisplayLayer?.controlTimebase else { return }
        let safeTime = currentTime.isFinite ? max(currentTime, 0) : 0
        CMTimebaseSetTime(timebase, time: CMTime(seconds: safeTime, preferredTimescale: 1000))
        CMTimebaseSetRate(timebase, rate: isPlaying ? 1 : 0)
    }

    func prepareForPlaybackRecovery(currentTime: Double) {
        refreshDrawableSize()
        warmSampleBufferTimebase(currentTime: currentTime, isPlaying: false)
    }
}

@MainActor
final class MPVDirectPlayerEngine: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated static var isAvailable: Bool { true }

    var onReadyToPlay: (() -> Void)?
    var onStateChanged: ((MPVPlaybackState) -> Void)?
    var onTracksChanged: (([MPVTrackInfo], [MPVTrackInfo]) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var onSubtitleText: ((String) -> Void)?
    var onPiPActiveChanged: ((Bool) -> Void)?

    private let videoViewInternal: MPVDirectVideoView
    private let mpvWindowObject: AnyObject
    private weak var inlineVideoContainer: UIView?
    private var activeVideoConstraints: [NSLayoutConstraint] = []
    private var mpv: OpaquePointer?
    private nonisolated let eventQueue = DispatchQueue(label: "streamify.mpv.events", qos: .userInitiated)
    private var stateTimer: Timer?
    private var activeRequestHeaders: [String: String] = [:]
    private var recentPlaybackLogs: [String] = []
    private let errorStateLock = NSLock()
    private let preferHDROutput: Bool
    private let videoOutputKind: MPVDirectVideoOutputKind
    private var didReportReady = false
    private var didReportFinished = false
    private var lastReportedHDRSignalPeak: Double?
    private var lastAudioTracks: [MPVTrackInfo] = []
    private var lastSubtitleTracks: [MPVTrackInfo] = []
    private var lastSubtitleText: String = ""
    private var pendingLoad: (url: URL, requestHeaders: [String: String])?
    private var pendingPlayAfterSurfaceReady = false
    private var foregroundResumeTargetTime: Double?
    private var foregroundRecoveryGeneration = 0
    private var backgroundedWhilePlaying = false
    private var backgroundPiPStartRequested = false
    private var backgroundPiPFallbackGeneration = 0
    private var needsForegroundVideoRepaint = false
    private var foregroundVideoRepaintTargetTime: Double?
    private var appliedPanscan: String?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedTime: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isLoading: Bool = true
    private(set) var currentSpeed: Float = 1.0
    private var cachedPaused = true
    private var cachedPausedForCache = false
    private var cachedCoreIdle = true
    private var cachedEofReached = false
    private var cachedSeeking = false
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0
    private var cachedDemuxerCacheTime: Double = 0
    private var cachedPlaybackSpeed: Double = 1
    private var pipController: AVPictureInPictureController?

    var videoView: UIView? { videoViewInternal }
    var isPiPSupported: Bool {
        guard videoOutputKind == .avFoundation,
              videoViewInternal.sampleBufferDisplayLayer != nil,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            return false
        }
        return true
    }
    var isPiPActive: Bool { pipController?.isPictureInPictureActive ?? false }
    private var playbackShouldAdvance: Bool {
        !cachedPaused && !cachedPausedForCache && !cachedEofReached
    }

    var isMuted: Bool {
        get { getFlag("mute") }
        set { setFlag("mute", newValue) }
    }

    init(preferHDROutput: Bool = false, videoOutputKind: MPVDirectVideoOutputKind = .avFoundation) {
        let videoView = MPVDirectVideoView(outputKind: videoOutputKind)
        self.preferHDROutput = preferHDROutput
        self.videoOutputKind = videoOutputKind
        self.videoViewInternal = videoView
        self.mpvWindowObject = videoView.mpvWindowObject
        super.init()
        self.videoViewInternal.setExtendedDynamicRangeEnabled(preferHDROutput)
        self.videoViewInternal.onSurfaceReady = { [weak self] in
            self?.startPendingLoadIfSurfaceReady()
        }
        self.videoViewInternal.onVideoFitModeChanged = { [weak self] _ in
            self?.applyVideoFitMode()
        }
        setupPiPControllerIfNeeded()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stateTimer?.invalidate()
        if let ctx = mpv {
            mpv = nil
            Self.destroyMpvContextAsync(Int(bitPattern: ctx), on: eventQueue)
        }
    }

    func load(url: URL, requestHeaders: [String: String] = [:]) {
        didReportReady = false
        didReportFinished = false
        lastAudioTracks = []
        lastSubtitleTracks = []
        lastSubtitleText = ""
        lastReportedHDRSignalPeak = nil
        resetCachedPlaybackState()
        clearPlaybackError()
        isLoading = true
        onStateChanged?(snapshotState(isLoadingOverride: true))
        setFlag("pause", true)
        pendingLoad = (url, requestHeaders)
        guard isVideoSurfaceReady else {
            StreamifyLogger.log("MPVDirectPlayerEngine: deferring load until video surface is laid out")
            return
        }
        startPendingLoadIfSurfaceReady()
    }

    private var isVideoSurfaceReady: Bool {
        guard inlineVideoContainer != nil,
              let window = videoViewInternal.window,
              (window.windowScene?.interfaceOrientation.isLandscape == true || window.bounds.width > window.bounds.height) else {
            return false
        }

        let bounds = videoViewInternal.bounds
        return bounds.width > 2 &&
            bounds.height > 2 &&
            bounds.width > bounds.height
    }

    private func startPendingLoadIfSurfaceReady() {
        guard isVideoSurfaceReady, let pendingLoad else { return }
        if mpv == nil {
            setupMpv()
        }
        guard mpv != nil else { return }
        self.pendingLoad = nil
        activeRequestHeaders = sanitizeRequestHeaders(pendingLoad.requestHeaders)
        applyRequestHeaders(activeRequestHeaders)
        commandAsync("loadfile", args: [pendingLoad.url.absoluteString, "replace"])
        startStateTimer()
        StreamifyLogger.log("MPVDirectPlayerEngine: load \(pendingLoad.url.absoluteString)")
    }

    func play(onStarted: (() -> Void)? = nil) {
        guard mpv != nil else { return }
        guard isPiPActive || isVideoSurfaceReady else {
            deferPlaybackUntilSurfaceReady(targetTime: currentTime)
            StreamifyLogger.log("MPVDirectPlayerEngine: deferred play until video surface is ready")
            return
        }
        foregroundRecoveryGeneration += 1
        pendingPlayAfterSurfaceReady = false
        foregroundResumeTargetTime = nil
        cachedPaused = false
        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "no"])
        refreshPlaybackState()
        updatePiPPlaybackState()
        onStarted?()
        StreamifyLogger.log("MPVDirectPlayerEngine: play()")
    }

    func pause() {
        guard mpv != nil else { return }
        foregroundRecoveryGeneration += 1
        pendingPlayAfterSurfaceReady = false
        foregroundResumeTargetTime = nil
        backgroundedWhilePlaying = false
        cachedPaused = true
        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"])
        refreshPlaybackState()
        updatePiPPlaybackState()
        StreamifyLogger.log("MPVDirectPlayerEngine: pause()")
    }

    func seek(time seconds: Double, completion: ((Bool) -> Void)? = nil) {
        guard mpv != nil else {
            completion?(false)
            return
        }
        let clamped = max(seconds, 0)
        cachedPosition = clamped
        var status = commandAsync(
            "seek",
            args: [String(format: "%.3f", clamped), "absolute+exact"],
            checkForErrors: false
        )
        if status < 0 {
            status = commandAsync("seek", args: [String(format: "%.3f", clamped), "absolute"])
        }
        guard status >= 0 else {
            completion?(false)
            return
        }
        completeSeekWhenSettled(target: clamped, attempt: 0, completion: completion)
    }

    func selectAudio(id: Int?) {
        guard mpv != nil else { return }
        if let id {
            commandAsync("set", args: ["aid", "\(id)"])
        } else {
            commandAsync("set", args: ["aid", "auto"])
        }
        refreshTracks()
    }

    func disableAudio() {
        guard mpv != nil else { return }
        commandAsync("set", args: ["aid", "no"])
        refreshTracks()
    }

    func selectSubtitle(id: Int?) {
        guard mpv != nil else { return }
        if let id {
            commandAsync("set", args: ["sid", "\(id)"])
        } else {
            commandAsync("set", args: ["sid", "no"])
        }
        refreshTracks()
    }

    func clearExternalSubtitles(selecting trackId: Int? = nil) {
        guard mpv != nil else { return }
        commandAsync("sub-remove", checkForErrors: false)
        selectSubtitle(id: trackId)
    }

    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        stateTimer?.invalidate()
        stateTimer = nil
        pendingLoad = nil
        pendingPlayAfterSurfaceReady = false
        foregroundResumeTargetTime = nil
        foregroundRecoveryGeneration += 1
        backgroundedWhilePlaying = false
        backgroundPiPStartRequested = false
        backgroundPiPFallbackGeneration += 1
        needsForegroundVideoRepaint = false
        foregroundVideoRepaintTargetTime = nil
        clearPlaybackError()
        guard let ctx = mpv else { return }
        mpv = nil
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil
        Self.destroyMpvContextAsync(Int(bitPattern: ctx), on: eventQueue)
        StreamifyLogger.log("MPVDirectPlayerEngine: cleanup()")
    }

    func attachVideoView(to container: UIView) {
        inlineVideoContainer = container
        attachVideoView(to: container, useSafeArea: true)
    }

    func refreshVideoOutputLayout() {
        inlineVideoContainer?.setNeedsLayout()
        inlineVideoContainer?.layoutIfNeeded()
        videoViewInternal.refreshDrawableSize()
        applyVideoFitMode()
        startPendingLoadIfSurfaceReady()
        resumePendingPlaybackIfReady()
        resumeForegroundVideoRepaintIfReady()
    }

    private func applyVideoFitMode() {
        let nextPanscan = videoViewInternal.shouldCropVideoToFill ? "1.0" : "0.0"
        guard appliedPanscan != nextPanscan else { return }
        appliedPanscan = nextPanscan
        guard mpv != nil else { return }
        checkOptionalError(setOptionString("panscan", nextPanscan), option: "panscan")
    }

    private func scheduleTrackRefresh() {
        for delay in [0.1, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshTracks()
            }
        }
    }

    private func deferPlaybackUntilSurfaceReady(targetTime: Double?) {
        pendingPlayAfterSurfaceReady = true
        if let targetTime, targetTime.isFinite {
            foregroundResumeTargetTime = max(targetTime, 0)
        }
        cachedPaused = true
        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
        refreshPlaybackState()
        updatePiPPlaybackState()
    }

    private func scheduleForegroundRecoveryAttempts() {
        for delay in [0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshVideoOutputLayout()
                self?.resumePendingPlaybackIfReady()
            }
        }
    }

    private func resumePendingPlaybackIfReady() {
        guard pendingPlayAfterSurfaceReady, mpv != nil else { return }
        guard isPiPActive || isVideoSurfaceReady else { return }

        pendingPlayAfterSurfaceReady = false
        let generation = foregroundRecoveryGeneration + 1
        foregroundRecoveryGeneration = generation
        let target = max(foregroundResumeTargetTime ?? currentTime, 0)
        let repaintTarget = target > 0.2 ? target - 0.12 : target
        foregroundResumeTargetTime = nil

        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
        cachedPaused = true
        videoViewInternal.prepareForPlaybackRecovery(currentTime: repaintTarget)

        seek(time: repaintTarget) { [weak self] _ in
            guard let self else { return }
            guard generation == self.foregroundRecoveryGeneration else { return }
            guard self.mpv != nil else { return }
            guard self.isPiPActive || self.isVideoSurfaceReady else {
                self.pendingPlayAfterSurfaceReady = true
                self.foregroundResumeTargetTime = target
                return
            }

            self.cachedPaused = false
            self.commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
            self.commandAsync("set", args: ["pause", "no"])
            self.refreshPlaybackState()
            self.updatePiPPlaybackState()
            StreamifyLogger.log("MPVDirectPlayerEngine: resumed after video surface recovery at \(String(format: "%.2f", repaintTarget))s")
        }
    }

    private func repaintVideoSurface(targetTime: Double, shouldResume: Bool) {
        guard mpv != nil else { return }
        guard isPiPActive || isVideoSurfaceReady else {
            needsForegroundVideoRepaint = true
            foregroundVideoRepaintTargetTime = targetTime
            scheduleForegroundRecoveryAttempts()
            return
        }

        needsForegroundVideoRepaint = false
        foregroundVideoRepaintTargetTime = nil
        let generation = foregroundRecoveryGeneration + 1
        foregroundRecoveryGeneration = generation
        let target = max(targetTime, 0)
        let repaintTarget = target > 0.2 ? target - 0.12 : target

        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
        cachedPaused = true
        videoViewInternal.prepareForPlaybackRecovery(currentTime: repaintTarget)

        seek(time: repaintTarget) { [weak self] _ in
            guard let self else { return }
            guard generation == self.foregroundRecoveryGeneration else { return }
            guard self.mpv != nil else { return }

            if shouldResume {
                self.cachedPaused = false
                self.commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
                self.commandAsync("set", args: ["pause", "no"])
            } else {
                self.cachedPaused = true
                self.commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
            }
            self.refreshPlaybackState()
            self.updatePiPPlaybackState()
            StreamifyLogger.log("MPVDirectPlayerEngine: repainted video surface at \(String(format: "%.2f", repaintTarget))s (resume=\(shouldResume))")
        }
    }

    private func resumeForegroundVideoRepaintIfReady() {
        guard needsForegroundVideoRepaint, mpv != nil else { return }
        guard isPiPActive || isVideoSurfaceReady else { return }
        let target = foregroundVideoRepaintTargetTime ?? currentTime
        repaintVideoSurface(targetTime: target, shouldResume: false)
    }

    private nonisolated static func destroyMpvContextAsync(_ contextAddress: Int, on queue: DispatchQueue) {
        queue.async {
            guard let context = OpaquePointer(bitPattern: contextAddress) else { return }
            c_mpv_set_wakeup_callback(context, nil, nil)
            c_mpv_terminate_destroy(context)
        }
    }

    func togglePiP() {
        guard isPiPSupported else {
            StreamifyLogger.log("MPVDirectPlayerEngine: PiP unavailable for current Matroska output")
            return
        }
        setupPiPControllerIfNeeded()
        guard let pipController else {
            StreamifyLogger.log("MPVDirectPlayerEngine: PiP controller unavailable")
            return
        }

        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
            return
        }

        videoViewInternal.warmSampleBufferTimebase(currentTime: currentTime, isPlaying: playbackShouldAdvance)
        startPiPWhenReady(attempt: 0)
    }

    private func setupMpv() {
        guard mpv == nil else { return }
        mpv = c_mpv_create()
        guard mpv != nil else {
            StreamifyLogger.log("MPVDirectPlayerEngine: failed to create mpv instance")
            return
        }

        checkError(requestLogMessages("warn"))
        var wid = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(mpvWindowObject).toOpaque())))
        withUnsafePointer(to: &wid) { pointer in
            checkError(setOption("wid", format: MPV_FORMAT_INT64, data: pointer))
        }
        switch videoOutputKind {
        case .avFoundation:
            StreamifyLogger.log("MPVDirectPlayerEngine: using AVFoundation video output")
            checkError(setOptionString("vo", "avfoundation"))
            checkOptionalError(setOptionString("avfoundation-composite-osd", "yes"), option: "avfoundation-composite-osd")
        case .metal:
            checkError(setOptionString("vo", "gpu-next"))
            checkOptionalError(setOptionString("gpu-api", "vulkan"), option: "gpu-api")
            checkOptionalError(setOptionString("gpu-context", "moltenvk"), option: "gpu-context")
        }
        checkOptionalError(setOptionString("ao", "avfoundation"), option: "ao")
        // Match MPVKit's Metal demo path; auto-safe can probe Vulkan video decode first on iOS.
        _ = setFirstAvailableOptionString("hwdec", values: ["videotoolbox", "auto-safe"])
        checkOptionalError(setOptionString("hwdec-codecs", "all"), option: "hwdec-codecs")
        checkOptionalError(setOptionString("hwdec-software-fallback", "yes"), option: "hwdec-software-fallback")
        checkError(setOptionString("video-rotate", "no"))
        checkOptionalError(setOptionString("aid", "1"), option: "aid")
        checkError(setOptionString("sid", "no"))
        checkOptionalError(setOptionString("sub-auto", "no"), option: "sub-auto")
        checkOptionalError(setOptionString("sub-visibility", "no"), option: "sub-visibility")
        checkOptionalError(setOptionString("subs-fallback", "no"), option: "subs-fallback")
        checkOptionalError(setOptionString("audio-display", "no"), option: "audio-display")
        checkOptionalError(setOptionString("audio-channels", "auto"), option: "audio-channels")
        checkOptionalError(setOptionString("audio-normalize-downmix", "no"), option: "audio-normalize-downmix")
        checkOptionalError(setOptionString("video-sync", "audio"), option: "video-sync")
        checkOptionalError(setOptionString("interpolation", "no"), option: "interpolation")
        checkOptionalError(setOptionString("demuxer-readahead-secs", String(Int(kMPVForwardBufferDuration))), option: "demuxer-readahead-secs")
        checkOptionalError(setOptionString("demuxer-max-bytes", String(kMPVDemuxerMaxBytes)), option: "demuxer-max-bytes")
        checkOptionalError(setOptionString("demuxer-max-back-bytes", "1048576"), option: "demuxer-max-back-bytes")
        checkOptionalError(setOptionString("cache-pause", "no"), option: "cache-pause")
        let initialPanscan = videoViewInternal.shouldCropVideoToFill ? "1.0" : "0.0"
        appliedPanscan = initialPanscan
        checkOptionalError(setOptionString("panscan", initialPanscan), option: "panscan")
        checkOptionalError(setOptionString("video-unscaled", "no"), option: "video-unscaled")
        checkError(setOptionString("keep-open", "yes"))
        checkError(setOptionString("pause", "yes"))
        checkOptionalError(setOptionString("target-colorspace-hint", "yes"), option: "target-colorspace-hint")
        applyHDRTargetOptions()

        checkError(c_mpv_initialize(mpv))
        StreamifyLogger.log("MPVDirectPlayerEngine: mpv initialized")

        observeProperty("pause", format: MPV_FORMAT_FLAG)
        observeProperty("paused-for-cache", format: MPV_FORMAT_FLAG)
        observeProperty("core-idle", format: MPV_FORMAT_FLAG)
        observeProperty("eof-reached", format: MPV_FORMAT_FLAG)
        observeProperty("seeking", format: MPV_FORMAT_FLAG)
        observeProperty("duration", format: MPV_FORMAT_DOUBLE)
        observeProperty("time-pos", format: MPV_FORMAT_DOUBLE)
        observeProperty("demuxer-cache-time", format: MPV_FORMAT_DOUBLE)
        observeProperty("speed", format: MPV_FORMAT_DOUBLE)
        observeProperty("track-list/count", format: MPV_FORMAT_INT64)
        observeProperty("sub-text", format: MPV_FORMAT_STRING)
        observeProperty("video-params/sig-peak", format: MPV_FORMAT_DOUBLE)

        c_mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVDirectPlayerEngine>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                engine.readEvents()
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func applyHDRTargetOptions() {
        guard preferHDROutput else { return }

        checkOptionalError(setOptionString("target-colorspace-hint-mode", "source"), option: "target-colorspace-hint-mode")
        switch videoOutputKind {
        case .avFoundation:
            StreamifyLogger.log("MPVDirectPlayerEngine: HDR passthrough via AVFoundation source colorspace metadata")
        case .metal:
            checkOptionalError(setOptionString("target-prim", "bt.2020"), option: "target-prim")
            let targetTRC = setFirstAvailableOptionString("target-trc", values: ["pq", "bt.2100-pq"])
            checkOptionalError(setOptionString("tone-mapping", "clip"), option: "tone-mapping")
            checkOptionalError(setOptionString("hdr-compute-peak", "no"), option: "hdr-compute-peak")
            StreamifyLogger.log("MPVDirectPlayerEngine: HDR passthrough target bt.2020/\(targetTRC ?? "unknown") using source colorspace metadata")
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prepareForBackgroundTransition),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    private func setupPiPControllerIfNeeded() {
        guard videoOutputKind == .avFoundation,
              pipController == nil,
              let displayLayer = videoViewInternal.sampleBufferDisplayLayer,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pipController = controller
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP controller configured")
    }

    private func startPiPWhenReady(attempt: Int) {
        guard let pipController else { return }
        guard !pipController.isPictureInPictureActive else { return }
        videoViewInternal.warmSampleBufferTimebase(
            currentTime: currentTime,
            isPlaying: playbackShouldAdvance || backgroundPiPStartRequested
        )
        let hasTimebase = videoViewInternal.sampleBufferDisplayLayer?.controlTimebase != nil
        let hasFrame: Bool
        if #available(iOS 17.4, *) {
            hasFrame = backgroundPiPStartRequested || (videoViewInternal.sampleBufferDisplayLayer?.isReadyForDisplay ?? false)
        } else {
            hasFrame = true
        }

        guard pipController.isPictureInPicturePossible, hasTimebase, hasFrame else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.startPiPWhenReady(attempt: attempt + 1)
                }
            } else {
                StreamifyLogger.log("MPVDirectPlayerEngine: PiP not ready (possible=\(pipController.isPictureInPicturePossible), timebase=\(hasTimebase), frame=\(hasFrame))")
            }
            return
        }

        StreamifyLogger.log("MPVDirectPlayerEngine: starting PiP (backgroundRequested=\(backgroundPiPStartRequested))")
        pipController.startPictureInPicture()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        updatePiPPlaybackState()
        onPiPActiveChanged?(true)
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP will start")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        backgroundPiPStartRequested = false
        backgroundPiPFallbackGeneration += 1
        backgroundedWhilePlaying = false
        onPiPActiveChanged?(true)
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP did start")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onPiPActiveChanged?(false)
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP will stop")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        backgroundPiPStartRequested = false
        backgroundPiPFallbackGeneration += 1
        onPiPActiveChanged?(false)
        if UIApplication.shared.applicationState == .active {
            repaintVideoSurface(targetTime: currentTime, shouldResume: playbackShouldAdvance || isPlaying)
        } else {
            needsForegroundVideoRepaint = true
            foregroundVideoRepaintTargetTime = currentTime
            if isPlaying || playbackShouldAdvance {
                pauseForBackground(wasPlaying: false, reason: "PiP stopped")
            }
        }
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP did stop")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let wasStartingForBackground = backgroundPiPStartRequested
        backgroundPiPStartRequested = false
        backgroundPiPFallbackGeneration += 1
        onPiPActiveChanged?(false)
        if wasStartingForBackground, UIApplication.shared.applicationState != .active {
            pauseForBackground(wasPlaying: true, reason: "PiP failed")
        }
        StreamifyLogger.log("MPVDirectPlayerEngine: PiP failed to start - \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        if playing {
            play()
        } else {
            pause()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: safeDuration, preferredTimescale: 1000)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !playbackShouldAdvance
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let seconds = CMTimeGetSeconds(skipInterval)
        guard seconds.isFinite else {
            completionHandler()
            return
        }
        let target = max(0, currentTime + seconds)
        seek(time: target) { _ in
            completionHandler()
        }
    }

    @objc private func prepareForBackgroundTransition() {
        _ = requestPiPForBackgroundTransition(source: "willResignActive")
    }

    @discardableResult
    private func requestPiPForBackgroundTransition(source: String) -> Bool {
        guard mpv != nil else { return false }
        guard !isPiPActive else { return false }
        let wasPlaying = isPlaying || playbackShouldAdvance || backgroundedWhilePlaying
        guard wasPlaying else { return false }
        guard isPiPSupported else { return false }

        setupPiPControllerIfNeeded()
        guard pipController != nil else { return false }

        if backgroundPiPStartRequested {
            videoViewInternal.warmSampleBufferTimebase(currentTime: currentTime, isPlaying: true)
            updatePiPPlaybackState()
            startPiPWhenReady(attempt: 0)
            StreamifyLogger.log("MPVDirectPlayerEngine: retried background PiP start from \(source)")
            return true
        }

        backgroundedWhilePlaying = true
        backgroundPiPStartRequested = true
        backgroundPiPFallbackGeneration += 1
        let generation = backgroundPiPFallbackGeneration
        pendingPlayAfterSurfaceReady = false
        foregroundResumeTargetTime = nil

        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "no"], checkForErrors: false)
        cachedPaused = false
        videoViewInternal.warmSampleBufferTimebase(currentTime: currentTime, isPlaying: true)
        updatePiPPlaybackState()
        startPiPWhenReady(attempt: 0)
        scheduleBackgroundPiPFallback(generation: generation)
        StreamifyLogger.log("MPVDirectPlayerEngine: requested PiP for background transition from \(source)")
        return true
    }

    @objc private func enterBackground() {
        guard mpv != nil else { return }
        if isPiPActive {
            backgroundPiPStartRequested = false
            backgroundPiPFallbackGeneration += 1
            backgroundedWhilePlaying = false
            updatePiPPlaybackState()
            StreamifyLogger.log("MPVDirectPlayerEngine: entered background with PiP active")
            return
        }
        if backgroundPiPStartRequested {
            videoViewInternal.warmSampleBufferTimebase(currentTime: currentTime, isPlaying: true)
            updatePiPPlaybackState()
            startPiPWhenReady(attempt: 0)
            StreamifyLogger.log("MPVDirectPlayerEngine: entered background while PiP start is pending")
            return
        }
        if requestPiPForBackgroundTransition(source: "didEnterBackground") {
            return
        }
        pauseForBackground(wasPlaying: isPlaying || playbackShouldAdvance, reason: "background")
    }

    private func pauseForBackground(wasPlaying: Bool, reason: String) {
        backgroundedWhilePlaying = wasPlaying
        pendingPlayAfterSurfaceReady = false
        foregroundResumeTargetTime = nil
        foregroundRecoveryGeneration += 1
        cachedPaused = true
        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
        videoViewInternal.syncSampleBufferTimebase(currentTime: currentTime, isPlaying: false)
        refreshPlaybackState()
        StreamifyLogger.log("MPVDirectPlayerEngine: paused for \(reason) (wasPlaying=\(backgroundedWhilePlaying))")
    }

    @objc private func enterForeground() {
        guard mpv != nil else { return }
        let shouldResumeAfterForeground = backgroundedWhilePlaying || playbackShouldAdvance || isPlaying
        backgroundPiPStartRequested = false
        backgroundPiPFallbackGeneration += 1
        if isPiPActive {
            backgroundedWhilePlaying = false
            pendingPlayAfterSurfaceReady = false
            foregroundResumeTargetTime = nil
            refreshVideoOutputLayout()
            updatePiPPlaybackState()
            StreamifyLogger.log("MPVDirectPlayerEngine: entered foreground with PiP active")
            return
        }
        commandAsync("set", args: ["speed", "1.0"], checkForErrors: false)
        commandAsync("set", args: ["pause", "yes"], checkForErrors: false)
        cachedPaused = true
        refreshVideoOutputLayout()
        videoViewInternal.prepareForPlaybackRecovery(currentTime: currentTime)
        backgroundedWhilePlaying = false
        repaintVideoSurface(
            targetTime: foregroundVideoRepaintTargetTime ?? currentTime,
            shouldResume: shouldResumeAfterForeground
        )
    }

    private func scheduleBackgroundPiPFallback(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.backgroundPiPStartRequested,
                  generation == self.backgroundPiPFallbackGeneration,
                  !self.isPiPActive else {
                return
            }
            self.backgroundPiPStartRequested = false
            guard UIApplication.shared.applicationState != .active else { return }
            self.pauseForBackground(wasPlaying: true, reason: "PiP fallback")
        }
    }

    private func startStateTimer() {
        stateTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPlaybackState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    private func readEvents() {
        guard let context = mpv else { return }
        let contextAddress = Int(bitPattern: context)
        eventQueue.async { [weak self, contextAddress] in
            guard let context = OpaquePointer(bitPattern: contextAddress) else { return }
            while true {
                guard let event = c_mpv_wait_event(context, 0) else { break }
                if event.pointee.event_id == MPV_EVENT_NONE { break }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    // Read the property name and — for sub-text — the new value
                    // synchronously here, before the event buffer is recycled on
                    // the next call to mpv_wait_event.
                    var propertyName: String?
                    var subtitleText: String?
                    var doubleValue: Double?
                    var flagValue: Bool?
                    if let propData = event.pointee.data {
                        let prop = propData.assumingMemoryBound(to: mpv_event_property.self).pointee
                        if let namePtr = prop.name {
                            propertyName = String(cString: namePtr)
                        }
                        if prop.format == MPV_FORMAT_STRING,
                           propertyName == "sub-text" {
                            // prop.data points to a (char *): dereference to get the string
                            let text: String
                            if let strPtrPtr = prop.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self),
                               let strPtr = strPtrPtr.pointee {
                                text = String(cString: strPtr)
                            } else {
                                text = ""
                            }
                            subtitleText = text
                        }
                        if prop.format == MPV_FORMAT_DOUBLE,
                           let value = prop.data?.assumingMemoryBound(to: Double.self) {
                            doubleValue = value.pointee
                        }
                        if prop.format == MPV_FORMAT_FLAG,
                           let value = prop.data?.assumingMemoryBound(to: Int32.self) {
                            flagValue = value.pointee != 0
                        }
                    }
                    let capturedPropertyName = propertyName
                    let capturedSubtitleText = subtitleText
                    let capturedDoubleValue = doubleValue
                    let capturedFlagValue = flagValue
                    Task { @MainActor in
                        if let name = capturedPropertyName {
                            self?.cacheObservedPlaybackProperty(
                                name: name,
                                doubleValue: capturedDoubleValue,
                                flagValue: capturedFlagValue
                            )
                        }
                        // Dispatch only the work that each observed property requires:
                        //   sub-text          → subtitle text update only
                        //   track-list/count  → track list refresh only
                        //   pause / paused-for-cache / core-idle / eof-reached / seeking
                        //                     → playback state refresh only
                        switch capturedPropertyName {
                        case "sub-text":
                            if let text = capturedSubtitleText {
                                self?.handleSubtitleTextChange(text)
                            }
                        case "track-list/count":
                            self?.refreshTracks()
                        case "video-params/sig-peak":
                            if let value = capturedDoubleValue {
                                self?.handleHDRSignalPeakChange(value)
                            }
                        default:
                            self?.refreshPlaybackState()
                        }
                    }
                case MPV_EVENT_FILE_LOADED:
                    Task { @MainActor in
                        guard let self else { return }
                        self.didReportReady = true
                        self.isLoading = false
                        StreamifyLogger.log("MPVDirectPlayerEngine: file-loaded")
                        self.refreshPlaybackState()
                        self.scheduleTrackRefresh()
                        self.onReadyToPlay?()
                    }
                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorText = String(cString: c_mpv_error_string(endFile.error))
                            Task { @MainActor in
                                self?.handlePlaybackError("[mpv] \(errorText)")
                            }
                        } else {
                            Task { @MainActor in
                                self?.didReportFinished = true
                                self?.onFinished?()
                            }
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                        let prefix = String(cString: message.pointee.prefix!)
                        let level = String(cString: message.pointee.level!)
                        let text = String(cString: message.pointee.text!)
                        Task { @MainActor in
                            self?.appendPlaybackLog(prefix: prefix, level: level, text: text)
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    private func refreshPlaybackState() {
        guard mpv != nil else { return }
        let state = snapshotState()
        currentTime = state.position
        duration = state.duration
        bufferedTime = state.buffered
        isPlaying = state.isPlaying
        isLoading = state.isLoading
        currentSpeed = state.speed
        onStateChanged?(state)
        if isPiPActive {
            videoViewInternal.syncSampleBufferTimebase(currentTime: state.position, isPlaying: state.isPlaying)
            pipController?.invalidatePlaybackState()
        }
        if state.isEnded && !didReportFinished {
            didReportFinished = true
            onFinished?()
        }
    }

    private func completeSeekWhenSettled(target: Double, attempt: Int, completion: ((Bool) -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.refreshPlaybackState()
            let targetDelta = abs(self.currentTime - target)
            let minimumAttemptsReached = attempt >= 4
            let settled = minimumAttemptsReached && !self.cachedSeeking && (targetDelta < 1.0 || attempt >= 8)
            if settled || attempt >= 16 {
                self.updatePiPPlaybackState()
                completion?(true)
            } else {
                self.completeSeekWhenSettled(target: target, attempt: attempt + 1, completion: completion)
            }
        }
    }

    private func updatePiPPlaybackState() {
        guard isPiPSupported else { return }
        videoViewInternal.warmSampleBufferTimebase(currentTime: currentTime, isPlaying: playbackShouldAdvance)
        pipController?.invalidatePlaybackState()
    }

    private func handleSubtitleTextChange(_ text: String) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        onSubtitleText?(text)
    }

    private func handleHDRSignalPeakChange(_ signalPeak: Double) {
        guard signalPeak.isFinite, signalPeak > 0 else { return }
        if let lastReportedHDRSignalPeak,
           abs(lastReportedHDRSignalPeak - signalPeak) < 0.05 {
            return
        }
        lastReportedHDRSignalPeak = signalPeak
        videoViewInternal.setExtendedDynamicRangeEnabled(preferHDROutput && signalPeak > 1)
        StreamifyLogger.log("MPVDirectPlayerEngine: HDR signal peak=\(String(format: "%.2f", signalPeak))x SDR")
    }

    private func snapshotState(isLoadingOverride: Bool? = nil) -> MPVPlaybackState {
        if videoOutputKind == .avFoundation {
            return cachedSnapshotState(isLoadingOverride: isLoadingOverride)
        }

        let rawDuration = getDouble("duration")
        let rawPosition = getDouble("time-pos")
        let rawCache = getDouble("demuxer-cache-time")
        let rawSpeed = getDouble("speed")
        let paused = getFlag("pause")
        let eofReached = getFlag("eof-reached")
        let idle = getFlag("core-idle")
        let seeking = getFlag("seeking")
        let bufferingCache = getFlag("paused-for-cache")

        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        let position = rawPosition.isFinite && rawPosition > 0 ? rawPosition : 0
        let cache = rawCache.isFinite && rawCache > 0 ? min(rawCache, kMPVForwardBufferDuration) : 0
        let loading = isLoadingOverride ?? ((idle && !paused && !eofReached) || seeking || bufferingCache)
        return MPVPlaybackState(
            isLoading: loading,
            isPlaying: !paused && !idle && !eofReached,
            isEnded: eofReached,
            duration: duration,
            position: position,
            buffered: max(position + cache, position),
            speed: Float(rawSpeed > 0 ? rawSpeed : 1.0)
        )
    }

    private func cachedSnapshotState(isLoadingOverride: Bool? = nil) -> MPVPlaybackState {
        let duration = cachedDuration.isFinite && cachedDuration > 0 ? cachedDuration : 0
        let position = cachedPosition.isFinite && cachedPosition > 0 ? cachedPosition : 0
        let cache = cachedDemuxerCacheTime.isFinite && cachedDemuxerCacheTime > 0
            ? min(cachedDemuxerCacheTime, kMPVForwardBufferDuration)
            : 0
        let loading = isLoadingOverride ??
            ((cachedCoreIdle && !cachedPaused && !cachedEofReached) || cachedSeeking || cachedPausedForCache)

        return MPVPlaybackState(
            isLoading: loading,
            isPlaying: !cachedPaused && !cachedCoreIdle && !cachedEofReached,
            isEnded: cachedEofReached,
            duration: duration,
            position: position,
            buffered: max(position + cache, position),
            speed: Float(cachedPlaybackSpeed > 0 ? cachedPlaybackSpeed : 1)
        )
    }

    private func cacheObservedPlaybackProperty(name: String, doubleValue: Double?, flagValue: Bool?) {
        switch name {
        case "pause":
            if let flagValue { cachedPaused = flagValue }
        case "paused-for-cache":
            if let flagValue { cachedPausedForCache = flagValue }
        case "core-idle":
            if let flagValue { cachedCoreIdle = flagValue }
        case "eof-reached":
            if let flagValue { cachedEofReached = flagValue }
        case "seeking":
            if let flagValue { cachedSeeking = flagValue }
        case "duration":
            if let doubleValue, doubleValue.isFinite { cachedDuration = max(doubleValue, 0) }
        case "time-pos":
            if let doubleValue, doubleValue.isFinite { cachedPosition = max(doubleValue, 0) }
        case "demuxer-cache-time":
            if let doubleValue, doubleValue.isFinite { cachedDemuxerCacheTime = max(doubleValue, 0) }
        case "speed":
            if let doubleValue, doubleValue.isFinite { cachedPlaybackSpeed = max(doubleValue, 0) }
        default:
            break
        }
    }

    private func resetCachedPlaybackState() {
        cachedPaused = true
        cachedPausedForCache = false
        cachedCoreIdle = true
        cachedEofReached = false
        cachedSeeking = false
        cachedDuration = 0
        cachedPosition = 0
        cachedDemuxerCacheTime = 0
        cachedPlaybackSpeed = 1
    }

    private func refreshTracks() {
        guard mpv != nil else { return }
        if videoOutputKind == .avFoundation {
            refreshTracksOffMain()
            return
        }

        var audio: [MPVTrackInfo] = []
        var subtitles: [MPVTrackInfo] = []
        let count = getInt("track-list/count")
        guard count > 0 else {
            publishTracksIfChanged(audio: [], subtitles: [])
            return
        }

        var audioIndex = 0
        var subtitleIndex = 0
        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let title = getString("track-list/\(i)/title") ?? ""
            let lang = getString("track-list/\(i)/lang") ?? ""
            let codec = getString("track-list/\(i)/codec") ?? ""
            let channelCount = getInt("track-list/\(i)/demux-channel-count")
            let sampleRate = getInt("track-list/\(i)/demux-samplerate")
            let external = getFlag("track-list/\(i)/external")
            let selected = getFlag("track-list/\(i)/selected")
            if type == "audio" {
                audio.append(MPVTrackInfo(
                    index: audioIndex,
                    id: id,
                    type: type,
                    title: title,
                    lang: lang,
                    codec: codec,
                    demuxChannelCount: channelCount,
                    demuxSamplerate: sampleRate,
                    external: external,
                    selected: selected
                ))
                audioIndex += 1
            } else if type == "sub" {
                subtitles.append(MPVTrackInfo(
                    index: subtitleIndex,
                    id: id,
                    type: type,
                    title: title,
                    lang: lang,
                    codec: codec,
                    demuxChannelCount: channelCount,
                    demuxSamplerate: sampleRate,
                    external: external,
                    selected: selected
                ))
                subtitleIndex += 1
            }
        }
        publishTracksIfChanged(audio: audio, subtitles: subtitles)
    }

    private func refreshTracksOffMain() {
        guard let context = mpv else { return }
        let contextAddress = Int(bitPattern: context)
        eventQueue.async { [weak self, contextAddress] in
            guard let self,
                  let context = OpaquePointer(bitPattern: contextAddress) else { return }

            let count = self.getInt("track-list/count", context: context)
            guard count > 0 else {
                Task { @MainActor in
                    self.publishTracksIfChanged(audio: [], subtitles: [])
                }
                return
            }

            var audio: [MPVTrackInfo] = []
            var subtitles: [MPVTrackInfo] = []
            var audioIndex = 0
            var subtitleIndex = 0
            for i in 0..<count {
                let type = self.getString("track-list/\(i)/type", context: context) ?? ""
                let id = self.getInt("track-list/\(i)/id", context: context)
                let title = self.getString("track-list/\(i)/title", context: context) ?? ""
                let lang = self.getString("track-list/\(i)/lang", context: context) ?? ""
                let codec = self.getString("track-list/\(i)/codec", context: context) ?? ""
                let channelCount = self.getInt("track-list/\(i)/demux-channel-count", context: context)
                let sampleRate = self.getInt("track-list/\(i)/demux-samplerate", context: context)
                let external = self.getFlag("track-list/\(i)/external", context: context)
                let selected = self.getFlag("track-list/\(i)/selected", context: context)
                if type == "audio" {
                    audio.append(MPVTrackInfo(
                        index: audioIndex,
                        id: id,
                        type: type,
                        title: title,
                        lang: lang,
                        codec: codec,
                        demuxChannelCount: channelCount,
                        demuxSamplerate: sampleRate,
                        external: external,
                        selected: selected
                    ))
                    audioIndex += 1
                } else if type == "sub" {
                    subtitles.append(MPVTrackInfo(
                        index: subtitleIndex,
                        id: id,
                        type: type,
                        title: title,
                        lang: lang,
                        codec: codec,
                        demuxChannelCount: channelCount,
                        demuxSamplerate: sampleRate,
                        external: external,
                        selected: selected
                    ))
                    subtitleIndex += 1
                }
            }

            Task { @MainActor in
                self.publishTracksIfChanged(audio: audio, subtitles: subtitles)
            }
        }
    }

    private func publishTracksIfChanged(audio: [MPVTrackInfo], subtitles: [MPVTrackInfo]) {
        guard audio != lastAudioTracks || subtitles != lastSubtitleTracks else { return }
        lastAudioTracks = audio
        lastSubtitleTracks = subtitles
        onTracksChanged?(audio, subtitles)
    }

    @discardableResult
    private func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) -> CInt {
        guard mpv != nil else { return -1 }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let ret = cargs.withUnsafeMutableBufferPointer { buffer in
            c_mpv_command(mpv, buffer.baseAddress)
        }
        if checkForErrors {
            checkError(ret)
        }
        return ret
    }

    @discardableResult
    private func commandAsync(_ command: String, args: [String?] = [], checkForErrors: Bool = true) -> CInt {
        guard mpv != nil else { return -1 }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let ret = cargs.withUnsafeMutableBufferPointer { buffer in
            c_mpv_command_async(mpv, 0, buffer.baseAddress)
        }
        if checkForErrors {
            checkError(ret)
        }
        return ret
    }

    private func attachVideoView(to container: UIView, useSafeArea: Bool) {
        activeVideoConstraints.forEach { $0.isActive = false }
        activeVideoConstraints.removeAll()
        videoViewInternal.removeFromSuperview()
        videoViewInternal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoViewInternal)

        let constraints: [NSLayoutConstraint]
        if useSafeArea {
            let layoutBounds = container.window?.bounds ?? UIScreen.main.bounds
            let resolvedSafeArea = StreamifySafeArea.resolvedInsets(fallback: container.safeAreaInsets)
            let insetReduction: CGFloat = StreamifySafeArea.shouldCropVideoToFill(bounds: layoutBounds, safeAreaInsets: resolvedSafeArea) ? 4 : 0
            constraints = [
                videoViewInternal.widthAnchor.constraint(
                    equalTo: container.safeAreaLayoutGuide.widthAnchor,
                    constant: insetReduction * 2
                ),
                videoViewInternal.heightAnchor.constraint(
                    equalTo: container.safeAreaLayoutGuide.heightAnchor,
                    constant: insetReduction * 2
                ),
                videoViewInternal.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                videoViewInternal.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ]
        } else {
            constraints = [
                videoViewInternal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                videoViewInternal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                videoViewInternal.topAnchor.constraint(equalTo: container.topAnchor),
                videoViewInternal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        activeVideoConstraints = constraints
        container.setNeedsLayout()
        container.layoutIfNeeded()
        videoViewInternal.refreshDrawableSize()
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        withUnsafeMutablePointer(to: &data) { pointer in
            _ = getProperty(name, format: MPV_FORMAT_DOUBLE, data: pointer)
        }
        return data
    }

    private nonisolated func getInt(_ name: String, context: OpaquePointer) -> Int {
        var data = Int64()
        name.withCString { namePointer in
            _ = c_mpv_get_property(context, namePointer, MPV_FORMAT_INT64, &data)
        }
        return Int(data)
    }

    private nonisolated func getFlag(_ name: String, context: OpaquePointer) -> Bool {
        var data = Int32()
        name.withCString { namePointer in
            _ = c_mpv_get_property(context, namePointer, MPV_FORMAT_FLAG, &data)
        }
        return data != 0
    }

    private nonisolated func getString(_ name: String, context: OpaquePointer) -> String? {
        let cstr = name.withCString { namePointer in
            c_mpv_get_property_string(context, namePointer)
        }
        guard let cstr else { return nil }
        defer { c_mpv_free(UnsafeMutableRawPointer(cstr)) }
        return String(cString: cstr)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = getPropertyString(name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        c_mpv_free(UnsafeMutableRawPointer(cstr))
        return str
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = CInt()
        withUnsafeMutablePointer(to: &data) { pointer in
            _ = getProperty(name, format: MPV_FORMAT_FLAG, data: pointer)
        }
        return data != 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: CInt = flag ? 1 : 0
        withUnsafePointer(to: &data) { pointer in
            checkError(setProperty(name, format: MPV_FORMAT_FLAG, data: pointer))
        }
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        withUnsafeMutablePointer(to: &data) { pointer in
            _ = getProperty(name, format: MPV_FORMAT_INT64, data: pointer)
        }
        return Int(data)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            let message = String(cString: c_mpv_error_string(status))
            StreamifyLogger.log("MPVDirectPlayerEngine: API error \(message)")
        }
    }

    private func checkOptionalError(_ status: CInt, option: String) {
        if status < 0 {
            let message = String(cString: c_mpv_error_string(status))
            StreamifyLogger.log("MPVDirectPlayerEngine: optional option \(option) unavailable (\(message))")
        }
    }

    @discardableResult
    private func setFirstAvailableOptionString(_ option: String, values: [String]) -> String? {
        var failures: [String] = []
        for value in values {
            let status = setOptionString(option, value)
            if status >= 0 {
                return value
            }

            let message = String(cString: c_mpv_error_string(status))
            failures.append("\(value): \(message)")
        }
        StreamifyLogger.log("MPVDirectPlayerEngine: optional option \(option) unavailable (\(failures.joined(separator: "; ")))")
        return nil
    }

    private func sanitizeRequestHeaders(_ headers: [String: String]) -> [String: String] {
        guard !headers.isEmpty else { return [:] }
        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(headers.count)
        headers.forEach { rawKey, rawValue in
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            guard key.caseInsensitiveCompare("Range") != .orderedSame else { return }
            sanitized[key] = value
        }
        return sanitized
    }

    private func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        if headers.isEmpty {
            checkError(setPropertyString("http-header-fields", ""))
            return
        }

        let serialized = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ",", with: "\\,")
                return "\(key): \(escapedValue)"
            }
            .joined(separator: ",")
        checkError(setPropertyString("http-header-fields", serialized))
    }

    private func requestLogMessages(_ level: String) -> CInt {
        level.withCString { levelPointer in
            c_mpv_request_log_messages(mpv, levelPointer)
        }
    }

    private func setOption(_ name: String, format: CInt, data: UnsafeRawPointer?) -> CInt {
        name.withCString { namePointer in
            c_mpv_set_option(mpv, namePointer, format, data)
        }
    }

    private func setOptionString(_ name: String, _ value: String) -> CInt {
        name.withCString { namePointer in
            value.withCString { valuePointer in
                c_mpv_set_option_string(mpv, namePointer, valuePointer)
            }
        }
    }

    private func setProperty(_ name: String, format: CInt, data: UnsafeRawPointer?) -> CInt {
        name.withCString { namePointer in
            c_mpv_set_property(mpv, namePointer, format, data)
        }
    }

    private func setPropertyString(_ name: String, _ value: String) -> CInt {
        name.withCString { namePointer in
            value.withCString { valuePointer in
                c_mpv_set_property_string(mpv, namePointer, valuePointer)
            }
        }
    }

    private func getProperty(_ name: String, format: CInt, data: UnsafeMutableRawPointer?) -> CInt {
        name.withCString { namePointer in
            c_mpv_get_property(mpv, namePointer, format, data)
        }
    }

    private func getPropertyString(_ name: String) -> UnsafeMutablePointer<CChar>? {
        name.withCString { namePointer in
            c_mpv_get_property_string(mpv, namePointer)
        }
    }

    private func observeProperty(_ name: String, format: CInt) {
        name.withCString { namePointer in
            _ = c_mpv_observe_property(mpv, 0, namePointer, format)
        }
    }

    private func clearPlaybackError() {
        errorStateLock.lock()
        recentPlaybackLogs.removeAll(keepingCapacity: true)
        errorStateLock.unlock()
    }

    private func appendPlaybackLog(prefix: String, level: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard level == "warn" || level == "error" || level == "fatal" else { return }
        errorStateLock.lock()
        recentPlaybackLogs.append("[\(prefix)] \(trimmed)")
        if recentPlaybackLogs.count > 4 {
            recentPlaybackLogs.removeFirst(recentPlaybackLogs.count - 4)
        }
        errorStateLock.unlock()
        StreamifyLogger.log("MPVDirectPlayerEngine[\(prefix)] \(level): \(trimmed)")
    }

    private func handlePlaybackError(_ fallback: String) {
        errorStateLock.lock()
        var parts = recentPlaybackLogs.suffix(3)
        if !fallback.isEmpty && !parts.contains(fallback) {
            parts.append(fallback)
        }
        let message = parts.isEmpty ? "Unable to play this stream." : parts.joined(separator: "\n")
        errorStateLock.unlock()
        onError?(message)
        StreamifyLogger.log("MPVDirectPlayerEngine: playback error \(message)")
    }
}

#else

@MainActor
final class MPVDirectPlayerEngine: ObservableObject {
    nonisolated static var isAvailable: Bool { false }
    var onReadyToPlay: (() -> Void)?
    var onStateChanged: ((MPVPlaybackState) -> Void)?
    var onTracksChanged: (([MPVTrackInfo], [MPVTrackInfo]) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var currentTime: Double { 0 }
    var duration: Double { 0 }
    var bufferedTime: Double { 0 }
    var isPlaying: Bool { false }
    var isLoading: Bool { false }
    var currentSpeed: Float { 1 }
    var isPiPSupported: Bool { false }
    var isPiPActive: Bool { false }
    var isMuted: Bool {
        get { false }
        set { _ = newValue }
    }
    #if canImport(UIKit)
    var videoView: UIView? { nil }
    func attachVideoView(to container: UIView) {}
    func refreshVideoOutputLayout() {}
    #endif

    func load(url: URL, requestHeaders: [String: String] = [:]) {}
    func play(onStarted: (() -> Void)? = nil) { onStarted?() }
    func pause() {}
    func seek(time seconds: Double, completion: ((Bool) -> Void)? = nil) { completion?(false) }
    func selectAudio(id: Int?) {}
    func disableAudio() {}
    func selectSubtitle(id: Int?) {}
    func clearExternalSubtitles(selecting trackId: Int? = nil) {}
    func togglePiP() {}
    func cleanup() {}
}

#endif

#if canImport(UIKit)
struct MPVDirectPlayerView: UIViewRepresentable {
    let engine: MPVDirectPlayerEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attachVideoView(to: container)
        engine.refreshVideoOutputLayout()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if engine.videoView?.superview !== uiView {
            attachVideoView(to: uiView)
        }
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        engine.refreshVideoOutputLayout()
    }

    private func attachVideoView(to container: UIView) {
        engine.attachVideoView(to: container)
    }
}
#endif
