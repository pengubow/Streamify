import SwiftUI

struct VerticalBrowseSourceCard: View {
    let content: SourceContent
    let fallbackPosterUrls: [URL]
    var cardWidth: CGFloat = 120

    var body: some View {
        let thumbURL = ContentImportService.posterThumbnailURL(from: content)
        let allUrls = StreamifyURLList.combining(primary: thumbURL, fallbacks: fallbackPosterUrls)
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
    }
}
