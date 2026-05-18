import SwiftUI

// MARK: - Add Source Sheet
struct AddSourceSheet: View {
    let viewModel: LibraryViewModel
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var sourceId: String = ""
    @State private var sourceName: String = ""
    @State private var errorMessage: String?

    private enum Field {
        case sourceId
        case sourceName
    }

    var body: some View {
        ZStack(alignment: .top) {
            StreamifyPageBackground()

            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        StreamifyIconWell(icon: "plus.rectangle.on.folder.fill", tint: .green)
                            .padding(.top, 28)

                        VStack(spacing: 6) {
                            Text("New Source")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)

                            Text("Create a source for movies and series")
                                .font(.subheadline)
                                .foregroundStyle(StreamifySurface.mutedText)
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 14) {
                            sourceInput(
                                title: "Source Name",
                                text: $sourceName,
                                field: .sourceName
                            )

                            sourceInput(
                                title: "ID",
                                text: $sourceId,
                                field: .sourceId,
                                autocapitalizationDisabled: true
                            )

                            if let error = errorMessage {
                                Text(error)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(14)
                        .streamifyPanel(cornerRadius: 10)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: sourceName) { newName in
            // Auto-generate ID from name if user hasn't manually edited the ID.
            let trimmedName = newName.trimmingCharacters(in: .whitespaces)
            if !trimmedName.isEmpty {
                let autoId = trimmedName.lowercased().replacingOccurrences(of: " ", with: "-")
                if sourceId.isEmpty || sourceId == sourceName.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-") {
                    sourceId = autoId
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 72, height: 44, alignment: .leading)
            }
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.9))

            Spacer()

            Text("New Source")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            Spacer()

            Button("Create") {
                createSource()
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(canCreate ? .white : StreamifySurface.mutedText)
            .frame(width: 72, height: 44, alignment: .trailing)
            .disabled(!canCreate)
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.94))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            StreamifyBarMaterial(edges: .top)
        }
        .overlay(alignment: .bottom) {
            StreamifyBarHairline()
        }
    }

    private func sourceInput(
        title: String,
        text: Binding<String>,
        field: Field,
        autocapitalizationDisabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            TextField("", text: text)
                .focused($focusedField, equals: field)
                .streamifyTextInput(isFocused: focusedField == field)
                .autocorrectionDisabled()
                .textInputAutocapitalization(autocapitalizationDisabled ? .never : .words)
        }
    }

    private var canCreate: Bool {
        !sourceName.trimmingCharacters(in: .whitespaces).isEmpty &&
            !sourceId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func createSource() {
        let trimmedName = sourceName.trimmingCharacters(in: .whitespaces)
        let trimmedId = sourceId.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "Source name cannot be empty."
            return
        }
        guard !trimmedId.isEmpty else {
            errorMessage = "Source ID cannot be empty."
            return
        }
        
        // Check for duplicate source ids
        let existingSources = SourcesManager.loadSources()
        if existingSources.contains(where: { $0.id == trimmedId }) {
            errorMessage = "A source with this ID already exists."
            return
        }
        
        let newSource = Source(id: trimmedId, name: trimmedName, movies: [])
        SourcesManager.addSource(newSource)
        viewModel.loadSources()
        onAdded()
        dismiss()
    }
}

