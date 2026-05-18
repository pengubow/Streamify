import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Helpers
    
    /// Check if local video file exists, including library lookup for Browse content
    func checkHasLocalFile() -> Bool {
        let url: URL?
        if let ep = currentEpisodeInfo {
            url = ContentImportService.videoURL(for: content, episode: ep)
        } else {
            url = ContentImportService.videoURL(for: content)
        }
        if let url = url, url.isFileURL || url.host == "localhost" {
            return true
        }
        // If content has empty folderPath (e.g. from Browse), check library for a local copy
        if content.folderPath.isEmpty {
            let library = ContentImportService.loadLibrary()
            if let libContent = library.first(where: { $0.id == content.id }), !libContent.folderPath.isEmpty {
                let libUrl: URL?
                if let ep = currentEpisodeInfo {
                    libUrl = ContentImportService.videoURL(for: libContent, episode: ep)
                } else {
                    libUrl = ContentImportService.videoURL(for: libContent)
                }
                if let libUrl = libUrl, libUrl.isFileURL || libUrl.host == "localhost" {
                    return true
                }
            }
        }
        // Check downloadedVideoQualities for quality-only downloads
        let qualities = loadDownloadedVideoQualities()
        if qualities.contains(where: { isDownloadedQualityOnDisk($0) }) {
            return true
        }
        return false
    }
    
    /// Resolve local video URL, checking library for Browse content
    func resolveLocalVideoURL() -> URL? {
        if let ep = currentEpisodeInfo {
            if let url = ContentImportService.videoURL(for: content, episode: ep),
               url.isFileURL || url.host == "localhost" {
                return url
            }
        } else {
            if let url = ContentImportService.videoURL(for: content),
               url.isFileURL || url.host == "localhost" {
                return url
            }
        }
        // Check library for Browse content
        if content.folderPath.isEmpty {
            let library = ContentImportService.loadLibrary()
            if let libContent = library.first(where: { $0.id == content.id }), !libContent.folderPath.isEmpty {
                if let ep = currentEpisodeInfo {
                    return ContentImportService.videoURL(for: libContent, episode: ep)
                } else {
                    return ContentImportService.videoURL(for: libContent)
                }
            }
        }
        return nil
    }

    func refreshLocalMasterAndCleanupIfEmpty() {
        let folderPath = effectiveFolderPath
        guard !folderPath.isEmpty else { return }
        DownloadManager.shared.refreshLocalMasterPlaylist(metadataFolder: folderPath, episode: currentEpisodeInfo)
        DownloadManager.shared.cleanupLocalContentFolderIfEmpty(metadataFolder: folderPath, episode: currentEpisodeInfo)
    }

    func scheduleHideControls() {
        guard !isPickerOrSwitchAlertPresented else { return }
        hideWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { 
                if !isPickerOrSwitchAlertPresented {
                    showControls = false 
                }
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    func cancelHideControls() {
        hideWorkItem?.cancel()
    }

    func formatTime(_ seconds: Double) -> String {
        TimeFormatting.formatTime(seconds)
    }
}
