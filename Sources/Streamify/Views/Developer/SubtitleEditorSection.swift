import SwiftUI

// MARK: - Subtitle Editor Section (reusable)
struct SubtitleEditorSection: View {
    @Binding var subtitleTracks: [SubtitleTrack]
    @State private var newLanguage: String = ""
    @State private var newLanguageId: String = ""
    @State private var newUrl: String = ""
    @State private var editingIndex: Int? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Subtitles")
                .font(.headline)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                if subtitleTracks.isEmpty {
                    Text("No subtitles added")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(subtitleTracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            editingIndex = index
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(track.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                        if let sn = track.sourceName, !sn.isEmpty {
                                            SourceBadge(sourceName: sn)
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        Text(track.languageId)
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundStyle(.gray)
                                        Text(track.source)
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                            .lineLimit(1)
                                    }
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                
                Divider().background(Color.gray.opacity(0.3))
                
                // Add new subtitle
                VStack(spacing: 8) {
                    LanguagePickerField(label: "Language", languageId: $newLanguageId, languageName: $newLanguage)
                    
                    TextField("VTT URL (https://...)", text: $newUrl)
                        .streamifyTextInput()
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Button {
                        let langId = newLanguageId.trimmingCharacters(in: .whitespaces)
                        let track = SubtitleTrack(
                            language: newLanguage.trimmingCharacters(in: .whitespaces),
                            source: newUrl.trimmingCharacters(in: .whitespaces),
                            languageId: langId.isEmpty ? nil : langId
                        )
                        subtitleTracks.append(track)
                        newLanguage = ""
                        newLanguageId = ""
                        newUrl = ""
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                            Text("Add Subtitles")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty || newUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    .onChange(of: newLanguage) { newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            let autoId = trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
                            if newLanguageId.isEmpty || newLanguageId == newLanguage.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_") {
                                newLanguageId = autoId
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .sheet(item: Binding<SubtitleEditItem?>(
            get: {
                if let idx = editingIndex, idx < subtitleTracks.count {
                    return SubtitleEditItem(index: idx, track: subtitleTracks[idx])
                }
                return nil
            },
            set: { newVal in
                editingIndex = newVal?.index
            }
        )) { item in
            SubtitleEditView(track: item.track) { updatedTrack in
                if item.index < subtitleTracks.count {
                    subtitleTracks[item.index] = updatedTrack
                }
                editingIndex = nil
            } onDelete: {
                if item.index < subtitleTracks.count {
                    subtitleTracks.remove(at: item.index)
                }
                editingIndex = nil
            }
        }
    }
}

// Helper for sheet item binding
private struct SubtitleEditItem: Identifiable {
    let index: Int
    let track: SubtitleTrack
    var id: String { "\(index)-\(track.trackId)" }
}

// MARK: - Subtitle Edit View
struct SubtitleEditView: View {
    let trackId: String
    @State private var language: String
    @State private var languageId: String
    @State private var url: String
    @State private var sourceName: String
    @Environment(\.dismiss) private var dismiss
    let onSave: (SubtitleTrack) -> Void
    let onDelete: () -> Void
    
    init(track: SubtitleTrack, onSave: @escaping (SubtitleTrack) -> Void, onDelete: @escaping () -> Void) {
        self.trackId = track.trackId
        _language = State(initialValue: track.language)
        _languageId = State(initialValue: track.languageId)
        _url = State(initialValue: track.source)
        _sourceName = State(initialValue: track.sourceName ?? "")
        self.onSave = onSave
        self.onDelete = onDelete
    }
    
    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Track ID (non-editable)
                        VStack(spacing: 8) {
                            Text("Track ID")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(trackId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(spacing: 16) {
                            Text("Language")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            LanguagePickerField(label: "Language", languageId: $languageId, languageName: $language)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(spacing: 16) {
                            Text("URL")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            TextField("VTT URL (https://...)", text: $url)
                                .streamifyTextInput()
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(spacing: 16) {
                            Text("Source Name")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            TextField("Source name (optional)", text: $sourceName)
                                .streamifyTextInput()
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                Text("Delete Subtitle")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Edit Subtitle")
            .navigationBarTitleDisplayMode(.inline)
            .streamifyNavigationBarChrome(color: .black, uiColor: .black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let trimmedLang = language.trimmingCharacters(in: .whitespaces)
                        let trimmedId = languageId.trimmingCharacters(in: .whitespaces)
                        let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
                        guard !trimmedLang.isEmpty, !trimmedUrl.isEmpty else { return }
                        let trimmedSn = sourceName.trimmingCharacters(in: .whitespaces)
                        onSave(SubtitleTrack(language: trimmedLang, source: trimmedUrl, languageId: trimmedId.isEmpty ? nil : trimmedId, trackId: trackId, sourceName: trimmedSn.isEmpty ? nil : trimmedSn))
                        dismiss()
                    }
                    .font(.body.weight(.bold))
                    .disabled(language.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

