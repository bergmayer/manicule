import SwiftUI

#if os(iOS)
import UIKit

/// UIPageViewController-based container for paginated comic reading on iOS.
/// Provides interactive finger-tracking swipe, tap zones, trackpad support,
/// and per-page pinch-to-zoom.
struct PaginatedComicContainerView: UIViewControllerRepresentable {
    let pages: [URL]
    @Binding var currentPage: Int
    let twoUp: Bool
    let readingDirection: ComicArchive.ReadingDirection
    var trimWhitespace: Bool = false
    let onToggleChrome: () -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 2]
        )
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = .black

        // Single tap for zone detection
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        pageVC.view.addGestureRecognizer(singleTap)

        // Set initial page
        if let vc = context.coordinator.viewController(for: currentPage) {
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }

        return pageVC
    }

    func updateUIViewController(_ pageVC: UIPageViewController, context: Context) {
        let coord = context.coordinator
        let oldPages = coord.pages
        let oldTwoUp = coord.twoUp
        let oldDirection = coord.readingDirection
        let oldTrim = coord.trimWhitespace
        coord.pages = pages
        coord.twoUp = twoUp
        coord.readingDirection = readingDirection
        coord.trimWhitespace = trimWhitespace
        coord.onToggleChrome = onToggleChrome
        coord.currentPage = currentPage

        // If external state changed (toolbar button, arrow key), update the page VC
        let displayedPage = coord.displayedPageIndex(from: pageVC)
        let pagesChanged = oldPages.count != pages.count
        let modeChanged = oldTwoUp != twoUp || oldDirection != readingDirection || oldTrim != trimWhitespace

        if displayedPage != currentPage || pagesChanged || modeChanged {
            if let vc = coord.viewController(for: currentPage) {
                let direction: UIPageViewController.NavigationDirection =
                    currentPage > (displayedPage ?? 0) ? .forward : .reverse
                pageVC.setViewControllers([vc], direction: direction, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pages: pages,
            currentPage: $currentPage,
            twoUp: twoUp,
            readingDirection: readingDirection,
            trimWhitespace: trimWhitespace,
            onToggleChrome: onToggleChrome
        )
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var pages: [URL]
        var currentPage: Int
        private var currentPageBinding: Binding<Int>
        var twoUp: Bool
        var readingDirection: ComicArchive.ReadingDirection
        var trimWhitespace: Bool
        var onToggleChrome: () -> Void
        private var lastTapTime: TimeInterval = 0

        init(pages: [URL], currentPage: Binding<Int>, twoUp: Bool,
             readingDirection: ComicArchive.ReadingDirection, trimWhitespace: Bool, onToggleChrome: @escaping () -> Void) {
            self.pages = pages
            self.currentPage = currentPage.wrappedValue
            self.currentPageBinding = currentPage
            self.twoUp = twoUp
            self.readingDirection = readingDirection
            self.trimWhitespace = trimWhitespace
            self.onToggleChrome = onToggleChrome
        }

        private var pageStep: Int { twoUp ? 2 : 1 }

        func viewController(for pageIndex: Int) -> ComicPageZoomViewController? {
            guard pageIndex >= 0, pageIndex < pages.count else { return nil }
            if twoUp {
                let secondIndex = pageIndex + 1 < pages.count ? pageIndex + 1 : nil
                let leftURL: URL
                let rightURL: URL?
                if readingDirection == .leftToRight {
                    leftURL = pages[pageIndex]
                    rightURL = secondIndex.map { pages[$0] }
                } else {
                    leftURL = secondIndex.map { pages[$0] } ?? pages[pageIndex]
                    rightURL = secondIndex != nil ? pages[pageIndex] : nil
                }
                return ComicPageZoomViewController(
                    primaryImageURL: leftURL,
                    secondaryImageURL: rightURL,
                    pageIndex: pageIndex,
                    trimWhitespace: trimWhitespace
                )
            } else {
                return ComicPageZoomViewController(
                    primaryImageURL: pages[pageIndex],
                    secondaryImageURL: nil,
                    pageIndex: pageIndex,
                    trimWhitespace: trimWhitespace
                )
            }
        }

        func displayedPageIndex(from pageVC: UIPageViewController) -> Int? {
            guard let vc = pageVC.viewControllers?.first as? ComicPageZoomViewController else { return nil }
            return vc.pageIndex
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? ComicPageZoomViewController else { return nil }
            let prevIndex = vc.pageIndex - pageStep
            guard prevIndex >= 0 else { return nil }
            return self.viewController(for: prevIndex)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? ComicPageZoomViewController else { return nil }
            let nextIndex = vc.pageIndex + pageStep
            guard nextIndex < pages.count else { return nil }
            return self.viewController(for: nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let vc = pageViewController.viewControllers?.first as? ComicPageZoomViewController else { return }
            currentPage = vc.pageIndex
            currentPageBinding.wrappedValue = vc.pageIndex
        }

        // MARK: - Tap Zones

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            // Debounce: prevent a single trackpad click from firing twice
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

        // MARK: - Programmatic Navigation (instant, no animation)

        private func goToNext(in view: UIView) {
            let nextIndex = currentPage + pageStep
            guard nextIndex < pages.count else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = self.viewController(for: nextIndex) else { return }
            currentPage = nextIndex
            currentPageBinding.wrappedValue = nextIndex
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }

        private func goToPrevious(in view: UIView) {
            let prevIndex = currentPage - pageStep
            guard prevIndex >= 0 else { return }
            guard let pageVC = findPageViewController(from: view),
                  let vc = self.viewController(for: prevIndex) else { return }
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

/// View controller for a single comic page (or two-page spread) with pinch-to-zoom.
class ComicPageZoomViewController: UIViewController, UIScrollViewDelegate {
    let primaryImageURL: URL
    let secondaryImageURL: URL?
    let pageIndex: Int
    let trimWhitespace: Bool

    private var scrollView: UIScrollView!
    private var contentView: UIView!

    init(primaryImageURL: URL, secondaryImageURL: URL?, pageIndex: Int, trimWhitespace: Bool = false) {
        self.primaryImageURL = primaryImageURL
        self.secondaryImageURL = secondaryImageURL
        self.pageIndex = pageIndex
        self.trimWhitespace = trimWhitespace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView = UIScrollView()
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isScrollEnabled = false // Disabled at 1x so UIPageViewController gets swipes
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        // Build image stack
        let primaryImage = loadImage(from: primaryImageURL)
        let primaryImageView = UIImageView(image: primaryImage)
        primaryImageView.contentMode = .scaleAspectFit
        primaryImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(primaryImageView)

        if let secondaryURL = secondaryImageURL {
            let secondaryImage = loadImage(from: secondaryURL)
            let secondaryImageView = UIImageView(image: secondaryImage)
            secondaryImageView.contentMode = .scaleAspectFit
            secondaryImageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(secondaryImageView)

            // Two-up: side by side, each taking half width
            NSLayoutConstraint.activate([
                primaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                primaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                primaryImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                primaryImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),

                secondaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                secondaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                secondaryImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                secondaryImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),
            ])
        } else {
            // Single page: fill content view
            NSLayoutConstraint.activate([
                primaryImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                primaryImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                primaryImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                primaryImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        // Content view matches scroll view size at 1x
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap to toggle zoom
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ensure scroll view content resizes when the parent frame changes
        // (fixes black screen when UIPageViewController initially has zero frame)
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
    }

    private func loadImage(from url: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        guard trimWhitespace, let cgImage = image.cgImage else { return image }
        let trimmed = ContentTrimmer.shared.trimmed(cgImage, key: url.lastPathComponent)
        return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Enable panning when zoomed, disable at 1x to let UIPageViewController handle swipes
        scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scrollView.isScrollEnabled = scale > 1.01
    }

    // MARK: - Double-tap zoom

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: contentView)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }
}
#endif
