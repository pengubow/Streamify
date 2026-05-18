import SwiftUI

// MARK: - Source Editor View
struct SourceEditorView: View {
    let source: Source
    let isLocal: Bool
    let viewModel: LibraryViewModel
    let onUpdated: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var sourceId: String = ""
    @State private var sourceName: String = ""
    @State private var movies: [SourceContent] = []
    @State private var selectedMovie: SourceContent?
    @State private var selectedSeries: SourceContent?
    @State private var showAddMovie = false
    @State private var showAddSeries = false
    @State private var showDeleteSourceAlert = false
    @State private var searchText: String = ""
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    private var moviesOnly: [SourceContent] {
        let all = movies.filter { $0.type == .movie }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
    
    private var seriesOnly: [SourceContent] {
        let all = movies.filter { $0.type == .series }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Source Info Section
                        VStack(spacing: 16) {
                            Text("Source Info")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(spacing: 16) {
                                if isLocal {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 4) {
                                            Text("ID")
                                                .font(.subheadline)
                                                .foregroundStyle(.white)
                                            Text("*")
                                                .font(.subheadline)
                                                .foregroundStyle(.red)
                                        }
                                        TextField("source-id", text: $sourceId)
                                            .streamifyTextInput()
                                            .autocapitalization(.none)
                                            .autocorrectionDisabled()
                                    }
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 4) {
                                        Text("Name")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Text("*")
                                            .font(.subheadline)
                                            .foregroundStyle(.red)
                                    }
                                    TextField("Source Name", text: $sourceName)
                                        .streamifyTextInput()
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        
                        // Search bar
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.gray)
                            
                            TextField("Search content...", text: $searchText)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                            
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.gray)
                                }
                            }
                        }
                        .streamifyTextInput()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        
                        // Movies Section
                        VStack(spacing: 12) {
                            Text("Movies")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                            
                            if moviesOnly.isEmpty {
                                // Empty state for movies
                                VStack(spacing: 8) {
                                    Image(systemName: "film")
                                        .font(.title)
                                        .foregroundStyle(.gray)
                                    
                                    Text("No Movies")
                                        .font(.subheadline)
                                        .foregroundStyle(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 16)
                            } else {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(moviesOnly) { movie in
                                        Button {
                                            selectedMovie = movie
                                        } label: {
                                            SourceMovieGridCard(movie: movie)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                deleteMovie(movie)
                                            } label: {
                                                Label("Delete Movie", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            
                            // Add Movie Button
                            Button {
                                showAddMovie = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                    Text("Add Movie")
                                        .font(.headline)
                                }
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 16)
                        
                        // Series Section
                        VStack(spacing: 12) {
                            Text("Series")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                            
                            if seriesOnly.isEmpty {
                                // Empty state for series
                                VStack(spacing: 8) {
                                    Image(systemName: "tv")
                                        .font(.title)
                                        .foregroundStyle(.gray)
                                    
                                    Text("No Series")
                                        .font(.subheadline)
                                        .foregroundStyle(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 16)
                            } else {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(seriesOnly) { series in
                                        Button {
                                            selectedSeries = series
                                        } label: {
                                            SourceSeriesGridCard(series: series)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                deleteMovie(series)
                                            } label: {
                                                Label("Delete Series", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            
                            // Add Series Button
                            Button {
                                showAddSeries = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                    Text("Add Series")
                                        .font(.headline)
                                }
                                .foregroundStyle(.purple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.purple.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 8)
                        
                        // Delete Source
                        Button {
                            showDeleteSourceAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                Text("Delete Source")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        
                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle(sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.blue)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(moviesOnly.count) movies")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .sheet(isPresented: $showAddMovie) {
                MovieEditorSheet(
                    source: Source(id: sourceId, name: sourceName, movies: movies),
                    viewModel: viewModel,
                    onSave: { newMovie in
                        movies.append(newMovie)
                        saveSource()
                    }
                )
            }
            .sheet(item: $selectedMovie) { movie in
                MovieEditorSheet(
                    source: Source(id: sourceId, name: sourceName, movies: movies),
                    movie: movie,
                    viewModel: viewModel,
                    onSave: { updatedMovie in
                        if let index = movies.firstIndex(where: { $0.id == movie.id }) {
                            movies[index] = updatedMovie
                            saveSource()
                        }
                    },
                    onDelete: {
                        deleteMovie(movie)
                    }
                )
            }
            .sheet(isPresented: $showAddSeries) {
                SeriesEditorSheet(
                    source: Source(id: sourceId, name: sourceName, movies: movies),
                    viewModel: viewModel,
                    onSave: { newSeries in
                        movies.append(newSeries)
                        saveSource()
                    }
                )
            }
            .sheet(item: $selectedSeries) { series in
                SeriesEditorSheet(
                    source: Source(id: sourceId, name: sourceName, movies: movies),
                    series: series,
                    viewModel: viewModel,
                    onSave: { updatedSeries in
                        if let index = movies.firstIndex(where: { $0.id == series.id }) {
                            movies[index] = updatedSeries
                            saveSource()
                        }
                    },
                    onDelete: {
                        deleteMovie(series)
                    }
                )
            }
            .streamifyAlert(
                title: "Delete Source?",
                message: "This will delete '\(sourceName)' and all its content. This cannot be undone.",
                isPresented: $showDeleteSourceAlert,
                primaryTitle: "Delete",
                secondaryTitle: "Cancel",
                primaryRole: .destructive,
                primaryAction: {
                    SourcesManager.deleteSource(Source(id: sourceId, name: sourceName, movies: movies))
                    onUpdated()
                    dismiss()
                }
            )
            .onAppear {
                sourceId = source.id
                sourceName = source.name
                movies = source.movies
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func saveSource() {
        // If id changed, remove the old source first
        if sourceId != source.id {
            SourcesManager.removeSource(source)
        }
        let updatedSource = Source(id: sourceId, name: sourceName, movies: movies)
        SourcesManager.addSource(updatedSource, isLocal: isLocal)
        viewModel.loadSources()
        onUpdated()
    }
    
    private func deleteMovie(_ movie: SourceContent) {
        movies.removeAll { $0.id == movie.id }
        saveSource()
    }
}

