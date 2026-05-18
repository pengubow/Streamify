import SwiftUI
import UIKit

struct ContentDetailView: View {
    let content: SavedContent
    var sourceContent: SourceContent? = nil  // Optional: if provided, this is from Browse
    @ObservedObject var viewModel: LibraryViewModel
    var onDismissRequest: (() -> Void)? = nil

    @State var playerContext: PlayerContext?
    @State var currentEpisodeIndex: Int = 0
    @State var downloadError: String?
    @State var showDownloadError: Bool = false
    @State var playError: String?
    @State var showPlayError: Bool = false
    @State var showQualityPicker: Bool = false
    @State var selectedEpisodeForDownload: EpisodeInfo?
    @State var multiSourceQualities: [MultiSourceQuality] = []
    @State var expandedDownloadQualityGroup: String?  // Tracks which quality group is expanded in download picker
    @State var selectedDownloadQualities: Set<UUID> = []  // Selected quality IDs for multi-select picker
    @State var isLoadingQualities: Bool = false
    @State var loadingMessage: String? = nil
    @State var selectedSeason: Int = 1
    @State var isAddingToLibrary: Bool = false
    @State var progressRefreshTrigger: Bool = false
    @State var detailBackdropColor: UIColor?

    // Granular remove picker
    @State var showRemovePicker: Bool = false
    @State var removePickerEpisode: EpisodeInfo? = nil  // nil = movie

    // Download track selection — use Identifiable wrappers so sheet(item:) works.
    // The data IS the presentation trigger: non-nil → sheet shown, nil → sheet hidden.
    @State var subtitlePickerData: SubtitlePickerData? = nil
    @State var audioPickerData: AudioPickerData? = nil
    @State var selectedDownloadSubtitles: Set<String> = []  // trackIds
    @State var selectedDownloadAudio: Set<String> = []  // trackIds
    @State var pendingDownloadUrl: String? = nil  // URL waiting for track selection
    @State var pendingVidLinkHlsUrl: String? = nil  // VidLink HLS URL for quality picker inclusion
    @State var pendingMovies111HlsUrl: String? = nil  // 111Movies HLS URL for quality picker inclusion
    @State var pendingTorrentioHlsUrl: String? = nil  // Torrentio HLS URL for quality picker inclusion
    @State var pendingStreamingQualities: [HLSQuality] = []  // Direct/non-HLS stream options from providers
    @State var pendingSubtitleTracks: [SubtitleTrack] = []  // subtitle tracks resolved for this download
    @State var pendingAudioTracks: [AudioTrack] = []  // audio tracks to show after subtitle sheet
    @State var downloadFlowNextStep: DownloadFlowStep = .idle
    /// Set to true when the user explicitly clicks Next. When false, onDismiss means user swiped down → cancel entire flow.
    @State var userConfirmedPicker: Bool = false
    @State private var detailTopSafeAreaInset: CGFloat = 0
    @Environment(\.dismiss) var dismiss

    // Get download manager - use @ObservedObject to react to changes
    @ObservedObject var downloadManager = DownloadManager.shared
    @AppStorage("vidLinkEnabled") var vidLinkEnabled: Bool = true
    @AppStorage("movies111Enabled") var movies111Enabled: Bool = true
    @AppStorage("torrentioEnabled") var torrentioEnabled: Bool = false

    // TMDB-fetched seasons/episodes for series without local data
    @State var tmdbFetchedSeasons: [SeasonInfo]? = nil
    @State var isFetchingTMDBDetails: Bool = false

    // Playback resolution — task handle for cancellation, skipper for per-URL skip
    @State var playResolutionTask: Task<Void, Never>? = nil
    @State var urlCheckSkipper: URLCheckSkipper? = nil
    // Retains the last non-nil loadingMessage so the exit animation of the overlay
    // shows the correct text instead of the "Setting up video player..." fallback.
    @State var loadingMessageSnapshot: String = ""

