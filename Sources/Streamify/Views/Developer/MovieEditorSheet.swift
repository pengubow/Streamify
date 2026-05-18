import SwiftUI

// MARK: - Movie Editor Sheet
struct MovieEditorSheet: View {
    let source: Source
    var movie: SourceContent? = nil  // nil for new movie
    let viewModel: LibraryViewModel
    var onSave: (SourceContent) -> Void
    var onDelete: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var movieId: String
    @State private var title: String
    @State private var description: String
    @State private var thumbnailUrl: String
    @State private var posterThumbnailUrl: String
    @State private var hlsUrl: String
    @State private var fileUrl: String
    @State private var endOffset: String
    @State private var introStart: String
    @State private var introEnd: String
    @State private var selectedGenres: Set<String>
    @State private var subtitleTracks: [SubtitleTrack]
    @State private var audioTracksList: [AudioTrack]
    @State private var embeddedAudioDisabled: Bool
    @State private var showDeleteAlert = false
    @State private var tmdbIdText: String
    
    init(source: Source, movie: SourceContent? = nil, viewModel: LibraryViewModel, onSave: @escaping (SourceContent) -> Void, onDelete: (() -> Void)? = nil) {
        self.source = source
        self.movie = movie
        self.viewModel = viewModel
        self.onSave = onSave
        self.onDelete = onDelete
        
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        
        _movieId = State(initialValue: movie?.id ?? "")
        _title = State(initialValue: movie?.title ?? "")
        _description = State(initialValue: movie?.description ?? "")
        _thumbnailUrl = State(initialValue: movie?.thumbnailUrl ?? "")
        _posterThumbnailUrl = State(initialValue: movie?.posterThumbnailUrl ?? "")
        _hlsUrl = State(initialValue: movie?.hlsUrl ?? "")
        _fileUrl = State(initialValue: movie?.fileUrl ?? "")
        _endOffset = State(initialValue: movie?.end.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _introStart = State(initialValue: movie?.intro.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _introEnd = State(initialValue: movie?.introDuration.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "")
        _selectedGenres = State(initialValue: Set(movie?.genres?.map { $0.rawValue } ?? []))
        _subtitleTracks = State(initialValue: movie?.subtitles ?? [])
        _audioTracksList = State(initialValue: movie?.audioTracks ?? [])
        _embeddedAudioDisabled = State(initialValue: movie?.embeddedAudioDisabled ?? false)
        _tmdbIdText = State(initialValue: movie?.tmdbId.map { String($0) } ?? "")
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: movie == nil ? "plus.circle.fill" : "film")
                            .font(.system(size: 40))
                            .foregroundStyle(movie == nil ? .green : .blue)
                        
                        Text(movie == nil ? "New Movie" : "Edit Movie")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)
                    
                    // Content Info Section
                    VStack(spacing: 16) {
                        Text("Content Info")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // ID Field
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    Text("ID")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Text("*")
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                }
                                TextField("unique-movie-id", text: $movieId)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
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
                                TextField("Movie Title", text: $title)
                                    .streamifyTextInput()
                            }
                            
