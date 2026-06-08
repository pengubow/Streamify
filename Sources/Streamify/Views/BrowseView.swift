import SwiftUI

enum VerticalBrowseSourceCardArtworkPreference {
    case thumbnailFirst
    case posterFirst
}

struct VerticalBrowseSourceCard: View {
    let content: SourceContent
    let fallbackPosterUrls: [URL]
    var cardWidth: CGFloat = 120
    var artworkPreference: VerticalBrowseSourceCardArtworkPreference = .thumbnailFirst

    var body: some View {
        let thumbURL = ContentImportService.thumbnailURL(from: content)
        let posterURL = ContentImportService.posterThumbnailURL(from: content)
        let allUrls = artworkURLs(thumbnail: thumbURL, poster: posterURL)
        let posterHeight = cardWidth * 1.4
        
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if !allUrls.isEmpty {
                    FallbackAsyncImage(urls: allUrls) {
                        Color(.systemGray5)
                            .overlay {
                                Image(systemName: content.type == .movie ? "film" : "tv")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                            }
                    }
                } else {
                    Color(.systemGray5)
                        .overlay {
                            Image(systemName: content.type == .movie ? "film" : "tv")
                                .font(.title)
                                .foregroundStyle(.gray)
                        }
                }
            }
            .frame(width: cardWidth, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
                
                Text(content.type == .movie ? "Movie" : "Series")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(.top, 6)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
    }

    private func artworkURLs(thumbnail: URL?, poster: URL?) -> [URL] {
        switch artworkPreference {
        case .thumbnailFirst:
            return StreamifyURLList.combining(
                primary: thumbnail,
                fallbacks: fallbackPosterUrls + [poster].compactMap { $0 }
            )
        case .posterFirst:
            return StreamifyURLList.combining(
                primary: poster,
                fallbacks: fallbackPosterUrls + [thumbnail].compactMap { $0 }
            )
        }
    }
}
