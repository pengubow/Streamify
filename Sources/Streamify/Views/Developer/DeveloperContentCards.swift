import SwiftUI

struct SourceMovieGridCard: View {
    let movie: SourceContent

    var body: some View {
        SourceContentGridCard(
            content: movie,
            fallbackIcon: "film",
            subtitle: movie.id
        )
    }
}

struct SourceSeriesGridCard: View {
    let series: SourceContent

    private var episodeCount: Int {
        series.allEpisodes.count
    }

    private var seasonCount: Int {
        series.seasons?.count ?? 1
    }

    var body: some View {
        SourceContentGridCard(
            content: series,
            fallbackIcon: "tv",
            subtitle: "\(seasonCount) season\(seasonCount == 1 ? "" : "s") • \(episodeCount) ep"
        )
    }
}

private struct SourceContentGridCard: View {
    let content: SourceContent
    let fallbackIcon: String
    let subtitle: String

    private var thumbURL: URL? {
        ContentImportService.posterThumbnailURL(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            poster
                .aspectRatio(2 / 3, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .padding(.top, 6)
        }
    }

    private var poster: some View {
        GeometryReader { geometry in
            ZStack {
                if let url = thumbURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        } else {
                            Color(.systemGray5)
                        }
                    }
                } else {
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        Color(.systemGray5)
            .overlay {
                Image(systemName: fallbackIcon)
                    .font(.title)
                    .foregroundStyle(.gray)
            }
    }
}