    // Max characters shown for a URL in the loading overlay (with "..." prefix for overflow).
    static let urlDisplayMaxLength = 60
    static let urlDisplaySuffixLength = 57
    // How long (nanoseconds) to wait before aborting the playback resolution task.
    static let playbackResolutionTimeoutNs: UInt64 = 30_000_000_000
    /// Identifiable wrapper for subtitle picker data — non-nil triggers the sheet.
    /// Pre-selected IDs are included so they travel with the trigger, avoiding SwiftUI
    /// state-batching issues where sheet(item:) renders before other @State changes.
    struct SubtitlePickerData: Identifiable {
        let id = UUID()
        let tracks: [SubtitleTrack]
        let preSelectedIds: Set<String>
    }

    /// Identifiable wrapper for audio picker data — non-nil triggers the sheet.
    struct AudioPickerData: Identifiable {
        let id = UUID()
        let tracks: [AudioTrack]
        let preSelectedIds: Set<String>
    }

    /// Tracks what should happen after the current sheet dismisses.
    enum DownloadFlowStep {
        case idle
        case showAudioPicker   // subtitle sheet done → show audio picker
        case showQualityPicker // audio sheet done → show quality picker
    }

    // Get the latest content from library (for UI updates after removal)
    var currentContent: SavedContent {
        if let sourceContent = sourceContent {
            return viewModel.library.first { $0.id == sourceContent.id } ?? content
        }
        return viewModel.library.first { $0.id == content.id } ?? content
    }

    // Is this content in the library?
    var isInLibrary: Bool {
        if let sourceContent = sourceContent {
            return viewModel.library.contains { $0.id == sourceContent.id }
        }
        return true
    }

    // Get saved progress for this content
    var savedProgress: WatchingProgress? {
        _ = progressRefreshTrigger
        return WatchingProgressManager.getCurrentProgress(for: content.id)
    }

    // Sorted episodes list (supports both nested seasons and flat episodes)
    var episodes: [EpisodeInfo] {
        let existing = currentContent.metadata.allEpisodes
        if !existing.isEmpty { return existing }
        // Fallback to TMDB-fetched seasons/episodes
        if let tmdbSeasons = tmdbFetchedSeasons {
            return tmdbSeasons.flatMap { season in
                (season.episodes ?? []).map { ep in
                    ep.season == season.season ? ep : ep.copying(season: season.season)
                }
            }
        }
        return []
    }

    // Get seasons from content
    var seasons: [SeasonInfo] {
        let existing = currentContent.metadata.seasons ?? []
        if !existing.isEmpty { return existing }
        // Fallback to TMDB-fetched seasons
        return tmdbFetchedSeasons ?? []
    }

    // Get available season numbers
    var seasonNumbers: [Int] {
        if !seasons.isEmpty {
            return seasons.map { $0.season }.sorted()
        }
        let seasonSet = Set(episodes.map { $0.season })
        return seasonSet.sorted()
    }

    // Get episodes for selected season
    var selectedSeasonEpisodes: [EpisodeInfo] {
        if !seasons.isEmpty {
            if let season = seasons.first(where: { $0.season == selectedSeason }),
               let seasonEpisodes = season.episodes {
                // Ensure episodes have the correct season number matching their parent
                return seasonEpisodes.map { ep in
                    ep.season == selectedSeason ? ep : ep.copying(season: selectedSeason)
                }
            }
        }
        return episodes.filter { $0.season == selectedSeason }
    }

    var hasSeasons: Bool {
        currentContent.metadata.type == .series && (!seasons.isEmpty || episodes.contains { $0.season > 1 })
    }

    var body: some View {
        ZStack {
            ContentDetailBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ContentDetailTopBarScrollReader(id: content.id)
                        .frame(width: 0, height: 0)

                    ZStack {
                        ContentDetailAmbientBackdrop(color: detailBackdropColor)
                            .allowsHitTesting(false)

                        heroImage
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .bottom) {
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.45)],
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                    }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(content.metadata.title)
                            .font(.title.bold())
                            .foregroundStyle(.white)

