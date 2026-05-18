import SwiftUI
import Foundation
import MediaPlayer

// MARK: - VTT Subtitle Cue
struct SubtitleCue: Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
}

struct RemoteCommandTarget {
    let command: MPRemoteCommand
    let target: Any
}

struct HiddenSystemVolumeHUDView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// Notification for progress updates
extension Notification.Name {
    static let watchingProgressUpdated = Notification.Name("watchingProgressUpdated")
}

// MARK: - Episode change request
struct EpisodeChangeRequest {
    let episode: EpisodeInfo
    let videoURL: URL
    let preloadedAudioTracks: [AudioTrack]?
    let streamingSubtitles: [SubtitleTrack]?
    let preloadedQualities: [HLSQuality]?
    
    init(episode: EpisodeInfo, videoURL: URL, preloadedAudioTracks: [AudioTrack]? = nil, streamingSubtitles: [SubtitleTrack]? = nil, preloadedQualities: [HLSQuality]? = nil) {
        self.episode = episode
        self.videoURL = videoURL
        self.preloadedAudioTracks = preloadedAudioTracks
        self.streamingSubtitles = streamingSubtitles
        self.preloadedQualities = preloadedQualities
    }
}

extension VideoPlayerView {
    func clampedResumeTime(_ seconds: Double, duration: Double) -> Double {
        let target = seconds.isFinite ? max(seconds, 0) : 0
        guard duration.isFinite, duration > 1 else {
            return target
        }
        return min(target, max(duration - 1, 0))
    }
}
