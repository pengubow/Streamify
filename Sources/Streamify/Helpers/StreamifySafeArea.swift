import SwiftUI
import UIKit

enum StreamifySafeArea {
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    static func insets(fallback: EdgeInsets) -> EdgeInsets {
        let uiInsets = resolvedInsets(
            fallback: UIEdgeInsets(
                top: fallback.top,
                left: fallback.leading,
                bottom: fallback.bottom,
                right: fallback.trailing
            )
        )

        return EdgeInsets(
            top: uiInsets.top,
            leading: uiInsets.left,
            bottom: uiInsets.bottom,
            trailing: uiInsets.right
        )
    }

    static func resolvedInsets(fallback: UIEdgeInsets = .zero) -> UIEdgeInsets {
        guard let insets = keyWindow?.safeAreaInsets else { return fallback }
        return UIEdgeInsets(
            top: max(fallback.top, insets.top),
            left: max(fallback.left, insets.left),
            bottom: max(fallback.bottom, insets.bottom),
            right: max(fallback.right, insets.right)
        )
    }

    static func bottomChromeInset(_ inset: CGFloat) -> CGFloat {
        inset > 0 ? inset : 24
    }

    static func shouldCropVideoToFill(bounds: CGRect, safeAreaInsets: UIEdgeInsets) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        guard bounds.width > bounds.height else { return false }
        return max(safeAreaInsets.left, safeAreaInsets.right) >= 20
    }

    static func playerControlTopPadding(size: CGSize, safeInsets: EdgeInsets) -> CGFloat {
        let isWide = size.width >= 900
        return max(isWide ? 38 : 18, safeInsets.top + (isWide ? 16 : 8))
    }

    static func playerControlHorizontalPadding(size: CGSize, safeInsets: EdgeInsets) -> CGFloat {
        let isWide = size.width >= 900
        let base: CGFloat = isWide ? 28 : 16
        let extra: CGFloat = isWide ? 8 : 0
        return max(base, max(safeInsets.leading, safeInsets.trailing) + extra)
    }

    static func playerControlBottomPadding(size: CGSize, safeInsets: EdgeInsets) -> CGFloat {
        let isWide = size.width >= 900
        return max(isWide ? 22 : 16, safeInsets.bottom + 12)
    }
}