                        metadataBadges

                        // Description
                        if !content.metadata.description.isEmpty {
                            Text(content.metadata.description)
                                .font(.body)
                                .foregroundStyle(StreamifySurface.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if content.metadata.type == .movie {
                            movieActionButtons
                        } else if !episodes.isEmpty {
                            seriesActionButtons
                        }

                        libraryButton

                        if !episodes.isEmpty {
                            episodeSection
                        } else if isFetchingTMDBDetails {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .tint(.white)
                                Text("Loading episodes...")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                    }
                    .padding(16)
                    .streamifyPanel(cornerRadius: 12, materialOpacity: 0)
                    .padding(.horizontal, 16)

                    Spacer(minLength: 86)
                }
            }
            .streamifyScrollIndicatorsHidden()
        }
        // Measure the real top safe-area inset for this presentation context:
        // • In a sheet the content starts below the status bar → 0 pt
        // • In a NavigationStack (full-screen) → status-bar height (~59 pt)
        // Using .ignoresSafeArea on the reader causes it to extend into the safe area,
        // so geo.safeAreaInsets.top reflects the actual inset to the system chrome.
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    detailTopSafeAreaInset = geo.safeAreaInsets.top
                }
            }
            .ignoresSafeArea(edges: .top)
        )
        .streamifyNavigationBarHidden()
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .top) {
            detailTopBar
        }
        .task(id: content.id) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.refreshLibrary()
                fetchTMDBSeasonsIfNeeded()
            }
        }
        .streamifyAlert(
            title: "Download Error",
            message: downloadError ?? "",
            isPresented: $showDownloadError,
            primaryAction: { downloadError = nil }
        )
        .streamifyAlert(
            title: "Playback Error",
            message: playError ?? "Unable to play this content. All sources failed.",
            isPresented: $showPlayError,
            primaryAction: { playError = nil }
        )
        .streamifyCenteredPopup(
            isPresented: Binding(
                get: { isLoadingQualities || loadingMessage != nil },
                set: { presented in
                    if !presented {
                        cancelLoadingOverlay()
                    }
                }
            ),
            dismissOnBackdrop: false
        ) {
            loadingOverlay
        }
        .streamifyBottomPopup(isPresented: $showQualityPicker) {
            qualityPickerSheet
        }
        .streamifyBottomPopup(item: $subtitlePickerData, onDismiss: {
            handleSubtitlePickerDismissed()
        }) { data in
            downloadSubtitlePickerSheet(data: data)
        }
        .streamifyBottomPopup(item: $audioPickerData, onDismiss: {
            handleAudioPickerDismissed()
        }) { data in
            downloadAudioPickerSheet(data: data)
        }
        .streamifyBottomPopup(isPresented: $showRemovePicker) {
            removeDownloadPickerSheet
        }
        .onChange(of: downloadManager.showErrorAlert) { showError in
            if showError {
                downloadError = downloadManager.lastError
                showDownloadError = true
                downloadManager.showErrorAlert = false
                downloadManager.lastError = nil
            }
        }
        .onChange(of: downloadManager.libraryRefreshNeeded) { needsRefresh in
            if needsRefresh {
                viewModel.refreshLibrary()
                downloadManager.libraryRefreshNeeded = false
            }
        }
        .onChange(of: loadingMessage) { msg in
            if let msg { loadingMessageSnapshot = msg }
        }
        .fullScreenCover(item: $playerContext) { context in
            playerView(for: context)
        }
    }

    func requestDismiss() {
        if let onDismissRequest {
            onDismissRequest()
        } else {
            dismiss()
        }
    }

    private var detailTopBar: some View {
        ContentDetailTopBarView(
            id: content.id,
            title: content.metadata.title,
            topInset: detailTopSafeAreaInset
        )
        .frame(height: detailTopSafeAreaInset + 44)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .contentShape(Rectangle())
    }

}

private enum ContentDetailTopBarBus {
    static let scrollOffsetDidChange = Notification.Name("ContentDetailTopBarScrollOffsetDidChange")
    static let idKey = "id"
    static let offsetKey = "offset"

