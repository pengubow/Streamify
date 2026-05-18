import SwiftUI

// MARK: - Developer View (Modern Settings-like UI)
struct DeveloperView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [Source] = []
    @State private var sourceReferences: [SourceReference] = []
    @State private var selectedSource: Source?
    @State private var showAddSourceSheet = false
    @State private var showOnboarding = false

    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                StreamifyPageBackground()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)

                            Text("Developer Tools")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)

                            Text("Edit sources and content")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .padding(.top, 24)

                        // Sources Section
                        VStack(spacing: 16) {
                            DeveloperSectionHeader("Sources")

                            VStack(spacing: 12) {
                                ForEach(sources) { source in
                                    SourceCardView(
                                        source: source,
                                        onTap: { selectedSource = source },
                                        onDelete: { deleteSource(source) }
                                    )
                                }

                                // Add Source Button
                                DeveloperAddButton(title: "Add Source", tint: .green) {
                                    showAddSourceSheet = true
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        // Quick Actions Section
                        VStack(spacing: 16) {
                            DeveloperSectionHeader("Quick Actions")

                            VStack(spacing: 12) {
                                DeveloperActionRow(
                                    icon: "arrow.clockwise",
                                    title: "Refresh All Sources",
                                    subtitle: "Reload content from all sources",
                                    tint: .orange
                                ) {
                                    Task {
                                        await viewModel.refreshSources()
                                        sources = SourcesManager.loadSources()
                                    }
                                }

                                DeveloperActionRow(
                                    icon: "clock.arrow.circlepath",
                                    title: "Clear Watch Progress",
                                    subtitle: "Reset progress for all content",
                                    tint: .red
                                ) {
                                    WatchingProgressManager.clear()
                                    viewModel.loadLibrary()
                                }

                                DeveloperActionRow(
                                    icon: "doc.on.clipboard",
                                    title: "Copy Library JSON",
                                    subtitle: "Copy library data to clipboard",
                                    tint: .blue
                                ) {
                                    let library = ContentImportService.loadLibrary()
                                    if let data = try? JSONEncoder().encode(library),
                                       let json = String(data: data, encoding: .utf8) {
                                        UIPasteboard.general.string = json
                                    }
                                }

                                DeveloperActionRow(
                                    icon: "sparkles",
                                    title: "Add Sample Source",
                                    subtitle: "Add demo content for testing",
                                    tint: .purple
                                ) {
                                    viewModel.addSampleSource()
                                    sources = SourcesManager.loadSources()
                                }

                                DeveloperActionRow(
                                    icon: "person.crop.circle.badge.checkmark",
                                    title: "Run Onboarding",
                                    subtitle: "Reopen first-run language, genre, and source setup",
                                    tint: .green
                                ) {
                                    showOnboarding = true
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        // Debug Info Section
                        VStack(spacing: 16) {
                            DeveloperSectionHeader("Debug Info")

                            VStack(spacing: 0) {
                                debugRow(title: "Library Items", value: "\(viewModel.library.count)")
                                Divider().background(Color.gray.opacity(0.3))
                                debugRow(title: "Sources", value: "\(sources.count)")
                                Divider().background(Color.gray.opacity(0.3))
                                debugRow(title: "Watch Progress", value: "\(WatchingProgressManager.load().count)")
                                Divider().background(Color.gray.opacity(0.3))
                                debugRow(title: "Content Directory", value: ContentImportService.contentDirectoryURL.lastPathComponent)
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Developer Tools")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.blue)
                }
            }
            .sheet(isPresented: $showAddSourceSheet) {
                AddSourceSheet(viewModel: viewModel, onAdded: {
                    sources = SourcesManager.loadSources()
                    sourceReferences = SourcesManager.loadSourceReferences()
                })
            }
            .sheet(item: $selectedSource) { source in
                let isLocal = sourceReferences.first(where: { $0.id == source.id })?.isLocal ?? true
                SourceEditorView(source: source, isLocal: isLocal, viewModel: viewModel, onUpdated: {
                    sources = SourcesManager.loadSources()
                    sourceReferences = SourcesManager.loadSourceReferences()
                })
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                StreamifyOnboardingView {
                    showOnboarding = false
                }
                .interactiveDismissDisabled()
            }
            .onAppear {
                sources = SourcesManager.loadSources()
                sourceReferences = SourcesManager.loadSourceReferences()
                viewModel.loadSources()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func debugRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
    }

    private func deleteSource(_ source: Source) {
        SourcesManager.deleteSource(source)
        sources = SourcesManager.loadSources()
        sourceReferences = SourcesManager.loadSourceReferences()
        viewModel.loadSources()
    }
}

// MARK: - Source Card View
struct SourceCardView: View {
    let source: Source
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                StreamifyIconWell(icon: "folder.fill", tint: .blue)

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

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding(14)
            .streamifyPanel(cornerRadius: 10)
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Source", systemImage: "trash")
            }
        }
    }
}
