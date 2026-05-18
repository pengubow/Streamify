import SwiftUI
import UIKit

enum StreamifyHomeGradientMetrics {
    static let fallbackColor = UIColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    static let materialBaseColor = UIColor(white: 0.16, alpha: 1)

    static var layoutHeight: CGFloat {
        720
    }

    static var visualHeight: CGFloat {
        980
    }

    static var locations: [NSNumber] {
        [0, 0.30, 0.56, 0.76, 0.91, 1]
    }

    static func colors(for baseColor: UIColor) -> [CGColor] {
        [
            baseColor.withAlphaComponent(0.48).cgColor,
            baseColor.withAlphaComponent(0.36).cgColor,
            baseColor.withAlphaComponent(0.25).cgColor,
            baseColor.withAlphaComponent(0.14).cgColor,
            baseColor.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
    }

    static func opacity(for scrollOffset: CGFloat) -> CGFloat {
        let fadeProgress = smoothOffsetProgress(scrollOffset, from: 240, to: 940)
        return max(0, 1 - fadeProgress)
    }

    static func headerBlurProgress(for scrollOffset: CGFloat) -> CGFloat {
        smoothOffsetProgress(scrollOffset, from: 180, to: 560)
    }

    static func headerMaterialProgress(for scrollOffset: CGFloat) -> CGFloat {
        smoothOffsetProgress(scrollOffset, from: 200, to: 640)
    }

    static func headerUnderlayReleaseProgress(for scrollOffset: CGFloat) -> CGFloat {
        smoothOffsetProgress(scrollOffset, from: 580, to: 940)
    }

    static func headerMaterialColor(
        for backdropColor: UIColor,
        backdropProgress: CGFloat,
        surfaceProgress: CGFloat
    ) -> UIColor {
        let tintAmount = min(max(surfaceProgress * 0.16 * backdropProgress, 0), 0.16)
        return materialBaseColor.streamifyMixed(with: backdropColor, amount: tintAmount)
    }

    private static func smoothOffsetProgress(_ scrollOffset: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        guard end > start else { return scrollOffset >= end ? 1 : 0 }
        let clamped = min(max((scrollOffset - start) / (end - start), 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}

struct StreamifyGradientBackground: View {
    var color: UIColor?
    var followsHomeScroll: Bool = false
    var verticalOffset: CGFloat = 0
    var usesHeaderMaterial: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            if usesHeaderMaterial {
                StreamifyHomeMaterialFill(color: color)
            } else {
                Color.black
            }
            if followsHomeScroll {
                StreamifyHomeBackdropView(
                    color: color,
                    verticalOffset: verticalOffset,
                    usesHeaderMaterial: usesHeaderMaterial
                )
                .modifier(StreamifyBackdropFrameModifier(expandsToFill: usesHeaderMaterial))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            } else {
                StreamifyStaticGradientBackdrop(color: color)
                    .frame(height: StreamifyHomeGradientMetrics.layoutHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

private struct StreamifyBackdropFrameModifier: ViewModifier {
    var expandsToFill: Bool

    func body(content: Content) -> some View {
        if expandsToFill {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
                .frame(height: StreamifyHomeGradientMetrics.layoutHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct StreamifyHomeMaterialFill: UIViewRepresentable {
    var color: UIColor?

    func makeUIView(context: Context) -> StreamifyHomeMaterialFillUIView {
        let view = StreamifyHomeMaterialFillUIView()
        view.update(color: color)
        return view
    }

    func updateUIView(_ uiView: StreamifyHomeMaterialFillUIView, context: Context) {
        uiView.update(color: color)
    }
}

private final class StreamifyHomeMaterialFillUIView: UIView {
    private var baseColor = StreamifyHomeGradientMetrics.fallbackColor
    private var scrollOffset = StreamifyHomeScrollBus.currentScrollOffset

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

    func update(color: UIColor?) {
        let nextColor = color ?? StreamifyHomeGradientMetrics.fallbackColor
        guard !nextColor.streamifyIsClose(to: baseColor) else { return }
        baseColor = nextColor
        applyColor()
    }

    private func setup() {
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collapseDidChange(_:)),
            name: StreamifyHomeScrollBus.collapseDidChange,
            object: nil
        )
        applyColor()
    }

    @objc private func collapseDidChange(_ notification: Notification) {
        scrollOffset = max(0, StreamifyHomeScrollBus.scrollOffset(from: notification) ?? 0)
        applyColor()
    }

    private func applyColor() {
        let backdropProgress = StreamifyHomeGradientMetrics.opacity(for: scrollOffset)
        let surfaceProgress = StreamifyHomeGradientMetrics.headerMaterialProgress(for: scrollOffset)
        let materialColor = StreamifyHomeGradientMetrics.headerMaterialColor(
            for: baseColor,
            backdropProgress: backdropProgress,
            surfaceProgress: surfaceProgress
        )
        let materialOpacity = 0.58 * surfaceProgress
        backgroundColor = UIColor.black.streamifyMixed(with: materialColor, amount: materialOpacity)
    }
}

private struct StreamifyStaticGradientBackdrop: View {
    var color: UIColor?

    var body: some View {
        let baseColor = color ?? StreamifyHomeGradientMetrics.fallbackColor
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(uiColor: baseColor.withAlphaComponent(0.48)), location: 0),
                .init(color: Color(uiColor: baseColor.withAlphaComponent(0.36)), location: 0.30),
                .init(color: Color(uiColor: baseColor.withAlphaComponent(0.25)), location: 0.56),
                .init(color: Color(uiColor: baseColor.withAlphaComponent(0.14)), location: 0.76),
                .init(color: Color(uiColor: baseColor.withAlphaComponent(0.05)), location: 0.91),
                .init(color: .clear, location: 1)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: StreamifyHomeGradientMetrics.visualHeight)
    }
}

extension UIImage {
    func streamifyFeaturedGradientColor() -> UIColor? {
        guard size.width > 0, size.height > 0 else { return nil }

        let sampleWidth = 40
        let aspectRatio = size.height / max(size.width, 1)
        let sampleHeight = min(54, max(22, Int(CGFloat(sampleWidth) * aspectRatio)))
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        UIGraphicsPushContext(context)
        draw(in: CGRect(x: 0, y: 0, width: CGFloat(sampleWidth), height: CGFloat(sampleHeight)))
        UIGraphicsPopContext()

        var candidates: [(score: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)] = []
        var fallbackRed: CGFloat = 0
        var fallbackGreen: CGFloat = 0
        var fallbackBlue: CGFloat = 0
        var fallbackWeight: CGFloat = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[index + 3]) / 255
            guard alpha > 0.35 else { continue }

            let red = CGFloat(pixels[index]) / 255
            let green = CGFloat(pixels[index + 1]) / 255
            let blue = CGFloat(pixels[index + 2]) / 255
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let saturation = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0
            let luminance = streamifyLuminance(red: red, green: green, blue: blue)

            if luminance > 0.24 && luminance < 0.9 {
                let fallbackScore = max(0.2, saturation + luminance)
                fallbackRed += red * fallbackScore
                fallbackGreen += green * fallbackScore
                fallbackBlue += blue * fallbackScore
                fallbackWeight += fallbackScore
            }

            guard maxChannel > 0.26, luminance > 0.18, saturation > 0.16 else {
                continue
            }

            let darknessPenalty = max(0, 0.38 - luminance) * 1.4
            let highlightPenalty = max(0, luminance - 0.86) * 0.7
            let score = saturation * 1.55 + luminance * 0.45 + maxChannel * 0.25 - darknessPenalty - highlightPenalty
            candidates.append((score, red, green, blue))
        }

        if !candidates.isEmpty {
            let sorted = candidates.sorted { $0.score > $1.score }
            let topCount = min(max(4, sorted.count / 8), 18, sorted.count)
            let topCandidates = sorted.prefix(topCount)
            let totalScore = topCandidates.reduce(CGFloat(0)) { $0 + max($1.score, 0.1) }
            let red = topCandidates.reduce(CGFloat(0)) { $0 + $1.red * max($1.score, 0.1) } / totalScore
            let green = topCandidates.reduce(CGFloat(0)) { $0 + $1.green * max($1.score, 0.1) } / totalScore
            let blue = topCandidates.reduce(CGFloat(0)) { $0 + $1.blue * max($1.score, 0.1) } / totalScore
            return streamifyVisibleGradientColor(red: red, green: green, blue: blue)
        }

        if fallbackWeight > 0 {
            return streamifyVisibleGradientColor(
                red: fallbackRed / fallbackWeight,
                green: fallbackGreen / fallbackWeight,
                blue: fallbackBlue / fallbackWeight
            )
        }

        return StreamifyHomeGradientMetrics.fallbackColor
    }

    private func streamifyVisibleGradientColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> UIColor {
        let luminance = streamifyLuminance(red: red, green: green, blue: blue)
        guard luminance < 0.46 else {
            return streamifyVibrantGradientColor(red: red, green: green, blue: blue)
        }

        let lift = min(0.58, (0.52 - luminance) / 0.52)
        return streamifyVibrantGradientColor(
            red: red + (1 - red) * lift,
            green: green + (1 - green) * lift,
            blue: blue + (1 - blue) * lift
        )
    }

    private func streamifyVibrantGradientColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        let color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }

        let boostedSaturation = min(1, saturation * 1.26 + 0.05)
        let boostedBrightness = min(0.92, max(0.58, brightness * 1.12 + 0.04))
        return UIColor(hue: hue, saturation: boostedSaturation, brightness: boostedBrightness, alpha: 1)
    }

    private func streamifyLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
}

extension UIColor {
    func streamifyMixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let clampedAmount = min(max(amount, 0), 1)

        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0

        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }

        return UIColor(
            red: r1 + ((r2 - r1) * clampedAmount),
            green: g1 + ((g2 - g1) * clampedAmount),
            blue: b1 + ((b2 - b1) * clampedAmount),
            alpha: a1 + ((a2 - a1) * clampedAmount)
        )
    }

    func streamifyIsClose(to other: UIColor) -> Bool {
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return false
        }
        return abs(r1 - r2) < 0.002 &&
            abs(g1 - g2) < 0.002 &&
            abs(b1 - b2) < 0.002 &&
            abs(a1 - a2) < 0.002
    }
}
