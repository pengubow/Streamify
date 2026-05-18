import SwiftUI

struct StreamifyTextInputStyle: ViewModifier {
    var minHeight: CGFloat = 44
    var isFocused: Bool = false
    @FocusState private var locallyFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .tint(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($locallyFocused)
            .padding(.horizontal, 12)
            .frame(minHeight: minHeight)
            .background(StreamifyPopupPalette.rowSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity((isFocused || locallyFocused) ? 0.34 : 0.11), lineWidth: 1)
            }
    }
}

extension View {
    func streamifyTextInput(minHeight: CGFloat = 44, isFocused: Bool = false) -> some View {
        modifier(StreamifyTextInputStyle(minHeight: minHeight, isFocused: isFocused))
    }
}