    static func post(id: String, scrollOffset: CGFloat) {
        NotificationCenter.default.post(
            name: scrollOffsetDidChange,
            object: nil,
            userInfo: [
                idKey: id,
                offsetKey: Double(scrollOffset)
            ]
        )
    }
}

private struct ContentDetailTopBarScrollReader: UIViewRepresentable {
    let id: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.id = id
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.id = id
        context.coordinator.attach(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var id = "" {
            didSet {
                if oldValue != id {
                    lastPublishedOffset = .greatestFiniteMagnitude
                    publish()
                }
            }
        }

        private weak var scrollView: UIScrollView?
        private var sourceView: UIView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var lastPublishedOffset = CGFloat.greatestFiniteMagnitude
        private var attachRetryCount = 0
        private static let maxAttachRetryCount = 8

        deinit {
            contentOffsetObservation?.invalidate()
        }

        func attach(from view: UIView) {
            sourceView = view

            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard let nextScrollView = view.streamifyEnclosingScrollView() else {
                    self.retryAttach()
                    return
                }

                self.attachRetryCount = 0
                guard nextScrollView !== self.scrollView else {
                    self.publish()
                    return
                }

                self.scrollView = nextScrollView
                self.lastPublishedOffset = .greatestFiniteMagnitude
                self.contentOffsetObservation?.invalidate()
                self.contentOffsetObservation = nextScrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                    self?.publish()
                }
                self.publish()
            }
        }

        private func retryAttach() {
            guard attachRetryCount < Self.maxAttachRetryCount else { return }
            attachRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let sourceView = self.sourceView else { return }
                self.attach(from: sourceView)
            }
        }

        private func publish() {
            guard !id.isEmpty, let scrollView else { return }
            let offset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            guard offset.isFinite else { return }
            let reachedEdge = (offset == 0 || offset >= 160) && lastPublishedOffset != offset
            guard abs(lastPublishedOffset - offset) > 2 || reachedEdge else { return }
            lastPublishedOffset = offset
            ContentDetailTopBarBus.post(id: id, scrollOffset: offset)
        }
    }
}

private struct ContentDetailTopBarView: UIViewRepresentable {
    let id: String
    let title: String
    let topInset: CGFloat

    func makeUIView(context: Context) -> ContentDetailTopBarUIView {
        let view = ContentDetailTopBarUIView()
        view.update(id: id, title: title, topInset: topInset)
        return view
    }

    func updateUIView(_ uiView: ContentDetailTopBarUIView, context: Context) {
        uiView.update(id: id, title: title, topInset: topInset)
    }
}

