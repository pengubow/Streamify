import SwiftUI
import UIKit

enum StreamifyPopupStyle {
    case center
    case bottom
}

enum StreamifyPopupPalette {
    static let surface = Color(red: 0.018, green: 0.019, blue: 0.023)
    static let raisedSurface = Color(red: 0.032, green: 0.034, blue: 0.041)
    static let selectedSurface = Color.white.opacity(0.12)
    static let rowSurface = Color.white.opacity(0.045)
    static let rowPressedSurface = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.11)
    static let secondaryText = Color.white.opacity(0.62)
}

struct StreamifyPressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.78, blendDuration: 0.04), value: configuration.isPressed)
    }
}

@MainActor
private final class StreamifyPopupCoordinator: ObservableObject {
    static let shared = StreamifyPopupCoordinator()

    @Published private(set) var stack: [UUID] = []

    var topID: UUID? {
        stack.last
    }

    func present(_ id: UUID) {
        stack.removeAll { $0 == id }
        stack.append(id)
    }

    func dismiss(_ id: UUID) {
        stack.removeAll { $0 == id }
    }
}

private struct StreamifyPopupLayer<PopupContent: View>: View {
    @Binding var isPresented: Bool
    let style: StreamifyPopupStyle
    let dismissOnBackdrop: Bool
    @ViewBuilder let popupContent: () -> PopupContent

    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            if isPresented || isVisible {
                ZStack(alignment: alignment) {
                    backdrop
                        .opacity(isVisible ? 1 : 0)
                    popup(in: proxy)
                        .opacity(isVisible ? 1 : 0)
                        .scaleEffect(isVisible ? 1 : hiddenScale)
                        .offset(y: isVisible ? 0 : hiddenYOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(presentationAnimation, value: isVisible)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard isPresented else { return }
            isVisible = false
            DispatchQueue.main.async {
                withAnimation(presentationAnimation) {
                    isVisible = true
                }
            }
        }
        .onChange(of: isPresented) { presented in
            withAnimation(presentationAnimation) {
                isVisible = presented
            }
        }
    }

    private var backdrop: some View {
        Group {
            switch style {
            case .center:
                StreamifyGrayBlurBackdrop()
            case .bottom:
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(Color(white: 0.16).opacity(0.66))
                    .overlay(Color.black.opacity(0.62))
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            guard dismissOnBackdrop else { return }
            dismiss()
        }
    }

    private var presentationAnimation: Animation {
        .interactiveSpring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.06)
    }

    private var hiddenScale: CGFloat {
        switch style {
        case .center: return 0.96
        case .bottom: return 1
        }
    }

    private var hiddenYOffset: CGFloat {
        switch style {
        case .center: return 0
        case .bottom: return 0
        }
    }

    private var alignment: Alignment {
        switch style {
        case .center:
            return .center
        case .bottom:
            return .bottom
        }
    }

    @ViewBuilder
    private func popup(in proxy: GeometryProxy) -> some View {
        switch style {
        case .center:
            popupContent()
                .preferredColorScheme(.dark)
                .tint(.white)
                .frame(maxWidth: min(proxy.size.width - 32, 430))
                .shadow(color: .black.opacity(0.68), radius: 30, x: 0, y: 14)
                .padding(.horizontal, 16)

        case .bottom:
            popupContent()
                .preferredColorScheme(.dark)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        }
    }

    private func dismiss() {
        withAnimation(presentationAnimation) {
            isPresented = false
        }
    }
}

private struct StreamifyPopupPresenter<PopupContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let style: StreamifyPopupStyle
    let dismissOnBackdrop: Bool
    @ViewBuilder let popupContent: () -> PopupContent

    @ObservedObject private var coordinator = StreamifyPopupCoordinator.shared
    @State private var popupID = UUID()

