import SwiftUI
import UniformTypeIdentifiers

struct ImportSourcesView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String = ""
    @State private var importError: String?
    @State private var isImporting: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var sources: [Source] = []
    @State private var showDeleteConfirmation: Bool = false
    @State private var sourceToDelete: Source?

    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "externaldrive.badge.icloud")
                                .font(.system(size: 48))
                                .foregroundStyle(.blue)
                            
                            Text("Manage Sources")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                            
                            Text("Import and manage content sources")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .padding(.top, 24)
                        
                        // Current Sources Section
                        VStack(spacing: 16) {
                            Text("Current Sources")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            if sources.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "tray")
                                        .font(.title)
                                        .foregroundStyle(.gray)
                                    
                                    Text("No sources added yet")
                                        .font(.subheadline)
                                        .foregroundStyle(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                VStack(spacing: 12) {
                                    ForEach(sources) { source in
                                        SourceRowView(
                                            source: source,
                                            onDelete: {
                                                sourceToDelete = source
                                                showDeleteConfirmation = true
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // Import New Section
                        VStack(spacing: 16) {
                            Text("Import New Source")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(spacing: 16) {
                                // URL input
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Source URL")
                                        .font(.subheadline)
                                        .foregroundStyle(.gray)
                                    
                                    TextField("https://example.com/source.json", text: $urlString)
                                        .streamifyTextInput()
                                        .autocapitalization(.none)
                                        .autocorrectionDisabled()
                                        .keyboardType(.URL)
                                }
                                
                                // Error message
                                if let error = importError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .multilineTextAlignment(.center)
                                }
                                
                                // Import from URL button
                                Button {
                                    Task { await importSource() }
                                } label: {
                                    HStack {
                                        if isImporting {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "arrow.down.to.line")
                                        }
                                        Text(isImporting ? "Importing..." : "Import from URL")
                                            .font(.headline)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(urlString.isEmpty || isImporting ? Color.blue.opacity(0.4) : Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .disabled(urlString.isEmpty || isImporting)
                                
                                // Or divider
                                HStack {
                                    VStack { Divider().background(Color.gray) }
                                    Text("or")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                    VStack { Divider().background(Color.gray) }
                                }
                                
                                // Import from file button
                                Button {
                                    showFilePicker = true
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.badge.plus")
                                        Text("Import from File")
                                            .font(.headline)
                                    }
                                    .foregroundStyle(.green)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .fileImporter(
                                    isPresented: $showFilePicker,
                                    allowedContentTypes: [UTType.json, UTType.text],
                                    allowsMultipleSelection: false
                                ) { result in
                                    handleFileImport(result: result)
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 16)
                        
                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Manage Sources")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.blue)
                }
            }
            .onAppear {
                sources = SourcesManager.loadSources()
            }
            .streamifyAlert(
                title: "Delete Source?",
                message: sourceToDelete.map {
                    "Are you sure you want to delete '\($0.name)'? This will remove \($0.movies.count) items from your library."
                } ?? "Are you sure you want to delete this source?",
                isPresented: $showDeleteConfirmation,
                primaryTitle: "Delete",
                secondaryTitle: "Cancel",
                primaryRole: .destructive,
                primaryAction: {
                    if let source = sourceToDelete {
                        deleteSource(source)
                    }
                    sourceToDelete = nil
                },
                secondaryAction: {
                    sourceToDelete = nil
                }
            )
        }
        .preferredColorScheme(.dark)
    }
    
    private func importSource() async {
        isImporting = true
        importError = nil
        
        do {
            _ = try await SourcesManager.addSource(from: urlString)
            await MainActor.run {
                viewModel.loadSources()
                sources = SourcesManager.loadSources()
                urlString = ""
            }
        } catch {
            await MainActor.run {
                importError = error.localizedDescription
            }
        }
        
        await MainActor.run {
            isImporting = false
        }
    }
    
    private func deleteSource(_ source: Source) {
        SourcesManager.deleteSource(source)
        sources = SourcesManager.loadSources()
        viewModel.loadSources()
        viewModel.loadLibrary()
    }
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file"
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            do {
                let data = try Data(contentsOf: url)
                let source = try JSONDecoder().decode(Source.self, from: data)
                SourcesManager.addSource(source)
                
                DispatchQueue.main.async {
                    importError = nil
                    viewModel.loadSources()
                    sources = SourcesManager.loadSources()
                }
            } catch let decodingError as DecodingError {
                DispatchQueue.main.async {
                    importError = "Invalid JSON format: \(decodingError.localizedDescription)"
                }
            } catch {
                DispatchQueue.main.async {
                    importError = "Failed to read file: \(error.localizedDescription)"
                }
            }
            
        case .failure(let error):
            DispatchQueue.main.async {
                importError = "File selection failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Source Row View
struct SourceRowView: View {
    let source: Source
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Text("\(source.movies.count) items")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            
            Spacer()
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
