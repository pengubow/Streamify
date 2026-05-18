import SwiftUI
import UIKit

enum StreamifyHomeScrollBus {
    static let collapseDidChange = Notification.Name("StreamifyHomeScrollCollapseDidChange")
    static let collapseKey = "collapse"
    static let scrollOffsetKey = "scrollOffset"
    private(set) static var currentCollapse: CGFloat = 0
    private(set) static var currentScrollOffset: CGFloat = 0

    static func post(collapse: CGFloat, scrollOffset: CGFloat? = nil) {
        currentCollapse = min(max(collapse, 0), 1)
        currentScrollOffset = max(0, scrollOffset ?? (currentCollapse * 132))
        var userInfo: [String: Double] = [collapseKey: Double(collapse)]
        if let scrollOffset {
            userInfo[scrollOffsetKey] = Double(scrollOffset)
        }

        NotificationCenter.default.post(
            name: collapseDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func collapse(from notification: Notification) -> CGFloat? {
        guard let value = notification.userInfo?[collapseKey] as? Double else { return nil }
        return CGFloat(value)
    }

    static func scrollOffset(from notification: Notification) -> CGFloat? {
        guard let value = notification.userInfo?[scrollOffsetKey] as? Double else { return nil }
        return CGFloat(value)
    }
}

struct StreamifyHomeBackdropView: UIViewRepresentable {
    var color: UIColor?
    var verticalOffset: CGFloat = 0
    var usesHeaderMaterial: Bool = false

    func makeUIView(context: Context) -> StreamifyHomeBackdropUIView {
        let view = StreamifyHomeBackdropUIView()
        view.update(
            color: color,
            verticalOffset: verticalOffset,
            usesHeaderMaterial: usesHeaderMaterial,
            animated: false
        )
        return view
    }

    func updateUIView(_ uiView: StreamifyHomeBackdropUIView, context: Context) {
        uiView.update(
            color: color,
            verticalOffset: verticalOffset,
            usesHeaderMaterial: usesHeaderMaterial,
            animated: true
        )
    }
}

final class StreamifyHomeBackdropUIView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let materialLayer = CALayer()
    private var baseColor = StreamifyHomeGradientMetrics.fallbackColor
    private var collapse: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    private var verticalOffset: CGFloat = 0
    private var usesHeaderMaterial = false

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

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGradientFrameAndOpacity()
    }

    func update(
        color: UIColor?,
        verticalOffset: CGFloat = 0,
        usesHeaderMaterial: Bool = false,
        animated: Bool = true
    ) {
        let nextColor = color ?? StreamifyHomeGradientMetrics.fallbackColor
        let colorChanged = !nextColor.streamifyIsClose(to: baseColor)
        let offsetChanged = abs(self.verticalOffset - verticalOffset) > 0.5
        let materialChanged = self.usesHeaderMaterial != usesHeaderMaterial
        guard colorChanged || offsetChanged || materialChanged else { return }
        self.verticalOffset = verticalOffset
        self.usesHeaderMaterial = usesHeaderMaterial
        if colorChanged {
            baseColor = nextColor
            applyGradient(animated: animated)
        } else {
            applyGradientFrameAndOpacity()
        }
    }

    private func setup() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        collapse = StreamifyHomeScrollBus.currentCollapse
        scrollOffset = StreamifyHomeScrollBus.currentScrollOffset
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)
        layer.addSublayer(materialLayer)
        applyGradient(animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collapseDidChange(_:)),
            name: StreamifyHomeScrollBus.collapseDidChange,
            object: nil
        )
    }

    @objc private func collapseDidChange(_ notification: Notification) {
        guard let nextCollapse = StreamifyHomeScrollBus.collapse(from: notification) else { return }
        collapse = min(max(nextCollapse, 0), 1)
        scrollOffset = max(0, StreamifyHomeScrollBus.scrollOffset(from: notification) ?? (collapse * 132))
        applyGradientFrameAndOpacity()
    }

    private func applyGradient(animated: Bool) {
        let colors = StreamifyHomeGradientMetrics.colors(for: baseColor)
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
        applyGradientFrameAndOpacity()
    }

    private func applyGradientFrameAndOpacity() {
        guard bounds.width > 0 else { return }
        let opacity = StreamifyHomeGradientMetrics.opacity(for: scrollOffset)
        let surfaceProgress = StreamifyHomeGradientMetrics.headerMaterialProgress(for: scrollOffset)
        let underlayReleaseProgress = StreamifyHomeGradientMetrics.headerUnderlayReleaseProgress(for: scrollOffset)
        let gradientOpacity = usesHeaderMaterial ? (opacity * (1 - underlayReleaseProgress)) : opacity
        let materialOpacity = usesHeaderMaterial ? (0.58 * surfaceProgress) : 0
        let materialColor = StreamifyHomeGradientMetrics.headerMaterialColor(
            for: baseColor,
            backdropProgress: opacity,
            surfaceProgress: surfaceProgress
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = CGRect(
            x: 0,
            y: -(scrollOffset + verticalOffset),
            width: bounds.width,
            height: StreamifyHomeGradientMetrics.visualHeight
        )
        gradientLayer.opacity = Float(gradientOpacity)
        materialLayer.frame = bounds
        materialLayer.backgroundColor = materialColor.cgColor
        materialLayer.opacity = Float(materialOpacity)
        CATransaction.commit()
    }
}
