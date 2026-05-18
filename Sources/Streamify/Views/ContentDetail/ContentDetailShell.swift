import SwiftUI
import UIKit

extension ContentDetailView {
    // MARK: - Extracted Body Sub-Views

    var metadataBadges: some View {
        HStack(spacing: 8) {
            Text(content.metadata.type == .movie ? "Movie" : "Series")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            
            if let genres = content.metadata.genres, !genres.isEmpty {
                ForEach(Array(genres.sorted { $0.rawValue < $1.rawValue }.prefix(3))) { genre in
                    Text(genre.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else if let genre = content.metadata.displayGenre {
                Text(genre.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            if !episodes.isEmpty {
                Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(StreamifySurface.mutedText)
            }
        }
    }

    var loadingOverlay: some View {
        VStack(spacing: 20) {
            // Show the base message (may include URL on a second line).
            // Fall back to loadingMessageSnapshot (last known non-nil message) so the
            // exit animation of the popup doesn't briefly flash "Setting up video player..."
            // when the loading message is cleared just before the overlay is dismissed.
            let parts = (loadingMessage ?? loadingMessageSnapshot).components(separatedBy: "\n")
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
            HStack(spacing: 12) {
                // Skip: only shown while a specific URL is being checked (second line present).
                // During Torrentio/VidLink/111Movies fetches there is no URL to skip, so the button
                // would do nothing — hide it to avoid confusing the user.
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
                // Cancel: aborts the entire resolution task
                Button("Cancel") {
                    cancelLoadingOverlay()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .streamifyPromptPanel()
        .padding(.horizontal, 32)
    }

    func cancelLoadingOverlay() {
        urlCheckSkipper?.skip()
        playResolutionTask?.cancel()
        playResolutionTask = nil
        urlCheckSkipper = nil
        isLoadingQualities = false
        downloadFlowNextStep = .idle
        userConfirmedPicker = false
        loadingMessage = nil
    }

    func playerView(for context: PlayerContext) -> some View {
        VideoPlayerView(
            content: currentContent,
            videoURL: context.videoURL,
            episodeInfo: context.episodeInfo,
            onDismiss: {
                playerContext = nil
                progressRefreshTrigger.toggle()
                viewModel.refreshLibrary()
            },
            onRequestNextEpisode: isInLibrary ? { currentEp, skipper, onCheckingURL, onPreparingPlayback in await getNextEpisodeRequest(currentEpisode: currentEp, skipper: skipper, onCheckingURL: onCheckingURL, onPreparingPlayback: onPreparingPlayback) } : nil,
            onAddToLibraryAndRequestNext: !isInLibrary ? { currentEp, skipper, onCheckingURL, onPreparingPlayback in await addLibraryAndGetNextEpisodeRequest(currentEpisode: currentEp, skipper: skipper, onCheckingURL: onCheckingURL, onPreparingPlayback: onPreparingPlayback) } : nil,
            onGoToBrowse: {
                playerContext = nil
                requestDismiss()
            },
            isInLibrary: isInLibrary,
            onlineUrls: {
                if let ep = context.episodeInfo {
                    return viewModel.allEpisodeHlsUrls(for: content.id, season: ep.season, episode: ep.episode)
                }
                return viewModel.allHlsUrls(for: content.id)
            }(),
            onlineUrlSourceNames: {
                if let ep = context.episodeInfo {
                    return viewModel.episodeHlsUrlSourceNames(for: content.id, season: ep.season, episode: ep.episode)
                }
                return viewModel.hlsUrlSourceNames(for: content.id)
            }(),
            preloadedAudioTracks: context.preloadedAudioTracks,
            streamingSubtitles: context.streamingSubtitles,
            preloadedQualities: context.preloadedQualities
        )
    }

    // MARK: - Library Button
    var libraryButton: some View {
        Group {
            if isInLibrary {
                Button {
                    viewModel.deleteContent(currentContent)
                    NotificationCenter.default.post(name: .watchingProgressUpdated, object: nil)
                    requestDismiss()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Remove from Library")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else if let sourceContent = sourceContent {
                Button {
                    addSourceContentToLibrary(sourceContent)
                } label: {
                    HStack {
                        if isAddingToLibrary {
                            ProgressView()
                                .tint(.blue)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text("Add to Library")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isAddingToLibrary)
            }
        }
    }

    // MARK: - Hero Image
    var heroImage: some View {
        // For series with seasons, use the selected season's thumbnail
        let seasonThumbURL: URL? = {
            if hasSeasons {
                return ContentImportService.seasonThumbnailURL(for: currentContent, season: selectedSeason)
            }
            return nil
        }()
        let localThumbURL = ContentImportService.thumbnailURL(for: currentContent)
        let remoteThumbURL: URL? = {
            if let sourceContent = sourceContent {
                return sourceContent.thumbnailUrl.flatMap { URL(string: $0) }
            }
            if let thumbnail = currentContent.metadata.thumbnail, thumbnail.hasPrefix("http") {
                return URL(string: thumbnail)
            }
            return nil
        }()
        let thumbnailURL = seasonThumbURL ?? localThumbURL ?? remoteThumbURL
        let fallbackThumbnailUrls = [remoteThumbURL].compactMap { $0 }.filter { $0 != thumbnailURL }
        let allThumbnailUrls = StreamifyURLList.combining(primary: thumbnailURL, fallbacks: fallbackThumbnailUrls)

        return Group {
            if !allThumbnailUrls.isEmpty {
                Color(.darkGray)
                    .aspectRatio(665.0/374.0, contentMode: .fit)
                    .overlay {
                        FallbackAsyncImage(
                            urls: allThumbnailUrls,
                            onImageLoaded: { image in
                                updateDetailBackdropColor(from: image)
                            },
                            onImageLoadedWithURL: { _, loadedURL in
                                if localThumbURL != nil, let remoteThumbURL, loadedURL == remoteThumbURL {
                                    downloadMissingThumbnail()
                                }
                            }
                        ) {
                            heroPlaceholder
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
            } else {
                heroPlaceholder
            }
        }
    }
    
    var heroPlaceholder: some View {
        LinearGradient(
            colors: [Color.indigo.opacity(0.5), Color.purple.opacity(0.3)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .aspectRatio(665.0/374.0, contentMode: .fit)
        .overlay {
            Image(systemName: currentContent.metadata.type == .movie ? "film" : "tv")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    func updateDetailBackdropColor(from image: UIImage) {
        guard let color = image.streamifyFeaturedGradientColor() else { return }
        if detailBackdropColor?.streamifyIsClose(to: color) == true { return }
        detailBackdropColor = color
    }
}
