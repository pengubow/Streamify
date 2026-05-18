import SwiftUI
import UIKit

/// An image view that tries multiple URLs in order using URLSession.
/// Uses .task for proper lifecycle management instead of AsyncImage,
/// which can fail to load images on first render due to internal caching.
struct FallbackAsyncImage<Placeholder: View>: View {
    let urls: [URL]
    let contentMode: ContentMode
    let onImageLoaded: (UIImage) -> Void
    let onImageLoadedWithURL: (UIImage, URL) -> Void
    let placeholder: () -> Placeholder
    
    private let imageLoadTimeout: TimeInterval = 10
    
    @State private var loadedImage: UIImage?
    @State private var allFailed: Bool = false
    @State private var taskId: UUID = UUID()
    
    init(
        urls: [URL],
        contentMode: ContentMode = .fill,
        onImageLoaded: @escaping (UIImage) -> Void = { _ in },
        onImageLoadedWithURL: @escaping (UIImage, URL) -> Void = { _, _ in },
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.contentMode = contentMode
        self.onImageLoaded = onImageLoaded
        self.onImageLoadedWithURL = onImageLoadedWithURL
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if urls.isEmpty || allFailed {
                placeholder()
            } else {
                Color(.systemGray5)
            }
        }
        .task(id: taskId) {
            guard !urls.isEmpty else { return }
            await loadFirstWorking()
        }
        .onChange(of: urls) { _ in
            loadedImage = nil
            allFailed = false
            taskId = UUID()
        }
    }
    
    private func loadFirstWorking() async {
        for url in urls {
            if Task.isCancelled { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = imageLoadTimeout
                let (data, _) = try await URLSession.shared.data(for: request)
                if Task.isCancelled { return }
                if let uiImage = UIImage(data: data) {
                    self.loadedImage = uiImage
                    self.onImageLoaded(uiImage)
                    self.onImageLoadedWithURL(uiImage, url)
                    return
                }
            } catch {
                continue
            }
        }
        if !Task.isCancelled {
            self.allFailed = true
        }
    }
}
