import SwiftUI

// MARK: - Series Editor Sheet
struct SeriesEditorSheet: View {
    let source: Source
    var series: SourceContent? = nil  // nil for new series
    let viewModel: LibraryViewModel
    var onSave: (SourceContent) -> Void
    var onDelete: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var seriesId: String
    @State private var title: String
    @State private var description: String
    @State private var thumbnailUrl: String
    @State private var posterThumbnailUrl: String
    @State private var selectedGenres: Set<String>
    @State private var seasons: [SeasonInfo]
    @State private var showDeleteAlert = false
    @State private var tmdbIdText: String
    
    // Navigation state
    @State private var selectedSeason: SeasonInfo?
    @State private var showAddSeason = false
    
    init(source: Source, series: SourceContent? = nil, viewModel: LibraryViewModel, onSave: @escaping (SourceContent) -> Void, onDelete: (() -> Void)? = nil) {
        self.source = source
        self.series = series
        self.viewModel = viewModel
        self.onSave = onSave
        self.onDelete = onDelete
        
        _seriesId = State(initialValue: series?.id ?? "")
        _title = State(initialValue: series?.title ?? "")
        _description = State(initialValue: series?.description ?? "")
        _thumbnailUrl = State(initialValue: series?.thumbnailUrl ?? "")
        _posterThumbnailUrl = State(initialValue: series?.posterThumbnailUrl ?? "")
        _selectedGenres = State(initialValue: Set(series?.genres?.map { $0.rawValue } ?? []))
        _seasons = State(initialValue: series?.seasons ?? [])
        _tmdbIdText = State(initialValue: series?.tmdbId.map { String($0) } ?? "")
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: series == nil ? "plus.circle.fill" : "tv")
                            .font(.system(size: 40))
                            .foregroundStyle(series == nil ? .purple : .blue)
                        
                        Text(series == nil ? "New Series" : "Edit Series")
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
                                TextField("unique-series-id", text: $seriesId)
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
                                TextField("Series Title", text: $title)
                                    .streamifyTextInput()
                            }
                            
                            // Description Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("Series description...", text: $description)
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
                                                .overlay { ProgressView() }
                                        }
                                    }
                                    .frame(maxHeight: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                                                .overlay { ProgressView() }
                                        }
                                    }
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    
                    // TMDB ID Section
                    VStack(spacing: 16) {
                        Text("TMDB ID")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TMDB Series ID")
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
                    
                    // Seasons Section
                    VStack(spacing: 16) {
                        Text("Seasons")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if seasons.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tv.and.mediabox")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                                
                                Text("No Seasons")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            VStack(spacing: 12) {
                                ForEach(seasons) { season in
                                    Button {
                                        selectedSeason = season
                                    } label: {
                                        HStack(spacing: 12) {
                                            // Season thumbnail
                                            if let thumbUrl = season.thumbnailUrl,
                                               let url = URL(string: thumbUrl) {
                                                AsyncImage(url: url) { phase in
                                                    if let image = phase.image {
                                                        image.resizable().aspectRatio(contentMode: .fill)
                                                    } else {
                                                        Color.gray.opacity(0.3)
                                                    }
                                                }
                                                .frame(width: 60, height: 40)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            } else {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.gray.opacity(0.3))
                                                    .frame(width: 60, height: 40)
                                                    .overlay {
                                                        Image(systemName: "tv")
                                                            .font(.caption)
                                                            .foregroundStyle(.gray)
                                                    }
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(season.title ?? "Season \(season.season)")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                
                                                Text("\(season.episodes?.count ?? 0) episodes")
                                                    .font(.caption)
                                                    .foregroundStyle(.gray)
                                            }
                                            
                                            Spacer()
                                            
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                        .padding(12)
                                        .background(Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            seasons.removeAll { $0.season == season.season }
                                        } label: {
                                            Label("Delete Season", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        
                        // Add Season Button
                        Button {
                            showAddSeason = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                Text("Add Season")
                                    .font(.headline)
                            }
                            .foregroundStyle(.purple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Delete Button
                    VStack(spacing: 12) {
                        if let _ = onDelete {
                            Button {
                                showDeleteAlert = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Delete Series")
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
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(series == nil ? "New Series" : "Edit Series")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(series == nil ? "Add" : "Save") { saveSeries() }
                        .font(.body.weight(.semibold))
                        .disabled(seriesId.isEmpty || title.isEmpty)
                }
            }
            .sheet(isPresented: $showAddSeason) {
                SeasonEditorView(
                    seasonNumber: (seasons.map { $0.season }.max() ?? 0) + 1,
                    onSave: { newSeason in
                        seasons.append(newSeason)
                        seasons.sort { $0.season < $1.season }
                    }
                )
            }
            .sheet(item: $selectedSeason) { season in
                SeasonEditorView(
                    seasonNumber: season.season,
                    season: season,
                    onSave: { updatedSeason in
                        if let index = seasons.firstIndex(where: { $0.season == season.season }) {
                            seasons[index] = updatedSeason
                            seasons.sort { $0.season < $1.season }
                        }
                    },
                    onDelete: {
                        seasons.removeAll { $0.season == season.season }
                    }
                )
            }
            .streamifyAlert(
                title: "Delete Series?",
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
    
    private func saveSeries() {
        let genres: [Genre]? = selectedGenres.isEmpty ? nil : selectedGenres.compactMap { Genre(rawValue: $0) }
        
        let updatedSeries = SourceContent(
            id: seriesId,
            title: title,
            description: description,
            type: .series,
            genres: genres,
            thumbnailUrl: thumbnailUrl.isEmpty ? nil : thumbnailUrl,
            posterThumbnailUrl: posterThumbnailUrl.isEmpty ? nil : posterThumbnailUrl,
            fileUrl: nil,
            hlsUrl: nil,
            intro: nil,
            introDuration: nil,
            end: nil,
            seasons: seasons.isEmpty ? nil : seasons,
            episodes: nil,
            subtitles: nil,
            audioTracks: nil,
            embeddedAudioDisabled: false,
            tmdbId: Int(tmdbIdText)
        )
        
        onSave(updatedSeries)
        dismiss()
    }
}

