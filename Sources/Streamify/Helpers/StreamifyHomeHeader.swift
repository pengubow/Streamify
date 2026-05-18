import SwiftUI
import UIKit

struct StreamifyHomeHeaderView: UIViewRepresentable {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @Binding var isFieldFocused: Bool
    var topInset: CGFloat
    var backdropColor: UIColor?
    var verticalOffset: CGFloat = 0

    func makeUIView(context: Context) -> StreamifyHomeHeaderUIView {
        let view = StreamifyHomeHeaderUIView()
        view.connect(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: StreamifyHomeHeaderUIView, context: Context) {
        context.coordinator.searchText = $searchText
        context.coordinator.isSearching = $isSearching
        context.coordinator.isFieldFocused = $isFieldFocused
        context.coordinator.host = uiView
        uiView.update(
            searchText: searchText,
            isSearching: isSearching,
            isFieldFocused: isFieldFocused,
            topInset: topInset,
            backdropColor: backdropColor,
            verticalOffset: verticalOffset
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            searchText: $searchText,
            isSearching: $isSearching,
            isFieldFocused: $isFieldFocused
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var searchText: Binding<String>
        var isSearching: Binding<Bool>
        var isFieldFocused: Binding<Bool>
        weak var host: StreamifyHomeHeaderUIView?
        private var cancelGeneration = 0

        init(
            searchText: Binding<String>,
            isSearching: Binding<Bool>,
            isFieldFocused: Binding<Bool>
        ) {
            self.searchText = searchText
            self.isSearching = isSearching
            self.isFieldFocused = isFieldFocused
        }

        @objc func openSearch() {
            cancelGeneration += 1
            guard !isSearching.wrappedValue else {
                isFieldFocused.wrappedValue = true
                host?.focusSearchFieldAfterExpansion()
                return
            }

            isSearching.wrappedValue = true
            isFieldFocused.wrappedValue = true
        }

        @objc func cancelSearch() {
            cancelGeneration += 1
            let generation = cancelGeneration
            let shouldWaitForResultsOverlay = !searchText.wrappedValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

            isFieldFocused.wrappedValue = false
            host?.commitSearchEditing()

            let closeSearch = { [weak self] in
                guard let self, self.cancelGeneration == generation else { return }
                self.searchText.wrappedValue = ""
                self.isSearching.wrappedValue = false
            }

            if shouldWaitForResultsOverlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: closeSearch)
            } else {
                closeSearch()
            }
        }

        @objc func clearSearch() {
            searchText.wrappedValue = ""
            host?.setSearchText("")
            isFieldFocused.wrappedValue = true
            host?.focusSearchFieldAfterExpansion()
        }

        @objc func textDidChange(_ sender: UITextField) {
            searchText.wrappedValue = sender.text ?? ""
            host?.updateClearButtonVisibility()
        }

        func textFieldDidBeginEditing(_: UITextField) {
            isFieldFocused.wrappedValue = true
            host?.updateFocusChrome()
        }

        func textFieldDidEndEditing(_: UITextField) {
            isFieldFocused.wrappedValue = false
            host?.updateFocusChrome()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            isFieldFocused.wrappedValue = false
            host?.commitSearchEditing()
            return false
        }
    }
}

final class StreamifyHomeHeaderUIView: UIView {
    private let backdropContainerLayer = CALayer()
    private let baseBlackLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let gradientContainerLayer = CALayer()
    private let grayOverlay = UIView()
    private let hairline = UIView()
    private let titleLabel = UILabel()
    private let searchContainer = UIView()
    private let searchIcon = UIImageView()
    private let textField = UITextField()
    private let clearButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private weak var coordinator: StreamifyHomeHeaderView.Coordinator?
    private var collapse: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    private var topInset: CGFloat = 0
    private var verticalOffset: CGFloat = 0
    private var backdropColor = UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    private var isSearching = false
    private var isFieldFocused = false
    private var currentBarHeight: CGFloat = 0
    private var didInstallActions = false
    private let expandedBlurAlpha: CGFloat = 0
    private let searchAnimationDuration: TimeInterval = 0.35
    private var isSearchTransitionAnimating = false
    private var searchTransitionGeneration = 0
    private var searchTransitionProgress: CGFloat?
    private var focusAfterSearchTransition = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard point.y <= currentBarHeight + 4 else { return false }
        return super.point(inside: point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isSearchTransitionAnimating else { return }
        applyLayout(animated: false, focusAfterAnimation: false)
    }

