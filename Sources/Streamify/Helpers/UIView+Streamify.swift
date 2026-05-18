import UIKit

extension UIView {
    func streamifyEnclosingScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let currentView = view {
            if let scrollView = currentView as? UIScrollView {
                return scrollView
            }
            view = currentView.superview
        }
        return nil
    }
}