    func body(content: Content) -> some View {
        content
            .background {
                StreamifyPopupWindowHost(
                    isPresented: Binding(
                        get: { isPresented && coordinator.topID == popupID },
                        set: { presented in
                            if !presented {
                                isPresented = false
                            }
                        }
                    ),
                    style: style,
                    dismissOnBackdrop: dismissOnBackdrop,
                    popupContent: popupContent
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onAppear {
                if isPresented {
                    coordinator.present(popupID)
                }
            }
            .onDisappear {
                coordinator.dismiss(popupID)
            }
            .onChange(of: isPresented) { presented in
                if presented {
                    coordinator.present(popupID)
                } else {
                    coordinator.dismiss(popupID)
                }
            }
    }
}

private struct StreamifyPopupWindowHost<PopupContent: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let style: StreamifyPopupStyle
    let dismissOnBackdrop: Bool
    @ViewBuilder let popupContent: () -> PopupContent

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let rootView = AnyView(
            StreamifyPopupLayer(
                isPresented: $isPresented,
                style: style,
                dismissOnBackdrop: dismissOnBackdrop,
                popupContent: popupContent
            )
        )
        context.coordinator.update(from: uiView, isPresented: isPresented, rootView: rootView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.dismissWindow()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var window: UIWindow?
        private var hostingController: UIHostingController<AnyView>?
        private var dismissalWork: DispatchWorkItem?

        func update(from hostView: UIView, isPresented: Bool, rootView: AnyView) {
            guard isPresented else {
                guard window != nil else { return }
                hostingController?.rootView = rootView
                window?.isUserInteractionEnabled = false
                guard dismissalWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    self?.dismissWindow()
                }
                dismissalWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: work)
                return
            }

            dismissalWork?.cancel()
            dismissalWork = nil

            guard let scene = hostView.window?.windowScene ?? activeWindowScene else {
                DispatchQueue.main.async { [weak self, weak hostView] in
                    guard let self, let hostView else { return }
                    self.update(from: hostView, isPresented: isPresented, rootView: rootView)
                }
                return
            }

            if window?.windowScene !== scene {
                dismissWindow()
            }

            if window == nil {
                let controller = UIHostingController(rootView: rootView)
                controller.view.backgroundColor = .clear
                controller.view.isOpaque = false

                let overlayWindow = UIWindow(windowScene: scene)
                overlayWindow.backgroundColor = .clear
                overlayWindow.isOpaque = false
                overlayWindow.isUserInteractionEnabled = true
                overlayWindow.windowLevel = .alert + 20
                overlayWindow.rootViewController = controller
                overlayWindow.isHidden = false

                hostingController = controller
                window = overlayWindow
            } else {
                hostingController?.rootView = rootView
                window?.isUserInteractionEnabled = true
                window?.isHidden = false
            }
        }

        func dismissWindow() {
            dismissalWork?.cancel()
            dismissalWork = nil
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
            hostingController = nil
        }

        private var activeWindowScene: UIWindowScene? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        }
    }
}

private struct StreamifyItemPopupPresenter<Item: Identifiable, PopupContent: View>: ViewModifier {
    @Binding var item: Item?
    let style: StreamifyPopupStyle
    let dismissOnBackdrop: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder let popupContent: (Item) -> PopupContent
    @State private var wasPresented = false

    func body(content: Content) -> some View {
        content
            .streamifyPopup(
                isPresented: Binding(
                    get: { item != nil },
                    set: { presented in
                        if !presented {
                            item = nil
                        }
                    }
                ),
                style: style,
                dismissOnBackdrop: dismissOnBackdrop
            ) {
                Group {
                    if let item {
                        popupContent(item)
                    }
                }
            }
            .onAppear {
                wasPresented = item != nil
            }
            .onChange(of: item?.id) { newID in
                let isPresentedNow = newID != nil
                if wasPresented && !isPresentedNow {
                    onDismiss?()
                }
                wasPresented = isPresentedNow
            }
    }
}

extension View {
    func streamifyPopup<PopupContent: View>(
        isPresented: Binding<Bool>,
        style: StreamifyPopupStyle,
        dismissOnBackdrop: Bool = true,
        @ViewBuilder content: @escaping () -> PopupContent
    ) -> some View {
        modifier(StreamifyPopupPresenter(
            isPresented: isPresented,
            style: style,
            dismissOnBackdrop: dismissOnBackdrop,
            popupContent: content
        ))
    }

    func streamifyBottomPopup<PopupContent: View>(
        isPresented: Binding<Bool>,
        dismissOnBackdrop: Bool = true,
        @ViewBuilder content: @escaping () -> PopupContent
    ) -> some View {
        streamifyPopup(
            isPresented: isPresented,
            style: .bottom,
            dismissOnBackdrop: dismissOnBackdrop,
            content: content
        )
    }

    func streamifyCenteredPopup<PopupContent: View>(
        isPresented: Binding<Bool>,
        dismissOnBackdrop: Bool = true,
        @ViewBuilder content: @escaping () -> PopupContent
    ) -> some View {
        streamifyPopup(
            isPresented: isPresented,
            style: .center,
            dismissOnBackdrop: dismissOnBackdrop,
            content: content
        )
    }

    func streamifyBottomPopup<Item: Identifiable, PopupContent: View>(
        item: Binding<Item?>,
        dismissOnBackdrop: Bool = true,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> PopupContent
    ) -> some View {
        modifier(StreamifyItemPopupPresenter(
            item: item,
            style: .bottom,
            dismissOnBackdrop: dismissOnBackdrop,
            onDismiss: onDismiss,
            popupContent: content
        ))
    }

}
