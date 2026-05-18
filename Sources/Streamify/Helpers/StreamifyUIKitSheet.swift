import SwiftUI
import UIKit

struct StreamifyUIKitSheetPresenter<Item: Identifiable, SheetContent: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder let sheetContent: (Item) -> SheetContent

    func makeCoordinator() -> Coordinator {
        Coordinator(item: $item, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        context.coordinator.item = $item
        context.coordinator.onDismiss = onDismiss
        uiViewController.update(
            item: item,
            coordinator: context.coordinator,
            makeContent: { AnyView(sheetContent($0)) }
        )
    }

    final class Coordinator {
        var item: Binding<Item?>
        var onDismiss: (() -> Void)?
        private var didNotifyDismissal = false

        init(item: Binding<Item?>, onDismiss: (() -> Void)?) {
            self.item = item
            self.onDismiss = onDismiss
        }

        func beginPresentation() {
            didNotifyDismissal = false
        }

        func finishUserDismissal() {
            guard !didNotifyDismissal else { return }
            didNotifyDismissal = true
            item.wrappedValue = nil
            onDismiss?()
        }
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private var presentedID: AnyHashable?
        private var hostedController: UIHostingController<AnyView>?
        private var overlayWindow: UIWindow?
        private var overlayView: SheetOverlayView?
        private weak var dimmingView: UIView?
        private weak var backgroundView: UIView?
        private weak var activeScrollView: UIScrollView?
        private weak var currentCoordinator: Coordinator?

        private var panStartFrame: CGRect = .zero
        private var panStartTranslationY: CGFloat = 0
        private var isDraggingSheet = false
        private var isDismissing = false
        private var openSheetFrame: CGRect = .zero
        private var presentationAnimator: UIViewPropertyAnimator?
        private var dismissalAnimator: UIViewPropertyAnimator?
        private weak var disabledScrollView: UIScrollView?
        private var disabledScrollViewWasScrollEnabled = true

        private var previousWindowBackgroundColor: UIColor?
        private var previousBackgroundMasksToBounds = false
        private var previousBackgroundCornerRadius: CGFloat = 0

        private let backgroundScale: CGFloat = 0.88
        private let backgroundCornerRadius: CGFloat = 18
        private let presentationDuration: TimeInterval = 0.42
        private let dismissalDuration: TimeInterval = 0.24

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        func update(
            item: Item?,
            coordinator: Coordinator,
            makeContent: @escaping (Item) -> AnyView
        ) {
            currentCoordinator = coordinator

            guard let item else {
                dismissPresentedSheet(coordinator: coordinator, animated: true, userInitiated: false)
                return
            }

            let nextID = AnyHashable(item.id)
            if let hostedController, presentedID == nextID {
                hostedController.rootView = makeContent(item)
                return
            }

            if hostedController != nil {
                dismissPresentedSheet(coordinator: coordinator, animated: false, userInitiated: false) { [weak self] in
                    self?.presentSheet(for: item, id: nextID, coordinator: coordinator, makeContent: makeContent)
                }
            } else {
                presentSheet(for: item, id: nextID, coordinator: coordinator, makeContent: makeContent)
            }
        }

        private func presentSheet(
            for item: Item,
            id: AnyHashable,
            coordinator: Coordinator,
            makeContent: @escaping (Item) -> AnyView
        ) {
            guard let presentingWindow = view.window,
                  let windowScene = presentingWindow.windowScene,
                  let backgroundView = presentingRootController()?.view
            else { return }

            presentationAnimator?.stopAnimation(true)
            dismissalAnimator?.stopAnimation(true)
            coordinator.beginPresentation()
            isDismissing = false

            previousWindowBackgroundColor = presentingWindow.backgroundColor
            previousBackgroundMasksToBounds = backgroundView.layer.masksToBounds
            previousBackgroundCornerRadius = backgroundView.layer.cornerRadius
            presentingWindow.backgroundColor = .black
            presentingWindow.endEditing(true)

            backgroundView.layer.masksToBounds = true
            if #available(iOS 13.0, *) {
                backgroundView.layer.cornerCurve = .continuous
            }

            let overlayWindow = UIWindow(windowScene: windowScene)
            overlayWindow.frame = presentingWindow.frame
            overlayWindow.windowLevel = presentingWindow.windowLevel + 1
            overlayWindow.backgroundColor = .clear
            overlayWindow.isHidden = false

            let overlayController = UIViewController()
            overlayController.view.backgroundColor = .clear
            overlayWindow.rootViewController = overlayController

            let overlay = SheetOverlayView(frame: overlayController.view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .clear
            overlayController.view.addSubview(overlay)

            let dimming = UIView(frame: overlay.bounds)
            dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dimming.backgroundColor = UIColor.black.withAlphaComponent(0.48)
            dimming.alpha = 0
            dimming.isUserInteractionEnabled = true
            overlay.addSubview(dimming)

            overlay.setNeedsLayout()
            overlay.layoutIfNeeded()

            let host = UIHostingController(rootView: makeContent(item))
            host.view.backgroundColor = .clear
            let initialSheetFrame = sheetFrame(in: overlay)
            openSheetFrame = initialSheetFrame
            host.view.frame = initialSheetFrame
            host.view.transform = closedTransform(from: initialSheetFrame, in: overlay)
            configureSheetView(host.view)

            overlayController.addChild(host)
            overlay.addSubview(host.view)
            host.didMove(toParent: overlayController)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            host.view.addGestureRecognizer(pan)

            overlay.onLayout = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.layoutOverlay(overlay)
            }

            self.overlayWindow = overlayWindow
            overlayView = overlay
            dimmingView = dimming
            self.backgroundView = backgroundView
            hostedController = host
            presentedID = id

            let animator = UIViewPropertyAnimator(
                duration: presentationDuration,
                timingParameters: StreamifySheetTimingParameters.opening
            )
            animator.addAnimations { [weak self, weak host, weak dimming] in
                guard let self else { return }
                host?.view.transform = .identity
                dimming?.alpha = 1
                self.backgroundView?.transform = CGAffineTransform(scaleX: self.backgroundScale, y: self.backgroundScale)
                self.backgroundView?.layer.cornerRadius = self.backgroundCornerRadius
            }
            animator.addCompletion { [weak self] _ in
                self?.presentationAnimator = nil
            }
            presentationAnimator = animator
            animator.startAnimation()
        }

        private func dismissPresentedSheet(
            coordinator: Coordinator,
            animated: Bool,
            userInitiated: Bool,
            initialVelocity: CGFloat = 0,
            completion: (() -> Void)? = nil
        ) {
            guard let host = hostedController, let overlay = overlayView else {
                completion?()
                return
            }
            guard !isDismissing else { return }

            isDismissing = true
            dimmingView?.layer.removeAllAnimations()
            backgroundView?.layer.removeAllAnimations()

            let baseFrame = settleSheetToCurrentTranslation(host.view, in: overlay)
            let currentTranslation = currentSheetTranslationY(host.view, from: baseFrame)
            let targetTranslation = dismissTranslation(from: baseFrame, in: overlay)
            let targetTransform = CGAffineTransform(translationX: 0, y: targetTranslation)

            let finish = { [weak self, weak coordinator] in
                guard let self else { return }
                self.cleanupPresentation(host: host)
                if userInitiated {
                    coordinator?.finishUserDismissal()
                }
                completion?()
            }

            guard animated else {
                host.view.transform = targetTransform
                dimmingView?.alpha = 0
                backgroundView?.transform = .identity
                backgroundView?.layer.cornerRadius = previousBackgroundCornerRadius
                finish()
                return
            }

            let remaining = max(1, targetTranslation - currentTranslation)
            let velocityDuration = TimeInterval(remaining / max(abs(initialVelocity), 1300))
            let duration = initialVelocity > 0 ? min(dismissalDuration, max(0.12, velocityDuration)) : dismissalDuration

            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) { [weak self, weak host] in
                guard let self, let host else { return }
                host.view.transform = targetTransform
                self.dimmingView?.alpha = 0
                self.backgroundView?.transform = .identity
                self.backgroundView?.layer.cornerRadius = self.previousBackgroundCornerRadius
            } completion: { _ in
                finish()
            }
        }

        private func cleanupPresentation(host: UIHostingController<AnyView>) {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()

            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil

            backgroundView?.transform = .identity
            backgroundView?.layer.cornerRadius = previousBackgroundCornerRadius
            backgroundView?.layer.masksToBounds = previousBackgroundMasksToBounds

            if let presentingWindow = view.window {
                presentingWindow.backgroundColor = previousWindowBackgroundColor
            }

            presentationAnimator = nil
            dismissalAnimator = nil
            restoreScrollViewAfterSheetDrag()
            overlayView = nil
            dimmingView = nil
            backgroundView = nil
            hostedController = nil
            presentedID = nil
            activeScrollView = nil
            isDraggingSheet = false
            isDismissing = false
        }

        private func layoutOverlay(_ overlay: SheetOverlayView) {
            guard let host = hostedController else { return }
            overlay.frame = overlay.superview?.bounds ?? overlay.frame
            dimmingView?.frame = overlay.bounds
            if !isDraggingSheet && !isDismissing && presentationAnimator == nil {
                let frame = sheetFrame(in: overlay)
                openSheetFrame = frame
                host.view.transform = .identity
                host.view.frame = frame
                configureSheetView(host.view)
            }
        }

        private func presentingRootController() -> UIViewController? {
            var controller: UIViewController = self
            while let parent = controller.parent {
                controller = parent
            }
            return controller
        }

        private func sheetFrame(in overlay: UIView) -> CGRect {
            let bounds = overlay.bounds
            let safe = overlay.safeAreaInsets
            let isWide = bounds.width >= 700
            let horizontalInset: CGFloat = isWide ? max(44, min(88, bounds.width * 0.055)) : 0
            let maxWidth = isWide ? min(bounds.width - horizontalInset * 2, 1188) : bounds.width
            let width = max(0, maxWidth)
            let x = isWide ? (bounds.width - width) / 2 : 0
            let topInset = isWide ? max(safe.top + 28, 56) : max(safe.top + 18, 42)
            let height = max(0, bounds.height - topInset)
            return CGRect(x: x, y: topInset, width: width, height: height)
        }

        private func closedTransform(from baseFrame: CGRect, in overlay: UIView) -> CGAffineTransform {
            let distance = dismissTranslation(from: baseFrame, in: overlay)
            return CGAffineTransform(translationX: 0, y: distance)
        }

        private func configureSheetView(_ sheetView: UIView) {
            sheetView.clipsToBounds = true
            sheetView.layer.cornerRadius = 16
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            if #available(iOS 13.0, *) {
                sheetView.layer.cornerCurve = .continuous
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let host = hostedController, let overlay = overlayView else { return }
            let sheetView = host.view!
            let translation = recognizer.translation(in: overlay)

            switch recognizer.state {
            case .began:
                dismissalAnimator?.stopAnimation(true)
                let baseFrame = settleSheetToCurrentTranslation(sheetView, in: overlay)
                activeScrollView = scrollView(at: recognizer.location(in: sheetView), in: sheetView)
                isDraggingSheet = shouldBeginSheetDrag(recognizer, in: sheetView)
                panStartFrame = baseFrame
                panStartTranslationY = currentSheetTranslationY(sheetView, from: baseFrame)
                if isDraggingSheet {
                    disableActiveScrollViewForSheetDrag()
                }
            case .changed:
                guard isDraggingSheet else { return }
                let offset = max(0, panStartTranslationY + translation.y)
                performImmediateUpdates {
                    sheetView.transform = CGAffineTransform(translationX: 0, y: offset)
                    updateDragProgress(dragProgress(for: offset, from: panStartFrame, in: overlay))
                }
            case .ended, .cancelled, .failed:
                guard isDraggingSheet else {
                    activeScrollView = nil
                    return
                }
                let velocity = recognizer.velocity(in: overlay).y
                let sheetOffset = currentSheetTranslationY(sheetView, from: panStartFrame)
                let shouldDismiss = sheetOffset > 120 || velocity > 900
                if shouldDismiss {
                    guard let currentCoordinator else { return }
                    dismissPresentedSheet(
                        coordinator: currentCoordinator,
                        animated: true,
                        userInitiated: true,
                        initialVelocity: velocity
                    )
                    isDraggingSheet = false
                    restoreScrollViewAfterSheetDrag()
                    activeScrollView = nil
                } else {
                    animateGestureCancellation(sheetView: sheetView, velocity: velocity)
                }
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let sheetView = hostedController?.view
            else { return true }
            let velocity = pan.velocity(in: sheetView)
            guard abs(velocity.y) > abs(velocity.x), velocity.y > 0 else { return false }
            let scrollView = scrollView(at: pan.location(in: sheetView), in: sheetView)
            guard let scrollView else { return true }
            return scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func shouldBeginSheetDrag(_ recognizer: UIPanGestureRecognizer, in sheetView: UIView) -> Bool {
            let velocity = recognizer.velocity(in: sheetView)
            guard abs(velocity.y) > abs(velocity.x), velocity.y > 0 else { return false }
            guard let activeScrollView else { return true }
            return activeScrollView.contentOffset.y <= -activeScrollView.adjustedContentInset.top + 1
        }

        private func scrollView(at location: CGPoint, in sheetView: UIView) -> UIScrollView? {
            guard let hitView = sheetView.hitTest(location, with: nil) else { return nil }
            return hitView.streamifyEnclosingScrollView()
        }

        private func updateDragProgress(_ rawProgress: CGFloat) {
            let progress = min(max(rawProgress, 0), 1)
            dimmingView?.alpha = 1 - progress
            let scale = backgroundScale + (1 - backgroundScale) * progress
            backgroundView?.transform = CGAffineTransform(scaleX: scale, y: scale)
            backgroundView?.layer.cornerRadius = backgroundCornerRadius * (1 - progress)
        }

        private func animateGestureCancellation(sheetView: UIView, velocity: CGFloat) {
            let distance = max(1, abs(currentSheetTranslationY(sheetView, from: panStartFrame)))
            let velocityDuration = TimeInterval(distance / max(abs(velocity), 1200))
            let duration = min(0.16, max(0.08, velocityDuration))
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) { [weak self] in
                sheetView.transform = .identity
                self?.dimmingView?.alpha = 1
                if let self {
                    self.backgroundView?.transform = CGAffineTransform(scaleX: self.backgroundScale, y: self.backgroundScale)
                    self.backgroundView?.layer.cornerRadius = self.backgroundCornerRadius
                }
            } completion: { [weak self] _ in
                self?.isDraggingSheet = false
                self?.restoreScrollViewAfterSheetDrag()
                self?.activeScrollView = nil
            }
        }

        private func dismissTranslation(from baseFrame: CGRect, in overlay: UIView) -> CGFloat {
            max(0, overlay.bounds.maxY - baseFrame.minY + 24)
        }

        private func dragProgress(for offset: CGFloat, from baseFrame: CGRect, in overlay: UIView) -> CGFloat {
            offset / max(1, dismissTranslation(from: baseFrame, in: overlay))
        }

        private func sheetBaseFrame(in overlay: UIView) -> CGRect {
            openSheetFrame == .zero ? sheetFrame(in: overlay) : openSheetFrame
        }

        private func visualFrame(of sheetView: UIView) -> CGRect {
            if let presentationFrame = sheetView.layer.presentation()?.frame {
                return presentationFrame
            }
            if sheetView.transform == .identity {
                return sheetView.frame
            }
            return sheetView.superview?.convert(sheetView.bounds, from: sheetView) ?? sheetView.frame
        }

        private func settleSheetToCurrentTranslation(_ sheetView: UIView, in overlay: UIView) -> CGRect {
            let baseFrame = sheetBaseFrame(in: overlay)
            let translation = max(0, visualFrame(of: sheetView).minY - baseFrame.minY)
            presentationAnimator?.stopAnimation(true)
            dismissalAnimator?.stopAnimation(true)
            sheetView.layer.removeAllAnimations()
            sheetView.transform = .identity
            sheetView.frame = baseFrame
            sheetView.transform = CGAffineTransform(translationX: 0, y: translation)
            configureSheetView(sheetView)
            return baseFrame
        }

        private func currentSheetTranslationY(_ sheetView: UIView, from baseFrame: CGRect) -> CGFloat {
            max(0, visualFrame(of: sheetView).minY - baseFrame.minY)
        }

        private func performImmediateUpdates(_ updates: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation(updates)
            CATransaction.commit()
        }

        private func disableActiveScrollViewForSheetDrag() {
            guard disabledScrollView == nil, let activeScrollView else { return }
            disabledScrollView = activeScrollView
            disabledScrollViewWasScrollEnabled = activeScrollView.isScrollEnabled
            activeScrollView.contentOffset.y = -activeScrollView.adjustedContentInset.top
            activeScrollView.isScrollEnabled = false
        }

        private func restoreScrollViewAfterSheetDrag() {
            disabledScrollView?.isScrollEnabled = disabledScrollViewWasScrollEnabled
            disabledScrollView = nil
        }

        private final class SheetOverlayView: UIView {
            var onLayout: (() -> Void)?

            override func layoutSubviews() {
                super.layoutSubviews()
                onLayout?()
            }
        }
    }
}

private enum StreamifySheetTimingParameters {
    static var opening: UITimingCurveProvider {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.22, y: 1),
            controlPoint2: CGPoint(x: 0.36, y: 1)
        )
    }

    static var closing: UITimingCurveProvider {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.4, y: 0),
            controlPoint2: CGPoint(x: 0.2, y: 1)
        )
    }
}
