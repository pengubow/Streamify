import SwiftUI

// MARK: - Episode Editor Sheet
struct EpisodeEditorSheet: View {
    let seasonNumber: Int
    let episodeNumber: Int
    var episode: EpisodeInfo? = nil
    
    var onSave: (EpisodeInfo) -> Void
    var onDelete: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var title: String
    @State private var description: String
    @State private var thumbnailUrl: String
    @State private var hlsUrl: String
    @State private var fileUrl: String
    @State private var introStart: String
    @State private var introDuration: String
    @State private var endOffset: String
    @State private var subtitleTracks: [SubtitleTrack]
    @State private var audioTracksList: [AudioTrack]
    @State private var showDeleteAlert = false
    
    init(seasonNumber: Int, episodeNumber: Int, episode: EpisodeInfo? = nil, onSave: @escaping (EpisodeInfo) -> Void, onDelete: (() -> Void)? = nil) {
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episode = episode
        self.onSave = onSave
        self.onDelete = onDelete
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        
        _title = State(initialValue: episode?.title ?? "")
        _description = State(initialValue: episode?.description ?? "")
        _thumbnailUrl = State(initialValue: episode?.thumbnailUrl ?? "")
        _hlsUrl = State(initialValue: episode?.hlsUrl ?? "")
        _fileUrl = State(initialValue: episode?.file ?? "")
        _introStart = State(initialValue: episode?.intro.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _introDuration = State(initialValue: episode?.introDuration.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _endOffset = State(initialValue: episode?.end.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _subtitleTracks = State(initialValue: episode?.subtitles ?? [])
        _audioTracksList = State(initialValue: episode?.audioTracks ?? [])
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: episode == nil ? "plus.circle.fill" : "play.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(episode == nil ? .purple : .blue)
                        
                        Text(episode == nil ? "New Episode" : "Edit Episode")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        
                        Text("S\(seasonNumber)E\(episodeNumber)")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                    .padding(.top, 24)
                    
                    // Episode Info Section
                    VStack(spacing: 16) {
                        Text("Episode Info")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // Episode Number (read-only)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Episode Number")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                Text("\(episodeNumber)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            
                            // Title Field
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    Text("Title")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Text("*")
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                }
                                TextField("Episode Title", text: $title)
                                    .streamifyTextInput()
                            }
                            
                            // Description Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("Episode description...", text: $description)
                                    .streamifyTextInput()
                            }
                            
                            // Thumbnail URL Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Thumbnail URL")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("https://...", text: $thumbnailUrl)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                
                                if let url = URL(string: thumbnailUrl), thumbnailUrl.hasPrefix("http") {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.2))
                                                .frame(height: 100)
                                                .overlay { ProgressView() }
                                        }
                                    }
                                    .frame(maxHeight: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Video URL Section
                    VStack(spacing: 16) {
                        Text("Video URL")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // HLS URL Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("HLS URL")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("https://...m3u8", text: $hlsUrl)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("File URL")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("https://...mkv / mp4 / webm", text: $fileUrl)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Video Properties Section
                    VStack(spacing: 16) {
                        Text("Video Properties")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // Intro Skip - Start and Duration
                            TimeInputPair(
                                firstLabel: "Intro Start",
                                firstValue: $introStart,
                                secondLabel: "Intro Duration",
                                secondValue: $introDuration
                            )
                            
                            Divider().background(Color.gray.opacity(0.3))
                            
                            // End Field (absolute timestamp from start)
                            TimeInputField(
                                label: "End",
                                totalSeconds: $endOffset,
                                caption: "Timestamp at which to show the 'Next Episode' button"
                            )
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Subtitles Section
                    SubtitleEditorSection(subtitleTracks: $subtitleTracks)
                        .padding(.horizontal, 16)
                    
                    // Audio Tracks Section
                    AudioEditorSection(audioTracks: $audioTracksList)
                        .padding(.horizontal, 16)
                    
                    // Delete Button
                    VStack(spacing: 12) {
                        if let _ = onDelete {
                            Button {
                                showDeleteAlert = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Delete Episode")
                                        .font(.headline)
                                }
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(episode == nil ? "New Episode" : "Episode \(episodeNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(episode == nil ? "Add" : "Save") { saveEpisode() }
                        .font(.body.weight(.semibold))
                        .disabled(title.isEmpty)
                }
            }
            .streamifyAlert(
                title: "Delete Episode?",
                message: "Are you sure you want to delete '\(title)'?",
                isPresented: $showDeleteAlert,
                primaryTitle: "Delete",
                secondaryTitle: "Cancel",
                primaryRole: .destructive,
                primaryAction: {
                    onDelete?()
                    dismiss()
                }
            )
        }
        .preferredColorScheme(.dark)
    }
    
    private func saveEpisode() {
        let introValue = Double(introStart)
        let introDurationValue = Double(introDuration)
        let endValue = Double(endOffset)
        
        let updatedEpisode = EpisodeInfo(
            season: seasonNumber,
            episode: episodeNumber,
            title: title,
            description: description,
            thumbnailUrl: thumbnailUrl.isEmpty ? nil : thumbnailUrl,
            file: fileUrl.isEmpty ? nil : fileUrl,
            hlsUrl: hlsUrl.isEmpty ? nil : hlsUrl,
            localFile: nil,
            intro: introValue,
            introDuration: introDurationValue,
            end: endValue,
            subtitles: subtitleTracks.isEmpty ? nil : subtitleTracks,
            audioTracks: audioTracksList.isEmpty ? nil : audioTracksList
        )
        
        onSave(updatedEpisode)
        dismiss()
    }
}

