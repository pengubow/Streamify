import UIKit

/// Manages the app-wide orientation lock.
/// Portrait is the default; only the video player unlocks landscape.
final class OrientationManager {
    static let shared = OrientationManager()
    private init() {}

    /// When `true`, orientation is locked to landscape (video player).
    /// When `false` (default), only portrait is allowed.
    var isLandscapeAllowed: Bool = false

    func rotate(to orientation: UIInterfaceOrientation) {
        isLandscapeAllowed = orientation == .landscapeLeft || orientation == .landscapeRight

        if #available(iOS 16.0, *),
           let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation)))
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}

/// AppDelegate adapter that restricts orientations based on OrientationManager state.
class StreamifyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if OrientationManager.shared.isLandscapeAllowed {
            return .landscape
        }
        return .portrait
    }
}
