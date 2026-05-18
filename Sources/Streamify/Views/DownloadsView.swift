import SwiftUI

// MARK: - Shared thumbnail resolution for download views
private func resolveDownloadThumbnailURL(contentId: String, metadata: ContentMetadata?, episodeIndex: Int? = nil, seasonIndex: Int? = nil) -> URL? {
    let safeId = contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentId
    let contentDir = ContentImportService.contentDirectoryURL
    let decodedContentId = contentId.removingPercentEncoding ?? contentId

    // Lazy-load sources only once if needed
    var cachedSources: [SourceContent]?
    func getSources() -> [SourceContent] {
        if let cached = cachedSources { return cached }
        let sources = SourcesManager.allContent()
        cachedSources = sources
        return sources
    }

    // For episodes, check episode-specific thumbnail first
    if let episodeIndex = episodeIndex {
        let season = seasonIndex ?? 1
        let episodeFolder = DownloadManager.episodeFolderPath(contentId: contentId, season: season, episode: episodeIndex)

        // Check for local episode thumbnail file
        let localEpDir = contentDir.appendingPathComponent(episodeFolder)
        for ext in ["jpg", "png", "webp", "jpeg"] {
            let thumbPath = localEpDir.appendingPathComponent("episode_thumbnail.\(ext)")
            if FileManager.default.fileExists(atPath: thumbPath.path) {
                return thumbPath
            }
        }

        // Check episode-specific thumbnail URL from metadata
        if let episodes = metadata?.allEpisodes,
           let ep = episodes.first(where: { $0.season == season && $0.episode == episodeIndex }),
           let thumbUrl = ep.thumbnailUrl, !thumbUrl.isEmpty {
            if thumbUrl.hasPrefix("http"), let url = URL(string: thumbUrl) {
                return url
            }
            // Local episode thumbnail: check episode subfolder first, then content root
            let localEpURL = localEpDir.appendingPathComponent(thumbUrl)
            if FileManager.default.fileExists(atPath: localEpURL.path) {
                return localEpURL
            }
            let localURL = contentDir.appendingPathComponent(safeId).appendingPathComponent(thumbUrl)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }

        // Check sources for episode thumbnail
        if let src = getSources().first(where: { $0.id == contentId || $0.id == decodedContentId }) {
            if let ep = src.allEpisodes.first(where: { $0.season == season && $0.episode == episodeIndex }),
               let thumbUrl = ep.thumbnailUrl, thumbUrl.hasPrefix("http"), let url = URL(string: thumbUrl) {
                return url
            }
        }
    }

    // Try local thumbnail file from metadata
    if let thumb = metadata?.thumbnail, !thumb.hasPrefix("http") {
        let localURL = contentDir.appendingPathComponent(safeId).appendingPathComponent(thumb)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
    }
    if let poster = metadata?.posterThumbnail, !poster.hasPrefix("http") {
        let localURL = contentDir.appendingPathComponent(safeId).appendingPathComponent(poster)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
    }
    // Check for locally downloaded thumbnail files (downloadThumbnail saves as "thumbnail.{ext}")
    // This handles the case where metadata has remote URLs but the thumbnail was already downloaded
    let contentFolder = contentDir.appendingPathComponent(safeId)
    for ext in ["jpg", "png", "webp", "jpeg"] {
        let thumbPath = contentFolder.appendingPathComponent("thumbnail.\(ext)")
        if FileManager.default.fileExists(atPath: thumbPath.path) {
            return thumbPath
        }
    }
    // Try remote thumbnail URLs from metadata (poster first for better quality)
    if let poster = metadata?.posterThumbnail, poster.hasPrefix("http"), let url = URL(string: poster) {
        return url
    }
    if let thumb = metadata?.thumbnail, thumb.hasPrefix("http"), let url = URL(string: thumb) {
        return url
    }
    // Fallback: check sources for thumbnail
    if let src = getSources().first(where: { $0.id == contentId || $0.id == decodedContentId }) {
        if let posterUrl = src.posterThumbnailUrl, let url = URL(string: posterUrl) {
            return url
        }
        if let thumbUrl = src.thumbnailUrl, let url = URL(string: thumbUrl) {
            return url
        }
    }
    return nil
}

// MARK: - Thumbnail view that handles local file URLs properly
private struct DownloadThumbnailView: View {
    let url: URL?
    let fallbackIcon: String

