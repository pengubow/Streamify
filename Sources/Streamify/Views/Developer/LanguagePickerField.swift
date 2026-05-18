import SwiftUI

// MARK: - Language Picker Field (reusable)
/// A picker that shows language names but saves the ISO 639-1 language code.
struct LanguagePickerField: View {
    let label: String
    @Binding var languageId: String
    @Binding var languageName: String
    
    @State private var showPicker: Bool = false
    
    /// Display text for the current selection.
    private var displayText: String {
        if languageName.isEmpty && languageId.isEmpty {
            return "Select language..."
        }
        if !languageName.isEmpty {
            return languageName
        }
        return languageId
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button {
                showPicker = true
            } label: {
                HStack {
                    Text(displayText)
                        .foregroundStyle(languageName.isEmpty && languageId.isEmpty ? .gray : .white)
                    Spacer()
                    if !languageId.isEmpty {
                        Text(languageId)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .streamifyBottomPopup(isPresented: $showPicker) {
            SingleLanguagePickerSheet(
                selectedCode: $languageId,
                selectedName: $languageName,
                onDismiss: {
                    showPicker = false
                }
            )
        }
    }
}