private final class ContentDetailTopBarUIView: UIView {
    private let blackView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let grayOverlay = UIView()
    private let titleLabel = UILabel()
    private let hairline = UIView()
    private var id = ""
    private var topInset: CGFloat = 0
    private var progress: CGFloat = 0
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBar()
    }

    func update(id: String, title: String, topInset: CGFloat) {
        if self.id != id {
            self.id = id
            progress = 0
        }

        titleLabel.text = title
        self.topInset = topInset
        setProgress(progress, force: true)
        setNeedsLayout()
    }

    private func setup() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        blackView.backgroundColor = .black
        addSubview(blackView)

        blurView.isUserInteractionEnabled = false
        blurView.contentView.backgroundColor = .clear
        addSubview(blurView)

        grayOverlay.backgroundColor = UIColor(white: 0.16, alpha: 1)
        grayOverlay.isUserInteractionEnabled = false
        addSubview(grayOverlay)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        addSubview(hairline)

        observer = NotificationCenter.default.addObserver(
            forName: ContentDetailTopBarBus.scrollOffsetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollOffset(notification)
        }

        setProgress(0, force: true)
    }

    private func layoutBar() {
        let fullBounds = bounds
        blackView.frame = fullBounds
        blurView.frame = fullBounds
        grayOverlay.frame = fullBounds
        hairline.frame = CGRect(x: 0, y: fullBounds.height - 1, width: fullBounds.width, height: 1)
        let labelHeight: CGFloat = 22
        let barContentHeight = fullBounds.height - topInset
        let labelY = topInset + (barContentHeight - labelHeight) / 2
        titleLabel.frame = CGRect(x: 18, y: labelY, width: max(0, fullBounds.width - 36), height: labelHeight)
        applyTitleTransform()
    }

    private func handleScrollOffset(_ notification: Notification) {
        guard let incomingId = notification.userInfo?[ContentDetailTopBarBus.idKey] as? String,
              incomingId == id,
              let value = notification.userInfo?[ContentDetailTopBarBus.offsetKey] as? Double
        else { return }

        // Fade in the navbar title once the hero title has scrolled well off screen.
        // revealStart: how far (pt) the user must scroll before any fade begins.
        // revealDistance: how many additional pt to go from 0 → full opacity.
        // A short revealDistance means a snappy, quick ramp-up once triggered.
        let revealStart: CGFloat = 220
        let revealDistance: CGFloat = 60
        let rawProgress = min(1, max(0, (CGFloat(value) - revealStart) / revealDistance))
        let next = rawProgress * rawProgress * (3 - (2 * rawProgress))
        setProgress(next)
    }

    private func setProgress(_ next: CGFloat, force: Bool = false) {
        let clamped = min(max(next, 0), 1)
        guard force || abs(progress - clamped) > 0.005 || clamped == 0 || clamped == 1 else { return }
        progress = clamped
        blackView.alpha = 0.42 * clamped
        blurView.alpha = clamped
        grayOverlay.alpha = 0.58 * clamped
        hairline.alpha = clamped
        titleLabel.alpha = clamped
        applyTitleTransform()
    }

    private func applyTitleTransform() {
        titleLabel.transform = CGAffineTransform(translationX: 0, y: 5 * (1 - progress))
    }
}

private struct ContentDetailBackdrop: View {
    var body: some View {
        Color.black
            .ignoresSafeArea()
    }
}

private struct ContentDetailAmbientBackdrop: UIViewRepresentable {
    var color: UIColor?

    func makeUIView(context: Context) -> ContentDetailAmbientBackdropUIView {
        let view = ContentDetailAmbientBackdropUIView()
        view.update(color: color, animated: false)
        return view
    }

    func updateUIView(_ uiView: ContentDetailAmbientBackdropUIView, context: Context) {
        uiView.update(color: color, animated: true)
    }
}

private final class ContentDetailAmbientBackdropUIView: UIView {
    private let ambientLayer = CAShapeLayer()
    private var baseColor = StreamifyHomeGradientMetrics.fallbackColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ambientLayer.frame = bounds
        applyAmbientPath()
    }

    func update(color: UIColor?, animated: Bool) {
        let nextColor = color ?? StreamifyHomeGradientMetrics.fallbackColor
        let colorChanged = !nextColor.streamifyIsClose(to: baseColor)
        guard colorChanged else { return }

        baseColor = nextColor

        if colorChanged && animated {
            let animation = CABasicAnimation(keyPath: "shadowColor")
            animation.fromValue = ambientLayer.shadowColor
            animation.toValue = nextColor.cgColor
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ambientLayer.add(animation, forKey: "shadowColor")
        }

        applyAmbientPath()
    }

    private func setup() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false

        ambientLayer.fillColor = UIColor.white.withAlphaComponent(0.001).cgColor
        ambientLayer.shadowOffset = .zero
        ambientLayer.shadowOpacity = 0.28
        ambientLayer.shadowRadius = 16
        layer.addSublayer(ambientLayer)
    }

    private func applyAmbientPath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: -1, dy: -1),
            cornerRadius: 17
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambientLayer.path = path.cgPath
        ambientLayer.shadowPath = path.cgPath
        ambientLayer.shadowColor = baseColor.cgColor
        CATransaction.commit()
    }
}