    var body: some View {
        if let url = url {
            if url.isFileURL {
                // Local file - use UIImage directly (AsyncImage can be unreliable with file URLs)
                if let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: fallbackIcon)
                        .foregroundStyle(.gray)
                }
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .clipped()
                    case .empty:
                        ProgressView()
                            .tint(.gray)
                    default:
                        Image(systemName: fallbackIcon)
                            .foregroundStyle(.gray)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else {
            Image(systemName: fallbackIcon)
                .foregroundStyle(.gray)
        }
    }
}

struct DownloadsView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var retryDownload: DownloadItem?

    // Track downloads that have missing files
    @State private var missingFileDownloads: Set<String> = []

    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                StreamifyPageBackground()

                if (downloadManager.downloads.isEmpty || downloadManager.downloads.allSatisfy({ missingFileDownloads.contains($0.id) })) && downloadManager.trackDownloads.isEmpty {
                    StreamifyEmptyState(
                        icon: "arrow.down.circle.fill",
                        title: "No Downloads",
                        subtitle: "Download movies and episodes to watch offline",
                        tint: .green.opacity(0.9)
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Error banner if there's a recent error
                            if downloadManager.showErrorAlert {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                    Text(downloadManager.lastError ?? "Download failed")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button("Dismiss") {
                                        downloadManager.showErrorAlert = false
                                        downloadManager.lastError = nil
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                }
                                .padding(12)
                                .background(Color.red.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 16)
                            }

                            // Active downloads
                            let activeDownloads = downloadManager.getActiveDownloads()
                            if !activeDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    StreamifySectionHeader(title: "Downloading")
                                        .padding(.horizontal, 16)

                                    ForEach(activeDownloads) { download in
                                        DownloadItemRow(
                                            download: download,
                                            onPause: {
                                                downloadManager.pauseDownload(download)
                                            },
                                            onCancel: {
                                                downloadManager.cancelDownload(download)
                                            }
                                        )
                                        .padding(.horizontal, 16)
                                    }
                                }
                            }

                            // Track downloads (subtitle/audio from player picker) — show downloading and queued
                            let activeTrackDownloads = downloadManager.trackDownloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .pending }
                            if !activeTrackDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    if activeDownloads.isEmpty {
                                        StreamifySectionHeader(title: "Downloading")
                                            .padding(.horizontal, 16)
                                    }

                                    ForEach(activeTrackDownloads) { trackDL in
                                        TrackDownloadRow(trackDownload: trackDL, onPause: {
                                            downloadManager.pauseTrackDownload(id: trackDL.id)
                                        }, onCancel: {
                                            downloadManager.cancelTrackDownload(id: trackDL.id)
                                        })
                                            .padding(.horizontal, 16)
                                    }
                                }
                            }

                            // Paused downloads
                            let pausedDownloads = downloadManager.downloads.filter { $0.status == .paused }
                            let pausedTrackDownloads = downloadManager.trackDownloads.filter { $0.status == .paused }
                            if !pausedDownloads.isEmpty || !pausedTrackDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    StreamifySectionHeader(title: "Paused", tint: .yellow)
                                        .padding(.horizontal, 16)

                                    ForEach(pausedDownloads) { download in
                                        PausedDownloadRow(
                                            download: download,
                                            onResume: {
                                                downloadManager.resumeDownload(download)
                                            },
                                            onCancel: {
                                                downloadManager.cancelDownload(download)
                                            }
                                        )
                                        .padding(.horizontal, 16)
                                    }

                                    ForEach(pausedTrackDownloads) { trackDL in
                                        TrackDownloadRow(trackDownload: trackDL, onCancel: {
                                            downloadManager.cancelTrackDownload(id: trackDL.id)
                                        }, onRemove: {
                                            downloadManager.clearTrackDownload(id: trackDL.id)
                                        }, onResume: {
                                            downloadManager.resumeTrackDownload(id: trackDL.id)
                                        })
                                            .padding(.horizontal, 16)
                                    }
                                }
                                .padding(.top, activeDownloads.isEmpty ? 0 : 8)
                            }

                            // Failed downloads
                            let failedDownloads = downloadManager.getFailedDownloads()
                            if !failedDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    StreamifySectionHeader(title: "Failed", tint: .red)
                                        .padding(.horizontal, 16)

                                    ForEach(failedDownloads) { download in
                                        FailedDownloadRow(
                                            download: download,
                                            onRetry: {
                                                downloadManager.retryDownload(download)
                                            },
                                            onRemove: {
                                                downloadManager.removeDownload(download)
                                            }
                                        )
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .padding(.top, activeDownloads.isEmpty ? 0 : 8)
                            }

                            // Completed downloads
                            let completedDownloads = downloadManager.getCompletedDownloads()
                            if !completedDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    StreamifySectionHeader(title: "Completed")
                                        .padding(.horizontal, 16)

                                    ForEach(completedDownloads) { download in
                                        CompletedDownloadRow(download: download)
                                            .padding(.horizontal, 16)
                                    }
                                }
                                .padding(.top, (activeDownloads.isEmpty && failedDownloads.isEmpty) ? 0 : 8)
                            }

                            Spacer(minLength: 86)
                        }
                        .padding(.top, 16)
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .streamifyNavigationChrome()
            .streamifyAlert(
                title: errorMessage.contains("Network") || errorMessage.contains("connection") ? "Download Paused" : "Download Failed",
                message: errorMessage,
                isPresented: $showErrorAlert,
                primaryTitle: retryDownload == nil ? "OK" : (retryDownload?.status == .paused ? "Resume" : "Retry"),
                secondaryTitle: retryDownload == nil ? nil : "OK",
                primaryAction: {
                    if let download = retryDownload {
                        if download.status == .paused {
                            downloadManager.resumeDownload(download)
                        } else {
                            downloadManager.retryDownload(download)
                        }
                    }
                    retryDownload = nil
                },
                secondaryAction: {
                    retryDownload = nil
                }
            )
            .onChange(of: downloadManager.showErrorAlert) { showError in
                if showError {
                    errorMessage = downloadManager.lastError ?? "An unknown error occurred"
                    // Find the paused/failed download to offer retry/resume
                    if let error = downloadManager.lastError {
                        // Check paused downloads first (for network errors)
                        for download in downloadManager.downloads.filter({ $0.status == .paused }) {
                            if error.contains(download.displayTitle) {
                                retryDownload = download
                                break
                            }
                        }
                        // Then check failed downloads
                        if retryDownload == nil {
                            for download in downloadManager.getFailedDownloads() {
                                if error.contains(download.displayTitle) {
                                    retryDownload = download
                                    break
                                }
                            }
                        }
                    }
                    showErrorAlert = true
                    downloadManager.showErrorAlert = false
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            checkDownloadedFiles()
        }
    }

    // MARK: - Check if downloaded files exist
    private func checkDownloadedFiles() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let contentDir = documentsURL.appendingPathComponent("Content")

        for download in downloadManager.downloads where download.status == .completed {
            var fileExists = false

            // Determine expected file path
            if let episodeIndex = download.episodeIndex {
                // Episode download - check for season_X_episode_Y folder
                let seriesId = download.contentId.components(separatedBy: "_ep").first ?? download.contentId
                let safeId = seriesId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seriesId
                let season = download.seasonIndex ?? 1
                let episodeFolder = contentDir.appendingPathComponent(DownloadManager.episodeFolderPath(contentId: seriesId, season: season, episode: episodeIndex))

                // Check for quality subfolder (video_{quality}_{uuid}/video.m3u8)
                if let qName = download.qualityName, !qName.isEmpty {
                    let qualitySubdir = DownloadManager.qualitySubdirName(qualityName: qName, downloadId: download.id, episodeIndex: episodeIndex)
                    let qualityM3u8 = episodeFolder.appendingPathComponent(qualitySubdir).appendingPathComponent("video.m3u8")
                    fileExists = FileManager.default.fileExists(atPath: qualityM3u8.path)
                }

                if !fileExists {
                    // Check for local HLS, direct files, original MKVs, and remuxed sidecars.
                    let m3u8Path = episodeFolder.appendingPathComponent("episode_\(episodeIndex).m3u8")
                    let directNames = [
                        "episode_\(episodeIndex).mp4",
                        "episode_\(episodeIndex).m4v",
                        "episode_\(episodeIndex).mkv",
                        "episode_\(episodeIndex).webm",
                        "episode_\(episodeIndex).streamify.m3u8"
                    ]
                    fileExists = FileManager.default.fileExists(atPath: m3u8Path.path) ||
                        directNames.contains { name in
                            FileManager.default.fileExists(atPath: episodeFolder.appendingPathComponent(name).path)
                        }
                }

                // Also check old structure
                if !fileExists {
                    let oldM3u8 = contentDir.appendingPathComponent("\(safeId)/episode_\(episodeIndex).m3u8")
                    let oldFolder = contentDir.appendingPathComponent(safeId)
                    let directNames = [
                        "episode_\(episodeIndex).mp4",
                        "episode_\(episodeIndex).m4v",
                        "episode_\(episodeIndex).mkv",
                        "episode_\(episodeIndex).webm",
                        "episode_\(episodeIndex).streamify.m3u8"
                    ]
                    fileExists = FileManager.default.fileExists(atPath: oldM3u8.path) ||
                        directNames.contains { name in
                            FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent(name).path)
                        }
                }
            } else {
                // Movie download
                let safeId = download.contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? download.contentId
                let movieFolder = contentDir.appendingPathComponent(safeId)

                // Check for quality subfolder (video_{quality}_{uuid}/video.m3u8)
                if let qName = download.qualityName, !qName.isEmpty {
                    let qualitySubdir = DownloadManager.qualitySubdirName(qualityName: qName, downloadId: download.id)
                    let qualityM3u8 = movieFolder.appendingPathComponent(qualitySubdir).appendingPathComponent("video.m3u8")
                    fileExists = FileManager.default.fileExists(atPath: qualityM3u8.path)
                }

                if !fileExists {
                    // Check for video.m3u8 or any direct/remuxed local video file.
                    let m3u8Path = movieFolder.appendingPathComponent("video.m3u8")
                    fileExists = FileManager.default.fileExists(atPath: m3u8Path.path)
                }

                if !fileExists {
                    if let files = try? FileManager.default.contentsOfDirectory(atPath: movieFolder.path) {
                        fileExists = files.contains { name in
                            let lowercased = name.lowercased()
                            return lowercased.hasSuffix(".mp4") ||
                                lowercased.hasSuffix(".mov") ||
                                lowercased.hasSuffix(".m4v") ||
                                lowercased.hasSuffix(".mkv") ||
                                lowercased.hasSuffix(".webm")
                        }
                    }
                }
            }

            if !fileExists {
                missingFileDownloads.insert(download.id)
                // Remove from downloads list
                downloadManager.removeDownload(download)
            }
        }
    }
}

