import SwiftUI
import UIKit

enum StreamifyPickerMotion {
    static let expansion = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.9, blendDuration: 0.05)
    private static let switchDelay: TimeInterval = 0.18

    static func toggle<Value: Equatable>(_ binding: Binding<Value?>, value: Value) {
        let current = binding.wrappedValue

        if current == value {
            withAnimation(expansion) {
                binding.wrappedValue = nil
            }
            return
        }

        if current != nil {
            withAnimation(expansion) {
                binding.wrappedValue = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay) {
                guard binding.wrappedValue == nil else { return }
                withAnimation(expansion) {
                    binding.wrappedValue = value
                }
            }
            return
        }

        withAnimation(expansion) {
            binding.wrappedValue = value
        }
    }
}

struct StreamifyPickerExpandableGroup<Content: View>: View {
    let isExpanded: Bool
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var shouldRenderContent = false
    @State private var collapseToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if shouldRenderContent {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: StreamifyPickerExpandableHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(StreamifyPickerExpandableHeightKey.self) { height in
            contentHeight = height
        }
        .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
        .opacity(isExpanded ? 1 : 0)
        .scaleEffect(y: isExpanded ? 1 : 0.97, anchor: .top)
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(StreamifyPickerMotion.expansion, value: isExpanded)
        .animation(StreamifyPickerMotion.expansion, value: contentHeight)
        .onAppear {
            shouldRenderContent = isExpanded
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                collapseToken = UUID()
                shouldRenderContent = true
            } else {
                let token = UUID()
                collapseToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                    guard collapseToken == token else { return }
                    shouldRenderContent = false
                }
            }
        }
    }
}

private struct StreamifyPickerExpandableHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct StreamifyPickerBatchedForEach<Element, ID: Hashable, Content: View>: View {
    private let data: [Element]
    private let id: KeyPath<Element, ID>
    private let initialCount: Int
    private let batchSize: Int
    private let batchDelayNanoseconds: UInt64
    @ViewBuilder private let content: (Element) -> Content

    @State private var visibleCount = 0

    init(
        _ data: [Element],
        id: KeyPath<Element, ID>,
        initialCount: Int = 16,
        batchSize: Int = 16,
        batchDelayNanoseconds: UInt64 = 10_000_000,
        @ViewBuilder content: @escaping (Element) -> Content
    ) {
        self.data = data
        self.id = id
        self.initialCount = initialCount
        self.batchSize = batchSize
        self.batchDelayNanoseconds = batchDelayNanoseconds
        self.content = content
        _visibleCount = State(initialValue: min(initialCount, data.count))
    }

    var body: some View {
        let firstBatchCount = min(initialCount, data.count)
        let currentVisibleCount = min(max(visibleCount, firstBatchCount), data.count)
        let visibleItems = Array(data.prefix(currentVisibleCount))

        ForEach(visibleItems, id: id) { item in
            content(item)
        }
        .task(id: data.map { $0[keyPath: id] }) {
            await revealRows()
        }
    }

    @MainActor
    private func revealRows() async {
        let total = data.count
        guard total > 0 else {
            visibleCount = 0
            return
        }

        visibleCount = min(initialCount, total)
        while visibleCount < total {
            try? await Task.sleep(nanoseconds: batchDelayNanoseconds)
            guard !Task.isCancelled else { return }
            visibleCount = min(visibleCount + batchSize, total)
        }
    }
}

struct StreamifyPickerShell<Content: View>: View {
    let title: String
    var leadingTitle: String?
    var trailingTitle: String?
    var leadingAction: (() -> Void)?
    var trailingAction: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var hasScrolled = false

    private enum HeaderActionSide {
        case leading
        case trailing

