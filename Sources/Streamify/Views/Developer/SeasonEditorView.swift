import SwiftUI

// MARK: - Season Editor View
struct SeasonEditorView: View {
    let seasonNumber: Int
    var season: SeasonInfo? = nil
    
    var onSave: (SeasonInfo) -> Void
    var onDelete: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var title: String
    @State private var thumbnailUrl: String
    @State private var episodes: [EpisodeInfo]
    @State private var showDeleteAlert = false
    
    // Navigation state
    @State private var selectedEpisode: EpisodeInfo?
    @State private var showAddEpisode = false
    
    init(seasonNumber: Int, season: SeasonInfo? = nil, onSave: @escaping (SeasonInfo) -> Void, onDelete: (() -> Void)? = nil) {
        self.seasonNumber = seasonNumber
        self.season = season
        self.onSave = onSave
        self.onDelete = onDelete
        
        _title = State(initialValue: season?.title ?? "")
        _thumbnailUrl = State(initialValue: season?.thumbnailUrl ?? "")
        _episodes = State(initialValue: season?.episodes ?? [])
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: season == nil ? "plus.circle.fill" : "tv.and.mediabox")
                            .font(.system(size: 40))
                            .foregroundStyle(season == nil ? .purple : .blue)
                        
                        Text(season == nil ? "New Season" : "Edit Season \(seasonNumber)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)
                    
                    // Season Info Section
                    VStack(spacing: 16) {
                        Text("Season Info")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(spacing: 16) {
                            // Season Number (read-only)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Season Number")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                Text("\(seasonNumber)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            
                            // Title Field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Title")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                TextField("Season \(seasonNumber)", text: $title)
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
                    
                    // Episodes Section
                    VStack(spacing: 16) {
                        Text("Episodes")
                            .font(.headline)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if episodes.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "play.rectangle")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                                
                                Text("No Episodes")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(episodes) { episode in
                                    Button {
                                        selectedEpisode = episode
                                    } label: {
                                        HStack(spacing: 12) {
                                            // Episode number
                                            Text("\(episode.episode)")
                                                .font(.title3.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 32)
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(episode.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                
                                                Text(episode.description)
                                                    .font(.caption)
                                                    .foregroundStyle(.gray)
                                                    .lineLimit(1)
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
                                            episodes.removeAll { $0.episode == episode.episode }
                                        } label: {
                                            Label("Delete Episode", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        
                        // Add Episode Button
                        Button {
                            showAddEpisode = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                Text("Add Episode")
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
                                    Text("Delete Season")
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
            .navigationTitle(season == nil ? "New Season" : "Season \(seasonNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(season == nil ? "Add" : "Save") { saveSeason() }
                        .font(.body.weight(.semibold))
                }
            }
            .sheet(isPresented: $showAddEpisode) {
                EpisodeEditorSheet(
                    seasonNumber: seasonNumber,
                    episodeNumber: (episodes.map { $0.episode }.max() ?? 0) + 1,
                    onSave: { newEpisode in
                        episodes.append(newEpisode)
                        episodes.sort { $0.episode < $1.episode }
                    }
                )
            }
            .sheet(item: $selectedEpisode) { episode in
                EpisodeEditorSheet(
                    seasonNumber: seasonNumber,
                    episodeNumber: episode.episode,
                    episode: episode,
                    onSave: { updatedEpisode in
                        if let index = episodes.firstIndex(where: { $0.episode == episode.episode }) {
                            episodes[index] = updatedEpisode
                            episodes.sort { $0.episode < $1.episode }
                        }
                    },
                    onDelete: {
                        episodes.removeAll { $0.episode == episode.episode }
                    }
                )
            }
            .streamifyAlert(
                title: "Delete Season?",
                message: "Are you sure you want to delete this season and all its episodes?",
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
    
    private func saveSeason() {
        let updatedSeason = SeasonInfo(
            season: seasonNumber,
            title: title.isEmpty ? nil : title,
            thumbnailUrl: thumbnailUrl.isEmpty ? nil : thumbnailUrl,
            episodes: episodes.isEmpty ? nil : episodes
        )
        
        onSave(updatedSeason)
        dismiss()
    }
}

