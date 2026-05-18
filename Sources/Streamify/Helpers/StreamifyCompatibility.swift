import SwiftUI
import UIKit

struct StreamifyNavigationContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct StreamifyFlowLayout<Content: View>: View {
    var spacing: CGFloat = 6
    var minimumItemWidth: CGFloat = 72
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            StreamifyWrappingLayout(spacing: spacing) {
                content()
            }
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: minimumItemWidth), spacing: spacing, alignment: .leading)
                ],
                alignment: .leading,
                spacing: spacing
            ) {
                content()
            }
        }
    }
}

@available(iOS 16.0, *)
struct StreamifyWrappingLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

private struct StreamifyNavigationBarConfigurator: UIViewControllerRepresentable {
    let backgroundColor: UIColor
    let titleColor: UIColor
    let tintColor: UIColor
    let visibleAtScrollEdge: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.backgroundColor = backgroundColor
        controller.titleColor = titleColor
        controller.tintColor = tintColor
        controller.visibleAtScrollEdge = visibleAtScrollEdge
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.backgroundColor = backgroundColor
        uiViewController.titleColor = titleColor
        uiViewController.tintColor = tintColor
        uiViewController.visibleAtScrollEdge = visibleAtScrollEdge
        uiViewController.applyAppearanceWhenReady()
    }

    final class Controller: UIViewController {
        var backgroundColor: UIColor = .black
        var titleColor: UIColor = .white
        var tintColor: UIColor = .white
        var visibleAtScrollEdge = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyAppearanceWhenReady()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyAppearanceWhenReady()
        }

        func applyAppearanceWhenReady() {
            DispatchQueue.main.async { [weak self] in
                self?.applyAppearance()
            }
        }

        private func applyAppearance() {
            guard let navigationBar = navigationController?.navigationBar else { return }

            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = backgroundColor
            appearance.shadowColor = UIColor(white: 1, alpha: 0.1)
            appearance.titleTextAttributes = [.foregroundColor: titleColor]
            appearance.largeTitleTextAttributes = [.foregroundColor: titleColor]

            let scrollEdgeAppearance = UINavigationBarAppearance()
            if visibleAtScrollEdge {
                scrollEdgeAppearance.configureWithOpaqueBackground()
                scrollEdgeAppearance.backgroundColor = backgroundColor
                scrollEdgeAppearance.shadowColor = UIColor(white: 1, alpha: 0.1)
            } else {
                scrollEdgeAppearance.configureWithTransparentBackground()
                scrollEdgeAppearance.backgroundColor = .clear
                scrollEdgeAppearance.shadowColor = .clear
            }
            scrollEdgeAppearance.titleTextAttributes = [.foregroundColor: titleColor]
            scrollEdgeAppearance.largeTitleTextAttributes = [.foregroundColor: titleColor]

            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = scrollEdgeAppearance
            navigationBar.compactAppearance = appearance
            navigationBar.compactScrollEdgeAppearance = visibleAtScrollEdge ? appearance : scrollEdgeAppearance
            navigationBar.tintColor = tintColor
            navigationBar.isTranslucent = !visibleAtScrollEdge
        }
    }
}

private struct StreamifyScrollIndicatorConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView] in
            guard let scrollView = uiView?.streamifyEnclosingScrollView() else { return }
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
        }
    }
}

extension View {
    @ViewBuilder
    func streamifyScrollIndicatorsHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollIndicators(.hidden)
        } else {
            background(StreamifyScrollIndicatorConfigurator().frame(width: 0, height: 0))
        }
    }

    @ViewBuilder
    func streamifyScrollDismissesKeyboardInteractively() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func streamifyPresentationDragIndicatorHidden() -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func streamifyPersistentSystemOverlaysHidden() -> some View {
        if #available(iOS 16.0, *) {
            persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func streamifyNavigationBarHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbar(.hidden, for: .navigationBar)
        } else {
            navigationBarHidden(true)
        }
    }

    @ViewBuilder
    func streamifyTracking(_ value: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            tracking(value)
        } else {
            self
        }
    }

    @ViewBuilder
    func streamifyNavigationBarChrome(
        color: Color = StreamifySurface.navigationBar,
        uiColor: UIColor = UIColor(white: 0.16, alpha: 0.92),
        visibleAtScrollEdge: Bool = false
    ) -> some View {
        if #available(iOS 16.0, *) {
            let base = toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(color, for: .navigationBar)
            if visibleAtScrollEdge {
                base.toolbarBackground(.visible, for: .navigationBar)
            } else {
                base
            }
        } else {
            background(
                StreamifyNavigationBarConfigurator(
                    backgroundColor: uiColor,
                    titleColor: .white,
                    tintColor: .white,
                    visibleAtScrollEdge: visibleAtScrollEdge
                )
                .frame(width: 0, height: 0)
            )
        }
    }
}