        var alignment: Alignment {
            switch self {
            case .leading:
                return .leading
            case .trailing:
                return .trailing
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let safeInsets = StreamifySafeArea.insets(fallback: proxy.safeAreaInsets)
            VStack(alignment: .leading, spacing: 0) {
                pickerHeader(width: proxy.size.width)
                    .frame(height: 44)
                    .padding(.top, max(safeInsets.top + 14, proxy.size.width > 700 ? 32 : 20))
                    .padding(.bottom, 8)
                    .background(alignment: .bottom) {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(.regularMaterial)
                            .opacity(hasScrolled ? 1 : 0)
                            .ignoresSafeArea(edges: .top)

                        Color(white: 0.16)
                            .opacity(hasScrolled ? 0.82 : 0)
                            .ignoresSafeArea(edges: .top)

                        Rectangle()
                            .fill(Color.white.opacity(hasScrolled ? 0.16 : 0))
                            .frame(height: 1)
                    }
                    .animation(.easeInOut(duration: 0.18), value: hasScrolled)
                }

                ScrollView(showsIndicators: false) {
                    StreamifyPickerScrollObserver(hasScrolled: $hasScrolled)
                    .frame(height: 0)

                    VStack(alignment: .leading, spacing: 12) {
                        content()
                    }
                    .padding(.horizontal, horizontalPadding(for: proxy.size.width))
                    .padding(.bottom, max(safeInsets.bottom + 34, 56))
                }
                .streamifyScrollIndicatorsHidden()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(white: 0.16).opacity(0.72).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func pickerHeader(width: CGFloat) -> some View {
        let actionRail = headerActionRail(for: width)
        let titleClearance = max(actionRail + 94, 120)
        let titleWidth = max(80, width - titleClearance * 2)

        return Color.clear
            .frame(width: width, height: 44)
            .overlay(alignment: .center) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .multilineTextAlignment(.center)
                    .frame(width: titleWidth, height: 44, alignment: .center)
            }
            .overlay(alignment: .leading) {
                headerButton(
                    title: leadingTitle,
                    action: leadingAction,
                    side: .leading,
                    prefersCloseIcon: leadingTitle == "Cancel"
                )
                .padding(.leading, actionRail)
            }
            .overlay(alignment: .trailing) {
                headerButton(
                    title: trailingTitle ?? (leadingAction == nil ? nil : "Done"),
                    action: trailingAction ?? leadingAction,
                    side: .trailing,
                    prefersCloseIcon: true
                )
                .padding(.trailing, actionRail)
            }
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        width > 1200 ? 40 : (width > 700 ? 44 : 22)
    }

    private func headerActionRail(for width: CGFloat) -> CGFloat {
        horizontalPadding(for: width)
    }

    @ViewBuilder
    private func headerButton(
        title: String?,
        action: (() -> Void)?,
        side: HeaderActionSide,
        prefersCloseIcon: Bool
    ) -> some View {
        Group {
            if let title, let action {
                pickerHeaderButton(title: title, action: action, side: side, prefersCloseIcon: prefersCloseIcon)
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
    }

    @ViewBuilder
    private func pickerHeaderButton(
        title: String,
        action: @escaping () -> Void,
        side: HeaderActionSide,
        prefersCloseIcon: Bool
    ) -> some View {
        Button(action: action) {
            Group {
                if prefersCloseIcon && (title == "Done" || title == "Cancel" || title == "Close") {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 44, height: 44, alignment: side.alignment)
                } else {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(minWidth: 44, minHeight: 44, alignment: side.alignment)
                }
            }
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44, alignment: side.alignment)
            .contentShape(Rectangle())
        }
        .frame(minWidth: 44, minHeight: 44, alignment: side.alignment)
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.9))
    }
}

private struct StreamifyPickerScrollObserver: UIViewRepresentable {
    @Binding var hasScrolled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hasScrolled = $hasScrolled
        context.coordinator.attach(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hasScrolled: $hasScrolled)
    }

    final class Coordinator: NSObject {
        var hasScrolled: Binding<Bool>
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?

        init(hasScrolled: Binding<Bool>) {
            self.hasScrolled = hasScrolled
        }

        func attach(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let scrollView = view.streamifyEnclosingScrollView() else { return }
                guard scrollView !== self.scrollView else {
                    self.publish(scrollView)
                    return
                }

                self.scrollView = scrollView
                self.contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] observedScrollView, _ in
                    self?.publish(observedScrollView)
                }
                self.publish(scrollView)
            }
        }

        private func publish(_ scrollView: UIScrollView) {
            let offset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            let next = offset > 3

            if Thread.isMainThread {
                withAnimation(.easeInOut(duration: 0.18)) {
                    hasScrolled.wrappedValue = next
                }
            } else {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.hasScrolled.wrappedValue = next
                    }
                }
            }
        }
    }
}

extension View {
    func streamifyPickerRow(selected: Bool = false, destructive: Bool = false) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? (destructive ? Color.red.opacity(0.15) : Color.white.opacity(0.075))
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func streamifyPickerButtonLabel(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
    }

    func streamifyPickerSectionTitle() -> some View {
        font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    func streamifyPickerDescription() -> some View {
        font(.subheadline)
            .foregroundStyle(StreamifyPopupPalette.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
    }

    func streamifyPickerExpandedItem(indented: Bool = false) -> some View {
        padding(.leading, indented ? 28 : 0)
            .padding(.top, indented ? 2 : 0)
            .padding(.bottom, indented ? 2 : 0)
    }

}
