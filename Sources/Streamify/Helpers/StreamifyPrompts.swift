import SwiftUI

enum StreamifyPromptRole {
    case normal
    case destructive
}

struct StreamifyGrayBlurBackdrop: View {
    var darkOpacity: Double = 0.44
    var grayOpacity: Double = 0.88

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(Color(white: 0.16).opacity(grayOpacity))
            .overlay(Color.black.opacity(darkOpacity))
            .ignoresSafeArea()
    }
}

struct StreamifyCenteredPrompt: View {
    let title: String
    let message: String
    let primaryTitle: String
    var secondaryTitle: String?
    var primaryRole: StreamifyPromptRole = .normal
    let primaryAction: () -> Void
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(StreamifyPromptButtonStyle(variant: .secondary))
                }

                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(StreamifyPromptButtonStyle(
                        variant: primaryRole == .destructive ? .destructive : .primary
                    ))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: 420)
        .streamifyPromptPanel()
    }
}

private struct StreamifyPromptButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
    }

    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .frame(minWidth: 118)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.78, blendDuration: 0.04), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return .black
        case .secondary, .destructive:
            return .white
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary:
            return .white
        case .secondary:
            return .white.opacity(0.14)
        case .destructive:
            return .red.opacity(0.82)
        }
    }
}

private struct StreamifyAlertPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let primaryTitle: String
    let secondaryTitle: String?
    let primaryRole: StreamifyPromptRole
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .streamifyCenteredPopup(isPresented: $isPresented, dismissOnBackdrop: false) {
                StreamifyCenteredPrompt(
                    title: title,
                    message: message,
                    primaryTitle: primaryTitle,
                    secondaryTitle: secondaryTitle,
                    primaryRole: primaryRole,
                    primaryAction: {
                        isPresented = false
                        primaryAction()
                    },
                    secondaryAction: secondaryTitle == nil ? nil : {
                        isPresented = false
                        secondaryAction?()
                    }
                )
            }
    }
}

extension View {
    func streamifyAlert(
        title: String,
        message: String,
        isPresented: Binding<Bool>,
        primaryTitle: String = "OK",
        secondaryTitle: String? = nil,
        primaryRole: StreamifyPromptRole = .normal,
        primaryAction: @escaping () -> Void = {},
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        modifier(StreamifyAlertPresenter(
            isPresented: isPresented,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            primaryRole: primaryRole,
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        ))
    }

    func streamifyPromptPanel(cornerRadius: CGFloat = 12) -> some View {
        background(Color(white: 0.16).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(0.42)
            }
    }
}