// MARK: - Download item row (active)
struct DownloadItemRow: View {
    @ObservedObject var download: DownloadItem
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onPause: () -> Void
    let onCancel: () -> Void

    private var thumbnailURL: URL? {
        // Access @Published properties so SwiftUI re-evaluates when status or library changes
        // (metadata may not exist on first render if library save is still in progress)
        let _ = download.status
        let _ = downloadManager.libraryRefreshNeeded
        return resolveDownloadThumbnailURL(contentId: download.libraryContentId, metadata: download.contentMetadata, episodeIndex: download.episodeIndex, seasonIndex: download.seasonIndex)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.darkGray))
                .frame(width: 80, height: 45)
                .overlay {
                    DownloadThumbnailView(url: thumbnailURL, fallbackIcon: download.displayType == .movie ? "film" : "tv")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(download.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let episodeTitle = download.episodeTitle {
                    Text("S\(download.seasonIndex ?? 1)E\(download.episodeIndex ?? 1): \(episodeTitle)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                StreamifyDownloadMetadataStrip(download: download)

                // Progress bar
                DownloadProgressBar(progress: download.progress)

                HStack {
                    Text("\(download.progressPercent)%")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                        .frame(minWidth: 30, alignment: .leading)

                    Spacer()

                    switch download.status {
                    case .downloading:
                        Text("Downloading...")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    case .pending:
                        Text("Starting...")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    case .queued:
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .foregroundStyle(.orange)
                            Text("Queued")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    case .paused:
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    case .completed:
                        Text("Completed")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    case .failed:
                        Text("Failed")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    case .cancelled:
                        Text("Cancelled")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
            }

            // Pause and Cancel buttons
            HStack(spacing: 8) {
                if download.status == .downloading {
                    Button {
                        onPause()
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                }

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10)
    }
}

// MARK: - Paused download row
struct PausedDownloadRow: View {
    @ObservedObject var download: DownloadItem
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onResume: () -> Void
    let onCancel: () -> Void

    // Check if this is a network-paused download
    private var isNetworkPaused: Bool {
        download.errorMessage?.contains("Network") ?? false ||
        download.errorMessage?.contains("connection") ?? false ||
        download.errorMessage?.contains("internet") ?? false
    }

    // Check if this was paused due to app closure
    private var isAppClosedPaused: Bool {
        download.errorMessage?.contains("app was closed") ?? false
    }

    private var thumbnailURL: URL? {
        let _ = download.status
        let _ = downloadManager.libraryRefreshNeeded
        return resolveDownloadThumbnailURL(contentId: download.libraryContentId, metadata: download.contentMetadata, episodeIndex: download.episodeIndex, seasonIndex: download.seasonIndex)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.darkGray))
                .frame(width: 80, height: 45)
                .overlay {
                    DownloadThumbnailView(url: thumbnailURL, fallbackIcon: download.displayType == .movie ? "film" : "tv")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(download.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let episodeTitle = download.episodeTitle {
                    Text("S\(download.seasonIndex ?? 1)E\(download.episodeIndex ?? 1): \(episodeTitle)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                StreamifyDownloadMetadataStrip(download: download)

                // Show appropriate paused message
                if isNetworkPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi.slash")
                            .font(.caption2)
                        Text("Connection lost - tap resume when online")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                } else if isAppClosedPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "app.badge.checkmark")
                            .font(.caption2)
                        Text("App was closed - tap resume to continue")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                } else if let error = download.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                // Progress bar (colored based on pause reason)
                DownloadProgressBar(
                    progress: download.progress,
                    color: isNetworkPaused ? .orange : (isAppClosedPaused ? .blue : .yellow)
                )

                HStack {
                    Text("\(download.progressPercent)%")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                        .frame(minWidth: 30, alignment: .leading)

                    Spacer()

                    if isNetworkPaused {
                        Text("Network Paused")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if isAppClosedPaused {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }

            // Resume and Cancel buttons
            HStack(spacing: 8) {
                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10)
    }
}

// MARK: - Failed download row
struct FailedDownloadRow: View {
    @ObservedObject var download: DownloadItem
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onRetry: () -> Void
    let onRemove: () -> Void

    private var thumbnailURL: URL? {
        let _ = download.status
        let _ = downloadManager.libraryRefreshNeeded
        return resolveDownloadThumbnailURL(contentId: download.libraryContentId, metadata: download.contentMetadata, episodeIndex: download.episodeIndex, seasonIndex: download.seasonIndex)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.darkGray))
                .frame(width: 80, height: 45)
                .overlay {
                    DownloadThumbnailView(url: thumbnailURL, fallbackIcon: download.displayType == .movie ? "film" : "tv")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(download.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let episodeTitle = download.episodeTitle {
                    Text("S\(download.seasonIndex ?? 1)E\(download.episodeIndex ?? 1): \(episodeTitle)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                if let error = download.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                StreamifyDownloadMetadataStrip(download: download)
            }

            Spacer()

            // Retry and remove buttons
            HStack(spacing: 8) {
                Button {
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue)
                        .clipShape(Circle())
                }

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
            }
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10)
    }
}

// MARK: - Completed download row
struct CompletedDownloadRow: View {
    @ObservedObject var download: DownloadItem
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var thumbnailURL: URL? {
        let _ = download.status
        let _ = downloadManager.libraryRefreshNeeded
        return resolveDownloadThumbnailURL(contentId: download.libraryContentId, metadata: download.contentMetadata, episodeIndex: download.episodeIndex, seasonIndex: download.seasonIndex)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.darkGray))
                .frame(width: 80, height: 45)
                .overlay {
                    DownloadThumbnailView(url: thumbnailURL, fallbackIcon: download.displayType == .movie ? "film" : "tv")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(download.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let episodeTitle = download.episodeTitle {
                    Text("S\(download.seasonIndex ?? 1)E\(download.episodeIndex ?? 1): \(episodeTitle)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                StreamifyDownloadMetadataStrip(download: download)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                        Text("Downloaded")
                            .font(.caption2)
                    }
                    .foregroundStyle(.green)
                }
            }

            Spacer()
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10)
    }
}

// MARK: - Track download row (subtitle/audio from player picker)
struct TrackDownloadRow: View {
    @ObservedObject var trackDownload: TrackDownloadItem
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onPause: (() -> Void)?
    let onCancel: (() -> Void)?
    let onRemove: (() -> Void)?
    let onResume: (() -> Void)?

    init(trackDownload: TrackDownloadItem, onPause: (() -> Void)? = nil, onCancel: (() -> Void)? = nil, onRemove: (() -> Void)? = nil, onResume: (() -> Void)? = nil) {
        self.trackDownload = trackDownload
        self.onPause = onPause
        self.onCancel = onCancel
        self.onRemove = onRemove
        self.onResume = onResume
    }

    private var thumbnailURL: URL? {
        // Access @Published properties so SwiftUI re-evaluates when status or library changes
        // (thumbnail file may not exist on first render if download just started)
        let _ = trackDownload.status
        let _ = downloadManager.libraryRefreshNeeded
        let safeId = trackDownload.contentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackDownload.contentId
        return resolveDownloadThumbnailURL(
            contentId: trackDownload.contentId,
            metadata: ContentImportService.loadMetadata(from: safeId),
            episodeIndex: trackDownload.episodeNumber,
            seasonIndex: trackDownload.seasonNumber
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.darkGray))
                .frame(width: 80, height: 45)
                .overlay {
                    DownloadThumbnailView(url: thumbnailURL, fallbackIcon: trackDownload.trackType == "subtitle" ? "captions.bubble.fill" : (trackDownload.trackType == "video" ? "film" : "speaker.wave.2.fill"))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(trackDownload.contentTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let epTitle = trackDownload.episodeTitle, let s = trackDownload.seasonNumber, let e = trackDownload.episodeNumber {
                    Text("S\(s)E\(e): \(epTitle)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                if trackDownload.status == .downloading || trackDownload.status == .paused {
                    // Show pause reason for app-closed paused tracks
                    if trackDownload.status == .paused, let msg = trackDownload.errorMessage, msg.contains("app was closed") {
                        HStack(spacing: 4) {
                            Image(systemName: "app.badge.checkmark")
                                .font(.caption2)
                            Text(trackDownload.canResume ? "App was closed — tap resume to continue" : "App was closed — remove to re-download")
                                .font(.caption2)
                        }
                        .foregroundStyle(.blue)
                    }

                    // Progress bar
                    DownloadProgressBar(
                        progress: trackDownload.progress,
                        color: trackDownload.status == .paused ? .yellow : (trackDownload.trackType == "subtitle" ? .blue : .green)
                    )

                    HStack {
                        Text("\(Int(trackDownload.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                        Spacer()
                        if trackDownload.status == .paused {
                            Text("Paused")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        } else {
                            let typeLabel = trackDownload.trackType == "subtitle" ? "Subtitle" : (trackDownload.trackType == "video" ? "Video" : "Audio")
                            let detail = trackDownload.trackType == "video" ? trackDownload.language : ": \(trackDownload.language)"
                            Text("Downloading \(typeLabel) \(detail)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                } else if trackDownload.status == .queued {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                        let typeLabel = trackDownload.trackType == "subtitle" ? "Subtitle" : (trackDownload.trackType == "video" ? "Video" : "Audio")
                        let detail = trackDownload.trackType == "video" ? trackDownload.language : ": \(trackDownload.language)"
                        Text("Queued — \(typeLabel) \(detail)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else if trackDownload.status == .pending {
                    Text("Starting...")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                } else if trackDownload.status == .completed {
                    Text("Completed")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if trackDownload.status == .failed {
                    Text(trackDownload.errorMessage ?? "Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Pause and Cancel buttons — matching main download row pattern
            if trackDownload.status == .downloading {
                HStack(spacing: 8) {
                    if let onPause = onPause {
                        Button {
                            onPause()
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                        }
                    }

                    if let onCancel = onCancel {
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.gray)
                        }
                    }
                }
            } else if trackDownload.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if trackDownload.status == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if trackDownload.status == .paused {
                HStack(spacing: 8) {
                    if let onResume = onResume, trackDownload.canResume {
                        Button {
                            onResume()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }
                    }
                    if let onRemove = onRemove {
                        Button {
                            onRemove()
                        } label: {
                            Image(systemName: "trash.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                    }
                    if let onCancel = onCancel {
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.gray)
                        }
                    }
                    if onResume == nil && onRemove == nil && onCancel == nil {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            } else if trackDownload.status == .queued || trackDownload.status == .pending {
                if let onCancel = onCancel {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                    }
                } else {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .streamifyPanel(cornerRadius: 10)
    }
}