                            // Description Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("Movie description...", text: $description)
                                    .streamifyTextInput()
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Thumbnails Section
                    VStack(spacing: 16) {
                        Text("Thumbnails")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // Thumbnail URL field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Thumbnail URL")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                
                                TextField("https://... (landscape banner)", text: $thumbnailUrl)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                
                                // Thumbnail preview
                                if let url = URL(string: thumbnailUrl), thumbnailUrl.hasPrefix("http") {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else if phase.error != nil {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.2))
                                                .overlay {
                                                    Text("Failed to load")
                                                        .font(.caption)
                                                        .foregroundStyle(.gray)
                                                }
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.2))
                                                .overlay {
                                                    ProgressView()
                                                }
                                        }
                                    }
                                    .frame(maxHeight: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else if !thumbnailUrl.isEmpty {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: 100)
                                        .overlay {
                                            Text("Enter a valid URL")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                }
                            }
                            
                            Divider().background(Color.gray.opacity(0.3))
                            
                            // Poster URL field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Poster URL")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                
                                TextField("https://... (portrait poster)", text: $posterThumbnailUrl)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                
                                // Poster preview
                                if let url = URL(string: posterThumbnailUrl), posterThumbnailUrl.hasPrefix("http") {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else if phase.error != nil {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.2))
                                                .overlay {
                                                    Text("Failed to load")
                                                        .font(.caption)
                                                        .foregroundStyle(.gray)
                                                }
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.2))
                                                .overlay {
                                                    ProgressView()
                                                }
                                        }
                                    }
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else if !posterThumbnailUrl.isEmpty {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: 150)
                                        .overlay {
                                            Text("Enter a valid URL")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
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

                            VStack(alignment: .leading, spacing: 8) {
                                Text("TMDB ID")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("e.g. 240411", text: $tmdbIdText)
                                    .streamifyTextInput()
                                    .keyboardType(.numberPad)
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
                                secondValue: $introEnd
                            )
                            
                            Divider().background(Color.gray.opacity(0.3))
                            
                            // End Field (absolute timestamp from start)
                            TimeInputField(
                                label: "End",
                                totalSeconds: $endOffset,
                                caption: "Timestamp at which to show the 'Next' button"
                            )
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Genres Section
                    VStack(spacing: 16) {
                        Text("Genres")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 8) {
                            ForEach(Genre.allCases.sorted { $0.rawValue < $1.rawValue }) { genre in
                                Button {
                                    if selectedGenres.contains(genre.rawValue) {
                                        selectedGenres.remove(genre.rawValue)
                                    } else {
                                        selectedGenres.insert(genre.rawValue)
                                    }
                                } label: {
                                    HStack {
                                        Text(genre.rawValue)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        
                                        Spacer()
                                        
                                        if selectedGenres.contains(genre.rawValue) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // Subtitles Section
                    SubtitleEditorSection(subtitleTracks: $subtitleTracks)
                        .padding(.horizontal, 16)
                    
                    // Embedded Audio Toggle
                    VStack(spacing: 12) {
                        Toggle(isOn: $embeddedAudioDisabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Disable Embedded Audio")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                Text("Use when video has no sound or should use external audio only")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                        }
                        .tint(.orange)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
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
                                    Text("Delete Movie")
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
            .navigationTitle(movie == nil ? "New Movie" : "Edit Movie")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(movie == nil ? "Add" : "Save") { saveMovie() }
                        .font(.body.weight(.semibold))
                        .disabled(movieId.isEmpty || title.isEmpty)
                }
            }
            .streamifyAlert(
                title: "Delete Movie?",
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
    
    private func saveMovie() {
        let genres: [Genre]? = selectedGenres.isEmpty ? nil : selectedGenres.compactMap { Genre(rawValue: $0) }
        
        let introValue = Double(introStart)
        let introDurationValue = Double(introEnd)
        
        let updatedMovie = SourceContent(
            id: movieId,
            title: title,
            description: description,
            type: .movie,
            genres: genres,
            thumbnailUrl: thumbnailUrl.isEmpty ? nil : thumbnailUrl,
            posterThumbnailUrl: posterThumbnailUrl.isEmpty ? nil : posterThumbnailUrl,
            fileUrl: fileUrl.isEmpty ? nil : fileUrl,
            hlsUrl: hlsUrl.isEmpty ? nil : hlsUrl,
            intro: introValue,
            introDuration: introDurationValue,
            end: Double(endOffset),
            seasons: nil,
            episodes: nil,
            subtitles: subtitleTracks.isEmpty ? nil : subtitleTracks,
            audioTracks: audioTracksList.isEmpty ? nil : audioTracksList,
            embeddedAudioDisabled: embeddedAudioDisabled,
            tmdbId: Int(tmdbIdText)
        )
        
        onSave(updatedMovie)
        dismiss()
    }
}

