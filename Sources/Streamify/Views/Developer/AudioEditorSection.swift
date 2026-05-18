import SwiftUI

// MARK: - Audio Track Editor Section (reusable)
struct AudioEditorSection: View {
    @Binding var audioTracks: [AudioTrack]
    @State private var newLanguage: String = ""
    @State private var newLanguageId: String = ""
    @State private var newUrl: String = ""
    @State private var newIsEmbedded: Bool = false
    @State private var newIsSpatial: Bool = false
    @State private var editingIndex: Int? = nil
    @State private var hlsImportUrl: String = ""
    @State private var isImportingHLS: Bool = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Audio Tracks")
                .font(.headline)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                if audioTracks.isEmpty {
                    Text("No audio tracks added")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(audioTracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            editingIndex = index
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(track.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                        if track.isSpatial {
                                            SpatialAudioBadge(isSpatial: true)
                                        }
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
                                        Text(track.isEmbedded ? "Embedded" : track.source)
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
                
                // Add new audio track
                VStack(spacing: 8) {
                    LanguagePickerField(label: "Language", languageId: $newLanguageId, languageName: $newLanguage)
                    
                    Toggle("Embedded (from video)", isOn: $newIsEmbedded)
                        .font(.subheadline)
                        .tint(.purple)
                    
                    if !newIsEmbedded {
                        TextField("HLS m3u8 URL (https://...)", text: $newUrl)
                            .streamifyTextInput()
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                    
                    Toggle("Spatial", isOn: $newIsSpatial)
                        .font(.subheadline)
                        .tint(.orange)
                    
                    Button {
                        let source = newIsEmbedded ? "" : newUrl.trimmingCharacters(in: .whitespaces)
                        let langId = newLanguageId.trimmingCharacters(in: .whitespaces)
                        let track = AudioTrack(
                            language: newLanguage.trimmingCharacters(in: .whitespaces),
                            source: source,
                            isSpatial: newIsSpatial,
                            languageId: langId.isEmpty ? nil : langId
                        )
                        audioTracks.append(track)
                        newLanguage = ""
                        newLanguageId = ""
                        newUrl = ""
                        newIsEmbedded = false
                        newIsSpatial = false
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                            Text("Add Audio Track")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    // Import audio tracks from HLS master m3u8
                    VStack(spacing: 8) {
                        Text("Import from HLS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        TextField("Master m3u8 URL", text: $hlsImportUrl)
                            .streamifyTextInput()
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        Button {
                            guard let url = URL(string: hlsImportUrl.trimmingCharacters(in: .whitespaces)) else { return }
                            isImportingHLS = true
                            Task {
                                let renditions = await PlayerViewModel.parseHLSAudioRenditions(from: url).renditions
                                await MainActor.run {
                                    let existingKeys = Set(audioTracks.map { "\($0.languageId)_\($0.displayName)" })
                                    for rendition in renditions {
                                        let track = rendition.toAudioTrack(hlsBaseUrl: url.absoluteString)
                                        let key = "\(track.languageId)_\(track.displayName)"
                                        if !existingKeys.contains(key) {
                                            audioTracks.append(track)
                                        }
                                    }
                                    hlsImportUrl = ""
                                    isImportingHLS = false
                                }
                            }
                        } label: {
                            HStack {
                                if isImportingHLS {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption)
                                }
                                Text("Import Audio Tracks")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .disabled(hlsImportUrl.trimmingCharacters(in: .whitespaces).isEmpty || isImportingHLS)
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .sheet(item: Binding<AudioEditItem?>(
            get: {
                if let idx = editingIndex, idx < audioTracks.count {
                    return AudioEditItem(index: idx, track: audioTracks[idx])
                }
                return nil
            },
            set: { newVal in
                editingIndex = newVal?.index
            }
        )) { item in
            AudioEditView(track: item.track) { updatedTrack in
                if item.index < audioTracks.count {
                    audioTracks[item.index] = updatedTrack
                }
                editingIndex = nil
            } onDelete: {
                if item.index < audioTracks.count {
                    audioTracks.remove(at: item.index)
                }
                editingIndex = nil
            }
        }
    }
}

private struct AudioEditItem: Identifiable {
    let index: Int
    let track: AudioTrack
    var id: String { "\(index)-\(track.trackId)" }
}

// MARK: - Audio Edit View
struct AudioEditView: View {
    let trackId: String
    @State private var language: String
    @State private var languageId: String
    @State private var url: String
    @State private var isEmbedded: Bool
    @State private var isSpatial: Bool
    @State private var sourceName: String
    @Environment(\.dismiss) private var dismiss
    let onSave: (AudioTrack) -> Void
    let onDelete: () -> Void
    
    init(track: AudioTrack, onSave: @escaping (AudioTrack) -> Void, onDelete: @escaping () -> Void) {
        self.trackId = track.trackId
        _language = State(initialValue: track.language)
        _languageId = State(initialValue: track.languageId)
        _url = State(initialValue: track.source)
        _isEmbedded = State(initialValue: track.isEmbedded)
        _isSpatial = State(initialValue: track.isSpatial)
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
                            Text("Source")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Toggle("Embedded (from video)", isOn: $isEmbedded)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .tint(.purple)
                            
                            if !isEmbedded {
                                TextField("HLS m3u8 URL (https://...)", text: $url)
                                    .streamifyTextInput()
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(spacing: 16) {
                            Text("Properties")
                                .font(.headline)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Toggle("Spatial", isOn: $isSpatial)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .tint(.orange)
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
                                Text("Delete Audio Track")
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
            .navigationTitle("Edit Audio Track")
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
                        guard !trimmedLang.isEmpty else { return }
                        let source = isEmbedded ? "" : url.trimmingCharacters(in: .whitespaces)
                        let trimmedSn = sourceName.trimmingCharacters(in: .whitespaces)
                        onSave(AudioTrack(language: trimmedLang, source: source, isSpatial: isSpatial, languageId: trimmedId.isEmpty ? nil : trimmedId, trackId: trackId, sourceName: trimmedSn.isEmpty ? nil : trimmedSn))
                        dismiss()
                    }
                    .font(.body.weight(.bold))
                    .disabled(language.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

