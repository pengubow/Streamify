import SwiftUI
import UIKit

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var localServer = LocalServer.shared

    // Player state for Continue Watching
    @State private var playerContext: PlayerContext?
    @State private var currentEpisodeIndex: Int = 0
    @State private var selectedDetail: DetailSelection?
    @State private var refreshTrigger: Bool = false
    @State private var watchingProgressData: [WatchingProgress] = []  // Store progress data

    // Force view update counter
    @State private var viewUpdateID: Int = 0

    // Server starting overlay
    @State private var isStartingServer: Bool = false

    // Playback error
    @State private var playError: String?
    @State private var showPlayError: Bool = false

    // Loading state for quality pre-parsing
    @State private var loadingMessage: String?
    @State private var playResolutionTask: Task<Void, Never>? = nil
    @State private var urlCheckSkipper: URLCheckSkipper? = nil

    // Source toggles
    @AppStorage("vidLinkEnabled") private var vidLinkEnabled: Bool = true
    @AppStorage("movies111Enabled") private var movies111Enabled: Bool = true
    @AppStorage("torrentioEnabled") private var torrentioEnabled: Bool = false
    @AppStorage("preferredGenres") private var preferredGenresRaw: String = ""

    // Server health check
    @State private var serverHealthy: Bool = false

    // Search state
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var searchFieldFocused: Bool = false
    @State private var keyboardIsVisibleInHome: Bool = false
    @State private var keyboardOverlapHeightInHome: CGFloat = 0
    @State private var homeKeyboardCounterOffset: CGFloat = 0

    // TMDB state
    @AppStorage("tmdbApiKey") private var tmdbApiKey: String = ""
    @State private var tmdbTrending: [SourceContent] = []
    @State private var tmdbPopularMovies: [SourceContent] = []
    @State private var tmdbPopularTVShows: [SourceContent] = []
    @State private var tmdbPreferredGenreSections: [(genre: Genre, content: [SourceContent])] = []
    @State private var tmdbLoaded: Bool = false
    @State private var tmdbIsLoading: Bool = false
    @State private var tmdbSearchResults: [SourceContent] = []
    @State private var tmdbSearchTask: Task<Void, Never>?
    @State private var featuredBackdropColor: UIColor?

    // Featured card persistence is owned by the ViewModel so it survives view re-creation.

    private var isTMDBConfigured: Bool {
        !tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct DetailSelection: Identifiable {
        let id = UUID()
        let content: SavedContent
        let sourceContent: SourceContent?
    }

    private var preferredGenres: [Genre] {
        StreamifyPreferences.genres(from: preferredGenresRaw)
            .sorted { $0.rawValue < $1.rawValue }
    }

    // Get watching progress from state
    private var watchingProgress: [WatchingProgress] {
        watchingProgressData
    }


    // Get content that has progress - includes content from sources not in library
    private var continueWatchingContent: [(SavedContent?, WatchingProgress, SourceContent?)] {
        var results: [(SavedContent?, WatchingProgress, SourceContent?)] = []
        var seenContentIds: Set<String> = []

        // Sort by lastWatched (most recent first) BEFORE processing
        // This ensures we keep the most recent progress for each content
        let sortedProgress = watchingProgress.sorted { $0.lastWatched > $1.lastWatched }

        for progress in sortedProgress {
            if seenContentIds.contains(progress.contentId) { continue }

            // Skip content that has been fully watched (isWatched flag set)
            if WatchingProgressManager.isContentWatched(contentId: progress.contentId) { continue }

            // First try to find in library
            if let content = viewModel.library.first(where: { $0.id == progress.contentId }) {
                results.append((content, progress, nil))
                seenContentIds.insert(progress.contentId)
            } else {
                // Try to find in merged sources content
                if let sourceContent = viewModel.mergedContent.first(where: { $0.id == progress.contentId }) {
                    // Create a temporary SavedContent for display
                    let tempContent = SavedContent(
                        id: sourceContent.id,
                        metadata: ContentMetadata(
                            id: sourceContent.id,
                            title: sourceContent.title,
                            description: sourceContent.description,
                            type: sourceContent.type,
                            genre: sourceContent.genre,
                            genres: sourceContent.genres,
                            thumbnail: sourceContent.thumbnailUrl,
                            posterThumbnail: sourceContent.posterThumbnailUrl,
                            file: sourceContent.fileUrl,
                            hlsUrl: sourceContent.hlsUrl,
                            intro: nil,
                            introDuration: nil,
                            end: sourceContent.end,
                            seasons: sourceContent.seasons,
                            episodes: sourceContent.episodes,
                            subtitles: sourceContent.subtitles,
                            audioTracks: sourceContent.audioTracks,
                            embeddedAudioDisabled: sourceContent.embeddedAudioDisabled,
                            tmdbId: sourceContent.tmdbId
                        ),
                        folderPath: "",
                        dateAdded: Date()
                    )
                    results.append((tempContent, progress, sourceContent))
                    seenContentIds.insert(progress.contentId)
                }
            }
        }

        // Sort by last watched date (most recent first)
        return results.sorted { $0.1.lastWatched > $1.1.lastWatched }
    }

    // Browse categories
    private let categories = Genre.allCases.sorted { $0.rawValue < $1.rawValue }

        // Get all content from sources (merged by ID)
        private var allContent: [SourceContent] {
            viewModel.mergedContent
        }

    // Search results combining library and source content
    private var searchResults: (library: [SavedContent], source: [SourceContent]) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return ([], []) }
        let libraryResults = viewModel.library.filter {
            $0.metadata.title.localizedCaseInsensitiveContains(trimmed)
        }
        var seenKeys = Set<String>()
        for content in libraryResults {
            seenKeys.formUnion(searchKeys(for: content))
        }
        let sourceResults = allContent.filter { content in
            guard content.title.localizedCaseInsensitiveContains(trimmed) else { return false }
            let keys = searchKeys(for: content)
            guard keys.isDisjoint(with: seenKeys) else { return false }
            seenKeys.formUnion(keys)
            return true
        }
        return (libraryResults, sourceResults)
    }

    private func searchKeys(for content: SavedContent) -> Set<String> {
        var keys: Set<String> = ["id:\(content.id)"]
        if let tmdbId = content.metadata.tmdbId {
            keys.insert("tmdb:\(content.metadata.type.rawValue):\(tmdbId)")
        }
        return keys
    }

    private func searchKeys(for content: SourceContent) -> Set<String> {
        var keys: Set<String> = ["id:\(content.id)"]
        if let tmdbId = content.tmdbId {
            keys.insert("tmdb:\(content.type.rawValue):\(tmdbId)")
        }
        return keys
    }

    // Filter content by genre
    private func categoryContent(for genre: Genre) -> [SourceContent] {
        allContent.filter { content in
            if let genres = content.genres, !genres.isEmpty {
                return genres.contains(genre)
            } else {
                return genre == .other
            }
        }
    }

    private var searchKeyboardCounterTarget: CGFloat {
        guard isSearching, searchFieldFocused, keyboardIsVisibleInHome else { return 0 }
        return topSafeAreaInset + 40
    }

    private func keyboardOverlapHeight(from notification: Notification) -> CGFloat {
        guard let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let windowBounds = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: { $0.isKeyWindow })?
                  .bounds
        else {
            return 0
        }

        return max(0, windowBounds.maxY - keyboardFrame.minY)
    }

    private func updateHomeKeyboardCounterOffset(duration: TimeInterval = 0.18) {
        let target = searchKeyboardCounterTarget
        if target == 0, keyboardIsVisibleInHome, homeKeyboardCounterOffset > 0 {
            return
        }
        withAnimation(.easeOut(duration: duration)) {
            homeKeyboardCounterOffset = target
        }
    }

    private func animateHomeKeyboardCounterOffset(to target: CGFloat, notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            homeKeyboardCounterOffset = target
        }
    }

    var body: some View {
        GeometryReader { _ in
            libraryNavigation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .preferredColorScheme(.dark)
        .streamifyAlert(
            title: "Playback Error",
            message: playError ?? "Unable to play this content. All sources failed.",
            isPresented: $showPlayError,
            primaryAction: { playError = nil }
        )
        .streamifyCenteredPopup(
            isPresented: Binding(
                get: { isStartingServer || loadingMessage != nil },
                set: { presented in
                    if !presented {
                        cancelLibraryLoadingOverlay()
                    }
                }
            ),
            dismissOnBackdrop: false
        ) {
            loadingOverlay
        }
        .onAppear {
            viewModel.loadLibrary()
            viewModel.loadSources()  // Load after library so enrichment runs with both available
            watchingProgressData = WatchingProgressManager.load()
            viewUpdateID += 1
            refreshFeaturedContent()
            loadTMDBDataIfNeeded()
            viewModel.enrichWithTMDB()

            checkServerHealthNow()
        }
        .task {
            // Periodic server health check — runs while the view is visible.
            // CancellationError from Task.sleep is caught to exit the loop without
            // making the closure throwing (SwiftUI .task requires non-throwing).
            while true {
                var isHealthy = await localServer.checkServerHealth()
                if !isHealthy && !localServer.isManuallyStopped {
                    let restarted = await LocalServer.shared.ensureRunningAsync()
                    if restarted {
                        isHealthy = await localServer.checkServerHealth()
                    }
                }
                serverHealthy = isHealthy
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return } // 3 s
            }
        }
        .onChange(of: tmdbApiKey) { _ in
            // Reload TMDB data when API key changes
            tmdbLoaded = false
            tmdbIsLoading = false
            loadTMDBDataIfNeeded()
            viewModel.enrichWithTMDB()
        }
        .onChange(of: preferredGenresRaw) { _ in
            tmdbLoaded = false
            tmdbIsLoading = false
            tmdbPreferredGenreSections = []
            tmdbTrending = []
            loadTMDBDataIfNeeded()
            refreshFeaturedContent()
        }
        .onChange(of: refreshTrigger) { _ in
            watchingProgressData = WatchingProgressManager.load()
            viewUpdateID += 1
            refreshFeaturedContent()
        }
        .onChange(of: viewModel.library.map(\.id).joined(separator: "|")) { _ in
            refreshFeaturedContent()
        }
        .onChange(of: viewModel.featuredContentId) { _ in
            seedFeaturedBackdropColor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchingProgressUpdated)) { _ in
            watchingProgressData = WatchingProgressManager.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardOverlapHeightInHome = keyboardOverlapHeight(from: notification)
            keyboardIsVisibleInHome = keyboardOverlapHeightInHome > 1
            animateHomeKeyboardCounterOffset(to: searchKeyboardCounterTarget, notification: notification)
        }
        .onChange(of: isSearching) { _ in
            updateHomeKeyboardCounterOffset()
        }
        .onChange(of: searchFieldFocused) { _ in
            updateHomeKeyboardCounterOffset()
        }
        .fullScreenCover(item: $playerContext) { context in
            playerView(for: context)
        }
    }

    private var libraryNavigation: some View {
        StreamifyNavigationContainer {
            ZStack(alignment: .top) {
                libraryBackground
                libraryContentArea
                    .offset(y: homeKeyboardCounterOffset)
                searchOverlay
                    .zIndex(10)
                headerView
                    .offset(y: homeKeyboardCounterOffset)
                    .zIndex(20)
            }
            .ignoresSafeArea(.keyboard, edges: .all)
            .ignoresSafeArea(edges: .top)
            .navigationBarHidden(true)
            .background {
                StreamifyUIKitSheetPresenter(item: $selectedDetail) { selection in
                    ContentDetailView(
                        content: selection.content,
                        sourceContent: selection.sourceContent,
                        viewModel: viewModel,
                        onDismissRequest: {
                            selectedDetail = nil
                        }
                    )
                    .streamifyPresentationDragIndicatorHidden()
                }
                .frame(width: 0, height: 0)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .all)
    }

    private var libraryContentArea: some View {
        libraryContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var libraryBackground: some View {
        let color = featuredBackdropColor ?? featuredContent.map(fallbackFeaturedBackdropColor)
        return StreamifyGradientBackground(color: color, followsHomeScroll: true)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if shouldShowEmptyState {
            emptyStateView
        } else {
            homeScrollView
        }
    }

    private var shouldShowEmptyState: Bool {
        viewModel.library.isEmpty && continueWatchingContent.isEmpty && viewModel.sources.isEmpty && !isTMDBConfigured
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.gray)
            Text("No Content")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Add content from Settings tab")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, topSafeAreaInset + 92)
    }

    private var homeScrollView: some View {
        GeometryReader { proxy in
            let cardWidth = homeCardWidth(for: proxy.size.width)

            ScrollView {
                VStack(spacing: 0) {
                    LibraryHomeHeaderCollapseReader()
                        .frame(width: 0, height: 0)

                    EmptyView().id(viewUpdateID)
                    refreshingSourcesView
                    featuredSection
                    continueWatchingSection(cardWidth: cardWidth)
                    myLibrarySection(cardWidth: cardWidth)
                    tmdbSections(cardWidth: cardWidth)
                    genreSections(cardWidth: cardWidth)
                    Spacer(minLength: 86)
                }
                .padding(.top, topSafeAreaInset + 92)
            }
            .streamifyScrollIndicatorsHidden()
        }
    }

    @ViewBuilder
    private var refreshingSourcesView: some View {
        if viewModel.isRefreshingSources {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Updating sources...")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var featuredSection: some View {
        if let featured = featuredContent {
            Button {
                selectedDetail = DetailSelection(
                    content: featured,
                    sourceContent: featuredSourceContent(for: featured)
                )
            } label: {
                FeaturedCardView(
                    content: featured,
                    fallbackThumbnailUrls: viewModel.allThumbnailUrls(for: featured.id).compactMap { URL(string: $0) },
                    onCenterColorChange: { color in
                        featuredBackdropColor = color
                    }
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onAppear {
                seedFeaturedBackdropColor(for: featured)
            }
        }
    }

    @ViewBuilder
    private func continueWatchingSection(cardWidth: CGFloat) -> some View {
        if !continueWatchingContent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Continue Watching")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(continueWatchingContent, id: \.1.id) { item in
                            VerticalContinueWatchingCard(
                                content: item.0,
                                progress: item.1,
                                onPlay: {
                                    if let content = item.0 {
                                        playContinueWatching(content: content, progress: item.1, sourceContent: item.2)
                                    }
                                },
                                onInfo: {
                                    if let content = item.0 {
                                        selectedDetail = DetailSelection(content: content, sourceContent: item.2)
                                    }
                                },
                                fallbackPosterUrls: continueWatchingFallbackPosters(for: item.0),
                                cardWidth: cardWidth
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, viewModel.library.isEmpty ? 8 : 16)
        }
    }

    @ViewBuilder
    private func myLibrarySection(cardWidth: CGFloat) -> some View {
        if !viewModel.library.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("My Library")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.library) { content in
                            Button {
                                selectedDetail = DetailSelection(content: content, sourceContent: nil)
                            } label: {
                                VerticalContentCardView(
                                    content: content,
                                    fallbackPosterUrls: viewModel.allPosterThumbnailUrls(for: content.id).compactMap { URL(string: $0) },
                                    cardWidth: cardWidth
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(width: cardWidth, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func tmdbSections(cardWidth: CGFloat) -> some View {
        if isTMDBConfigured {
            if tmdbIsLoading && tmdbTrending.isEmpty && tmdbPopularMovies.isEmpty && tmdbPopularTVShows.isEmpty && tmdbPreferredGenreSections.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading TMDB...")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            sourceCarouselSection(title: "Trending", contents: tmdbTrending, cardWidth: cardWidth, artworkPreference: .posterFirst) { _ in [] }
            sourceCarouselSection(title: "Popular Movies", contents: tmdbPopularMovies, cardWidth: cardWidth, artworkPreference: .posterFirst) { _ in [] }
            sourceCarouselSection(title: "Popular TV Shows", contents: tmdbPopularTVShows, cardWidth: cardWidth, artworkPreference: .posterFirst) { _ in [] }

            ForEach(Array(tmdbPreferredGenreSections.enumerated()), id: \.offset) { _, section in
                sourceCarouselSection(title: section.genre.rawValue, contents: section.content, cardWidth: cardWidth, artworkPreference: .posterFirst) { _ in [] }
            }
        }
    }

    @ViewBuilder
    private func genreSections(cardWidth: CGFloat) -> some View {
        if !allContent.isEmpty {
            ForEach(categories) { genre in
                genreSection(for: genre, cardWidth: cardWidth)
            }
        }
    }

    @ViewBuilder
    private func genreSection(for genre: Genre, cardWidth: CGFloat) -> some View {
        let content = categoryContent(for: genre)
        sourceCarouselSection(title: genre.rawValue, contents: content, cardWidth: cardWidth) { item in
            viewModel.allThumbnailUrls(for: item.id).compactMap { URL(string: $0) }
        }
    }

    @ViewBuilder
    private func sourceCarouselSection(
        title: String,
        contents: [SourceContent],
        cardWidth: CGFloat,
        artworkPreference: VerticalBrowseSourceCardArtworkPreference = .thumbnailFirst,
        fallbackPosterUrls: @escaping (SourceContent) -> [URL]
    ) -> some View {
        if !contents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(contents) { content in
                            Button {
                                selectedDetail = DetailSelection(
                                    content: makeSavedContent(from: content),
                                    sourceContent: content
                                )
                            } label: {
                                VerticalBrowseSourceCard(
                                    content: content,
                                    fallbackPosterUrls: fallbackPosterUrls(content),
                                    cardWidth: cardWidth,
                                    artworkPreference: artworkPreference
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(width: cardWidth, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 16)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
    }

    private func continueWatchingFallbackPosters(for content: SavedContent?) -> [URL] {
        guard let content else { return [] }
        return viewModel.allPosterThumbnailUrls(for: content.id).compactMap { URL(string: $0) }
    }

    private func makeSavedContent(from content: SourceContent) -> SavedContent {
        SavedContent(
            id: content.id,
            metadata: ContentMetadata(
                id: content.id,
                title: content.title,
                description: content.description,
                type: content.type,
                genre: content.genre,
                genres: content.genres,
                thumbnail: content.thumbnailUrl,
                posterThumbnail: content.posterThumbnailUrl,
                file: content.fileUrl,
                hlsUrl: content.hlsUrl,
                intro: nil,
                introDuration: nil,
                end: content.end,
                seasons: content.seasons,
                episodes: content.episodes,
                subtitles: content.subtitles,
                audioTracks: content.audioTracks,
                embeddedAudioDisabled: content.embeddedAudioDisabled,
                tmdbId: content.tmdbId
            ),
            folderPath: "",
            dateAdded: Date()
        )
    }

    private func playerView(for context: PlayerContext) -> some View {
        VideoPlayerView(
            content: context.content,
            videoURL: context.videoURL,
            episodeInfo: context.episodeInfo,
            onDismiss: {
                guard playerContext != nil else { return }
                playerContext = nil
                refreshAfterPlayerDismiss()
            },
            onRequestNextEpisode: context.hasNext && isInLibrary(content: context.content)
                ? { currentEp, skipper, onCheckingURL, onPreparingPlayback in
                    await getNextEpisodeRequest(
                        currentEpisode: currentEp,
                        skipper: skipper,
                        onCheckingURL: onCheckingURL,
                        onPreparingPlayback: onPreparingPlayback
                    )
                }
                : nil,
            onAddToLibraryAndRequestNext: context.hasNext && !isInLibrary(content: context.content)
                ? { currentEp, skipper, onCheckingURL, onPreparingPlayback in
                    await addLibraryAndGetNextEpisodeRequest(
                        currentEpisode: currentEp,
                        skipper: skipper,
                        onCheckingURL: onCheckingURL,
                        onPreparingPlayback: onPreparingPlayback
                    )
                }
                : nil,
            onGoToBrowse: {
                guard playerContext != nil else { return }
                playerContext = nil
                selectedDetail = nil
            },
            isInLibrary: isInLibrary(content: context.content),
            onlineUrls: onlineUrls(for: context),
            onlineUrlSourceNames: onlineUrlSourceNames(for: context),
            preloadedAudioTracks: context.preloadedAudioTracks,
            streamingSubtitles: context.streamingSubtitles,
            preloadedQualities: context.preloadedQualities
        )
    }

    private func onlineUrls(for context: PlayerContext) -> [String] {
        if let ep = context.episodeInfo {
            return viewModel.allEpisodeHlsUrls(for: context.content.id, season: ep.season, episode: ep.episode)
        }
        return viewModel.allHlsUrls(for: context.content.id)
    }

    private func onlineUrlSourceNames(for context: PlayerContext) -> [String: String] {
        if let ep = context.episodeInfo {
            return viewModel.episodeHlsUrlSourceNames(for: context.content.id, season: ep.season, episode: ep.episode)
        }
        return viewModel.hlsUrlSourceNames(for: context.content.id)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            let parts = (loadingMessage ?? "Loading...").components(separatedBy: "\n")
            Text(parts[0])
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if parts.count > 1 {
                Text(parts[1])
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if loadingMessage != nil {
                HStack(spacing: 12) {
                    if urlCheckSkipper != nil && parts.count > 1 {
                        Button("Skip") {
                            urlCheckSkipper?.skip()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button("Cancel") {
                        cancelLibraryLoadingOverlay()
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

    private func cancelLibraryLoadingOverlay() {
        urlCheckSkipper?.skip()
        playResolutionTask?.cancel()
        playResolutionTask = nil
        urlCheckSkipper = nil
        loadingMessage = nil
    }

    // MARK: - Play from Continue Watching
    private func playContinueWatching(content: SavedContent, progress: WatchingProgress, sourceContent: SourceContent? = nil) {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        if let episodeNum = progress.episodeIndex {
            let episodes = content.metadata.allEpisodes

            if let seasonNum = progress.seasonIndex {
                if let epIndex = episodes.firstIndex(where: { $0.season == seasonNum && $0.episode == episodeNum }) {
                    playEpisode(content: content, at: epIndex, sourceContent: sourceContent)
                    return
                }
            }

            if let epIndex = episodes.firstIndex(where: { $0.episode == episodeNum }) {
                playEpisode(content: content, at: epIndex, sourceContent: sourceContent)
            } else if !episodes.isEmpty {
                playEpisode(content: content, at: 0, sourceContent: sourceContent)
            } else if let seasonNum = progress.seasonIndex,
                      PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent) != nil {
                let fallbackEpisode = EpisodeInfo(season: seasonNum, episode: episodeNum, title: "")
                let fallbackMetadata = content.metadata.copying(episodes: .some([fallbackEpisode]))
                let fallbackContent = SavedContent(
                    id: content.id,
                    metadata: fallbackMetadata,
                    folderPath: content.folderPath,
                    dateAdded: content.dateAdded
                )
                playEpisode(content: fallbackContent, at: 0, sourceContent: sourceContent)
            } else {
                // Episodes not available yet (e.g. TMDB seasons not fetched/persisted).
                // Open the detail view so fetchTMDBSeasonsIfNeeded can run.
                selectedDetail = DetailSelection(content: content, sourceContent: sourceContent)
            }
        } else {
            let skipper = URLCheckSkipper()
            urlCheckSkipper = skipper
            let task = Task { [skipper] in
                await playMovieAsync(content: content, sourceContent: sourceContent, skipper: skipper)
            }
            playResolutionTask = task
        }
    }

    // MARK: - Play movie with server check
    private func playMovieAsync(content: SavedContent, sourceContent: SourceContent? = nil, skipper: URLCheckSkipper) async {
        await MainActor.run { loadingMessage = "Setting up video player..." }

        if !content.folderPath.isEmpty {
            let hasLocalContent = FileManager.default.fileExists(atPath:
                ContentImportService.contentDirectoryURL
                    .appendingPathComponent(content.folderPath)
                    .appendingPathComponent("video.m3u8").path)

            if hasLocalContent && !localServer.isRunning {
                await MainActor.run { isStartingServer = true }
                _ = await LocalServer.shared.ensureRunningAsync()
                await MainActor.run { isStartingServer = false }
            }
        }

        // Check local file first
        if let url = ContentImportService.videoURL(for: content),
           url.isFileURL || url.host == "localhost" {
            await MainActor.run {
                loadingMessage = nil
                urlCheckSkipper = nil
                playResolutionTask = nil
                playerContext = PlayerContext(
                    content: content,
                    videoURL: url,
                    episodeInfo: nil,
                    episodeIndex: nil,
                    totalEpisodes: 0
                )
            }
            return
        }

        let directUrls = PlaybackResolver.collectMovieUrls(
            content: content, sourceContent: sourceContent, viewModel: viewModel)
        let sourceNames = viewModel.hlsUrlSourceNames(for: content.id)
        let tmdbId = PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent)

        guard let result = await PlaybackResolver.resolveMovie(
            directUrls: directUrls,
            sourceNamesMap: sourceNames,
            tmdbId: tmdbId,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            onCheckingURL: { [weak skipper] candidate in
                guard self.loadingMessage != nil else { return }
                let display = candidate.count > 60
                    ? "..." + candidate.suffix(57) : candidate
                self.loadingMessage = "Setting up video player...\n\(display)"
                if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
            },
            onPreparingPlayback: {
                guard self.loadingMessage != nil else { return }
                self.urlCheckSkipper = nil
                self.loadingMessage = "Setting up video player..."
            },
            skipper: skipper
        ) else {
            await MainActor.run {
                loadingMessage = nil
                urlCheckSkipper = nil
                playResolutionTask = nil
                if !skipper.wasSkipped {
                    playError = "Unable to play \(content.metadata.title). All sources failed."
                    showPlayError = true
                }
            }
            return
        }

        await MainActor.run {
            loadingMessage = nil
            urlCheckSkipper = nil
            playResolutionTask = nil
            playerContext = PlayerContext(
                content: content,
                videoURL: result.url,
                episodeInfo: nil,
                episodeIndex: nil,
                totalEpisodes: 0,

                preloadedAudioTracks: result.preloadedAudioTracks,
                streamingSubtitles: result.mergedSubtitles,
                preloadedQualities: result.preloadedQualities
            )
        }
    }

    // MARK: - Play episode
    private func playEpisode(content: SavedContent, at index: Int, sourceContent: SourceContent? = nil) {
        guard playResolutionTask == nil, loadingMessage == nil else { return }
        let episodes = content.metadata.allEpisodes
        guard index < episodes.count else { return }

        let episode = episodes[index]
        currentEpisodeIndex = index

        let skipper = URLCheckSkipper()
        urlCheckSkipper = skipper
        let task = Task { [skipper] in
            await MainActor.run { loadingMessage = "Setting up video player..." }

            // Check local file first
            if let localURL = ContentImportService.videoURL(for: content, episode: episode),
               localURL.isFileURL || localURL.host == "localhost" {
                await MainActor.run {
                    loadingMessage = nil
                    urlCheckSkipper = nil
                    playResolutionTask = nil
                    playerContext = PlayerContext(
                        content: content,
                        videoURL: localURL,
                        episodeInfo: episode,
                        episodeIndex: index,
                        totalEpisodes: episodes.count
                    )
                }
                return
            }

            let directUrls = PlaybackResolver.collectEpisodeUrls(
                content: content, episode: episode, sourceContent: sourceContent, viewModel: viewModel)
            let sourceNames = viewModel.episodeHlsUrlSourceNames(
                for: content.id, season: episode.season, episode: episode.episode)
            let tmdbId = PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent)

            guard let result = await PlaybackResolver.resolveEpisode(
                directUrls: directUrls,
                sourceNamesMap: sourceNames,
                tmdbId: tmdbId,
                season: episode.season,
                episode: episode.episode,
                vidLinkEnabled: vidLinkEnabled,
                movies111Enabled: movies111Enabled,
                torrentioEnabled: torrentioEnabled,
                onCheckingURL: { [weak skipper] candidate in
                    guard self.loadingMessage != nil else { return }
                    let display = candidate.count > 60
                        ? "..." + candidate.suffix(57) : candidate
                    self.loadingMessage = "Setting up video player...\n\(display)"
                    if self.urlCheckSkipper == nil { self.urlCheckSkipper = skipper }
                },
                onPreparingPlayback: {
                    guard self.loadingMessage != nil else { return }
                    self.urlCheckSkipper = nil
                    self.loadingMessage = "Setting up video player..."
                },
                skipper: skipper
            ) else {
                await MainActor.run {
                    loadingMessage = nil
                    urlCheckSkipper = nil
                    playResolutionTask = nil
                    if !skipper.wasSkipped {
                        playError = "Unable to play S\(episode.season) E\(episode.episode). All sources failed."
                        showPlayError = true
                    }
                }
                return
            }

            await MainActor.run {
                loadingMessage = nil
                urlCheckSkipper = nil
                playResolutionTask = nil
                playerContext = PlayerContext(
                    content: content,
                    videoURL: result.url,
                    episodeInfo: episode,
                    episodeIndex: index,
                    totalEpisodes: episodes.count,

                    preloadedAudioTracks: result.preloadedAudioTracks,
                    streamingSubtitles: result.mergedSubtitles,
                    preloadedQualities: result.preloadedQualities
                )
            }
        }
        playResolutionTask = task
    }

    // MARK: - Get next episode request for VideoPlayerView
    private func getNextEpisodeRequest(
        currentEpisode: EpisodeInfo,
        skipper: URLCheckSkipper? = nil,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil
    ) async -> EpisodeChangeRequest? {
        guard let ctx = playerContext else { return nil }
        let content = ctx.content
        let episodes = content.metadata.allEpisodes

        let currentEp = currentEpisode
        guard let currentIndex = episodes.firstIndex(where: { $0.season == currentEp.season && $0.episode == currentEp.episode }) else { return nil }

        let nextIndex = currentIndex + 1
        guard nextIndex < episodes.count else { return nil }

        let nextEpisode = episodes[nextIndex]

        // Check local file first
        if let localURL = ContentImportService.videoURL(for: content, episode: nextEpisode),
           localURL.isFileURL || localURL.host == "localhost" {
            return EpisodeChangeRequest(episode: nextEpisode, videoURL: localURL)
        }

        let directUrls = PlaybackResolver.collectEpisodeUrls(
            content: content, episode: nextEpisode, sourceContent: nil, viewModel: viewModel)
        let sourceNames = viewModel.episodeHlsUrlSourceNames(
            for: content.id, season: nextEpisode.season, episode: nextEpisode.episode)
        let tmdbId = PlaybackResolver.resolveTmdbId(for: content)

        guard let result = await PlaybackResolver.resolveEpisode(
            directUrls: directUrls,
            sourceNamesMap: sourceNames,
            tmdbId: tmdbId,
            season: nextEpisode.season,
            episode: nextEpisode.episode,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        ) else { return nil }

        return EpisodeChangeRequest(
            episode: nextEpisode,
            videoURL: result.url,
            preloadedAudioTracks: result.preloadedAudioTracks,
            streamingSubtitles: result.mergedSubtitles,
            preloadedQualities: result.preloadedQualities
        )
    }

    // MARK: - Add to library and get next episode request
    private func addLibraryAndGetNextEpisodeRequest(
        currentEpisode: EpisodeInfo,
        skipper: URLCheckSkipper? = nil,
        onCheckingURL: (@MainActor @Sendable (String) -> Void)? = nil,
        onPreparingPlayback: (@MainActor @Sendable () -> Void)? = nil
    ) async -> EpisodeChangeRequest? {
        guard let ctx = playerContext else { return nil }
        let content = ctx.content
        let episodes = content.metadata.allEpisodes

        let currentEp = currentEpisode
        guard let currentIndex = episodes.firstIndex(where: { $0.season == currentEp.season && $0.episode == currentEp.episode }) else { return nil }

        let nextIndex = currentIndex + 1
        guard nextIndex < episodes.count else { return nil }

        let nextEpisode = episodes[nextIndex]

        let sourceContent = viewModel.mergedContent.first(where: { $0.id == content.id })

        let directUrls = PlaybackResolver.collectEpisodeUrls(
            content: content, episode: nextEpisode, sourceContent: sourceContent, viewModel: viewModel)
        let sourceNames = viewModel.episodeHlsUrlSourceNames(
            for: content.id, season: nextEpisode.season, episode: nextEpisode.episode)
        let tmdbId = PlaybackResolver.resolveTmdbId(for: content, sourceContent: sourceContent)

        guard let result = await PlaybackResolver.resolveEpisode(
            directUrls: directUrls,
            sourceNamesMap: sourceNames,
            tmdbId: tmdbId,
            season: nextEpisode.season,
            episode: nextEpisode.episode,
            vidLinkEnabled: vidLinkEnabled,
            movies111Enabled: movies111Enabled,
            torrentioEnabled: torrentioEnabled,
            onCheckingURL: onCheckingURL,
            onPreparingPlayback: onPreparingPlayback,
            skipper: skipper
        ) else { return nil }

        if let sourceContent = sourceContent {
            await viewModel.addToLibrary(from: sourceContent)
            await MainActor.run {
                viewModel.loadLibrary()
            }
        }

        return EpisodeChangeRequest(
            episode: nextEpisode,
            videoURL: result.url,
            preloadedAudioTracks: result.preloadedAudioTracks,
            streamingSubtitles: result.mergedSubtitles,
            preloadedQualities: result.preloadedQualities
        )
    }

    // MARK: - Refresh after player dismiss
    private func refreshAfterPlayerDismiss() {
        watchingProgressData = WatchingProgressManager.load()
        refreshTrigger.toggle()
        viewUpdateID += 1
    }

    // MARK: - Check server health
    private func checkServerHealthNow() {
        Task {
            var isHealthy = await localServer.checkServerHealth()
            if !isHealthy && !localServer.isManuallyStopped {
                // Auto-restart the server if health check fails
                let restarted = await LocalServer.shared.ensureRunningAsync()
                if restarted {
                    isHealthy = await localServer.checkServerHealth()
                }
            }
            await MainActor.run {
                serverHealthy = isHealthy
            }
        }
    }

    // MARK: - Check if content is in library
    private func isInLibrary(content: SavedContent) -> Bool {
        return viewModel.library.contains { $0.id == content.id }
    }

    // MARK: - Resolve TMDB ID for VidLink
    private func resolveTmdbId(for content: SavedContent) -> Int? {
        PlaybackResolver.resolveTmdbId(for: content)
    }

    // MARK: - Featured content
    private var isWaitingForTMDBFeatured: Bool {
        isTMDBConfigured && tmdbTrending.isEmpty && (tmdbIsLoading || !tmdbLoaded)
    }

    private var featuredContent: SavedContent? {
        guard !isWaitingForTMDBFeatured else { return nil }
        guard let storedId = viewModel.featuredContentId else { return nil }
        if let sourceContent = featuredTMDBSourceContent(id: storedId) {
            return makeSavedContent(from: sourceContent)
        }
        if let found = viewModel.library.first(where: { $0.id == storedId }) {
            return found
        }
        return nil
    }

    private func featuredSourceContent(for content: SavedContent) -> SourceContent? {
        if viewModel.library.contains(where: { $0.id == content.id }) {
            return nil
        }
        return featuredTMDBSourceContent(id: content.id)
    }

    private func featuredTMDBSourceContent(id: String) -> SourceContent? {
        (preferredGenreFeaturedCandidates + tmdbTrending + tmdbPopularMovies + tmdbPopularTVShows).first { $0.id == id }
    }

    private func refreshFeaturedContent() {
        if isWaitingForTMDBFeatured {
            if let storedId = viewModel.featuredContentId,
               viewModel.library.contains(where: { $0.id == storedId }) {
                viewModel.featuredContentId = nil
            }
            return
        }

        if !tmdbTrending.isEmpty {
            if let storedId = viewModel.featuredContentId,
               tmdbTrending.contains(where: { $0.id == storedId }) {
                return
            }

            let shouldUseLibrary = !viewModel.library.isEmpty && Int.random(in: 0..<10) == 0
            viewModel.featuredContentId = shouldUseLibrary
                ? viewModel.library.randomElement()?.id
                : tmdbTrending.randomElement()?.id
            return
        }

        if featuredContent != nil {
            return
        }

        viewModel.featuredContentId = viewModel.library.randomElement()?.id
    }

    private var preferredGenreFeaturedCandidates: [SourceContent] {
        var seen: Set<String> = []
        return tmdbPreferredGenreSections
            .flatMap(\.content)
            .filter { content in
                guard !seen.contains(content.id) else { return false }
                seen.insert(content.id)
                return true
            }
    }

    private func seedFeaturedBackdropColor() {
        guard let content = featuredContent else {
            featuredBackdropColor = nil
            return
        }
        seedFeaturedBackdropColor(for: content)
    }

    private func seedFeaturedBackdropColor(for content: SavedContent) {
        let fallback = fallbackFeaturedBackdropColor(for: content)
        featuredBackdropColor = fallback
    }

    private func fallbackFeaturedBackdropColor(for _: SavedContent) -> UIColor {
        UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    }

    // MARK: - TMDB Data Loading

    private func loadTMDBDataIfNeeded() {
        guard isTMDBConfigured, !tmdbLoaded else { return }
        let selectedPreferredGenres = preferredGenres
        tmdbLoaded = true
        tmdbIsLoading = true
        Task {
            // Fetch genres, popular movies and TV shows in parallel
            async let movieGenres = TMDBService.fetchMovieGenres()
            async let tvGenres = TMDBService.fetchTVGenres()
            async let trending = TMDBService.fetchTrendingWeek()
            async let popularMovies = TMDBService.fetchPopularMovies()
            async let popularTVShows = TMDBService.fetchPopularTVShows()

            let mg = await movieGenres
            let tg = await tvGenres
            let tr = await trending
            let pm = await popularMovies
            let ptv = await popularTVShows

            // Convert to SourceContent
            let trendingContent = tr.map { TMDBService.toSourceContent($0, movieGenres: mg, tvGenres: tg) }
            let movieContent = pm.map { TMDBService.toSourceContent($0, movieGenres: mg) }
            let tvContent = ptv.map { TMDBService.toSourceContent($0, tvGenres: tg) }

            await MainActor.run {
                tmdbTrending = uniqueSourceContents(trendingContent)
                tmdbPopularMovies = movieContent
                tmdbPopularTVShows = tvContent
            }

            var preferredSections: [(genre: Genre, content: [SourceContent])] = []
            for genre in selectedPreferredGenres {
                var contents: [SourceContent] = []
                if let movieGenreId = tmdbMovieGenreId(for: genre, in: mg) {
                    let movies = await TMDBService.fetchMoviesByGenre(genreId: movieGenreId)
                    contents.append(contentsOf: movies.map { TMDBService.toSourceContent($0, movieGenres: mg) })
                }
                if let tvGenreId = tmdbTVGenreId(for: genre, in: tg) {
                    let shows = await TMDBService.fetchTVShowsByGenre(genreId: tvGenreId)
                    contents.append(contentsOf: shows.map { TMDBService.toSourceContent($0, tvGenres: tg) })
                }
                let uniqueContents = uniqueSourceContents(contents)
                if !uniqueContents.isEmpty {
                    preferredSections.append((genre: genre, content: uniqueContents))
                }
            }

            await MainActor.run {
                tmdbPreferredGenreSections = preferredSections
                tmdbIsLoading = false
                refreshFeaturedContent()
            }
        }
    }

    private func uniqueSourceContents(_ contents: [SourceContent]) -> [SourceContent] {
        var seen: Set<String> = []
        return contents.filter { content in
            guard !seen.contains(content.id) else { return false }
            seen.insert(content.id)
            return true
        }
    }

    private func tmdbMovieGenreId(for genre: Genre, in tmdbGenres: [TMDBService.TMDBGenre]) -> Int? {
        tmdbGenreId(for: genre, in: tmdbGenres, names: tmdbMovieGenreNames(for: genre))
    }

    private func tmdbTVGenreId(for genre: Genre, in tmdbGenres: [TMDBService.TMDBGenre]) -> Int? {
        tmdbGenreId(for: genre, in: tmdbGenres, names: tmdbTVGenreNames(for: genre))
    }

    private func tmdbGenreId(for _: Genre, in tmdbGenres: [TMDBService.TMDBGenre], names: [String]) -> Int? {
        for name in names {
            if let match = tmdbGenres.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return match.id
            }
        }
        return nil
    }

    private func tmdbMovieGenreNames(for genre: Genre) -> [String] {
        switch genre {
        case .action: return ["Action"]
        case .comedy: return ["Comedy"]
        case .drama: return ["Drama"]
        case .sciFi: return ["Science Fiction"]
        case .horror: return ["Horror"]
        case .thriller: return ["Thriller"]
        case .romance: return ["Romance"]
        case .animation: return ["Animation"]
        case .documentary: return ["Documentary"]
        case .other: return []
        }
    }

    private func tmdbTVGenreNames(for genre: Genre) -> [String] {
        switch genre {
        case .action: return ["Action & Adventure"]
        case .comedy: return ["Comedy"]
        case .drama: return ["Drama"]
        case .sciFi: return ["Sci-Fi & Fantasy"]
        case .horror: return []
        case .thriller: return ["Mystery", "Crime"]
        case .romance: return ["Drama"]
        case .animation: return ["Animation"]
        case .documentary: return ["Documentary"]
        case .other: return []
        }
    }

    private func searchTMDB(query: String) {
        tmdbSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, isTMDBConfigured else {
            tmdbSearchResults = []
            return
        }
        tmdbSearchTask = Task {
            // Debounce
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            let results = await TMDBService.search(query: trimmed)
            guard !Task.isCancelled else { return }
            // Convert to SourceContent
            let content = results.map { TMDBService.toSourceContent($0) }
            await MainActor.run {
                viewModel.cacheTMDBSearchResults(content)
                tmdbSearchResults = content
            }
        }
    }

    // MARK: - Custom Header
    private var headerView: some View {
        let topInset = topSafeAreaInset

        return StreamifyHomeHeaderView(
            searchText: $searchText,
            isSearching: $isSearching,
            isFieldFocused: $searchFieldFocused,
            topInset: topInset,
            backdropColor: featuredBackdropColor ?? featuredContent.map(fallbackFeaturedBackdropColor),
            verticalOffset: homeKeyboardCounterOffset
        )
        .frame(height: topInset + 92, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var searchOverlay: some View {
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            ZStack(alignment: .top) {
                if hasQuery {
                    searchResultsView
                        .padding(.top, topSafeAreaInset + 92 + homeKeyboardCounterOffset)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background {
                    let color = featuredBackdropColor ?? featuredContent.map(fallbackFeaturedBackdropColor)
                    StreamifyGradientBackground(
                        color: color,
                        followsHomeScroll: true,
                        usesHeaderMaterial: true
                    )
                }
                .ignoresSafeArea()
        }
    }

    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    private var searchResultsBottomInset: CGFloat {
        if keyboardIsVisibleInHome {
            return max(220, keyboardOverlapHeightInHome + 120)
        }
        return StreamifySafeArea.bottomChromeInset(bottomSafeAreaInset) + 128
    }

    private func homeCardWidth(for width: CGFloat) -> CGFloat {
        searchGridMetrics(for: width).cardWidth
    }

    private struct SearchGridMetrics {
        let columns: [GridItem]
        let cardWidth: CGFloat
    }

    private func searchGridMetrics(for width: CGFloat) -> SearchGridMetrics {
        let spacing: CGFloat = width > 700 ? 18 : 12
        let availableWidth = max(0, width - 32)
        let targetCardWidth: CGFloat = width > 700 ? 124 : 112
        let minimumColumns = availableWidth < 330 ? 2 : 3
        let maximumColumns = width > 1200 ? 9 : (width > 900 ? 7 : (width > 700 ? 5 : 3))
        let rawCount = Int((availableWidth + spacing) / (targetCardWidth + spacing))
        let count = max(minimumColumns, min(maximumColumns, rawCount))
        let cardWidth = floor((availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count))

        return SearchGridMetrics(
            columns: Array(
                repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .leading),
                count: count
            ),
            cardWidth: cardWidth
        )
    }

    // MARK: - Search Results View
    private var searchResultsView: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = searchResults
        let visibleTMDBResults = filteredTMDBSearchResults(excluding: results)
        let hasResults = !results.library.isEmpty || !results.source.isEmpty || !visibleTMDBResults.isEmpty

        return GeometryReader { proxy in
            let metrics = searchGridMetrics(for: proxy.size.width)
            ScrollView {
                Group {
                    if trimmed.count < 2 {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)
                            Text("Search movies & series")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Type at least two characters")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 132)
                    } else if hasResults {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Results for \"\(searchText)\"")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .padding(.horizontal, 16)

                            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 16) {
                                ForEach(results.library) { content in
                                    Button {
                                        openSearchResult(content: content, sourceContent: nil)
                                    } label: {
                                        VerticalContentCardView(
                                            content: content,
                                            fallbackPosterUrls: viewModel.allPosterThumbnailUrls(for: content.id).compactMap { URL(string: $0) },
                                            cardWidth: metrics.cardWidth
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: metrics.cardWidth, alignment: .leading)
                                    .contentShape(Rectangle())
                                }

                                ForEach(results.source) { content in
                                    Button {
                                        openSearchResult(content: makeSavedContent(from: content), sourceContent: content)
                                    } label: {
                                        VerticalBrowseSourceCard(
                                            content: content,
                                            fallbackPosterUrls: viewModel.allThumbnailUrls(for: content.id).compactMap { URL(string: $0) },
                                            cardWidth: metrics.cardWidth
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: metrics.cardWidth, alignment: .leading)
                                    .contentShape(Rectangle())
                                }

                                ForEach(visibleTMDBResults) { content in
                                    Button {
                                        openSearchResult(content: makeSavedContent(from: content), sourceContent: content)
                                    } label: {
                                        VerticalBrowseSourceCard(
                                            content: content,
                                            fallbackPosterUrls: [],
                                            cardWidth: metrics.cardWidth,
                                            artworkPreference: .posterFirst
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: metrics.cardWidth, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 8)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)
                            Text("No results for \"\(searchText)\"")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Try a different search term")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 132)
                    }
                }
                .padding(.bottom, searchResultsBottomInset)
            }
        }
        .onChange(of: searchText) { newValue in
            searchTMDB(query: newValue)
        }
    }

    private func filteredTMDBSearchResults(
        excluding results: (library: [SavedContent], source: [SourceContent])
    ) -> [SourceContent] {
        var seenKeys = Set<String>()
        for content in results.library {
            seenKeys.formUnion(searchKeys(for: content))
        }
        for content in results.source {
            seenKeys.formUnion(searchKeys(for: content))
        }

        var filtered: [SourceContent] = []
        for content in tmdbSearchResults {
            let keys = searchKeys(for: content)
            guard keys.isDisjoint(with: seenKeys) else { continue }
            seenKeys.formUnion(keys)
            filtered.append(content)
        }
        return filtered
    }

    private func openSearchResult(content: SavedContent, sourceContent: SourceContent?) {
        dismissSearchKeyboard()
        if let sourceContent, let libraryContent = existingLibraryContent(for: sourceContent) {
            selectedDetail = DetailSelection(content: libraryContent, sourceContent: nil)
        } else {
            selectedDetail = DetailSelection(content: content, sourceContent: sourceContent)
        }
    }

    private func existingLibraryContent(for sourceContent: SourceContent) -> SavedContent? {
        viewModel.library.first { content in
            if content.id == sourceContent.id {
                return true
            }
            guard let tmdbId = sourceContent.tmdbId else {
                return false
            }
            return content.metadata.tmdbId == tmdbId && content.metadata.type == sourceContent.type
        }
    }

    private func dismissSearchKeyboard() {
        searchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

}

// MARK: - Vertical Continue Watching card (Netflix-style)
struct VerticalContinueWatchingCard: View {
    let content: SavedContent?
    let progress: WatchingProgress
    let onPlay: () -> Void
    let onInfo: () -> Void
    var fallbackPosterUrls: [URL] = []
    var cardWidth: CGFloat = 120

    private var episodeText: String {
        guard let content = content else { return "" }
        if let episodeIndex = progress.episodeIndex {
            // Find the episode - match BOTH season AND episode
            let allEpisodes = content.metadata.allEpisodes
            if let seasonIndex = progress.seasonIndex {
                // Match both season and episode
                if let ep = allEpisodes.first(where: { $0.season == seasonIndex && $0.episode == episodeIndex }) {
                    return ep.title.isEmpty ? "S\(ep.season) E\(ep.episode)" : "S\(ep.season) E\(ep.episode): \(ep.title)"
                }
            }
            // Fallback: match by episode only (for legacy data without seasonIndex)
            if let ep = allEpisodes.first(where: { $0.episode == episodeIndex }) {
                return ep.title.isEmpty ? "S\(ep.season) E\(ep.episode)" : "S\(ep.season) E\(ep.episode): \(ep.title)"
            }
            return "Episode \(episodeIndex)"
        }
        // For movies, show "Movie"
        return "Movie"
    }

    private var contentType: ContentType {
        content?.metadata.type ?? .movie
    }

    private var contentTitle: String {
        content?.metadata.title ?? "Unknown"
    }

    var body: some View {
        let posterURL: URL? = content.flatMap { ContentImportService.posterThumbnailURL(for: $0) }
        let thumbURL: URL? = content.flatMap { ContentImportService.thumbnailURLWithFallback(for: $0) }
        let fallbackUrls = fallbackPosterUrls + [thumbURL].compactMap { $0 }
        let allUrls = StreamifyURLList.combining(primary: posterURL, fallbacks: fallbackUrls)
        let posterHeight = cardWidth * 1.4

        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if !allUrls.isEmpty {
                        FallbackAsyncImage(urls: allUrls) {
                            Color(.systemGray5)
                                .overlay {
                                    Image(systemName: contentType == .movie ? "film" : "tv")
                                        .font(.title)
                                        .foregroundStyle(.gray)
                                }
                        }
                    } else {
                        Color(.systemGray5)
                            .overlay {
                                Image(systemName: contentType == .movie ? "film" : "tv")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                            }
                    }
                }
                .frame(width: cardWidth, height: posterHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Progress bar at bottom with animation
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 3)
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: geo.size.width * CGFloat(progress.progressPercent), height: 3)
                                .animation(.easeInOut(duration: 0.3), value: progress.progressPercent)
                        }
                    }
                    .frame(height: 3)
                }
                .frame(width: cardWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Info button - gray box with i icon, positioned inside thumbnail
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onInfo()
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.gray.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(6)
                    }
                    Spacer()
                }
            }
            .onTapGesture {
                onPlay()
            }

            // Title and episode info
            VStack(alignment: .leading, spacing: 2) {
                Text(contentTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(episodeText)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: cardWidth, alignment: .leading)
            .padding(.top, 6)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
    }
}

private struct LibraryHomeHeaderCollapseReader: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var lastPublishedCollapse: CGFloat = 0
        private var lastPublishedOffset: CGFloat = 0

        func attach(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let scrollView = view.streamifyEnclosingScrollView() else { return }
                guard scrollView !== self.scrollView else {
                    self.publish(scrollView)
                    return
                }

                self.scrollView = scrollView
                self.lastPublishedCollapse = 0
                self.lastPublishedOffset = 0
                self.contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] observedScrollView, _ in
                    self?.publish(observedScrollView)
                }
                self.publish(scrollView)
            }
        }

        private func publish(_ scrollView: UIScrollView) {
            let nextOffset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            let nextCollapse = nextOffset <= 1 ? 0 : min(1, nextOffset / 132)
            let clamped = min(max(nextCollapse, 0), 1)
            let reachedEdge = (clamped == 0 || clamped == 1) && lastPublishedCollapse != clamped
            let collapseChanged = abs(lastPublishedCollapse - clamped) > 0.012 || reachedEdge
            let offsetChanged = abs(lastPublishedOffset - nextOffset) > 4 || nextOffset == 0
            guard collapseChanged || offsetChanged else { return }
            lastPublishedCollapse = clamped
            lastPublishedOffset = nextOffset
            if Thread.isMainThread {
                StreamifyHomeScrollBus.post(collapse: clamped, scrollOffset: nextOffset)
            } else {
                DispatchQueue.main.async {
                    StreamifyHomeScrollBus.post(collapse: clamped, scrollOffset: nextOffset)
                }
            }
        }
    }
}

// MARK: - Featured card (large, first item)
struct FeaturedCardView: View {
    let content: SavedContent
    var fallbackThumbnailUrls: [URL] = []
    var seasonNumber: Int? = nil  // If set, use season-specific thumbnail
    var onCenterColorChange: (UIColor) -> Void = { _ in }

    var body: some View {
        // Use season-specific thumbnail if available, otherwise fall back to content thumbnail
        let seasonThumbURL: URL? = {
            if let season = seasonNumber {
                return ContentImportService.seasonThumbnailURL(for: content, season: season)
            }
            return nil
        }()
        let thumbURL = seasonThumbURL ?? ContentImportService.thumbnailURLWithFallback(for: content)

        let allUrls = StreamifyURLList.combining(primary: thumbURL, fallbacks: fallbackThumbnailUrls)

        ZStack(alignment: .bottomLeading) {
            // Thumbnail or placeholder
            if !allUrls.isEmpty {
                Color(.darkGray)
                    .aspectRatio(665.0/374.0, contentMode: .fit)
                    .overlay {
                        FallbackAsyncImage(
                            urls: allUrls,
                            onImageLoaded: { image in
                                if let gradientColor = image.streamifyFeaturedGradientColor() {
                                    onCenterColorChange(gradientColor)
                                }
                            }
                        ) {
                            Color(.darkGray)
                                .overlay {
                                    Image(systemName: content.metadata.type == .movie ? "film" : "tv")
                                        .font(.system(size: 44))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.6), Color.purple.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(665.0/374.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: content.metadata.type == .movie ? "film" : "tv")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.4))
                            .allowsHitTesting(false)
                    }
            }

            // Gradient overlay for text readability
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center, endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Title, tags, and type
            VStack(alignment: .leading, spacing: 6) {
                Text(content.metadata.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let genres = content.metadata.genres, !genres.isEmpty {
                        ForEach(Array(genres.sorted { $0.rawValue < $1.rawValue }.prefix(3))) { genre in
                            Text(genre.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.82))
                                .streamifyTracking(1)
                        }
                    } else {
                        Text(Genre.other.rawValue.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.82))
                            .streamifyTracking(1)
                    }
                }

                Text(content.metadata.type == .movie ? "MOVIE" : "SERIES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .streamifyTracking(1)
            }
            .padding(16)
        }
    }
}

// MARK: - Vertical content card (grid item) - Netflix-style
struct VerticalContentCardView: View {
    let content: SavedContent
    var fallbackPosterUrls: [URL] = []
    var cardWidth: CGFloat = 120

    var body: some View {
        let posterURL = ContentImportService.posterThumbnailURL(for: content)
        let thumbURL = ContentImportService.thumbnailURLWithFallback(for: content)
        let fallbackUrls = fallbackPosterUrls + [thumbURL].compactMap { $0 }
        let allUrls = StreamifyURLList.combining(
            primary: posterURL,
            fallbacks: fallbackUrls
        )
        let posterHeight = cardWidth * 1.4

        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail with fallback
            Group {
                if !allUrls.isEmpty {
                    FallbackAsyncImage(urls: allUrls) {
                        Color(.systemGray5)
                            .overlay {
                                Image(systemName: content.metadata.type == .movie ? "film" : "tv")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                            }
                    }
                } else {
                    Color(.systemGray5)
                        .overlay {
                            Image(systemName: content.metadata.type == .movie ? "film" : "tv")
                                .font(.title)
                                .foregroundStyle(.gray)
                        }
                }
            }
            .frame(width: cardWidth, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text(content.metadata.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)

                Text(content.metadata.type == .movie ? "Movie" : "Series")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(.top, 6)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
    }
}
