import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit

/// A per-page view controller that exposes its index, so the generic
/// container can implement next/previous navigation.
protocol PaginatedPageVC: UIViewController {
    var pageIndex: Int { get }
}

/// Generic `UIPageViewController` wrapper used by the iOS comic reader. The
/// caller supplies a factory closure that builds the page VC for an index.
///
/// `layoutKey` is an opaque hash that, when changed, forces the displayed
/// page to be re-built (e.g. flipping single-page ↔ two-up, toggling trim,
/// or changing reading direction in the comic reader).
struct PaginatedContainer<PageVC: PaginatedPageVC>: UIViewControllerRepresentable {
    let pageCount: Int
    @Binding var currentPage: Int
    let pageStep: Int
    let backgroundColor: UIColor
    let interPageSpacing: CGFloat
    let supportsTrackpadPan: Bool
    let layoutKey: AnyHashable
    let onToggleChrome: () -> Void
    let makeViewController: (Int) -> PageVC?

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: interPageSpacing]
        )
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = backgroundColor

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        pageVC.view.addGestureRecognizer(singleTap)

        if supportsTrackpadPan {
            let trackpadPan = UIPanGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleTrackpadPan(_:)))
            trackpadPan.allowedScrollTypesMask = .continuous
            trackpadPan.maximumNumberOfTouches = 0
            pageVC.view.addGestureRecognizer(trackpadPan)
        }

        if let vc = makeViewController(currentPage) {
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }
        return pageVC
    }

    func updateUIViewController(_ pageVC: UIPageViewController, context: Context) {
        let coord = context.coordinator
        let oldKey = coord.layoutKey
        coord.pageCount = pageCount
        coord.pageStep = pageStep
        coord.layoutKey = layoutKey
        coord.onToggleChrome = onToggleChrome
        coord.makeViewController = makeViewController

        let displayedPage = coord.displayedPageIndex(from: pageVC)
        let layoutChanged = oldKey != layoutKey

        if displayedPage != currentPage || layoutChanged {
            if let vc = makeViewController(currentPage) {
                let direction: UIPageViewController.NavigationDirection =
                    currentPage > (displayedPage ?? 0) ? .forward : .reverse
                pageVC.setViewControllers([vc], direction: direction, animated: false)
            }
        }
        coord.currentPage = currentPage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pageCount: pageCount,
            currentPage: $currentPage,
            pageStep: pageStep,
            layoutKey: layoutKey,
            onToggleChrome: onToggleChrome,
            makeViewController: makeViewController
        )
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var pageCount: Int
        var currentPage: Int
        private var currentPageBinding: Binding<Int>
        var pageStep: Int
        var layoutKey: AnyHashable
        var onToggleChrome: () -> Void
        var makeViewController: (Int) -> PageVC?
        private var trackpadTriggered = false
        private var lastTapTime: TimeInterval = 0

        init(pageCount: Int,
             currentPage: Binding<Int>,
             pageStep: Int,
             layoutKey: AnyHashable,
             onToggleChrome: @escaping () -> Void,
             makeViewController: @escaping (Int) -> PageVC?) {
            self.pageCount = pageCount
            self.currentPage = currentPage.wrappedValue
            self.currentPageBinding = currentPage
            self.pageStep = pageStep
            self.layoutKey = layoutKey
            self.onToggleChrome = onToggleChrome
            self.makeViewController = makeViewController
        }

        func displayedPageIndex(from pageVC: UIPageViewController) -> Int? {
            (pageVC.viewControllers?.first as? PageVC)?.pageIndex
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageVC else { return nil }
            let prevIndex = vc.pageIndex - pageStep
            guard prevIndex >= 0 else { return nil }
            return makeViewController(prevIndex)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageVC else { return nil }
            let nextIndex = vc.pageIndex + pageStep
            guard nextIndex < pageCount else { return nil }
            return makeViewController(nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let vc = pageViewController.viewControllers?.first as? PageVC else { return }
            currentPage = vc.pageIndex
            currentPageBinding.wrappedValue = vc.pageIndex
        }

        // MARK: - Tap Zones

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            // Debounce: a single trackpad click can fire twice on iPadOS.
            let now = CACurrentMediaTime()
            guard now - lastTapTime > 0.2 else { return }
            lastTapTime = now
            let x = gesture.location(in: view).x
            let width = view.bounds.width
            if x < width / 3 {
                goToPrevious(in: view)
            } else if x > width * 2 / 3 {
                goToNext(in: view)
            } else {
                onToggleChrome()
            }
        }

        // MARK: - Trackpad Pan

        @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                trackpadTriggered = false
            case .changed:
                guard !trackpadTriggered else { return }
                let tx = gesture.translation(in: gesture.view).x
                if abs(tx) > 20 {
                    trackpadTriggered = true
                    if let view = gesture.view {
                        if tx < 0 { goToNext(in: view) } else { goToPrevious(in: view) }
                    }
                }
            default:
                break
            }
        }

        // MARK: - Programmatic Navigation (instant, no animation)

        private func goToNext(in view: UIView) {
            let nextIndex = currentPage + pageStep
            guard nextIndex < pageCount else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = makeViewController(nextIndex) else { return }
            currentPage = nextIndex
            currentPageBinding.wrappedValue = nextIndex
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }

        private func goToPrevious(in view: UIView) {
            let prevIndex = currentPage - pageStep
            guard prevIndex >= 0 else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = makeViewController(prevIndex) else { return }
            currentPage = prevIndex
            currentPageBinding.wrappedValue = prevIndex
            pageVC.setViewControllers([vc], direction: .reverse, animated: false)
        }

        private func findPageViewController(from view: UIView) -> UIPageViewController? {
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let pageVC = next as? UIPageViewController { return pageVC }
                responder = next
            }
            return nil
        }
    }
}
#endif