    func connect(_ coordinator: StreamifyHomeHeaderView.Coordinator) {
        self.coordinator = coordinator
        coordinator.host = self
        textField.delegate = coordinator

        guard !didInstallActions else { return }
        didInstallActions = true

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(StreamifyHomeHeaderView.Coordinator.openSearch))
        tap.cancelsTouchesInView = false
        searchContainer.addGestureRecognizer(tap)
        textField.addTarget(coordinator, action: #selector(StreamifyHomeHeaderView.Coordinator.textDidChange(_:)), for: .editingChanged)
        clearButton.addTarget(coordinator, action: #selector(StreamifyHomeHeaderView.Coordinator.clearSearch), for: .touchUpInside)
        cancelButton.addTarget(coordinator, action: #selector(StreamifyHomeHeaderView.Coordinator.cancelSearch), for: .touchUpInside)
    }

    func update(
        searchText: String,
        isSearching: Bool,
        isFieldFocused: Bool,
        topInset: CGFloat,
        backdropColor: UIColor?,
        verticalOffset: CGFloat
    ) {
        let previousSearchProgress = currentSearchProgress
        let searchChanged = self.isSearching != isSearching
        let focusChanged = self.isFieldFocused != isFieldFocused
        self.isSearching = isSearching
        self.isFieldFocused = isFieldFocused
        self.topInset = topInset
        self.verticalOffset = verticalOffset
        updateBackdropColor(backdropColor)

        setSearchText(searchText)

        if !isSearching {
            focusAfterSearchTransition = false
        }

        if !isSearching || !isFieldFocused {
            textField.resignFirstResponder()
        }

        if searchChanged {
            applyLayout(animated: true, focusAfterAnimation: isSearching && isFieldFocused, fromSearchProgress: previousSearchProgress)
        } else if focusChanged && isSearching && isFieldFocused {
            focusSearchFieldAfterExpansion()
            applyChrome()
        } else {
            applyLayout(animated: false, focusAfterAnimation: false)
        }
    }

    @objc private func collapseDidChange(_ notification: Notification) {
        guard let nextCollapse = StreamifyHomeScrollBus.collapse(from: notification) else { return }
        collapse = min(max(nextCollapse, 0), 1)
        scrollOffset = max(0, StreamifyHomeScrollBus.scrollOffset(from: notification) ?? (collapse * 132))
        guard !isSearchTransitionAnimating else { return }
        applyLayout(animated: false, focusAfterAnimation: false)
    }

    func setSearchText(_ text: String) {
        if textField.text != text {
            textField.text = text
        }
        updateClearButtonVisibility()
    }

    func updateClearButtonVisibility() {
        clearButton.isHidden = (textField.text ?? "").isEmpty || !isSearching
        clearButton.alpha = clearButton.isHidden ? 0 : currentSearchProgress
    }

    func updateFocusChrome() {
        isFieldFocused = textField.isFirstResponder
        applyChrome()
    }

    func focusSearchFieldAfterExpansion() {
        guard isSearching else { return }

        guard !isSearchTransitionAnimating else {
            focusAfterSearchTransition = true
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isSearching,
                  self.coordinator?.isFieldFocused.wrappedValue == true
            else { return }
            self.textField.becomeFirstResponder()
            self.isFieldFocused = true
            self.applyChrome()
        }
    }

    func commitSearchEditing() {
        focusAfterSearchTransition = false
        isFieldFocused = false
        textField.resignFirstResponder()
        applyChrome()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = true

        backdropContainerLayer.masksToBounds = true
        layer.addSublayer(backdropContainerLayer)

        baseBlackLayer.backgroundColor = UIColor.black.cgColor
        backdropContainerLayer.addSublayer(baseBlackLayer)

        gradientContainerLayer.masksToBounds = true
        layer.addSublayer(gradientContainerLayer)

        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientContainerLayer.addSublayer(gradientLayer)
        applyGradient(animated: false)

        blurView.alpha = 1
        blurView.isUserInteractionEnabled = false
        blurView.contentView.backgroundColor = .clear
        addSubview(blurView)

        grayOverlay.backgroundColor = UIColor(white: 0.16, alpha: 1)
        grayOverlay.alpha = 0
        grayOverlay.isUserInteractionEnabled = false
        addSubview(grayOverlay)

        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        hairline.alpha = 0
        hairline.isUserInteractionEnabled = false
        addSubview(hairline)

        titleLabel.text = "Home"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        addSubview(titleLabel)

        searchContainer.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        searchContainer.layer.cornerRadius = 9
        searchContainer.layer.cornerCurve = .continuous
        searchContainer.layer.borderWidth = 1
        searchContainer.layer.borderColor = UIColor.clear.cgColor
        searchContainer.clipsToBounds = true
        addSubview(searchContainer)

        searchIcon.image = UIImage(systemName: "magnifyingglass")
        searchIcon.tintColor = .white
        searchIcon.contentMode = .center
        searchContainer.addSubview(searchIcon)

        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.textColor = .white
        textField.tintColor = .white
        textField.font = .systemFont(ofSize: 16, weight: .medium)
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.attributedPlaceholder = NSAttributedString(
            string: "Search movies & series",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.42)]
        )
        searchContainer.addSubview(textField)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = UIColor.white.withAlphaComponent(0.55)
        searchContainer.addSubview(clearButton)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        searchContainer.addSubview(cancelButton)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collapseDidChange(_:)),
            name: StreamifyHomeScrollBus.collapseDidChange,
            object: nil
        )
    }

    private func applyLayout(animated: Bool, focusAfterAnimation: Bool, fromSearchProgress: CGFloat? = nil) {
        let changes = { [self] in
            layoutHeader()
            applyChrome()
        }

        if animated {
            focusAfterSearchTransition = focusAfterSearchTransition || focusAfterAnimation
            searchTransitionGeneration += 1
            let generation = searchTransitionGeneration
            isSearchTransitionAnimating = true

            let targetProgress: CGFloat = isSearching ? 1 : 0
            searchTransitionProgress = fromSearchProgress ?? currentSearchProgress

            removeSearchTransitionAnimations()
            UIView.performWithoutAnimation {
                changes()
                layoutIfNeeded()
            }

            let keyframes = searchAnimationKeyframes(from: searchTransitionProgress ?? targetProgress, to: targetProgress)
            UIView.animateKeyframes(
                withDuration: searchAnimationDuration,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .calculationModeCubic],
                animations: { [weak self] in
                    guard let self else { return }
                    var previousTime = keyframes.first?.time ?? 0
                    for keyframe in keyframes.dropFirst() {
                        let relativeDuration = keyframe.time - previousTime
                        UIView.addKeyframe(withRelativeStartTime: previousTime, relativeDuration: relativeDuration) {
                            self.searchTransitionProgress = keyframe.progress
                            changes()
                            self.layoutIfNeeded()
                        }
                        previousTime = keyframe.time
                    }
                },
                completion: { [weak self] _ in
                guard let self else { return }
                guard self.searchTransitionGeneration == generation else { return }
                self.isSearchTransitionAnimating = false
                UIView.performWithoutAnimation {
                    self.searchTransitionProgress = nil
                    self.layoutHeader()
                    self.applyChrome()
                }
                guard self.focusAfterSearchTransition,
                      self.isSearching,
                      self.coordinator?.isFieldFocused.wrappedValue == true
                else {
                    self.focusAfterSearchTransition = false
                    return
                }
                self.focusAfterSearchTransition = false
                self.textField.becomeFirstResponder()
                self.isFieldFocused = true
                self.applyChrome()
                }
            )
        } else {
            searchTransitionProgress = nil
            UIView.performWithoutAnimation(changes)
            if focusAfterAnimation, !textField.isFirstResponder {
                textField.becomeFirstResponder()
                applyChrome()
            }
        }
    }

    private func layoutHeader() {
        let width = bounds.width
        guard width > 1 else { return }

        let blurProgress = StreamifyHomeGradientMetrics.headerBlurProgress(for: scrollOffset)
        let surfaceProgress = StreamifyHomeGradientMetrics.headerMaterialProgress(for: scrollOffset)
        let underlayReleaseProgress = StreamifyHomeGradientMetrics.headerUnderlayReleaseProgress(for: scrollOffset)
        let backdropProgress = StreamifyHomeGradientMetrics.opacity(for: scrollOffset)
        let barHeight = topInset + 92 - (34 * collapse)
        currentBarHeight = barHeight

        let backgroundFrame = CGRect(x: 0, y: 0, width: width, height: barHeight)
        let gradientFrame = CGRect(
            x: 0,
            y: -(scrollOffset + verticalOffset),
            width: width,
            height: StreamifyHomeGradientMetrics.visualHeight
        )
        let headerBackdropAlpha: CGFloat = isSearching ? 0 : 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropContainerLayer.frame = backgroundFrame
        backdropContainerLayer.opacity = Float(headerBackdropAlpha)
        baseBlackLayer.frame = backdropContainerLayer.bounds
        baseBlackLayer.opacity = Float(1 - (0.58 * underlayReleaseProgress))
        baseBlackLayer.backgroundColor = UIColor.black.cgColor
        gradientContainerLayer.frame = backgroundFrame
        gradientContainerLayer.opacity = Float((1 - underlayReleaseProgress) * headerBackdropAlpha)
        gradientLayer.frame = gradientFrame
        gradientLayer.opacity = 1
        CATransaction.commit()

        blurView.frame = backgroundFrame
        grayOverlay.frame = backgroundFrame
        hairline.frame = CGRect(x: 0, y: barHeight - 1, width: width, height: 1)

        blurView.alpha = (expandedBlurAlpha + ((1 - expandedBlurAlpha) * blurProgress)) * headerBackdropAlpha
        grayOverlay.backgroundColor = materialGrayColor(backdropProgress: backdropProgress, surfaceProgress: surfaceProgress)
        grayOverlay.alpha = 0.58 * surfaceProgress * headerBackdropAlpha
        hairline.alpha = 0.08 * surfaceProgress * headerBackdropAlpha

        let horizontalPadding: CGFloat = 16
        let bottomPadding = 14 - (6 * collapse)
        let contentHeight: CGFloat = 44
        let contentY = max(topInset + 2, barHeight - bottomPadding - contentHeight)
        let titleFontSize = 38 - (13 * collapse)
        let searchProgress = currentSearchProgress

        titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .bold)
        titleLabel.frame = CGRect(x: horizontalPadding, y: contentY, width: 190, height: contentHeight)
        titleLabel.alpha = 1 - searchProgress

        let collapsedSearchWidth: CGFloat = 44
        let expandedSearchWidth = max(collapsedSearchWidth, width - (horizontalPadding * 2))
        let searchWidth = interpolated(from: collapsedSearchWidth, to: expandedSearchWidth, progress: searchProgress)
        let collapsedSearchX = width - horizontalPadding - collapsedSearchWidth
        let searchX = interpolated(from: collapsedSearchX, to: horizontalPadding, progress: searchProgress)
        searchContainer.frame = CGRect(x: searchX, y: contentY, width: searchWidth, height: contentHeight)

        let collapsedSymbolSize = 24 - (4 * collapse)
        let symbolSize = interpolated(from: collapsedSymbolSize, to: 18, progress: searchProgress)
        searchIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        searchIcon.frame = CGRect(
            x: interpolated(from: 0, to: 12, progress: searchProgress),
            y: 0,
            width: interpolated(from: 44, to: 20, progress: searchProgress),
            height: contentHeight
        )

        let cancelWidth: CGFloat = 58 * searchProgress
        let clearWidth: CGFloat = (textField.text ?? "").isEmpty ? 0 : (30 * searchProgress)
        let textX: CGFloat = 42
        let textRightInset: CGFloat = 10
        let textWidth = max(0, searchWidth - textX - cancelWidth - clearWidth - textRightInset)
        textField.frame = CGRect(x: textX, y: 4, width: textWidth, height: 36)
        clearButton.frame = CGRect(x: textX + textWidth, y: 4, width: clearWidth, height: 36)
        cancelButton.frame = CGRect(x: max(textX, searchWidth - cancelWidth - 8), y: 0, width: cancelWidth, height: contentHeight)

        textField.alpha = searchProgress
        cancelButton.alpha = searchProgress
        clearButton.alpha = clearWidth > 0 ? searchProgress : 0
        textField.isUserInteractionEnabled = isSearching
        clearButton.isUserInteractionEnabled = clearWidth > 0
        cancelButton.isUserInteractionEnabled = isSearching
    }

    private func applyChrome() {
        let focusAlpha: CGFloat = (textField.isFirstResponder || isFieldFocused) ? 0.34 : 0.22
        let searchProgress = currentSearchProgress
        searchContainer.backgroundColor = UIColor.white.withAlphaComponent(0.08 + (0.04 * collapse))
        searchContainer.layer.borderColor = UIColor.white.withAlphaComponent(focusAlpha * searchProgress).cgColor
        updateClearButtonVisibility()
    }

    private var currentSearchProgress: CGFloat {
        searchTransitionProgress ?? (isSearching ? 1 : 0)
    }

    private func searchAnimationKeyframes(from start: CGFloat, to target: CGFloat) -> [(time: Double, progress: CGFloat)] {
        let delta = target - start
        return [
            (0, start),
            (0.18, start + (delta * 0.04)),
            (0.48, start + (delta * 0.48)),
            (0.78, start + (delta * 0.90)),
            (1, target)
        ]
    }

    private func interpolated(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * min(max(progress, 0), 1))
    }

    private func removeSearchTransitionAnimations() {
        [titleLabel, searchContainer, searchIcon, textField, clearButton, cancelButton].forEach {
            $0.layer.removeAllAnimations()
        }
        searchContainer.layer.sublayers?.forEach { $0.removeAllAnimations() }
    }

    private func materialGrayColor(backdropProgress: CGFloat, surfaceProgress: CGFloat) -> UIColor {
        StreamifyHomeGradientMetrics.headerMaterialColor(
            for: backdropColor,
            backdropProgress: backdropProgress,
            surfaceProgress: surfaceProgress
        )
    }

    private func updateBackdropColor(_ color: UIColor?) {
        let nextColor = color ?? UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
        guard !nextColor.streamifyIsClose(to: backdropColor) else { return }
        backdropColor = nextColor
        applyGradient(animated: true)
    }

    private func applyGradient(animated: Bool) {
        let colors = StreamifyHomeGradientMetrics.colors(for: backdropColor)
        gradientLayer.locations = StreamifyHomeGradientMetrics.locations

        if animated {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = gradientLayer.colors
            animation.toValue = colors
            animation.duration = 0.24
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradientLayer.add(animation, forKey: "colors")
        }

        gradientLayer.colors = colors
    }
}
